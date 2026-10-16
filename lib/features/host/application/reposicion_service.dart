import 'dart:async';

import '../../../core/errors/app_exception.dart';
import '../../../core/facturascripts/documents/supplier_order_models.dart';
import '../../../core/isolates/isolate_runner.dart';
import '../../../core/isolates/reposicion/reposicion_engine.dart'
    show auditarReposicionEnIsolate;
import '../../../core/isolates/reposicion/reposicion_models.dart';
import '../../../core/logging/app_logger.dart';
import '../../../core/money/money.dart';
import '../../../core/utils/json_map.dart';
import '../../../core/utils/streams.dart';
import '../domain/host_settings.dart';
import '../domain/sync_job.dart';
import 'alert_bus.dart';
import 'ports.dart';
import 'sync_outbox.dart';

/// Reaprovisionamiento: auditoría de roturas de stock y pedidos a proveedor.
///
/// [auditar] lee niveles y ofertas por MySQL, pasa por el motor (isolate) y,
/// si la reposición automática está activa, encola un trabajo
/// `pedidoProveedor` por pedido propuesto con clave determinista por
/// proveedor y día, `TPV-REPO-<yyyyMMdd>-<codproveedor>` (con sufijo `-2`,
/// `-3`... si ese día ya hubo otro). Las referencias que ya figuran en un
/// pedido de la cola sin terminar no se vuelven a pedir: FacturaScripts solo
/// las cuenta como pendientes de recibir cuando el pedido se crea, así que
/// mientras el ERP no responde cada auditoría volvería a pedirlas. Se
/// dispara tras cada descuento de stock (con *debounce*) y, si así se
/// configura, en el Cierre Z.
final class ReposicionService {
  ReposicionService({
    required this._alerts,
    required this._outbox,
    required this._runner,
    required ReposicionSettings settings,
    required String codalmacen,
    StockPort? stock,
    SupplierOrderPort? supplierOrders,
    DateTime Function()? now,
    // Sin uso desde que la clave del pedido es determinista por proveedor y
    // día; se conserva para no romper a quien lo pase.
    String Function()? newLoteId,
  }) : _now = now ?? DateTime.now {
    configurar(
      settings: settings,
      codalmacen: codalmacen,
      stock: stock,
      supplierOrders: supplierOrders,
    );
    _outbox.registerHandler(SyncJobTipo.pedidoProveedor, ejecutarPedido);
  }

  static final Logger _log = appLogger('host.reposicion');

  final AlertBus _alerts;
  final SyncOutbox _outbox;
  final IsolateRunner _runner;
  final DateTime Function() _now;
  final StreamController<ReposicionResult> _auditorias =
      StreamController<ReposicionResult>.broadcast();

  ReposicionSettings _settings = const ReposicionSettings();
  String _codalmacen = '';
  StockPort? _stock;
  SupplierOrderPort? _supplierOrders;
  Timer? _debounce;
  Future<ReposicionResult?>? _enCurso;
  ReposicionResult? _ultima;
  DateTime? _ultimaEn;

  ReposicionSettings get settings => _settings;

  /// Hay MySQL para leer niveles y ofertas.
  bool get disponible => _stock != null;

  /// Última auditoría realizada (alertas para la UI).
  ReposicionResult? get ultimaAuditoria => _ultima;
  DateTime? get ultimaAuditoriaEn => _ultimaEn;

  /// Resultado de cada auditoría.
  Stream<ReposicionResult> get auditorias => _auditorias.stream;

  /// Hay una auditoría programada por el *debounce*.
  bool get auditoriaProgramada => _debounce?.isActive ?? false;

  /// Reconfigura en caliente. Los ajustes nulos se conservan; los puertos se
  /// sustituyen siempre (nulo = sin ERP / sin MySQL).
  void configurar({
    ReposicionSettings? settings,
    String? codalmacen,
    StockPort? stock,
    SupplierOrderPort? supplierOrders,
  }) {
    if (settings != null) _settings = settings;
    if (codalmacen != null) _codalmacen = codalmacen;
    _stock = stock;
    _supplierOrders = supplierOrders;
  }

  // ---------------------------------------------------------------------------
  // Disparadores

  /// Tras un descuento de stock: si la reposición automática está activa,
  /// programa una auditoría pasado el *debounce* (cada nuevo descuento lo
  /// reinicia).
  void onStockDescontado() {
    if (!_settings.automatica || !disponible) return;
    _debounce?.cancel();
    _debounce = Timer(_settings.debounce, () {
      _debounce = null;
      unawaited(
        auditar().catchError((Object error, StackTrace stackTrace) {
          _log.warning('Auditoría de reposición fallida', error, stackTrace);
          return null;
        }),
      );
    });
  }

  /// En el Cierre Z: audita si `enCierre` (y pide si `automatica`).
  Future<ReposicionResult?> onCierre() async {
    if (!_settings.enCierre || !disponible) return null;
    _debounce?.cancel();
    _debounce = null;
    return auditar();
  }

  /// Audita el almacén ahora. Varias llamadas simultáneas comparten la misma
  /// auditoría. Devuelve `null` si no hay MySQL. Lanza [NetworkException] /
  /// [DatabaseException] si falla la lectura y [ValidationException] si el
  /// motor rechaza los datos.
  Future<ReposicionResult?> auditar({bool? pedir}) {
    final stock = _stock;
    if (stock == null) return Future.value();
    return _enCurso ??= _auditar(
      stock,
      pedir: pedir ?? _settings.automatica,
    ).whenComplete(() => _enCurso = null);
  }

  Future<ReposicionResult?> _auditar(
    StockPort stock, {
    required bool pedir,
  }) async {
    final niveles = await stock.leerNiveles(
      codalmacen: _codalmacen,
      soloConMinimo: !_settings.politica.incluirSinMinimo,
    );
    final ofertas = await stock.leerOfertas({
      for (final n in niveles) n.referencia,
    });
    final result = await auditarReposicionEnIsolate(
      ReposicionRequest(
        niveles: niveles,
        ofertas: ofertas,
        politica: _settings.politica,
      ),
      runner: _runner,
    );
    _ultima = result;
    _ultimaEn = _now();
    if (!_auditorias.isClosed) _auditorias.add(result);

    for (final aviso in result.avisos) {
      _alerts.aviso('Reposición: $aviso', origen: 'reposicion');
    }
    if (result.sinProveedor.isNotEmpty) {
      _alerts.aviso(
        '${result.sinProveedor.length} referencias bajo mínimo sin proveedor',
        detalle: result.sinProveedor
            .map((r) => '${r.referencia} (faltan ${r.cantidadNecesaria})')
            .join(', '),
        origen: 'reposicion',
      );
    }
    if (result.pedidos.isEmpty) return result;

    if (!pedir) {
      _alerts.info(
        '${result.pedidos.length} pedidos propuestos pendientes de aprobar',
        origen: 'reposicion',
      );
      return result;
    }
    final enCola = _referenciasEnPedidosPendientes();
    for (final propuesto in result.pedidos) {
      final pedido = _sinReferencias(propuesto, enCola);
      if (pedido == null) {
        _log.info(
          'Pedido a ${propuesto.codproveedor} omitido: sus referencias ya '
          'están en un pedido pendiente de la cola',
        );
        continue;
      }
      final fechaHora = _now();
      final clave = _clavePedido(pedido.codproveedor, fechaHora);
      await _outbox.enqueue(
        SyncJobTipo.pedidoProveedor,
        _pedidoAJson(pedido, clave: clave, fechaHora: fechaHora),
        id: 'pedido:$clave',
      );
      enCola.addAll(pedido.lineas.map((l) => l.referencia));
      _log.info(
        'Pedido $clave encolado: ${pedido.lineas.length} líneas, '
        '${formatCents(pedido.importeEstimadoCents)}',
      );
    }
    return result;
  }

  /// Referencias de los pedidos a proveedor de la cola que aún no se han
  /// creado en el ERP (pendientes, en curso, en error o en pausa).
  Set<String> _referenciasEnPedidosPendientes() => {
    for (final job in _outbox.jobs)
      if (job.tipo == SyncJobTipo.pedidoProveedor &&
          job.estado != SyncJobEstado.hecho)
        for (final linea in switch (job.payload['lineas']) {
          final List<Object?> l => l,
          _ => const <Object?>[],
        })
          if (linea case {'referencia': final String referencia}) referencia,
  };

  /// [pedido] sin las líneas de [excluidas] (importe recalculado), o `null`
  /// si no queda ninguna.
  static PedidoPropuesto? _sinReferencias(
    PedidoPropuesto pedido,
    Set<String> excluidas,
  ) {
    final lineas = [
      for (final l in pedido.lineas)
        if (!excluidas.contains(l.referencia)) l,
    ];
    if (lineas.isEmpty) return null;
    if (lineas.length == pedido.lineas.length) return pedido;
    return PedidoPropuesto(
      codproveedor: pedido.codproveedor,
      nombreProveedor: pedido.nombreProveedor,
      lineas: lineas,
      importeEstimadoCents: lineas.fold(
        0,
        (total, l) => total + l.importeEstimadoCents,
      ),
    );
  }

  /// Clave determinista `TPV-REPO-<yyyyMMdd>-<codproveedor>` (≤ 50
  /// caracteres, `numproveedor` en FS). Si ese día ya existe un trabajo con
  /// esa clave (p. ej. un pedido ya creado), se añade `-2`, `-3`...
  String _clavePedido(String codproveedor, DateTime fecha) {
    final dia =
        '${fecha.year.toString().padLeft(4, '0')}'
        '${fecha.month.toString().padLeft(2, '0')}'
        '${fecha.day.toString().padLeft(2, '0')}';
    final base = 'TPV-REPO-$dia-$codproveedor';
    var clave = base;
    for (var n = 2; _existeTrabajo('pedido:$clave'); n++) {
      clave = '$base-$n';
    }
    return clave.length <= _maxClave ? clave : clave.substring(0, _maxClave);
  }

  bool _existeTrabajo(String id) => _outbox.jobs.any((j) => j.id == id);

  /// Longitud de `numproveedor` en FacturaScripts.
  static const int _maxClave = 50;

  // ---------------------------------------------------------------------------
  // Ejecutor del trabajo `pedidoProveedor`

  Future<List<String>> ejecutarPedido(SyncJob job) async {
    final port = _supplierOrders;
    if (port == null) {
      throw const ConfigException('ERP no configurado: pedido pendiente');
    }
    final PedidoProveedorDraft draft;
    try {
      draft = _pedidoDeJson(job.payload);
    } on FormatException catch (error) {
      throw ValidationException(
        'Trabajo de pedido ${job.id} corrupto: ${error.message}',
        cause: error,
      );
    }
    final resultado = await port.crearOReanudar(draft);
    _log.info(
      'Pedido ${draft.clave} → ${resultado.codigo}'
      '${resultado.yaExistia ? ' (ya existía)' : ''}',
    );
    final desconocidas = resultado.referenciasSinProducto;
    return [
      if (desconocidas.isNotEmpty)
        "Referencias desconocidas para FacturaScripts: ${desconocidas.join(', ')}",
    ];
  }

  // ---------------------------------------------------------------------------

  Map<String, Object?> _pedidoAJson(
    PedidoPropuesto pedido, {
    required String clave,
    required DateTime fechaHora,
  }) => {
    'clave': clave,
    'codproveedor': pedido.codproveedor,
    'nombreProveedor': pedido.nombreProveedor,
    'codalmacen': _codalmacen,
    'fechaHora': fechaHora.toIso8601String(),
    'observaciones':
        'Reposición automática TPV · ${pedido.lineas.length} referencias',
    'importeEstimadoCents': pedido.importeEstimadoCents,
    'lineas': [
      for (final l in pedido.lineas)
        {
          'referencia': l.referencia,
          'cantidad': l.cantidad,
          if (l.descripcion != null) 'descripcion': l.descripcion,
        },
    ],
  };

  static PedidoProveedorDraft _pedidoDeJson(Map<String, Object?> json) =>
      PedidoProveedorDraft(
        clave: json.requireString('clave'),
        codproveedor: json.requireString('codproveedor'),
        codalmacen: json.requireString('codalmacen'),
        fechaHora: DateTime.parse(json.requireString('fechaHora')),
        observaciones: json.optionalString('observaciones'),
        lineas: [
          for (final l in json.requireMapList('lineas'))
            LineaPedido(
              referencia: l.requireString('referencia'),
              cantidad: l.requireDouble('cantidad'),
              descripcion: l.optionalString('descripcion'),
            ),
        ],
      );

  Future<void> dispose() async {
    _debounce?.cancel();
    _debounce = null;
    await _enCurso;
    cerrarSinEsperar(_auditorias);
  }
}
