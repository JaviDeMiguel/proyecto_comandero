import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:proyecto_comandero/core/facturascripts/fs_api.dart';
import 'package:proyecto_comandero/core/facturascripts/fs_api_config.dart';
import 'package:proyecto_comandero/core/facturascripts/fs_http_api.dart';
import 'package:proyecto_comandero/core/isolates/isolate_runner.dart';
import 'package:proyecto_comandero/core/network/printing/raw_printer_transport.dart';
import 'package:proyecto_comandero/core/network/tcp/tcp_comandero_client.dart';
import 'package:proyecto_comandero/core/network/tcp/tcp_host_server.dart';
import 'package:proyecto_comandero/features/host/application/catalog_service.dart';
import 'package:proyecto_comandero/features/host/application/host_runtime.dart';
import 'package:proyecto_comandero/features/host/data/in_memory_host_state_repository.dart';
import 'package:proyecto_comandero/features/host/domain/host_settings.dart';
import 'package:proyecto_comandero/features/host/domain/host_snapshot.dart';
import 'package:proyecto_comandero/features/host/domain/sync_job.dart';
import 'package:proyecto_comandero/features/sala/domain/enrutamiento_comandas.dart';
import 'package:proyecto_comandero/features/sala/domain/linea_comanda.dart';
import 'package:proyecto_comandero/features/sala/domain/mesa.dart';
import 'package:proyecto_comandero/features/sala/domain/ticket.dart';
import 'package:proyecto_comandero/features/sala/protocol/sala_messages.dart';
import 'package:test/test.dart';

import '../../core/facturascripts/fake_fs_api.dart';
import '../../core/network/tcp/test_support.dart';
import 'fakes/fake_ports.dart';
import 'support/host_test_support.dart';

const HostServerOptions _serverOptions = HostServerOptions(
  handshakeTimeout: Duration(seconds: 1),
  heartbeatInterval: Duration(milliseconds: 50),
  idleTimeout: Duration(milliseconds: 500),
  closeTimeout: Duration(milliseconds: 100),
);

/// `FakeFsApi.conDatosBasicos` no conoce el recurso `familias` (ni
/// `settings`); se cubre para que el catálogo pueda descargarse.
final class ApiConCatalogo extends FakeFsApiDelegate {
  ApiConCatalogo(super.inner);

  @override
  Future<List<FsRecord>> listAll(
    String resource, {
    Map<String, Object?> filters = const {},
    required String sortBy,
    int pageSize = 200,
  }) {
    if (resource == 'familias') return Future.value(const []);
    return super.listAll(
      resource,
      filters: filters,
      sortBy: sortBy,
      pageSize: pageSize,
    );
  }
}

HostSettings settingsBase({bool conErp = false}) => HostSettings(
  deviceId: 'tablet-1',
  nombreTpv: 'Barra',
  tcpPort: 0,
  discoveryPort: 0,
  erp: conErp
      ? FsApiConfig(baseUrl: 'http://erp.local/fs', token: 'secreto')
      : null,
  fiscal: const FiscalSettings(
    codcliente: 'TPVVARIOS',
    codserie: 'S',
    codpagoEfectivo: 'TPVEFE',
    codpagoTarjeta: 'TPVTAR',
    codalmacen: 'ALG',
  ),
  impresion: ImpresionSettings(tickets: PrinterEndpoint('10.0.0.12')),
  mesas: mesasPrueba,
);

void main() {
  late InMemoryHostStateRepository repo;
  late FakeClock clock;
  final runtimes = <HostRuntime>[];
  final clients = <TcpComanderoClient>[];

  setUp(() {
    repo = InMemoryHostStateRepository();
    clock = FakeClock();
  });

  tearDown(() async {
    for (final c in clients) {
      await c.dispose();
    }
    clients.clear();
    for (final r in runtimes) {
      await r.dispose();
    }
    runtimes.clear();
  });

  Future<HostRuntime> arrancar(
    HostSettings settings, {
    FakeFsApi? api,
    FakePrinterPort? printer,
  }) async {
    final runtime = await HostRuntime.create(
      settings: settings,
      stateRepo: repo,
      api: api == null ? null : ApiConCatalogo(api),
      printerPort: printer ?? FakePrinterPort(),
      runner: const InlineIsolateRunner(),
      now: clock.call,
      serverOptions: _serverOptions,
      bindAddress: InternetAddress.loopbackIPv4,
      discoveryEnabled: false,
    );
    runtimes.add(runtime);
    await runtime.start();
    await runtime.listo;
    return runtime;
  }

  Future<TcpComanderoClient> conectar(HostRuntime runtime) async {
    final client = TcpComanderoClient(
      identity: const ClientIdentity(deviceId: 'movil', deviceName: 'Móvil'),
      options: const ClientOptions(
        connectTimeout: Duration(seconds: 1),
        handshakeTimeout: Duration(seconds: 1),
        requestTimeout: Duration(seconds: 2),
        reconnectBaseDelay: Duration(milliseconds: 10),
        reconnectMaxDelay: Duration(milliseconds: 50),
        closeTimeout: Duration(milliseconds: 100),
      ),
      random: Random(1),
    );
    clients.add(client);
    final connected = client.states.firstWhere((s) => s is Connected);
    client.connect(
      HostEndpoint(host: '127.0.0.1', port: runtime.network.tcpPort!),
    );
    await connected.timeout(kWait);
    return client;
  }

  test(
    'sin ERP ni MySQL la sala funciona en red y la factura espera',
    () async {
      final printer = FakePrinterPort();
      final runtime = await arrancar(settingsBase(), printer: printer);
      expect(runtime.erpConfigurado, isFalse);
      expect(runtime.mysqlConfigurado, isFalse);
      expect(runtime.impresoraConfigurada, isTrue);
      expect(runtime.network.isRunning, isTrue);
      expect(runtime.sala.mesas, mesasPrueba);

      final client = await conectar(runtime);
      final result = ComandaSubmitResult.fromJson(
        (await client.request(
          SalaMessageTypes.comandaSubmit,
          ComandaSubmitPayload(
            mesaId: 'm1',
            lineas: [linea('l1', 'CANA', 7)],
          ).toJson(),
          reliable: true,
        )).payload,
      );
      expect(result.lineasNuevas, 1);

      final ticket = await runtime.sala.cobrar(
        'm1',
        MetodoPago.efectivo,
        entregadoCents: 700,
      );
      await runtime.sala.idle();
      await runtime.outbox.idle();
      await runtime.printing.idle();
      expect(ticket.totalCents, 665);
      expect(printer.jobs.single.description, 'Ticket 1');
      // La factura queda en la cola, en pausa por falta de ERP.
      expect(runtime.outbox.pausada, isTrue);
      expect(runtime.outbox.estado.bloqueados, 1);
      expect(
        runtime.alerts.recientes.map((a) => a.titulo),
        contains(contains('en pausa')),
      );
    },
  );

  test(
    'reinicio sobre el mismo diario con ERP: la cola se reanuda y factura',
    () async {
      final primero = await arrancar(settingsBase());
      await primero.sala.aceptarLineas(submit('m1', [linea('l1', 'CANA', 7)]));
      final ticket = await primero.sala.cobrar('m1', MetodoPago.tarjeta);
      await primero.sala.aceptarLineas(submit('m2', [linea('l2', 'CAFE', 1)]));
      await primero.sala.idle();
      await primero.outbox.idle();
      await primero.dispose();
      runtimes.remove(primero);

      final api = FakeFsApi.conDatosBasicos();
      final segundo = await arrancar(settingsBase(conErp: true), api: api);
      expect(segundo.erpConfigurado, isTrue);
      // El estado sobrevivió: mesa 2 sigue abierta y el ticket en el turno.
      expect(segundo.sala.comandaDeMesa('m2'), isNotNull);
      expect(segundo.store.snapshot.ticketPorId(ticket.id), isNotNull);
      // El catálogo se cargó del ERP y la sala conoce el método de cálculo.
      expect(segundo.catalog.disponible, isTrue);
      expect(segundo.catalog.articulo('PAELLA'), isNotNull);

      // La cola arrancó en pausa (venía bloqueada): al reanudar factura.
      expect(segundo.outbox.pausada, isTrue);
      await segundo.outbox.reanudar();
      await segundo.outbox.idle();
      final job = segundo.store.snapshot.jobPorId('factura:${ticket.id}')!;
      expect(job.estado, SyncJobEstado.hecho);
      final factura = segundo.store.snapshot.ticketPorId(ticket.id)!.factura!;
      expect(factura.estado, EstadoSincronizacion.sincronizado);
      expect(api.table('facturaclientes'), hasLength(1));
    },
  );

  test(
    'applySettings reconfigura el ERP en caliente y reanuda la cola',
    () async {
      final runtime = await arrancar(settingsBase());
      await runtime.sala.aceptarLineas(submit('m1', [linea('l1', 'CANA', 1)]));
      final ticket = await runtime.sala.cobrar('m1', MetodoPago.tarjeta);
      await runtime.sala.idle();
      await runtime.outbox.idle();
      expect(runtime.outbox.pausada, isTrue);

      // Un ERP nuevo: como la API real no es alcanzable en el test, se
      // inyecta tras aplicar los ajustes sustituyendo los puertos.
      final api = FakeFsApi.conDatosBasicos();
      final conErp = await HostRuntime.create(
        settings: settingsBase(conErp: true),
        stateRepo: repo,
        api: api,
        printerPort: FakePrinterPort(),
        runner: const InlineIsolateRunner(),
        now: clock.call,
        serverOptions: _serverOptions,
        bindAddress: InternetAddress.loopbackIPv4,
        discoveryEnabled: false,
      );
      runtimes.add(conErp);
      await runtime.dispose();
      runtimes.remove(runtime);
      await conErp.start();
      await conErp.listo;

      // Cambio de nombre y de mesas en caliente, sin tocar la red.
      final puerto = conErp.network.tcpPort;
      await conErp.applySettings(
        conErp.settings.copyWith(
          nombreTpv: 'Terraza',
          mesas: [
            ...mesasPrueba,
            const Mesa(id: 'm9', nombre: 'Mesa 9'),
          ],
        ),
      );
      expect(conErp.network.tcpPort, puerto);
      expect(conErp.sala.mesas.map((m) => m.id), contains('m9'));
      expect(conErp.network.config.hostName, 'Terraza');

      await conErp.outbox.reanudar();
      await conErp.outbox.idle();
      expect(
        conErp.store.snapshot.ticketPorId(ticket.id)!.factura!.estado,
        EstadoSincronizacion.sincronizado,
      );
      // Quitar el ERP deja la facturación no disponible pero la sala sigue.
      await conErp.applySettings(conErp.settings.copyWith(quitarErp: true));
      expect(conErp.erpConfigurado, isFalse);
      expect(conErp.billing.disponible, isFalse);
      await conErp.sala.aceptarLineas(submit('m9', [linea('l3', 'CANA', 1)]));
      expect(conErp.sala.comandaDeMesa('m9'), isNotNull);
    },
  );

  test('un puerto TCP ocupado no tumba el runtime: avisa', () async {
    final ocupado = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(ocupado.close);
    final runtime = await HostRuntime.create(
      settings: settingsBase().copyWith(tcpPort: ocupado.port),
      stateRepo: repo,
      printerPort: FakePrinterPort(),
      runner: const InlineIsolateRunner(),
      now: clock.call,
      serverOptions: _serverOptions,
      bindAddress: InternetAddress.loopbackIPv4,
      discoveryEnabled: false,
    );
    runtimes.add(runtime);
    await runtime.start();
    expect(runtime.network.isRunning, isFalse);
    expect(
      runtime.alerts.recientes.map((a) => a.titulo),
      contains(contains('red del host')),
    );
    // Con un puerto libre la red arranca al aplicar ajustes.
    await runtime.applySettings(runtime.settings.copyWith(tcpPort: 0));
    expect(runtime.network.isRunning, isTrue);
  });

  test('el enrutamiento de los ajustes llega a la sala y se cambia en '
      'caliente con applySettings', () async {
    repo = InMemoryHostStateRepository(
      HostSnapshot(
        mesas: mesasPrueba,
        catalogo: catalogoPrueba(),
        catalogoVersion: CatalogService.versionDe(catalogoPrueba()),
      ),
    );
    const bebidasABarra = EnrutamientoComandas(
      porFamilia: {'BEB': DestinoPreparacion.barra},
    );
    final printer = FakePrinterPort();
    final base = settingsBase();
    final runtime = await arrancar(
      base.copyWith(
        impresion: ImpresionSettings(
          cocina: PrinterEndpoint('10.0.0.10'),
          barra: PrinterEndpoint('10.0.0.11'),
          enrutamiento: bebidasABarra,
        ),
      ),
      printer: printer,
    );
    expect(runtime.sala.enrutamiento, bebidasABarra);
    expect(runtime.sala.snapshot().enrutamiento, bebidasABarra);
    final antes = await runtime.sala.aceptarLineas(
      submit('m1', [linea('l1', 'CANA', 1)]),
    );
    expect(antes.comanda.lineaPorId('l1')!.destino, DestinoPreparacion.barra);

    await runtime.applySettings(
      runtime.settings.copyWith(
        impresion: ImpresionSettings(
          cocina: PrinterEndpoint('10.0.0.10'),
          barra: PrinterEndpoint('10.0.0.11'),
        ),
      ),
    );
    expect(runtime.sala.enrutamiento, const EnrutamientoComandas());
    final despues = await runtime.sala.aceptarLineas(
      submit('m1', [linea('l2', 'CANA', 1, destino: DestinoPreparacion.barra)]),
    );
    expect(
      despues.comanda.lineaPorId('l2')!.destino,
      DestinoPreparacion.cocina,
      reason: 'sin reglas, el host manda todo a cocina',
    );
    await runtime.sala.idle();
    await runtime.printing.idle();
    expect(printer.jobs.map((j) => j.endpoint.host), [
      '10.0.0.11',
      '10.0.0.10',
    ]);
  });

  test('las comandas sin impresora ni destino no fallan', () async {
    final runtime = await arrancar(
      settingsBase().copyWith(impresion: const ImpresionSettings()),
    );
    expect(runtime.printing.disponible, isFalse);
    final result = await runtime.sala.aceptarLineas(
      submit('barra', [
        linea('l1', 'CANA', 1, destino: DestinoPreparacion.barra),
      ]),
    );
    await runtime.sala.idle();
    expect(result.lineasNuevas, 1);
    expect(
      runtime.alerts.recientes.where((a) => a.origen == 'impresion'),
      isEmpty,
    );
  });

  Future<HostRuntime> crearConFactoria(
    HostSettings settings,
    FsApi Function(FsApiConfig config) apiFactory,
  ) async {
    final runtime = await HostRuntime.create(
      settings: settings,
      stateRepo: repo,
      apiFactory: apiFactory,
      printerPort: FakePrinterPort(),
      runner: const InlineIsolateRunner(),
      now: clock.call,
      serverOptions: _serverOptions,
      bindAddress: InternetAddress.loopbackIPv4,
      discoveryEnabled: false,
    );
    runtimes.add(runtime);
    return runtime;
  }

  test('h6: reanudarSincronizacion rearma el cortafuegos del cliente del ERP '
      'antes de reanudar la cola', () async {
    var peticiones = 0;
    final runtime = await crearConFactoria(
      settingsBase(conErp: true),
      (config) => FsHttpApi(
        config,
        client: MockClient((request) async {
          peticiones++;
          return http.Response('{"error":"Token no válido"}', 401);
        }),
        now: clock.call,
      ),
    );
    await runtime.start();
    await runtime.listo;
    // La puesta a punto recibió el 401: el cliente rechaza ya en local.
    final tras401 = peticiones;
    expect(tras401, greaterThan(0));

    await runtime.sala.aceptarLineas(submit('m1', [linea('l1', 'CANA', 1)]));
    await runtime.sala.cobrar('m1', MetodoPago.tarjeta);
    await runtime.sala.idle();
    await runtime.outbox.idle();
    expect(runtime.outbox.pausada, isTrue);
    expect(peticiones, tras401, reason: 'rechazada en local');

    // Reanudar solo la cola no basta: vuelve a fallar sin salir a la red.
    await runtime.outbox.reanudar();
    await runtime.outbox.idle();
    expect(peticiones, tras401);
    expect(runtime.outbox.pausada, isTrue);

    await runtime.reanudarSincronizacion();
    await runtime.outbox.idle();
    expect(peticiones, tras401 + 1, reason: 'una petición real al ERP');
  });

  test('h11: un puerto ocupado en applySettings avisa sin lanzar y la cola '
      'se reanuda igualmente', () async {
    final runtime = await arrancar(settingsBase());
    await runtime.sala.aceptarLineas(submit('m1', [linea('l1', 'CANA', 1)]));
    final ticket = await runtime.sala.cobrar('m1', MetodoPago.tarjeta);
    await runtime.sala.idle();
    await runtime.outbox.idle();
    expect(runtime.outbox.pausada, isTrue);
    final jobId = 'factura:${ticket.id}';
    final intentos = runtime.store.snapshot.jobPorId(jobId)!.intentos;

    final ocupado = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(ocupado.close);
    final fiscal = runtime.settings.fiscal;
    await runtime.applySettings(
      runtime.settings.copyWith(
        tcpPort: ocupado.port,
        fiscal: FiscalSettings(
          codcliente: fiscal.codcliente,
          codserie: fiscal.codserie,
          codpagoEfectivo: fiscal.codpagoEfectivo,
          codpagoTarjeta: fiscal.codpagoTarjeta,
          codalmacen: fiscal.codalmacen,
          codimpuestoPorDefecto: 'IVA21',
        ),
      ),
    );
    await runtime.outbox.idle();
    expect(
      runtime.alerts.recientes.map((a) => a.titulo),
      contains(contains('red del host')),
    );
    expect(
      runtime.store.snapshot.jobPorId(jobId)!.intentos,
      intentos + 1,
      reason: 'la cola se reanudó pese al fallo de red',
    );
  });

  test('h12: el cliente del ERP creado por el runtime se sigue cerrando '
      'tras un cambio de ajustes que lo reutiliza', () async {
    final creadas = <FsHttpApi>[];
    final runtime = await crearConFactoria(settingsBase(conErp: true), (
      config,
    ) {
      final api = FsHttpApi(
        config,
        client: MockClient((_) async => http.Response('{}', 503)),
        now: clock.call,
      );
      creadas.add(api);
      return api;
    });
    // Solo cambia la impresora: el cliente del ERP se reutiliza.
    await runtime.applySettings(
      runtime.settings.copyWith(impresion: const ImpresionSettings()),
    );
    expect(creadas, hasLength(1));
    await runtime.dispose();
    expect(creadas.single.resources(), throwsStateError);
  });

  test('h13: cerrar el runtime durante la puesta a punto no deja errores '
      'asíncronos sin capturar', () async {
    final api = ApiQueSeCierra(FakeFsApi.conDatosBasicos());
    final runtime = await HostRuntime.create(
      settings: settingsBase(conErp: true),
      stateRepo: repo,
      api: api,
      printerPort: FakePrinterPort(),
      runner: const InlineIsolateRunner(),
      now: clock.call,
      serverOptions: _serverOptions,
      bindAddress: InternetAddress.loopbackIPv4,
      discoveryEnabled: false,
    );
    runtimes.add(runtime);
    await runtime.start();
    await api.llamado.future;
    await runtime.dispose();
    api.gate.complete();
    // Ni `listo` falla ni queda un error sin capturar en la zona del test.
    await runtime.listo;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  });
}

/// API cuyo listado de familias se queda colgado hasta [gate] y después
/// falla como un cliente cerrado (`StateError`), igual que `FsHttpApi` tras
/// `close()`.
final class ApiQueSeCierra extends FakeFsApiDelegate {
  ApiQueSeCierra(super.inner);

  final Completer<void> gate = Completer<void>();
  final Completer<void> llamado = Completer<void>();

  @override
  Future<List<FsRecord>> listAll(
    String resource, {
    Map<String, Object?> filters = const {},
    required String sortBy,
    int pageSize = 200,
  }) async {
    if (resource == 'familias') {
      if (!llamado.isCompleted) llamado.complete();
      await gate.future;
      throw StateError('FsHttpApi cerrado');
    }
    return super.listAll(
      resource,
      filters: filters,
      sortBy: sortBy,
      pageSize: pageSize,
    );
  }
}
