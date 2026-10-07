import 'dart:async';

import '../../../core/database/repositories/stock_repository.dart'
    show StockApplyResult;
import '../../../core/errors/app_exception.dart';
import '../../../core/inventory/inventory_models.dart';
import '../../../core/isolates/escandallos/escandallo_engine.dart';
import '../../../core/isolates/isolate_runner.dart';
import '../../../core/logging/app_logger.dart';
import '../../../core/utils/json_map.dart';
import '../../sala/domain/comanda.dart';
import '../../sala/domain/linea_comanda.dart';
import '../../sala/domain/mesa.dart';
import '../domain/host_snapshot.dart';
import '../domain/sync_job.dart';
import 'alert_bus.dart';
import 'host_state_store.dart';
import 'ports.dart';
import 'sala_effects.dart';
import 'sync_outbox.dart';

//// Descuento de materias primas por escandallo.
///
/// * **Durable al aceptar.** En la misma escritura del diario que incorpora
///   la línea se encola el trabajo `descuentoStock` `stock:<idLínea>` con
///   `{lineaId, referencia del plato, cantidad}`. El escandallo se resuelve
///   al ejecutarlo (recetas cacheadas con TTL, explosión en un isolate): si
///   no hay recetas o MySQL no responde, el trabajo falla como transitorio y
///   se reintenta, nunca se pierde. Con la caché de recetas vigente, los
///   platos sin receta no generan trabajo (FS mueve su stock).
/// * **Anulación = revertir lo aplicado.** Si el descuento original sigue
///   sin ejecutar en la cola se cancela y ninguno de los dos toca el stock.
///   Si no, se encola `stock:<idLínea>:anulacion`, que al ejecutarse cancela
///   el original si aún no se ha aplicado y aplica la negación de los
///   consumos que el diario `tpv_movimientos_stock` (fuente de verdad)
///   registra para la línea. Si no consta nada aplicado, no hace nada.
///
/// [StockPort] aplica cada operación en una transacción idempotente por
/// clave (`operacion`).
final class StockService extends SalaEffects {
  StockService({
    required this._store,
    required this._alerts,
    required this._outbox,
    required this._runner,
    required String codalmacen,
    StockPort? stock,
    RecetasPort? recetas,
    DateTime Function()? now,
    this.recetasTtl = const Duration(minutes: 10),
  }) : _now = now ?? DateTime.now {
    configurar(stock: stock, recetas: recetas, codalmacen: codalmacen);
    _outbox.registerHandler(SyncJobTipo.descuentoStock, ejecutar);
  }

  static final Logger _log = appLogger('host.stock');

  /// Longitud máxima de `origen` en el diario de stock.
  static const int _maxOrigen = 100;

  final HostStateStore _store;
  final AlertBus _alerts;
  final SyncOutbox _outbox;
  final IsolateRunner _runner;
  final DateTime Function() _now;
  final Duration recetasTtl;
  String _codalmacen = '';
  StockPort? _stock;
  RecetasPort? _recetas;
  bool _avisadoSinConfigurar = false;

  final StreamController<List<NivelStock>> _descuentos =
      StreamController<List<NivelStock>>.broadcast();

  /// Hay MySQL configurado para stock y recetas.
  bool get disponible => _stock != null && _recetas != null;

  /// Niveles resultantes tras cada descuento aplicado (para la reposición).
  Stream<List<NivelStock>> get descuentos => _descuentos.stream;

  /// Identificador del trabajo de stock de una operación (`<idLínea>` o
  /// `<idLínea>:anulacion`).
  static String jobIdDe(String operacion) => 'stock:$operacion';

  /// Reconfigura en caliente. Los ajustes nulos se conservan; los puertos se
  /// sustituyen siempre (nulo = sin ERP / sin MySQL).
  void configurar({
    StockPort? stock,
    RecetasPort? recetas,
    String? codalmacen,
  }) {
    _stock = stock;
    _recetas = recetas;
    if (codalmacen != null) _codalmacen = codalmacen;
    _avisadoSinConfigurar = false;
  }

  // ---------------------------------------------------------------------------
  // Efectos de la sala

  @override
  HostSnapshot alAceptarLineas(
    HostSnapshot snapshot,
    Mesa mesa,
    List<LineaComanda> nuevas,
  ) {
    if (!disponible) return snapshot;
    final cache = snapshot.recetas;
    final platos = cache != null && !cache.caducada(_now(), recetasTtl)
        ? {for (final r in cache.lineas) r.refPlato}
        : null;
    var next = snapshot;
    for (final linea in nuevas) {
      // Con la caché vigente se sabe que el plato no tiene receta.
      if (platos != null && !platos.contains(linea.referencia)) continue;
      next = _outbox.encolarEn(next, SyncJobTipo.descuentoStock, {
        'operacion': linea.id,
        'lineaId': linea.id,
        'referencia': linea.referencia,
        'cantidad': linea.cantidad,
        'codalmacen': _codalmacen,
        'motivo': 'comanda',
        'origen': _origen(mesa, linea),
      }, id: jobIdDe(linea.id));
    }
    return next;
  }

  @override
  HostSnapshot alAnularLinea(
    HostSnapshot snapshot,
    Mesa mesa,
    LineaComanda linea,
  ) {
    final originalId = jobIdDe(linea.id);
    final original = snapshot.jobPorId(originalId);
    if (original != null &&
        original.intentos == 0 &&
        (original.estado == SyncJobEstado.pendiente ||
            original.estado == SyncJobEstado.bloqueado)) {
      // Nunca llegó a ejecutarse: se cancela y nadie toca el stock.
      return snapshot.copyWith(
        cola: [
          for (final j in snapshot.cola)
            if (j.id != originalId) j,
        ],
      );
    }
    if (original == null && !disponible) return snapshot;
    final codalmacen = switch (original?.payload['codalmacen']) {
      final String c when c.isNotEmpty => c,
      _ => _codalmacen,
    };
    final operacion = '${linea.id}:anulacion';
    return _outbox.encolarEn(snapshot, SyncJobTipo.descuentoStock, {
      'operacion': operacion,
      'revierte': linea.id,
      'codalmacen': codalmacen,
      'motivo': 'anulacion',
      'origen': _origen(mesa, linea),
    }, id: jobIdDe(operacion));
  }

  @override
  Future<void> onLineasAceptadas(
    Mesa mesa,
    Comanda comanda,
    List<LineaComanda> nuevas,
  ) async {
    _comprobarConfiguracion();
  }

  static String _origen(Mesa mesa, LineaComanda linea) {
    final origen = 'Mesa ${mesa.nombre} · ${linea.descripcion}';
    return origen.length <= _maxOrigen
        ? origen
        : origen.substring(0, _maxOrigen);
  }

  // ---------------------------------------------------------------------------
  // Ejecución del trabajo

  /// Ejecutor del trabajo `descuentoStock` (registrado en la cola).
  ///
  /// Admite tres formas de payload: la línea (`referencia` + `cantidad`; el
  /// escandallo se resuelve aquí), la reversión (`revierte`: id de la
  /// operación original) y la antigua con los `consumos` ya calculados.
  Future<List<String>> ejecutar(SyncJob job) async {
    final stock = _stock;
    if (stock == null) {
      throw const ConfigException('MySQL no configurado: stock sin descontar');
    }
    final payload = job.payload;
    final String operacion;
    final String codalmacen;
    final String motivo;
    final String? origen;
    final String? revierte;
    try {
      operacion = payload.requireString('operacion');
      codalmacen = payload.requireString('codalmacen');
      motivo = payload.requireString('motivo');
      origen = payload.optionalString('origen');
      revierte = payload.optionalString('revierte');
    } on FormatException catch (error) {
      throw _corrupto(job, error);
    }
    if (revierte != null) {
      return _revertir(
        stock,
        operacion: operacion,
        revierte: revierte,
        motivo: motivo,
        origen: origen,
      );
    }

    final avisos = <String>[];
    final List<ConsumoStock> consumos;
    if (payload.containsKey('consumos')) {
      try {
        consumos = [
          for (final c in payload.requireMapList('consumos'))
            ConsumoStock.fromJson(c),
        ];
      } on FormatException catch (error) {
        throw _corrupto(job, error);
      }
    } else {
      final String referencia;
      final double cantidad;
      try {
        referencia = payload.requireString('referencia');
        cantidad = payload.requireDouble('cantidad');
      } on FormatException catch (error) {
        throw _corrupto(job, error);
      }
      consumos = await _consumosDeLinea(referencia, cantidad, avisos);
    }
    if (consumos.isEmpty) return avisos; // Sin receta: FS mueve su stock.

    final resultado = await stock.aplicarConsumos(
      operacion: operacion,
      consumos: consumos,
      codalmacen: codalmacen,
      motivo: motivo,
      origen: origen,
    );
    _publicar(operacion, resultado);
    return [...avisos, ...resultado.avisos];
  }

  /// Revierte exactamente lo que el diario registra para [revierte].
  Future<List<String>> _revertir(
    StockPort stock, {
    required String operacion,
    required String revierte,
    required String motivo,
    required String? origen,
  }) async {
    // El descuento original ya no debe ejecutarse: si sigue en la cola sin
    // aplicar (en backoff, en error o en pausa), se cancela.
    final original = _store.snapshot.jobPorId(jobIdDe(revierte));
    if (original != null &&
        original.estado != SyncJobEstado.hecho &&
        original.estado != SyncJobEstado.enCurso) {
      await _outbox.descartar(original.id);
      _log.info('Descuento $revierte cancelado por la anulación');
    }
    final aplicados = await stock.leerConsumosAplicados(revierte);
    if (aplicados.isEmpty) {
      _log.info('Anulación $operacion: no consta descuento de $revierte');
      return const [];
    }
    final avisos = <String>[];
    for (final MapEntry(key: codalmacen, value: consumos)
        in aplicados.entries) {
      final resultado = await stock.aplicarConsumos(
        operacion: operacion,
        consumos: [
          for (final c in consumos)
            ConsumoStock(referencia: c.referencia, cantidad: -c.cantidad),
        ],
        codalmacen: codalmacen,
        motivo: motivo,
        origen: origen,
      );
      _publicar(operacion, resultado);
      avisos.addAll(resultado.avisos);
    }
    return avisos;
  }

  /// Explota el escandallo de la línea con las recetas vigentes.
  Future<List<ConsumoStock>> _consumosDeLinea(
    String referencia,
    double cantidad,
    List<String> avisos,
  ) async {
    if (_recetas == null) {
      throw const ConfigException('MySQL no configurado: sin recetas');
    }
    final recetas = await _recetasVigentes();
    if (recetas == null) {
      // Se reintenta con backoff: el descuento no se pierde.
      throw const NetworkException(
        'No se pudieron leer las recetas; se reintentará',
      );
    }
    final EscandalloResult resultado;
    try {
      resultado = await resolverEscandallosEnIsolate(
        EscandalloRequest(
          ventas: [VentaLinea(referencia: referencia, cantidad: cantidad)],
          recetas: recetas,
        ),
        runner: _runner,
      );
    } on ValidationException catch (error) {
      // Receta cíclica o demasiado profunda: dato corrupto (error definitivo).
      throw ValidationException(
        "Escandallo de '$referencia' inválido: ${error.message}",
        cause: error,
      );
    }
    for (final aviso in resultado.avisos) {
      avisos.add("Escandallo '$referencia': $aviso");
    }
    return resultado.consumos;
  }

  void _publicar(String operacion, StockApplyResult resultado) {
    if (resultado.yaAplicada) {
      _log.info('Operación de stock $operacion ya estaba aplicada');
    } else if (!_descuentos.isClosed) {
      _descuentos.add(resultado.niveles);
    }
  }

  static ValidationException _corrupto(SyncJob job, FormatException error) =>
      ValidationException(
        'Trabajo de stock ${job.id} corrupto: ${error.message}',
        cause: error,
      );

  // ---------------------------------------------------------------------------
  // Recetas

  /// Recetas vigentes: la caché si no ha caducado; si no, se releen. Si la
  /// lectura falla se usa la caché caducada (con aviso) o `null`.
  Future<List<RecetaLinea>?> recetasVigentes({bool forzar = false}) =>
      _recetasVigentes(forzar: forzar);

  Future<List<RecetaLinea>?> _recetasVigentes({bool forzar = false}) async {
    final port = _recetas;
    final cache = _store.snapshot.recetas;
    final now = _now();
    if (!forzar && cache != null && !cache.caducada(now, recetasTtl)) {
      return cache.lineas;
    }
    if (port == null) return cache?.lineas;
    try {
      final lineas = await port.listAll();
      await _store.update(
        (s) => s.copyWith(
          recetas: RecetasCache(lineas: lineas, obtenidasEn: now),
        ),
      );
      return lineas;
    } on AppException catch (error) {
      _log.warning('No se pudieron leer las recetas', error);
      if (cache == null) return null;
      _alerts.aviso(
        'Recetas: se usa la caché de ${cache.obtenidasEn}',
        detalle: error.message,
        origen: 'stock',
      );
      return cache.lineas;
    }
  }

  bool _comprobarConfiguracion() {
    if (disponible) return true;
    if (!_avisadoSinConfigurar) {
      _avisadoSinConfigurar = true;
      _alerts.info(
        'Sin MySQL configurado: no se descuenta stock por escandallo',
        origen: 'stock',
      );
    }
    return false;
  }

  Future<void> dispose() => _descuentos.close();
}
