import 'dart:async';
import 'dart:io';

import '../../../core/database/mysql_database.dart';
import '../../../core/database/schema/tpv_schema.dart';
import '../../../core/errors/app_exception.dart';
import '../../../core/facturascripts/fs_api.dart';
import '../../../core/facturascripts/fs_api_config.dart';
import '../../../core/facturascripts/fs_http_api.dart';
import '../../../core/facturascripts/master_data/fs_master_models.dart';
import '../../../core/fiscal/fs_totales_calculator.dart';
import '../../../core/isolates/isolate_runner.dart';
import '../../../core/logging/app_logger.dart';
import '../../../core/network/printing/raw_printer_transport.dart';
import '../../../core/network/tcp/tcp_host_server.dart' show HostServerOptions;
import '../data/fs_port_adapters.dart';
import '../data/mysql_port_adapters.dart';
import '../data/print_queue_adapter.dart';
import '../domain/empresa_emisora.dart';
import '../domain/host_settings.dart';
import '../domain/host_snapshot.dart';
import '../domain/operational_alert.dart';
import 'alert_bus.dart';
import 'billing_service.dart';
import 'catalog_service.dart';
import 'cierre_z_service.dart';
import 'host_network_service.dart';
import 'host_state_repository.dart';
import 'host_state_store.dart';
import 'ports.dart';
import 'printing_service.dart';
import 'reposicion_service.dart';
import 'sala_service.dart';
import 'stock_service.dart';
import 'sync_outbox.dart';

/// Composición del host: construye todos los servicios con sus adaptadores
/// reales cuando los ajustes lo permiten y con "no configurado" en caso
/// contrario. La sala, las comandas y la red funcionan aunque no haya ERP,
/// MySQL ni impresora; lo que dependa de ellos queda en la cola o se avisa.
///
/// Los parámetros opcionales de [create] permiten inyectar dobles (API,
/// base de datos, transporte de impresora, runner de isolates, reloj) para
/// probar el runtime completo sin red ni hardware.
final class HostRuntime {
  HostRuntime._({
    required this.settings,
    required this.alerts,
    required this.store,
    required this.catalog,
    required this.sala,
    required this.outbox,
    required this.printing,
    required this.stock,
    required this.billing,
    required this.cierreZ,
    required this.reposicion,
    required this.network,
    required this._now,
    required this._infra,
    required this._apiFactory,
  });

  static final Logger _log = appLogger('host.runtime');

  /// Crea el runtime (sin arrancarlo) sobre el diario de [stateRepo].
  ///
  /// [api], [db] y [printer] sustituyen a las implementaciones reales que se
  /// construirían a partir de [settings]; [printerPort] sustituye la cola de
  /// impresión entera. [apiFactory] construye el cliente del ERP cada vez
  /// que hace falta uno nuevo (al crear y al cambiar los ajustes del ERP);
  /// a diferencia de [api], el runtime es su dueño y lo cierra.
  static Future<HostRuntime> create({
    required HostSettings settings,
    required HostStateRepository stateRepo,
    FsApi? api,
    MysqlDatabase? db,
    RawPrinterTransport? printer,
    PrinterPort? printerPort,
    IsolateRunner runner = const SpawningIsolateRunner(),
    DateTime Function()? now,
    HostServerOptions? serverOptions,
    InternetAddress? bindAddress,
    bool discoveryEnabled = true,
    FsApi Function(FsApiConfig config)? apiFactory,
  }) async {
    final clock = now ?? DateTime.now;
    final alerts = AlertBus(now: clock);
    final store = await HostStateStore.load(
      stateRepo,
      initial: () => HostSnapshot(mesas: settings.mesas),
      alerts: alerts,
    );
    final infra = _Infra.build(
      settings,
      api: api,
      db: db,
      printer: printer,
      printerPort: printerPort,
      apiFactory: apiFactory,
      now: clock,
    );

    final catalog = CatalogService(
      store: store,
      alerts: alerts,
      port: infra.fs?.catalog,
      codimpuestoPorDefecto: settings.fiscal.codimpuestoPorDefecto,
      now: clock,
    );
    final sala = SalaService(
      store: store,
      alerts: alerts,
      catalog: catalog,
      now: clock,
      enrutamiento: settings.impresion.enrutamiento,
    )..configurarPases(settings.impresion.pases);
    final outbox = SyncOutbox(store: store, alerts: alerts, now: clock);
    // La empresa guardada en el diario es la última identidad buena del
    // emisor: la cabecera de los tickets funciona aunque el ERP no responda.
    final printing = PrintingService(
      alerts: alerts,
      runner: runner,
      settings: settings.impresion,
      nombreTpv: settings.nombreTpv,
      store: store,
      printer: infra.printerPort,
      empresa: settings.empresa,
      empresaErp: store.snapshot.empresa,
      now: clock,
    );
    final stock = StockService(
      store: store,
      alerts: alerts,
      outbox: outbox,
      runner: runner,
      codalmacen: settings.fiscal.codalmacen,
      stock: infra.mysql?.stock,
      recetas: infra.mysql?.recetas,
      now: clock,
    );
    final billing = BillingService(
      store: store,
      alerts: alerts,
      outbox: outbox,
      printing: printing,
      fiscal: settings.fiscal,
      invoice: infra.fs?.invoice,
      masterData: infra.fs?.masterData,
      now: clock,
    );
    final cierreZ = CierreZService(
      store: store,
      alerts: alerts,
      outbox: outbox,
      printing: printing,
      runner: runner,
      cierre: settings.cierre,
      fiscal: settings.fiscal,
      nombreTpv: settings.nombreTpv,
      accounting: infra.fs?.accounting,
      now: clock,
    );
    final reposicion = ReposicionService(
      alerts: alerts,
      outbox: outbox,
      runner: runner,
      settings: settings.reposicion,
      codalmacen: settings.fiscal.codalmacen,
      stock: infra.mysql?.stock,
      supplierOrders: infra.fs?.supplierOrder,
      now: clock,
    );
    final network = HostNetworkService(
      sala: sala,
      catalog: catalog,
      alerts: alerts,
      config: _networkConfig(
        settings,
        serverOptions: serverOptions,
        bindAddress: bindAddress,
        discoveryEnabled: discoveryEnabled,
      ),
    );

    sala
      ..addEffects(printing)
      ..addEffects(stock)
      ..addEffects(billing);

    final runtime = HostRuntime._(
      settings: settings,
      alerts: alerts,
      store: store,
      catalog: catalog,
      sala: sala,
      outbox: outbox,
      printing: printing,
      stock: stock,
      billing: billing,
      cierreZ: cierreZ,
      reposicion: reposicion,
      network: network,
      now: clock,
      infra: infra,
      apiFactory: apiFactory,
    );
    runtime._subscriptions.addAll([
      stock.descuentos.listen((_) => reposicion.onStockDescontado()),
      cierreZ.cierres.listen((_) => runtime._tras(reposicion.onCierre())),
    ]);
    if (settings.mesas.isNotEmpty && store.snapshot.mesas != settings.mesas) {
      _avisarMesasConservadas(
        alerts,
        await sala.configurarMesas(settings.mesas),
      );
    }
    return runtime;
  }

  HostSettings settings;
  final AlertBus alerts;
  final HostStateStore store;
  final CatalogService catalog;
  final SalaService sala;
  final SyncOutbox outbox;
  final PrintingService printing;
  final StockService stock;
  final BillingService billing;
  final CierreZService cierreZ;
  final ReposicionService reposicion;
  final HostNetworkService network;

  final DateTime Function() _now;
  final FsApi Function(FsApiConfig config)? _apiFactory;
  _Infra _infra;
  final List<StreamSubscription<Object?>> _subscriptions = [];
  Future<void>? _bootstrap;
  bool _started = false;
  bool _disposed = false;

  /// `idempresa` de los ajustes de FacturaScripts (nulo hasta leerlos).
  int? _idempresaErp;

  /// El aviso «Sin NIF del emisor» ya se emitió en esta sesión.
  bool _avisoSinNif = false;

  /// Avisos operativos de todos los servicios.
  Stream<OperationalAlert> get alertas => alerts.stream;

  bool get isRunning => _started && !_disposed;
  bool get erpConfigurado => _infra.fs != null;
  bool get mysqlConfigurado => _infra.mysql != null;
  bool get impresoraConfigurada => _infra.printerPort != null;

  /// Arranca la cola y la red y lanza en segundo plano la puesta a punto
  /// con el ERP y MySQL (ajustes, catálogo, esquema `tpv_*`, diagnóstico).
  ///
  /// Si el puerto TCP no se puede abrir se avisa y el runtime sigue en pie
  /// (la UI puede corregir el puerto y llamar a [applySettings]).
  Future<void> start() async {
    if (_disposed) throw StateError('HostRuntime cerrado');
    if (_started) return;
    _started = true;
    await outbox.start();
    // Tickets cobrados cuya factura no llegó a la cola (diario antiguo o
    // corte entre escrituras): se vuelven a encolar.
    await billing.reconciliar();
    try {
      await network.start();
    } on NetworkException catch (error) {
      alerts.error(
        'No se pudo abrir la red del host',
        detalle: error.message,
        origen: 'red',
      );
    }
    _bootstrap = _lanzarBootstrap();
  }

  /// Reanuda la sincronización en pausa. Antes rearma el cortafuegos del
  /// cliente del ERP, que tras un 401/403 rechaza en local todas las
  /// peticiones hasta que alguien lo desbloquea: sin esto, el primer trabajo
  /// volvería a fallar sin llegar al servidor y la cola se pausaría otra vez.
  ///
  /// Es la acción que debe ofrecer la interfaz como "Reanudar" (en lugar de
  /// `outbox.reanudar()` directo).
  Future<void> reanudarSincronizacion() async {
    final api = _infra.api;
    if (api is FsHttpApi) api.resetGuard();
    await outbox.reanudar();
  }

  /// Completa cuando termina la puesta a punto lanzada por [start].
  Future<void> get listo => _bootstrap ?? Future<void>.value();

  /// Vuelve a leer la empresa emisora de FacturaScripts (§5.13): la guarda en
  /// el diario si cambió y la usa desde ya en la cabecera de los tickets.
  /// Lanza [ConfigException] si no hay ERP configurado o el runtime ya está
  /// cerrado (antes o durante la lectura) y deja pasar la [ErpApiException]
  /// del ERP para que la interfaz la muestre.
  Future<EmpresaEmisora> refrescarEmpresa() async {
    _comprobarAbierto();
    final fs = _infra.fs;
    if (fs == null) {
      throw const ConfigException(
        'FacturaScripts no está configurado: no se pueden leer los datos de '
        'la empresa',
      );
    }
    return _leerEmpresa(fs);
  }

  /// Aplica unos ajustes nuevos en caliente: reconstruye los adaptadores cuya
  /// configuración cambió (ERP, MySQL, impresora), reconfigura los servicios
  /// y reinicia la red si hace falta. Si la cola estaba en pausa y cambió la
  /// configuración del ERP, de MySQL, fiscal o del cierre, se reanuda (con
  /// [reanudarSincronizacion]). Un puerto TCP ocupado se avisa sin
  /// interrumpir el resto.
  Future<void> applySettings(HostSettings nuevos) async {
    final previos = settings;
    settings = nuevos;

    final erpCambio = previos.erp != nuevos.erp;
    final mysqlCambio = previos.mysql != nuevos.mysql;
    final fiscalCambio = previos.fiscal != nuevos.fiscal;
    final cierreCambio = previos.cierre != nuevos.cierre;
    final impresoraCambio =
        previos.impresion.hayImpresora != nuevos.impresion.hayImpresora;
    if (erpCambio || mysqlCambio || impresoraCambio) {
      final anterior = _infra;
      // Lo que se reutiliza conserva su dueño: si el runtime lo creó, el
      // runtime lo seguirá cerrando.
      _infra = _Infra.build(
        nuevos,
        api: erpCambio ? null : anterior.api,
        db: mysqlCambio ? null : anterior.db,
        printerPort: impresoraCambio ? null : anterior.printerPort,
        ownsApi: !erpCambio && anterior._ownsApi,
        ownsDb: !mysqlCambio && anterior._ownsDb,
        ownsPrinter: !impresoraCambio && anterior._ownsPrinter,
        apiFactory: _apiFactory,
        now: _now,
      );
      await anterior.dispose(
        keepApi: !erpCambio,
        keepDb: !mysqlCambio,
        keepPrinter: !impresoraCambio,
      );
    }
    final fs = _infra.fs;
    final mysql = _infra.mysql;

    catalog.configurar(
      port: fs?.catalog,
      codimpuestoPorDefecto: nuevos.fiscal.codimpuestoPorDefecto,
    );
    printing.configurar(
      printer: _infra.printerPort,
      settings: nuevos.impresion,
      empresa: nuevos.empresa,
      nombreTpv: nuevos.nombreTpv,
    );
    sala
      ..configurarEnrutamiento(nuevos.impresion.enrutamiento)
      ..configurarPases(nuevos.impresion.pases);
    stock.configurar(
      stock: mysql?.stock,
      recetas: mysql?.recetas,
      codalmacen: nuevos.fiscal.codalmacen,
    );
    billing.configurar(
      fiscal: nuevos.fiscal,
      invoice: fs?.invoice,
      masterData: fs?.masterData,
    );
    cierreZ.configurar(
      cierre: nuevos.cierre,
      fiscal: nuevos.fiscal,
      accounting: fs?.accounting,
      nombreTpv: nuevos.nombreTpv,
    );
    reposicion.configurar(
      settings: nuevos.reposicion,
      codalmacen: nuevos.fiscal.codalmacen,
      stock: mysql?.stock,
      supplierOrders: fs?.supplierOrder,
    );
    if (previos.mesas != nuevos.mesas) {
      _avisarMesasConservadas(alerts, await sala.configurarMesas(nuevos.mesas));
    }
    if (_started) {
      try {
        await network.applyConfig(
          _networkConfig(
            nuevos,
            serverOptions: network.config.serverOptions,
            bindAddress: network.config.bindAddress,
            discoveryEnabled: network.config.discoveryEnabled,
          ),
        );
        if (!network.isRunning) await network.start();
      } on NetworkException catch (error) {
        // Puerto ocupado u otro fallo de red: se avisa y el resto de los
        // ajustes (cola, puesta a punto) se aplica igualmente.
        alerts.error(
          'No se pudo abrir la red del host',
          detalle: error.message,
          origen: 'red',
        );
      }
      if (outbox.pausada &&
          (erpCambio || mysqlCambio || fiscalCambio || cierreCambio)) {
        await reanudarSincronizacion();
      }
      if (erpCambio || mysqlCambio) _bootstrap = _lanzarBootstrap();
    }
  }

  /// Para todo y libera los recursos. Espera a los efectos en vuelo y a la
  /// escritura del diario.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final s in _subscriptions) {
      await s.cancel();
    }
    // Antes de esperar los efectos en vuelo: una espera de factura del modo
    // «Emitir factura al cobrar» retendría el cierre hasta su plazo.
    printing.cancelarEsperas();
    await network.dispose();
    await sala.dispose();
    await printing.idle();
    await outbox.dispose();
    await reposicion.dispose();
    await cierreZ.dispose();
    await billing.dispose();
    await stock.dispose();
    await catalog.dispose();
    await _infra.dispose();
    await store.dispose();
    await alerts.dispose();
  }

  // ---------------------------------------------------------------------------

  static void _avisarMesasConservadas(AlertBus alerts, List<String> nombres) {
    if (nombres.isEmpty) return;
    alerts.aviso(
      'Mesas con comanda abierta conservadas',
      detalle:
          'No se han quitado ${nombres.join(', ')} porque tienen una comanda '
          'abierta. Cóbralas o vacíalas y vuelve a guardar los ajustes.',
      origen: 'sala',
    );
  }

  /// Lanza la puesta a punto en segundo plano. Nadie espera ese `Future`
  /// (salvo [listo]) y un cambio de ajustes lo sustituye: cualquier error se
  /// registra aquí para que nunca acabe como error asíncrono sin capturar.
  Future<void> _lanzarBootstrap() =>
      _bootstrapInfra().catchError((Object error, StackTrace stackTrace) {
        _log.warning('Puesta a punto interrumpida', error, stackTrace);
      });

  Future<void> _bootstrapInfra() async {
    final fs = _infra.fs;
    if (fs != null) {
      await _bootstrapErp(fs);
    }
    final db = _infra.db;
    if (db != null) {
      await _bootstrapMysql(db);
    }
    if (fs != null) _avisarSinNif();
  }

  /// Lee la empresa emisora del ERP, la guarda en el diario si difiere de la
  /// guardada (sin contar `obtenidaEn`) y la pasa a la impresión. Lanza
  /// [ConfigException] si el runtime se cerró mientras se leía.
  Future<EmpresaEmisora> _leerEmpresa(FsPorts fs) async {
    final idempresa = _idempresaErp ?? settings.fiscal.idempresa;
    final leida = EmpresaEmisora.desdeFs(
      await fs.masterData.empresa(idempresa),
      _now(),
    );
    _comprobarAbierto();
    // La comparación va dentro de la escritura: decide sobre el diario
    // vigente al escribir. Si no cambia nada, el store no escribe.
    await store.update((s) {
      final guardada = s.empresa;
      final igual =
          guardada != null && _identidad(guardada) == _identidad(leida);
      return igual ? s : s.copyWith(empresa: leida);
    });
    printing.configurar(empresaErp: leida);
    return leida;
  }

  /// Lanza [ConfigException] si el runtime ya se cerró con [dispose].
  void _comprobarAbierto() {
    if (_disposed) {
      throw const ConfigException(
        'El TPV está cerrado: no se pueden leer los datos de la empresa',
      );
    }
  }

  static String _identidad(EmpresaEmisora empresa) =>
      (empresa.toJson()..remove('obtenidaEn')).toString();

  /// Una vez por sesión, al terminar la puesta a punto con el ERP: sin NIF
  /// del emisor no se pueden imprimir facturas simplificadas.
  void _avisarSinNif() {
    if (_disposed || _avisoSinNif || printing.cabeceraFiscalCompleta) return;
    _avisoSinNif = true;
    alerts.aviso(
      'Sin NIF del emisor: no se pueden imprimir facturas simplificadas',
      origen: 'impresion',
    );
  }

  /// Cada paso es independiente: un fallo (p. ej. `settings` no accesible)
  /// no impide cargar el catálogo.
  Future<void> _bootstrapErp(FsPorts fs) async {
    await _paso('leer los ajustes de FacturaScripts', () async {
      final ajustes = await fs.masterData.settingsDefault();
      sala.configurarCalculo(
        metodo: MetodoIva.parse(ajustes.taxCalculationMethod),
        decimales: ajustes.decimals,
      );
      catalog.configurar(
        port: fs.catalog,
        codimpuestoPorDefecto:
            settings.fiscal.codimpuestoPorDefecto ?? ajustes.codimpuesto,
      );
      _idempresaErp = ajustes.idempresa;
      if (settings.empresa == null) await _leerEmpresa(fs);
    });
    await _paso('descargar el catálogo', () async {
      await catalog.refrescar();
    });
    await _paso('diagnosticar la configuración', () async {
      final diagnostico = await fs.masterData.diagnosticar(
        DiagnosticoConfig(
          codserie: settings.fiscal.codserie,
          codpagoEfectivo: settings.fiscal.codpagoEfectivo,
          codpagoTarjeta: settings.fiscal.codpagoTarjeta,
          codalmacen: settings.fiscal.codalmacen,
          codcliente: settings.fiscal.codcliente,
        ),
      );
      for (final item in diagnostico) {
        if (item.nivel == DiagnosticoNivel.ok) continue;
        alerts.emit(
          item.nivel == DiagnosticoNivel.error
              ? AlertaNivel.error
              : AlertaNivel.aviso,
          item.titulo,
          detalle: item.detalle,
          origen: 'erp',
        );
      }
    });
  }

  Future<void> _paso(String que, Future<void> Function() accion) async {
    if (_disposed) return;
    try {
      await accion();
    } on AppException catch (error) {
      _log.warning('No se pudo $que', error);
      if (!_disposed) {
        alerts.aviso('No se pudo $que', detalle: error.message, origen: 'erp');
      }
    } on Object catch (error, stackTrace) {
      // Cliente cerrado por un cambio de ajustes, runtime cerrado durante la
      // puesta a punto...: se registra y se sigue con el siguiente paso.
      _log.warning('No se pudo $que', error, stackTrace);
    }
  }

  Future<void> _bootstrapMysql(MysqlDatabase db) async {
    if (_disposed) return;
    try {
      final inspeccion = await TpvSchemaMigrator(db).ensure();
      for (final aviso in inspeccion.warnings) {
        alerts.aviso('Esquema MySQL: $aviso', origen: 'mysql');
      }
      await stock.recetasVigentes(forzar: true);
    } on AppException catch (error) {
      _log.warning('Puesta a punto de MySQL incompleta', error);
      if (!_disposed) {
        alerts.aviso(
          'No se pudo preparar MySQL para el stock',
          detalle: error.message,
          origen: 'mysql',
        );
      }
    } on Object catch (error, stackTrace) {
      _log.warning('Puesta a punto de MySQL interrumpida', error, stackTrace);
    }
  }

  void _tras(Future<Object?> future) {
    unawaited(
      future.catchError((Object error, StackTrace stackTrace) {
        _log.warning('Tarea encadenada fallida', error, stackTrace);
        return null;
      }),
    );
  }

  static HostNetworkConfig _networkConfig(
    HostSettings s, {
    HostServerOptions? serverOptions,
    InternetAddress? bindAddress,
    required bool discoveryEnabled,
  }) => HostNetworkConfig(
    hostId: s.deviceId,
    hostName: s.nombreTpv,
    tcpPort: s.tcpPort,
    discoveryPort: s.discoveryPort,
    pairingCode: s.pairingCode,
    bindAddress: bindAddress,
    discoveryEnabled: discoveryEnabled,
    serverOptions: serverOptions,
  );
}

/// Recursos externos construidos a partir de los ajustes (o inyectados).
final class _Infra {
  _Infra({
    required this.api,
    required this.db,
    required this.printerPort,
    required this.fs,
    required this.mysql,
    required this._ownsApi,
    required this._ownsDb,
    required this._ownsPrinter,
  });

  factory _Infra.build(
    HostSettings settings, {
    FsApi? api,
    MysqlDatabase? db,
    RawPrinterTransport? printer,
    PrinterPort? printerPort,
    bool ownsApi = false,
    bool ownsDb = false,
    bool ownsPrinter = false,
    FsApi Function(FsApiConfig config)? apiFactory,
    required DateTime Function() now,
  }) {
    // [ownsApi], [ownsDb] y [ownsPrinter] dicen si el recurso INYECTADO es
    // del runtime (lo creó un _Infra anterior); lo que se crea aquí siempre
    // lo es.
    var fsApi = api;
    if (fsApi == null) ownsApi = false;
    final erp = settings.erp;
    if (fsApi == null && erp != null) {
      fsApi = apiFactory?.call(erp) ?? FsHttpApi(erp, now: now);
      ownsApi = true;
    }
    var database = db;
    if (database == null) ownsDb = false;
    if (database == null && settings.mysql != null) {
      database = MysqlDatabase(settings.mysql!);
      ownsDb = true;
    }
    var port = printerPort;
    if (port == null) ownsPrinter = false;
    if (port == null && settings.impresion.hayImpresora) {
      port = PrintQueueAdapter.forTransport(
        printer ?? EscPosSocketPrinter(),
        now: now,
      );
      ownsPrinter = true;
    }
    return _Infra(
      api: fsApi,
      db: database,
      printerPort: port,
      fs: fsApi == null ? null : FsPorts(fsApi, now: now),
      mysql: database == null ? null : MysqlPorts(database, now: now),
      ownsApi: ownsApi,
      ownsDb: ownsDb,
      ownsPrinter: ownsPrinter,
    );
  }

  final FsApi? api;
  final MysqlDatabase? db;
  final PrinterPort? printerPort;
  final FsPorts? fs;
  final MysqlPorts? mysql;
  final bool _ownsApi;
  final bool _ownsDb;
  final bool _ownsPrinter;

  Future<void> dispose({
    bool keepApi = false,
    bool keepDb = false,
    bool keepPrinter = false,
  }) async {
    final http = api;
    if (_ownsApi && !keepApi && http is FsHttpApi) await http.close();
    final database = db;
    if (_ownsDb && !keepDb && database != null) await database.close();
    final queue = printerPort;
    if (_ownsPrinter && !keepPrinter && queue is PrintQueueAdapter) {
      await queue.dispose();
    }
  }
}
