import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:uuid/uuid.dart';

import '../../../core/errors/app_exception.dart';
import '../../../core/facturascripts/accounting/accounting_models.dart';
import '../../../core/isolates/cierre_z/cierre_z_engine.dart'
    show calcularCierreZEnIsolate;
import '../../../core/isolates/cierre_z/cierre_z_models.dart' as cz;
import '../../../core/isolates/isolate_runner.dart';
import '../../../core/logging/app_logger.dart';
import '../../../core/money/money.dart';
import '../../../core/utils/json_map.dart';
import '../../../core/utils/streams.dart';
import '../../sala/domain/ticket.dart';
import '../domain/host_settings.dart';
import '../domain/host_snapshot.dart';
import '../domain/sync_job.dart';
import 'alert_bus.dart';
import 'billing_service.dart';
import 'host_state_store.dart';
import 'ports.dart';
import 'printing_service.dart';
import 'sync_outbox.dart';

const Uuid _uuid = Uuid();

/// Informe y asiento propuestos para el cierre, con la valoración de si el
/// asiento puede contabilizarse en el ERP.
final class CierreZPreview extends Equatable {
  const CierreZPreview({
    required this.result,
    required this.asientoContabilizable,
    this.motivoNoContabilizable,
  });

  final cz.CierreZResult result;

  /// Las subcuentas se resolvieron en el ERP y el asiento tiene partidas.
  final bool asientoContabilizable;

  /// Por qué no se contabilizará (ERP sin configurar, ejercicio cerrado,
  /// asiento vacío...).
  final String? motivoNoContabilizable;

  cz.InformeCierreZ get informe => result.informe;
  cz.AsientoPropuesto get asiento => result.asiento;

  @override
  List<Object?> get props => [
    result,
    asientoContabilizable,
    motivoNoContabilizable,
  ];
}

/// Turno de caja y Cierre Z.
///
/// El informe y el asiento los calcula el motor de `core/isolates/cierre_z`
/// con los tickets del turno. Al cerrar se archiva el resumen (con las
/// precuentas de las mesas vaciadas sin cobrar), se vacían los tickets del
/// turno, se reinicia el nº de envío, se encola el asiento (si procede) y se
/// imprime el informe. El asiento se contabiliza con [AccountingPort] de
/// forma idempotente (clave `documento`).
final class CierreZService {
  CierreZService({
    required this._store,
    required this._alerts,
    required this._outbox,
    required this._printing,
    required this._runner,
    required CierreSettings cierre,
    required FiscalSettings fiscal,
    required String nombreTpv,
    AccountingPort? accounting,
    DateTime Function()? now,
    String Function()? newId,
  }) : _now = now ?? DateTime.now,
       _newId = newId ?? _uuid.v4 {
    configurar(
      cierre: cierre,
      fiscal: fiscal,
      accounting: accounting,
      nombreTpv: nombreTpv,
    );
    _outbox.registerHandler(SyncJobTipo.asientoZ, ejecutarAsiento);
  }

  static final Logger _log = appLogger('host.cierre');

  final HostStateStore _store;
  final AlertBus _alerts;
  final SyncOutbox _outbox;
  final PrintingService _printing;
  final IsolateRunner _runner;
  final DateTime Function() _now;
  final String Function() _newId;
  final StreamController<ResumenCierre> _cierres =
      StreamController<ResumenCierre>.broadcast();

  CierreSettings _cierre = const CierreSettings();
  FiscalSettings _fiscal = const FiscalSettings(
    codcliente: '',
    codpagoEfectivo: '',
    codpagoTarjeta: '',
    codalmacen: '',
  );
  String _nombreTpv = '';
  AccountingPort? _accounting;
  Future<ResumenCierre>? _cerrando;

  CierreAbierto? get turno => _store.snapshot.cierreAbierto;
  List<Ticket> get ticketsTurno => _store.snapshot.ticketsTurno;

  /// Hay un turno abierto o tickets por cerrar (si no, [cerrar] lo rechaza).
  bool get hayAlgoQueCerrar => turno != null || ticketsTurno.isNotEmpty;
  List<ResumenCierre> get historial => _store.snapshot.historialCierres;

  /// Cierres completados (para encadenar la auditoría de reposición).
  Stream<ResumenCierre> get cierres => _cierres.stream;

  /// Reconfigura en caliente. Los ajustes nulos se conservan; los puertos se
  /// sustituyen siempre (nulo = sin ERP / sin MySQL).
  void configurar({
    CierreSettings? cierre,
    FiscalSettings? fiscal,
    AccountingPort? accounting,
    String? nombreTpv,
  }) {
    if (cierre != null) _cierre = cierre;
    if (fiscal != null) _fiscal = fiscal;
    if (nombreTpv != null) _nombreTpv = nombreTpv;
    _accounting = accounting;
  }

  // ---------------------------------------------------------------------------
  // Turno

  /// Abre el turno con un fondo de caja. Lanza [ValidationException] si ya
  /// hay uno abierto o el fondo es negativo.
  Future<CierreAbierto> iniciarTurno(int fondoCajaCents) async {
    if (fondoCajaCents < 0) {
      throw const ValidationException('El fondo de caja no puede ser negativo');
    }
    if (turno != null) {
      throw const ValidationException('Ya hay un turno abierto');
    }
    final nuevo = CierreAbierto(
      id: _newId(),
      abiertoEn: _now(),
      fondoCajaCents: fondoCajaCents,
    );
    await _store.update((s) => s.copyWith(cierreAbierto: nuevo));
    _log.info('Turno ${nuevo.id} abierto con ${formatCents(fondoCajaCents)}');
    return nuevo;
  }

  /// Anota una retirada de efectivo. Si no hay turno abierto lo abre con
  /// fondo cero.
  Future<CierreAbierto> registrarRetirada(int importeCents) async {
    if (importeCents <= 0) {
      throw const ValidationException('La retirada debe ser positiva');
    }
    final actual = turno ?? await _abrirImplicito();
    final actualizado = actual.conRetirada(importeCents);
    await _store.update((s) => s.copyWith(cierreAbierto: actualizado));
    return actualizado;
  }

  // ---------------------------------------------------------------------------
  // Cierre

  /// Calcula informe y asiento sin cerrar nada.
  Future<CierreZPreview> previsualizar({int? efectivoContadoCents}) =>
      _calcular(turno ?? _turnoImplicito(), ticketsTurno, efectivoContadoCents);

  /// Cierra el turno: archiva el resumen, retira del turno los tickets que
  /// entraron en el informe, encola el asiento si tiene partidas y se pudo
  /// resolver, imprime el informe Z. Devuelve (y emite en [cierres]) el
  /// resumen tal como queda archivado: el primero de [historial].
  ///
  /// En la misma escritura del diario que archiva el resumen, el nº de envío
  /// vuelve a 1 y las precuentas de las mesas vaciadas sin cobrar pasan de
  /// `HostSnapshot.precuentasSinCobro` a [ResumenCierre.precuentasSinCobro].
  /// Se leen dentro de esa escritura: una mesa vaciada mientras se calculaba
  /// el cierre entra en este Z. Las comandas abiertas conservan sus números
  /// de envío y sus precuentas.
  ///
  /// Los tickets cobrados (y las retiradas anotadas) mientras se calculaba
  /// el cierre no entran en este Z y se quedan para el siguiente turno. Dos
  /// llamadas simultáneas (doble toque) comparten el mismo cierre.
  ///
  /// En modo `resumenCompleto` comprueba antes que ninguna factura de los
  /// días del turno tenga asiento ni esté pendiente de sincronizar
  /// (duplicaría ventas e IVA); si lo tienen o no se puede comprobar, el
  /// asiento no se encola y se avisa.
  Future<ResumenCierre> cerrar({required int efectivoContadoCents}) {
    if (efectivoContadoCents < 0) {
      return Future<ResumenCierre>.error(
        const ValidationException('El efectivo contado no puede ser negativo'),
      );
    }
    // Un doble toque comparte el cierre en curso; un cierre repetido tras
    // terminar el anterior no tiene turno ni tickets y se rechaza (archivaría
    // un Z vacío con el fondo que queda en caja como sobrante).
    final enCurso = _cerrando;
    if (enCurso != null) return enCurso;
    if (!hayAlgoQueCerrar) {
      return Future<ResumenCierre>.error(
        const ValidationException('No hay turno ni tickets que cerrar'),
      );
    }
    return _cerrando ??= _cerrar(efectivoContadoCents)
        .whenComplete(() => _cerrando = null);
  }

  Future<ResumenCierre> _cerrar(int efectivoContadoCents) async {
    final abierto = turno ?? _turnoImplicito();
    final tickets = ticketsTurno;
    final preview = await _calcular(abierto, tickets, efectivoContadoCents);
    final informe = preview.informe;
    final asiento = preview.asiento;

    var contabilizar = preview.asientoContabilizable;
    var motivo = preview.motivoNoContabilizable;
    final resumenCompleto =
        _cierre.modoAsientoZ == cz.ModoAsientoZ.resumenCompleto;
    final fechas = _fechasDe(tickets, informe.fecha);
    if (contabilizar && resumenCompleto) {
      final bloqueo = await _comprobarDuplicidad(
        fechas,
        ticketIds: [for (final t in tickets) t.id],
        facturasSincronizadas: tickets.every(
          (t) => t.factura?.estado == EstadoSincronizacion.sincronizado,
        ),
      );
      if (bloqueo != null) {
        contabilizar = false;
        motivo = bloqueo;
      }
    }

    final resumen = ResumenCierre(
      id: abierto.id,
      abiertoEn: abierto.abiertoEn,
      cerradoEn: _now(),
      numTickets: informe.numTickets,
      numAnulados: informe.numAnulados,
      ventasTotalCents: informe.ventasTotalCents,
      ventasEfectivoCents: informe.ventasEfectivoCents,
      ventasTarjetaCents: informe.ventasTarjetaCents,
      numTicketsMixtos: informe.numTicketsMixtos,
      fondoCajaCents: informe.fondoCajaCents,
      retiradasCents: informe.retiradasCents,
      efectivoEsperadoCents: informe.efectivoEsperadoCents,
      efectivoContadoCents: informe.efectivoContadoCents,
      descuadreCents: informe.descuadreCents,
      documentoAsiento: asiento.vacio ? null : asiento.documento,
      asientoEncolado: contabilizar,
    );

    final incluidos = {for (final t in tickets) t.id};
    // El cierre archivado y su asiento se guardan en la misma escritura, con
    // el reinicio del nº de envío y las precuentas sin cobro, que se leen
    // aquí dentro para no perder las de una mesa vaciada durante el cálculo.
    late final ResumenCierre archivado;
    await _store.update((s) {
      final actual = s.cierreAbierto;
      // Turno que sigue tras el cierre: el abierto durante el cálculo, o uno
      // implícito con las retiradas anotadas mientras se calculaba.
      CierreAbierto? siguiente;
      if (actual != null && actual.id != abierto.id) {
        siguiente = actual;
      } else if (actual != null &&
          actual.retiradasCents > abierto.retiradasCents) {
        siguiente = CierreAbierto(
          id: _newId(),
          abiertoEn: resumen.cerradoEn,
          fondoCajaCents: 0,
          retiradasCents: actual.retiradasCents - abierto.retiradasCents,
        );
      }
      archivado = resumen.copyWith(precuentasSinCobro: s.precuentasSinCobro);
      final cerrado = s.copyWith(
        ticketsTurno: [
          for (final t in s.ticketsTurno)
            if (!incluidos.contains(t.id)) t,
        ],
        cerrarTurno: siguiente == null,
        cierreAbierto: siguiente,
        historialCierres: [
          archivado,
          ...s.historialCierres.take(HostSnapshot.maxHistorialCierres - 1),
        ],
        numeroEnvioSiguiente: 1,
        precuentasSinCobro: const [],
      );
      if (!contabilizar) return cerrado;
      return _outbox.encolarEn(cerrado, SyncJobTipo.asientoZ, {
        ..._asientoAJson(asiento),
        if (resumenCompleto) ...{
          'modo': cz.ModoAsientoZ.resumenCompleto.name,
          'fechasTickets': [for (final f in fechas) f.toIso8601String()],
          'ticketIds': [for (final t in tickets) t.id],
        },
      }, id: 'asientoZ:${asiento.documento}');
    });
    _log.info(
      'Cierre ${resumen.id}: ${informe.numTickets} tickets, '
      '${formatCents(informe.ventasTotalCents)}, descuadre '
      '${formatCents(informe.descuadreCents)}, '
      '${archivado.precuentasSinCobro.length} precuentas sin cobro',
    );

    if (contabilizar) {
      _log.info('Asiento ${asiento.documento} encolado');
    } else if (asiento.vacio) {
      _alerts.info(
        'Cierre Z sin descuadre: nada que contabilizar',
        origen: 'cierre',
      );
    } else {
      _alerts.aviso(
        'El asiento del Cierre Z no se contabiliza',
        detalle: motivo,
        origen: 'cierre',
      );
    }

    await _printing.imprimirInformeZ(
      preview.result,
      precuentasSinCobro: archivado.precuentasSinCobro,
    );
    if (!_cierres.isClosed) _cierres.add(archivado);
    return archivado;
  }

  // ---------------------------------------------------------------------------
  // Ejecutor del trabajo `asientoZ`

  Future<List<String>> ejecutarAsiento(SyncJob job) async {
    final accounting = _accounting;
    if (accounting == null) {
      throw const ConfigException('ERP no configurado: asiento Z pendiente');
    }
    final AsientoZ asiento;
    final List<DateTime>? fechasTickets;
    final List<String> ticketIds;
    try {
      asiento = _asientoDeJson(job.payload);
      final resumenCompleto =
          job.payload.optionalString('modo') ==
          cz.ModoAsientoZ.resumenCompleto.name;
      fechasTickets = resumenCompleto
          ? [
              for (final f in job.payload.optionalList('fechasTickets') ?? [])
                DateTime.parse(f.toString()),
            ]
          : null;
      ticketIds = [
        for (final id in job.payload.optionalList('ticketIds') ?? [])
          id.toString(),
      ];
    } on FormatException catch (error) {
      throw ValidationException(
        'Trabajo de asiento ${job.id} corrupto: ${error.message}',
        cause: error,
      );
    }
    if (fechasTickets != null) {
      // Resumen completo: se repite la comprobación justo antes de
      // contabilizar (las facturas pueden haberse sincronizado después del
      // cierre y haber generado ya su propio asiento).
      final bloqueo = await _comprobarDuplicidad(
        fechasTickets.isEmpty ? [asiento.fecha] : fechasTickets,
        ticketIds: ticketIds,
        facturasSincronizadas: true,
        propagarErrores: true,
      );
      if (bloqueo != null) {
        throw ValidationException('Asiento Z no contabilizado: $bloqueo');
      }
    }
    final resultado = await accounting.contabilizarOReanudar(asiento);
    _log.info(
      'Asiento ${asiento.clave} → idasiento ${resultado.idasiento}'
      '${resultado.yaExistia ? ' (ya existía)' : ''}',
    );
    return [
      if (!resultado.verificado)
        'El asiento ${resultado.idasiento} se creó pero no se pudo verificar',
    ];
  }

  // ---------------------------------------------------------------------------
  // Internos

  Future<CierreZPreview> _calcular(
    CierreAbierto abierto,
    List<Ticket> tickets,
    int? efectivoContadoCents,
  ) async {
    final fecha = _now();
    final (cuentas, motivo) = await _cuentas(fecha);
    final request = cz.CierreZRequest(
      idCierre: abierto.id,
      fecha: fecha,
      tickets: [for (final t in tickets) _ticketCierre(t)],
      fondoCajaCents: abierto.fondoCajaCents,
      efectivoContadoCents: efectivoContadoCents,
      retiradasCents: abierto.retiradasCents,
      modo: _cierre.modoAsientoZ,
      cuentas: cuentas,
      nombreTpv: _nombreTpv,
    );
    final result = await calcularCierreZEnIsolate(request, runner: _runner);
    final vacio = result.asiento.vacio;
    return CierreZPreview(
      result: result,
      asientoContabilizable: motivo == null && !vacio,
      motivoNoContabilizable:
          motivo ?? (vacio ? 'Sin descuadre: asiento vacío' : null),
    );
  }

  /// Subcuentas reales del ejercicio o, si no se pueden resolver, las
  /// cuentas genéricas (para que el informe salga igualmente) y el motivo.
  Future<(cz.CuentasCierre, String?)> _cuentas(DateTime fecha) async {
    final accounting = _accounting;
    if (accounting == null) {
      return (_cuentasGenericas(), 'ERP no configurado');
    }
    try {
      final s = await accounting.resolverSubcuentas(
        fecha,
        idempresa: _fiscal.idempresa,
        overrides: _cierre.overridesSubcuentas,
      );
      return (
        cz.CuentasCierre(
          subcuentaCaja: s[CuentaZ.caja570],
          subcuentaBanco: s[CuentaZ.banco572],
          subcuentaVentas: s[CuentaZ.ventas700],
          subcuentaIvaGenerica: s[CuentaZ.ivaRepercutido477],
          subcuentaIvaPorCodimpuesto: s.ivaPorCodimpuesto,
          subcuentaPerdidas: s[CuentaZ.perdidas659],
          subcuentaIngresos: s[CuentaZ.ingresos759],
        ),
        null,
      );
    } on AppException catch (error) {
      _log.warning('No se pudieron resolver las subcuentas', error);
      return (_cuentasGenericas(), error.message);
    }
  }

  static cz.CuentasCierre _cuentasGenericas() => cz.CuentasCierre(
    subcuentaCaja: CuentaZ.caja570.codcuenta,
    subcuentaBanco: CuentaZ.banco572.codcuenta,
    subcuentaVentas: CuentaZ.ventas700.codcuenta,
    subcuentaIvaGenerica: CuentaZ.ivaRepercutido477.codcuenta,
    subcuentaPerdidas: CuentaZ.perdidas659.codcuenta,
    subcuentaIngresos: CuentaZ.ingresos759.codcuenta,
  );

  /// Días naturales que abarcan los tickets del turno (un turno que cruza la
  /// medianoche abarca dos) más el del cierre, sin repetir y en orden.
  static List<DateTime> _fechasDe(List<Ticket> tickets, DateTime cierre) {
    final dias = <DateTime>{
      for (final t in tickets)
        DateTime(t.fechaHora.year, t.fechaHora.month, t.fechaHora.day),
      DateTime(cierre.year, cierre.month, cierre.day),
    };
    return dias.toList()..sort();
  }

  /// `null` si el resumen completo se puede contabilizar; si no, el motivo
  /// del bloqueo. Bloquea si alguna factura de los tickets no está aún
  /// sincronizada (al crearse generará su propio asiento) o si alguna
  /// factura de cualquiera de los [fechas] ya tiene asiento.
  ///
  /// Con [propagarErrores] un fallo al consultar el ERP se relanza (el
  /// trabajo de la cola lo reintentará); si no, bloquea con el motivo.
  Future<String?> _comprobarDuplicidad(
    List<DateTime> fechas, {
    required List<String> ticketIds,
    required bool facturasSincronizadas,
    bool propagarErrores = false,
  }) async {
    final accounting = _accounting;
    if (accounting == null) return 'ERP no configurado';
    if (!facturasSincronizadas || _hayFacturasEnCola(ticketIds)) {
      return 'Hay facturas del turno pendientes de sincronizar: al crearse '
          'generarán su propio asiento y un resumen completo duplicaría '
          'ventas e IVA.';
    }
    try {
      for (final fecha in fechas) {
        final hay = await accounting.hayFacturasConAsiento(
          fecha: fecha,
          codserie: _fiscal.codserie,
        );
        if (hay) {
          return 'Las facturas del ${_dia(fecha)} ya generan asiento en '
              'FacturaScripts: un resumen completo duplicaría ventas e IVA. '
              'Cambia el modo a "solo descuadre".';
        }
      }
      return null;
    } on AppException catch (error) {
      if (propagarErrores) rethrow;
      return 'No se pudo comprobar si las facturas tienen asiento: '
          '${error.message}';
    }
  }

  /// Algún trabajo de factura de [ticketIds] sigue sin terminar en la cola.
  bool _hayFacturasEnCola(List<String> ticketIds) {
    final s = _store.snapshot;
    for (final id in ticketIds) {
      final job = s.jobPorId(BillingService.jobIdDe(id));
      if (job != null && job.estado != SyncJobEstado.hecho) return true;
    }
    return false;
  }

  static String _dia(DateTime fecha) =>
      '${fecha.day.toString().padLeft(2, '0')}/'
      '${fecha.month.toString().padLeft(2, '0')}/${fecha.year}';

  /// Ticket del turno tal como lo necesita el motor del cierre. Lleva el
  /// reparto del cobro: en un ticket mixto solo la parte en efectivo entra en
  /// caja (efectivo esperado) y cada parte suma a las ventas de su forma de
  /// pago.
  static cz.TicketCierre _ticketCierre(Ticket t) => cz.TicketCierre(
    id: t.id,
    fechaHora: t.fechaHora,
    totalCents: t.totalCents,
    metodoPago: _metodoCierre(t.metodoPago),
    pagos: [
      for (final pago in t.pagos)
        cz.PagoCierre(
          metodo: _metodoCierre(pago.metodo),
          importeCents: pago.importeCents,
        ),
    ],
    desglose: [
      for (final d in t.totales.desglose)
        cz.DesgloseIvaTicket(
          codimpuesto: d.codimpuesto,
          ivaBp: d.ivaBp,
          baseCents: d.baseCents,
          cuotaCents: d.cuotaCents,
        ),
    ],
    codigoFactura: t.factura?.codigo,
  );

  static cz.MetodoPago _metodoCierre(MetodoPago metodo) => switch (metodo) {
    MetodoPago.efectivo => cz.MetodoPago.efectivo,
    MetodoPago.tarjeta => cz.MetodoPago.tarjeta,
  };

  CierreAbierto _turnoImplicito() {
    final tickets = ticketsTurno;
    return CierreAbierto(
      id: _newId(),
      abiertoEn: tickets.isEmpty ? _now() : tickets.first.fechaHora,
      fondoCajaCents: 0,
    );
  }

  Future<CierreAbierto> _abrirImplicito() async {
    final nuevo = _turnoImplicito();
    await _store.update((s) => s.copyWith(cierreAbierto: nuevo));
    return nuevo;
  }

  static Map<String, Object?> _asientoAJson(cz.AsientoPropuesto a) => {
    'clave': a.documento,
    'fecha': a.fecha.toIso8601String(),
    'concepto': a.concepto,
    'lineas': [
      for (final p in a.partidas)
        {
          'codsubcuenta': p.codsubcuenta,
          'concepto': p.concepto,
          'debeCents': p.debeCents,
          'haberCents': p.haberCents,
          if (p.baseCents != null) 'baseCents': p.baseCents,
          if (p.ivaPct != null) 'ivaPct': p.ivaPct,
        },
    ],
  };

  static AsientoZ _asientoDeJson(Map<String, Object?> json) => AsientoZ(
    clave: json.requireString('clave'),
    fecha: DateTime.parse(json.requireString('fecha')),
    concepto: json.requireString('concepto'),
    lineas: [
      for (final l in json.requireMapList('lineas'))
        PartidaZ(
          codsubcuenta: l.requireString('codsubcuenta'),
          concepto: l.requireString('concepto'),
          debeCents: l.optionalInt('debeCents') ?? 0,
          haberCents: l.optionalInt('haberCents') ?? 0,
          baseCents: l.optionalInt('baseCents'),
          ivaPct: l.optionalDouble('ivaPct'),
        ),
    ],
  );

  Future<void> dispose() async {
    cerrarSinEsperar(_cierres);
  }
}
