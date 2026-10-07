import 'dart:async';

import '../../../core/errors/app_exception.dart';
import '../../../core/facturascripts/documents/invoice_models.dart';
import '../../../core/facturascripts/master_data/fs_master_models.dart';
import '../../../core/logging/app_logger.dart';
import '../../../core/utils/json_map.dart';
import '../../sala/domain/linea_comanda.dart';
import '../../sala/domain/ticket.dart';
import '../domain/host_settings.dart';
import '../domain/host_snapshot.dart';
import '../domain/sync_job.dart';
import 'alert_bus.dart';
import 'host_state_store.dart';
import 'ports.dart';
import 'printing_service.dart';
import 'sala_effects.dart';
import 'sync_outbox.dart';

/// Facturación de tickets en FacturaScripts.
///
/// Al cobrar una mesa encola un trabajo `factura` autosuficiente (el ticket
/// completo va en el payload: debe poder facturarse aunque el turno ya se
/// haya cerrado) en la MISMA escritura del diario que archiva el ticket
/// ([alCobrar]); al arrancar, [reconciliar] encola los tickets pendientes
/// que se hubieran quedado sin trabajo. El ejecutor construye el [TicketFactura] y delega en
/// [InvoicePort] (idempotente por `numero2 = ticket.claveFactura`); el
/// resultado se vuelca en `Ticket.factura` del diario local.
final class BillingService extends SalaEffects {
  BillingService({
    required this._store,
    required this._alerts,
    required this._outbox,
    required this._printing,
    required FiscalSettings fiscal,
    InvoicePort? invoice,
    MasterDataPort? masterData,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now {
    configurar(fiscal: fiscal, invoice: invoice, masterData: masterData);
    _outbox.registerHandler(SyncJobTipo.factura, ejecutar);
    _terminados = _outbox.terminados.listen(_onJobTerminado);
  }

  static final Logger _log = appLogger('host.facturacion');

  final HostStateStore _store;
  final AlertBus _alerts;
  final SyncOutbox _outbox;
  final PrintingService _printing;
  final DateTime Function() _now;
  late StreamSubscription<SyncJob> _terminados;

  FiscalSettings _fiscal = const FiscalSettings(
    codcliente: '',
    codpagoEfectivo: '',
    codpagoTarjeta: '',
    codalmacen: '',
  );
  InvoicePort? _invoice;
  MasterDataPort? _masterData;

  /// `pagado` de cada forma de pago (`codpago` → nace pagada).
  Map<String, bool>? _formasPago;
  int? _idEstadoEmitida;
  bool _estadoEmitidaBuscado = false;

  /// `codimpuesto` por defecto de los ajustes del ERP (caché).
  String? _codimpuestoErp;
  bool _codimpuestoErpBuscado = false;

  FiscalSettings get fiscal => _fiscal;

  /// Hay ERP y configuración fiscal suficiente para facturar.
  bool get disponible => _invoice != null && _fiscal.completa;

  /// Reconfigura en caliente. Los ajustes nulos se conservan; los puertos se
  /// sustituyen siempre (nulo = sin ERP / sin MySQL).
  void configurar({
    FiscalSettings? fiscal,
    InvoicePort? invoice,
    MasterDataPort? masterData,
  }) {
    if (fiscal != null) _fiscal = fiscal;
    _invoice = invoice;
    _masterData = masterData;
    _formasPago = null;
    _idEstadoEmitida = null;
    _estadoEmitidaBuscado = false;
    _codimpuestoErp = null;
    _codimpuestoErpBuscado = false;
  }

  /// Identificador del trabajo de factura de un ticket.
  static String jobIdDe(String ticketId) => 'factura:$ticketId';

  // ---------------------------------------------------------------------------
  // Efectos de la sala

  @override
  HostSnapshot alCobrar(HostSnapshot snapshot, Ticket ticket) =>
      _outbox.encolarEn(snapshot, SyncJobTipo.factura, {
        'ticket': ticket.toJson(),
      }, id: jobIdDe(ticket.id));

  /// Red de seguridad: el trabajo ya se guardó con el ticket ([alCobrar]);
  /// `enqueue` es idempotente por id.
  @override
  Future<void> onMesaCobrada(Ticket ticket) async {
    await _outbox.enqueue(SyncJobTipo.factura, {
      'ticket': ticket.toJson(),
    }, id: jobIdDe(ticket.id));
  }

  /// Encola la factura de cada ticket del turno que sigue `pendiente` y no
  /// tiene trabajo en la cola (p. ej. un diario de una versión anterior que
  /// guardaba el ticket y el trabajo por separado y se cortó entre ambos).
  /// Idempotente. Devuelve cuántos trabajos encoló.
  Future<int> reconciliar() async {
    var encolados = 0;
    for (final ticket in _store.snapshot.ticketsTurno) {
      if (ticket.factura?.estado != EstadoSincronizacion.pendiente) continue;
      final id = jobIdDe(ticket.id);
      if (_store.snapshot.jobPorId(id) != null) continue;
      await _outbox.enqueue(SyncJobTipo.factura, {
        'ticket': ticket.toJson(),
      }, id: id);
      encolados++;
    }
    if (encolados > 0) {
      _log.warning('$encolados tickets sin trabajo de factura: encolados');
      _alerts.aviso(
        'Facturas recuperadas',
        detalle:
            '$encolados tickets cobrados no tenían su factura en la cola; '
            'se han vuelto a encolar.',
        origen: 'facturacion',
      );
    }
    return encolados;
  }

  // ---------------------------------------------------------------------------
  // Operaciones para la UI

  /// Reimprime el ticket (con el código de factura si ya existe).
  ///
  /// Lanza [ValidationException] si el ticket no está en el turno y
  /// [PrinterException] si no hay impresora.
  Future<void> reimprimir(String ticketId) async {
    final ticket = _store.snapshot.ticketPorId(ticketId);
    if (ticket == null) {
      throw ValidationException('El ticket $ticketId no está en el turno');
    }
    await _printing.imprimirTicket(ticket, reimpresion: true);
  }

  /// Vuelve a intentar la factura de un ticket rechazado.
  Future<void> reintentarFactura(String ticketId) =>
      _outbox.reintentar(jobIdDe(ticketId));

  // ---------------------------------------------------------------------------
  // Ejecutor del trabajo `factura`

  Future<List<String>> ejecutar(SyncJob job) async {
    final invoice = _invoice;
    if (invoice == null) {
      throw const ConfigException('ERP no configurado: factura pendiente');
    }
    if (!_fiscal.completa) {
      throw const ConfigException(
        'Faltan datos fiscales (cliente, serie, formas de pago o almacén)',
      );
    }
    final Ticket ticket;
    try {
      ticket = Ticket.fromJson(job.payload.requireMap('ticket'));
    } on FormatException catch (error) {
      throw ValidationException(
        'Trabajo de factura ${job.id} corrupto: ${error.message}',
        cause: error,
      );
    }

    final avisos = <String>[];
    var codpago = _codpagoDe(ticket.metodoPago);
    var modoPago = await _modoPago(codpago, avisos);
    // Cobro mixto: un pago por forma de pago, cada uno con el modo de su
    // `formapagos.pagado`.
    final pagos = <PagoFactura>[];
    if (ticket.esMixto) {
      final modos = <String, ModoPago>{codpago: modoPago};
      for (final pago in ticket.pagos) {
        final cod = _codpagoDe(pago.metodo);
        final modo = modos[cod] ??= await _modoPago(cod, avisos);
        pagos.add(
          PagoFactura(
            codpago: cod,
            importeCents: pago.importeCents,
            modoPago: modo,
            efectivo: pago.metodo == MetodoPago.efectivo,
          ),
        );
      }
      // Cabecera (recibo n.º 1): la forma principal si NO nace pagada; si
      // nace pagada, la primera que no lo haga. Así el recibo automático de
      // `crearFacturaCliente` nace abierto y se ajusta con un PUT. Con una
      // forma pagado=1 nacería cobrado por el total y habría que borrarlo con
      // su pago y su asiento (hueco en la numeración de asientos). Solo si
      // todas nacen pagadas se mantiene la principal y se asume ese coste.
      if (modoPago == ModoPago.nacePagada) {
        for (final pago in pagos) {
          if (pago.importeCents > 0 &&
              pago.modoPago == ModoPago.pagarTrasCrear) {
            codpago = pago.codpago;
            modoPago = pago.modoPago;
            break;
          }
        }
      }
    }
    var emitir = _fiscal.emitirFacturas;
    int? idEstadoEmitida;
    if (emitir) {
      idEstadoEmitida = await _resolverEstadoEmitida();
      if (idEstadoEmitida == null) {
        emitir = false;
        avisos.add(
          'No se encontró el estado "Emitida" en FacturaScripts: la factura '
          'queda en el estado por defecto',
        );
      }
    }

    final lineas = <LineaFactura>[
      for (final l in ticket.lineas)
        LineaFactura(
          referencia: l.referencia,
          descripcion: l.descripcion,
          cantidad: l.cantidad,
          pvpunitarioNeto: l.pvpUnitarioNeto,
          codimpuesto: l.codimpuesto ?? await _codimpuestoRespaldo(l),
        ),
    ];
    final factura = TicketFactura(
      claveIdempotente: ticket.claveFactura,
      codcliente: _fiscal.codcliente,
      codserie: _fiscal.codserie,
      codpago: codpago,
      codalmacen: _fiscal.codalmacen,
      fechaHora: ticket.fechaHora,
      observaciones: [
        'TPV ticket ${ticket.numeroLocal}',
        'Mesa ${ticket.nombreMesa}',
        if (ticket.camarero case final c?) 'Camarero $c',
      ].join(' · '),
      lineas: lineas,
      totalEsperadoCents: ticket.totalCents,
      modoPago: modoPago,
      pagos: pagos,
      emitir: emitir,
      idEstadoEmitida: idEstadoEmitida,
    );

    final resultado = await invoice.crearOReanudar(factura);
    avisos.addAll(resultado.avisos);
    final sincronizada = FacturaSincronizada(
      estado: EstadoSincronizacion.sincronizado,
      idfactura: resultado.idfactura,
      codigo: resultado.codigo,
      numero: int.tryParse(resultado.numero),
      idasiento: resultado.idasiento,
      pagada: resultado.pagada,
      emitida: resultado.emitida,
      avisos: avisos,
      actualizadoEn: _now(),
    );
    await _actualizarTicket(ticket.id, sincronizada);
    _log.info(
      'Ticket ${ticket.numeroLocal} facturado como ${resultado.codigo}'
      '${resultado.yaExistia ? ' (ya existía)' : ''}',
    );
    return avisos;
  }

  /// Impuesto de una línea que llegó sin `codimpuesto`: el del artículo en
  /// el catálogo del host, el de los ajustes fiscales o el por defecto del
  /// ERP (el mismo con el que el catálogo calculó su IVA). Nunca `''`: si no
  /// hay ninguno, [ConfigException] (pausa las facturas hasta corregirlo).
  Future<String> _codimpuestoRespaldo(LineaComanda linea) async {
    final catalogo = _store.snapshot.catalogo?.porReferencia(linea.referencia);
    final candidato =
        _noVacio(catalogo?.codimpuesto) ??
        _noVacio(_fiscal.codimpuestoPorDefecto) ??
        await _codimpuestoPorDefectoErp();
    if (candidato != null) return candidato;
    throw ConfigException(
      "No se sabe con qué impuesto facturar '${linea.referencia}': "
      'configura el impuesto por defecto en los ajustes fiscales o en '
      'FacturaScripts',
    );
  }

  Future<String?> _codimpuestoPorDefectoErp() async {
    if (_codimpuestoErpBuscado) return _codimpuestoErp;
    final masterData = _masterData;
    if (masterData == null) return null;
    final ajustes = await masterData.settingsDefault();
    _codimpuestoErp = _noVacio(ajustes.codimpuesto);
    _codimpuestoErpBuscado = true;
    return _codimpuestoErp;
  }

  /// `codpago` de FacturaScripts de cada forma de cobro (ajustes fiscales).
  String _codpagoDe(MetodoPago metodo) => switch (metodo) {
    MetodoPago.efectivo => _fiscal.codpagoEfectivo,
    MetodoPago.tarjeta => _fiscal.codpagoTarjeta,
  };

  static String? _noVacio(String? value) =>
      value == null || value.trim().isEmpty ? null : value;

  Future<ModoPago> _modoPago(String codpago, List<String> avisos) async {
    var formas = _formasPago;
    final masterData = _masterData;
    if (formas == null && masterData != null) {
      final lista = await masterData.formasPago();
      formas = _formasPago = {for (final f in lista) f.codpago: f.pagado};
    }
    if (formas == null) return ModoPago.pagarTrasCrear;
    final pagado = formas[codpago];
    if (pagado == null) {
      avisos.add("La forma de pago '$codpago' no existe en FacturaScripts");
      return ModoPago.pagarTrasCrear;
    }
    return pagado ? ModoPago.nacePagada : ModoPago.pagarTrasCrear;
  }

  Future<int?> _resolverEstadoEmitida() async {
    if (_estadoEmitidaBuscado) return _idEstadoEmitida;
    final masterData = _masterData;
    if (masterData == null) return null;
    final estados = await masterData.estadosFactura();
    _idEstadoEmitida = _estadoEmitida(estados)?.idestado;
    _estadoEmitidaBuscado = true;
    return _idEstadoEmitida;
  }

  /// Estado "Emitida": por nombre o, si no, el primer estado activo no
  /// editable que no sea el predeterminado.
  static FsEstadoDocumento? _estadoEmitida(List<FsEstadoDocumento> estados) {
    for (final e in estados) {
      if (e.nombre.trim().toLowerCase() == 'emitida' && e.activo) return e;
    }
    for (final e in estados) {
      if (!e.editable && !e.predeterminado && e.activo) return e;
    }
    return null;
  }

  Future<void> _actualizarTicket(
    String ticketId,
    FacturaSincronizada factura,
  ) async {
    final ticket = _store.snapshot.ticketPorId(ticketId);
    if (ticket == null) {
      _log.info('Ticket $ticketId ya no está en el turno; factura $factura');
      return;
    }
    await _store.update((s) => s.conTicket(ticket.conFactura(factura)));
  }

  void _onJobTerminado(SyncJob job) {
    if (job.tipo != SyncJobTipo.factura || job.estado != SyncJobEstado.error) {
      return;
    }
    final ticketJson = job.payload['ticket'];
    if (ticketJson is! Map<String, Object?>) return;
    final id = ticketJson['id'];
    if (id is! String) return;
    unawaited(
      _actualizarTicket(
        id,
        FacturaSincronizada(
          estado: EstadoSincronizacion.error,
          error: job.ultimoError,
          actualizadoEn: _now(),
        ),
      ).catchError((Object error, StackTrace stackTrace) {
        _log.warning('No se pudo marcar el ticket $id en error', error);
        _alerts.aviso(
          'No se pudo anotar el rechazo de la factura del ticket',
          detalle: error.toString(),
          origen: 'facturacion',
        );
      }),
    );
  }

  Future<void> dispose() => _terminados.cancel();
}
