import 'dart:async';
import 'dart:typed_data';

import '../../../core/errors/app_exception.dart';
import '../../../core/isolates/cierre_z/cierre_z_models.dart'
    show CierreZResult;
import '../../../core/isolates/escpos/ticket_documents.dart';
import '../../../core/isolates/isolate_runner.dart';
import '../../../core/logging/app_logger.dart';
import '../../../core/money/money.dart';
import '../../../core/network/printing/raw_printer_transport.dart'
    show PrinterEndpoint;
import '../../sala/domain/comanda.dart';
import '../../sala/domain/linea_comanda.dart';
import '../../sala/domain/mesa.dart';
import '../../sala/domain/ticket.dart';
import '../domain/host_settings.dart';
import 'alert_bus.dart';
import 'ports.dart';
import 'sala_effects.dart';

/// Impresión ESC/POS del host: comandas de cocina/barra, tickets e informe Z.
///
/// Los bytes se generan en un isolate y se entregan a [PrinterPort] (la cola
/// de impresión, que serializa y reintenta). Un fallo de impresión nunca
/// se propaga al llamador: se convierte en aviso operativo.
///
/// Como [SalaEffects], imprime la comanda de cocina al aceptar líneas y el
/// ticket al cobrar (si `imprimirTicketAlCobrar`).
final class PrintingService extends SalaEffects {
  PrintingService({
    required this._alerts,
    required this._runner,
    required ImpresionSettings settings,
    required String nombreTpv,
    PrinterPort? printer,
    EmpresaTicket? empresa,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now {
    configurar(
      printer: printer,
      settings: settings,
      empresa: empresa,
      nombreTpv: nombreTpv,
    );
  }

  static final Logger _log = appLogger('host.impresion');

  final AlertBus _alerts;
  final IsolateRunner _runner;
  final DateTime Function() _now;
  ImpresionSettings _settings = const ImpresionSettings();
  String _nombreTpv = '';
  PrinterPort? _printer;
  EmpresaTicket? _empresa;
  final Set<Future<void>> _inFlight = {};

  ImpresionSettings get settings => _settings;

  /// Hay transporte y al menos una impresora configurada.
  bool get disponible => _printer != null && _settings.hayImpresora;

  void configurar({
    PrinterPort? printer,
    ImpresionSettings? settings,
    EmpresaTicket? empresa,
    String? nombreTpv,
  }) {
    _printer = printer ?? _printer;
    if (settings != null) _settings = settings;
    if (empresa != null) _empresa = empresa;
    if (nombreTpv != null) _nombreTpv = nombreTpv;
  }

  /// Completa cuando no queda ninguna impresión en curso (tests y cierre).
  Future<void> idle() async {
    while (_inFlight.isNotEmpty) {
      await Future.wait(_inFlight.toList());
    }
  }

  EmpresaTicket get _cabecera => _empresa ?? EmpresaTicket(nombre: _nombreTpv);

  /// Texto impreso de cada forma de cobro.
  static String formaDePago(MetodoPago metodo) => switch (metodo) {
    MetodoPago.efectivo => 'Efectivo',
    MetodoPago.tarjeta => 'Tarjeta',
  };

  // ---------------------------------------------------------------------------
  // Efectos de la sala

  @override
  Future<void> onLineasAceptadas(
    Mesa mesa,
    Comanda comanda,
    List<LineaComanda> nuevas,
  ) => imprimirComanda(mesa, comanda, nuevas, _now());

  @override
  Future<void> onLineasAnuladas(
    Mesa mesa,
    Comanda comanda,
    List<LineaComanda> anuladas,
  ) => imprimirAnulacion(mesa, comanda, anuladas, _now());

  @override
  Future<void> onMesaCobrada(Ticket ticket) async {
    if (_settings.imprimirTicketAlCobrar) await imprimirTicket(ticket);
  }

  // ---------------------------------------------------------------------------
  // Documentos

  /// Imprime las líneas nuevas divididas por destino de preparación: un
  /// ticket por puesto (cocina / barra) con solo sus líneas.
  ///
  /// Si un puesto no tiene impresora propia, su ticket sale por la del otro
  /// (ninguna línea se pierde), pero **sigue siendo un ticket aparte** con
  /// el título de su puesto y una indicación para llevarlo allí. Se prefiere
  /// a un único ticket con dos secciones porque en la cocina el ticket es la
  /// unidad de trabajo: se corta, se cuelga en el pase o se entrega al
  /// camarero de barra tal cual, sin que nadie tenga que separar a mano qué
  /// parte es de quién. La cola de impresión serializa los trabajos de una
  /// misma impresora, así que salen seguidos.
  Future<void> imprimirComanda(
    Mesa mesa,
    Comanda comanda,
    List<LineaComanda> nuevas,
    DateTime cuando,
  ) => _imprimirPorDestino(mesa, comanda, nuevas, cuando, anulacion: false);

  /// Imprime el aviso de anulación de [anuladas] en el puesto que las
  /// prepara: un ticket "ANULACIÓN COCINA/BARRA" con las líneas marcadas
  /// como anuladas, para que el puesto deje de prepararlas.
  Future<void> imprimirAnulacion(
    Mesa mesa,
    Comanda comanda,
    List<LineaComanda> anuladas,
    DateTime cuando,
  ) => _imprimirPorDestino(mesa, comanda, anuladas, cuando, anulacion: true);

  Future<void> _imprimirPorDestino(
    Mesa mesa,
    Comanda comanda,
    List<LineaComanda> lineas,
    DateTime cuando, {
    required bool anulacion,
  }) async {
    if (!_settings.imprimirComandas || !disponible || lineas.isEmpty) return;
    final porDestino = <DestinoPreparacion, List<LineaComanda>>{
      for (final destino in DestinoPreparacion.values) destino: [],
    };
    for (final linea in lineas) {
      porDestino[linea.destino]!.add(linea);
    }
    for (final MapEntry(key: destino, value: delDestino)
        in porDestino.entries) {
      if (delDestino.isEmpty) continue;
      final impresora = _settings.impresoraDe(destino);
      if (impresora == null) continue;
      final puesto = tituloPuesto(destino);
      // Cada puesto se aísla: un fallo no tipado (isolate que no arranca,
      // error de programación del builder...) al generar o encolar el
      // ticket de un puesto no debe impedir que salgan los de los demás.
      try {
        final data = KitchenOrderPrintData(
          titulo: anulacion ? 'ANULACIÓN $puesto' : puesto,
          mesa: mesa.nombre,
          camarero: comanda.camarero,
          fechaHora: cuando,
          numeroComanda: comanda.id.length > 8
              ? comanda.id.substring(0, 8)
              : comanda.id,
          lineas: [
            for (final l in delDestino)
              LineaComandaPrint(
                cantidad: l.cantidad,
                descripcion: l.descripcion,
                nota: anulacion ? _notaAnulacion(l) : l.nota,
                anulada: anulacion,
              ),
          ],
          observaciones: _observaciones(
            destino,
            respaldo: impresora.respaldo,
            anulacion: anulacion,
            deLaComanda: comanda.observaciones,
          ),
          paper: _settings.paper,
        );
        await _enviar(
          impresora.endpoint,
          '${anulacion ? 'Anulación' : 'Comanda'} ${mesa.nombre} · '
          '${destino.name}',
          () => generarComandaCocinaEnIsolate(data, runner: _runner),
        );
      } on Object catch (error, stackTrace) {
        final documento = anulacion ? 'la anulación' : 'la comanda';
        _log.warning(
          'Fallo inesperado al imprimir $documento de ${destino.name} '
          'de ${mesa.nombre}',
          error,
          stackTrace,
        );
        _alerts.error(
          'No se pudo imprimir $documento de ${puesto.toLowerCase()} '
          'de ${mesa.nombre}',
          detalle: error.toString(),
          origen: 'impresion',
        );
      }
    }
  }

  /// Título del puesto en los tickets de comanda.
  static String tituloPuesto(DestinoPreparacion destino) => switch (destino) {
    DestinoPreparacion.cocina => 'COCINA',
    DestinoPreparacion.barra => 'BARRA',
  };

  static String? _notaAnulacion(LineaComanda linea) {
    final motivo = switch (linea.motivoAnulacion?.trim()) {
      null || '' => null,
      'vaciar' => 'mesa vaciada',
      final String texto => texto,
    };
    return motivo == null ? linea.nota : 'Motivo: $motivo';
  }

  static String? _observaciones(
    DestinoPreparacion destino, {
    required bool respaldo,
    required bool anulacion,
    String? deLaComanda,
  }) {
    final puesto = tituloPuesto(destino).toLowerCase();
    final partes = [
      if (respaldo) 'Sin impresora de $puesto: llevar a $puesto',
      if (!anulacion && deLaComanda != null && deLaComanda.trim().isNotEmpty)
        deLaComanda.trim(),
    ];
    return partes.isEmpty ? null : partes.join(' · ');
  }

  /// Imprime el ticket (factura simplificada si ya tiene código de FS).
  Future<void> imprimirTicket(Ticket ticket, {bool reimpresion = false}) async {
    final endpoint = _settings.paraTickets;
    if (_printer == null || endpoint == null) {
      if (reimpresion) {
        throw const PrinterException('No hay impresora de tickets configurada');
      }
      return;
    }
    final factura = ticket.factura;
    final codigo = factura?.codigo;
    final data = TicketPrintData(
      empresa: _cabecera,
      tituloDocumento: codigo != null ? 'FACTURA SIMPLIFICADA' : 'TICKET',
      codigoFactura: codigo,
      numero2: ticket.claveFactura,
      fechaHora: ticket.fechaHora,
      mesa: ticket.nombreMesa,
      camarero: ticket.camarero,
      lineas: [
        for (final l in ticket.lineas)
          LineaTicket(
            descripcion: l.descripcion,
            cantidad: l.cantidad,
            pvpUnitarioCents: l.pvpUnitarioCents,
            importeCents: l.importeCents,
            nota: l.nota,
          ),
      ],
      desglose: [
        for (final d in ticket.totales.desglose)
          DesgloseIvaTicketPrint(
            ivaPct: basisPointsToPercent(d.ivaBp),
            baseCents: d.baseCents,
            cuotaCents: d.cuotaCents,
          ),
      ],
      totalCents: ticket.totalCents,
      metodoPago: ticket.esMixto ? 'Mixto' : formaDePago(ticket.metodoPago),
      // Pago único: sin desglose (el ticket sale exactamente como siempre).
      pagos: [
        if (ticket.esMixto)
          for (final pago in ticket.pagos)
            PagoTicketPrint(
              formaPago: formaDePago(pago.metodo),
              importeCents: pago.importeCents,
            ),
      ],
      entregadoCents: ticket.entregadoCents,
      cambioCents: ticket.entregadoCents == null ? null : ticket.cambioCents,
      avisos: [
        if (reimpresion) 'COPIA',
        if (factura?.estado == EstadoSincronizacion.error)
          'Factura pendiente de revisión',
      ],
      paper: _settings.paper,
      // El cajón se abre si parte del cobro (o todo) entra en caja.
      abrirCajon:
          !reimpresion &&
          _settings.abrirCajonEfectivo &&
          ticket.pagos.any((pago) => pago.metodo == MetodoPago.efectivo),
    );
    await _enviar(
      endpoint,
      'Ticket ${ticket.numeroLocal}${reimpresion ? ' (copia)' : ''}',
      () => generarTicketEnIsolate(data, runner: _runner),
    );
  }

  /// Imprime la precuenta de una mesa (cuenta provisional sin validez fiscal:
  /// sin número, sin forma de pago y sin abrir el cajón). Lanza
  /// [PrinterException] si no hay impresora de tickets, porque la pide el
  /// usuario y debe saber que no ha salido.
  Future<void> imprimirPrecuenta(
    Mesa mesa,
    Comanda comanda,
    TotalesTicket totales, {
    DateTime? cuando,
  }) async {
    final endpoint = _settings.paraTickets;
    if (_printer == null || endpoint == null) {
      throw const PrinterException('No hay impresora de tickets configurada');
    }
    final activas = comanda.lineasActivas.toList();
    if (activas.isEmpty) {
      throw const ValidationException(
        'La mesa no tiene líneas: no hay precuenta que imprimir',
      );
    }
    final data = PrecuentaPrintData(
      empresa: _cabecera,
      fechaHora: cuando ?? _now(),
      mesa: mesa.nombre,
      camarero: comanda.camarero,
      comensales: comanda.comensales,
      lineas: [
        for (final l in activas)
          LineaTicket(
            descripcion: l.descripcion,
            cantidad: l.cantidad,
            pvpUnitarioCents: l.pvpUnitarioCents,
            importeCents: l.importeCents,
            nota: l.nota,
          ),
      ],
      desglose: [
        for (final d in totales.desglose)
          DesgloseIvaTicketPrint(
            ivaPct: basisPointsToPercent(d.ivaBp),
            baseCents: d.baseCents,
            cuotaCents: d.cuotaCents,
          ),
      ],
      totalCents: totales.totalCents,
      paper: _settings.paper,
    );
    await _enviar(
      endpoint,
      'Precuenta ${mesa.nombre}',
      () => generarPrecuentaEnIsolate(data, runner: _runner),
    );
  }

  /// Imprime el informe del Cierre Z.
  Future<void> imprimirInformeZ(CierreZResult result) async {
    final endpoint = _settings.paraTickets;
    if (_printer == null || endpoint == null) return;
    final informe = result.informe;
    final data = ZReportPrintData(
      empresa: _cabecera,
      nombreTpv: _nombreTpv,
      fecha: informe.fecha,
      numTickets: informe.numTickets,
      numAnulados: informe.numAnulados,
      ventasTotalCents: informe.ventasTotalCents,
      ventasEfectivoCents: informe.ventasEfectivoCents,
      ventasTarjetaCents: informe.ventasTarjetaCents,
      ticketMedioCents: informe.ticketMedioCents,
      porIva: [
        for (final v in informe.porIva)
          DesgloseIvaTicketPrint(
            ivaPct: basisPointsToPercent(v.ivaBp),
            baseCents: v.baseCents,
            cuotaCents: v.cuotaCents,
          ),
      ],
      fondoCajaCents: informe.fondoCajaCents,
      retiradasCents: informe.retiradasCents,
      efectivoEsperadoCents: informe.efectivoEsperadoCents,
      efectivoContadoCents: informe.efectivoContadoCents,
      descuadreCents: informe.descuadreCents,
      partidas: [
        for (final p in result.asiento.partidas)
          (
            codsubcuenta: p.codsubcuenta,
            concepto: p.concepto,
            debeCents: p.debeCents,
            haberCents: p.haberCents,
          ),
      ],
      paper: _settings.paper,
    );
    await _enviar(
      endpoint,
      'Informe Z ${informe.idCierre}',
      () => generarInformeZEnIsolate(data, runner: _runner),
    );
  }

  // ---------------------------------------------------------------------------

  Future<void> _enviar(
    PrinterEndpoint endpoint,
    String description,
    Future<Uint8List> Function() generar,
  ) async {
    final printer = _printer;
    if (printer == null) return;
    final Uint8List bytes;
    try {
      bytes = await generar();
    } on AppException catch (error) {
      _alerts.error(
        'No se pudo generar "$description"',
        detalle: error.message,
        origen: 'impresion',
      );
      return;
    }
    final String jobId;
    try {
      jobId = printer.imprimir(endpoint, bytes, description: description);
    } on AppException catch (error) {
      _alerts.error(
        'No se pudo encolar "$description"',
        detalle: error.message,
        origen: 'impresion',
      );
      return;
    }
    _log.fine('Encolado "$description" → $endpoint ($jobId)');
    late final Future<void> seguimiento;
    seguimiento = printer
        .terminado(jobId)
        .then((error) {
          if (error != null) {
            _alerts.error(
              'Fallo de impresión: $description',
              detalle: '$endpoint: $error',
              origen: 'impresion',
            );
          }
        })
        .catchError((Object error) {
          _log.warning('Seguimiento de "$description" falló', error);
        })
        .whenComplete(() => _inFlight.remove(seguimiento));
    _inFlight.add(seguimiento);
  }
}
