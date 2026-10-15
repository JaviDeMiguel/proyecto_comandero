/// El comandero REAL contra el host REAL: un [ComanderoController] habla por
/// TCP en loopback con [HostNetworkService] y [SalaService], la misma pila
/// que monta `host_network_service_test.dart`. Recorre los pases de punta a
/// punta: pedir con pases, marchar, reconectar con retransmisión sin
/// duplicar la marcha (aunque el host pierda su caché de respuestas), la
/// orden caducada de una comanda ya cobrada y los comensales. Así
/// `FakeSalaHost` no puede divergir del host real sin que se note.
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:proyecto_comandero/core/network/tcp/tcp_comandero_client.dart';
import 'package:proyecto_comandero/core/network/tcp/tcp_host_server.dart';
import 'package:proyecto_comandero/features/comandero/application/comandero_controller.dart';
import 'package:proyecto_comandero/features/comandero/domain/comandero_config.dart';
import 'package:proyecto_comandero/features/comandero/domain/comandero_exceptions.dart';
import 'package:proyecto_comandero/features/comandero/domain/comandero_state.dart';
import 'package:proyecto_comandero/features/host/application/alert_bus.dart';
import 'package:proyecto_comandero/features/host/application/catalog_service.dart';
import 'package:proyecto_comandero/features/host/application/host_network_service.dart';
import 'package:proyecto_comandero/features/host/application/host_state_repository.dart';
import 'package:proyecto_comandero/features/host/application/host_state_store.dart';
import 'package:proyecto_comandero/features/host/application/sala_effects.dart';
import 'package:proyecto_comandero/features/host/application/sala_service.dart';
import 'package:proyecto_comandero/features/host/domain/host_snapshot.dart';
import 'package:proyecto_comandero/features/sala/domain/comanda.dart';
import 'package:proyecto_comandero/features/sala/domain/linea_comanda.dart';
import 'package:proyecto_comandero/features/sala/domain/marcha_pase.dart';
import 'package:proyecto_comandero/features/sala/domain/mesa.dart';
import 'package:proyecto_comandero/features/sala/domain/pases.dart';
import 'package:proyecto_comandero/features/sala/domain/ticket.dart';
import 'package:proyecto_comandero/features/sala/protocol/sala_messages.dart';
import 'package:test/test.dart';

import '../comandero/fake_sala_host.dart' show freeTcpPort, kWait, waitState;
import 'fakes/fake_ports.dart';
import 'support/host_test_support.dart';

/// Servidor con latido y plazos cortos, como en `host_network_service_test`.
const HostServerOptions _opcionesServidor = HostServerOptions(
  handshakeTimeout: Duration(seconds: 1),
  heartbeatInterval: Duration(milliseconds: 50),
  idleTimeout: Duration(milliseconds: 500),
  closeTimeout: Duration(milliseconds: 100),
);

/// Reconexión rápida y sin redescubrimiento UDP: el host de la prueba vuelve
/// siempre en la misma dirección y el mismo puerto.
const ClientOptions _opcionesComandero = ClientOptions(
  connectTimeout: Duration(seconds: 1),
  handshakeTimeout: Duration(seconds: 1),
  requestTimeout: Duration(seconds: 2),
  reconnectBaseDelay: Duration(milliseconds: 20),
  reconnectMaxDelay: Duration(milliseconds: 80),
  rediscoverAfterFailures: 1000,
  closeTimeout: Duration(milliseconds: 100),
);

/// El comandero no manda camarero: el host firma con este nombre.
const String _dispositivo = 'Comandero 1';

const ComanderoConfig _config = ComanderoConfig(
  deviceId: 'movil-1',
  deviceName: _dispositivo,
  appVersion: '1.0.0',
);

/// Diario en memoria cuyos guardados se pueden retener: la mutación ya está
/// aplicada en el host, pero la petición que la hizo no responde hasta que
/// se suelta. Así se pierde un `ack` de forma determinista.
final class _DiarioRetenible implements HostStateRepository {
  HostSnapshot? _guardado;
  Completer<void>? _puerta;

  /// Se completa cuando un guardado queda retenido tras [retener].
  Completer<void> retenido = Completer<void>();

  /// Retiene los guardados desde ahora hasta [soltar].
  void retener() {
    _puerta = Completer<void>();
    retenido = Completer<void>();
  }

  void soltar() {
    final puerta = _puerta;
    _puerta = null;
    puerta?.complete();
  }

  @override
  Future<HostSnapshot?> load() async => _guardado;

  @override
  Future<void> save(HostSnapshot snapshot) async {
    _guardado = snapshot;
    final puerta = _puerta;
    if (puerta == null) return;
    if (!retenido.isCompleted) retenido.complete();
    await puerta.future;
  }
}

/// Marchas que la sala despacha a la impresión: solo las pulsaciones nuevas,
/// nunca una retransmisión ni una marcha automática.
final class _MarchasImpresas extends SalaEffects {
  final List<MarchaPase> marchas = [];

  @override
  Future<void> onPaseMarchado(
    Mesa mesa,
    Comanda comanda,
    MarchaPase marcha,
    List<LineaComanda> lineas,
  ) async => marchas.add(marcha);
}

/// Host real: diario, catálogo, sala (pases por defecto: activos y con
/// «marchar al enviar») y red en un puerto fijo de loopback, para poder
/// pararla y volver a arrancarla en el mismo puerto.
final class _Host {
  _Host._({
    required this.diario,
    required this.alerts,
    required this.store,
    required this.catalog,
    required this.sala,
    required this.efectos,
    required this.red,
  });

  static Future<_Host> arrancar() async {
    final diario = _DiarioRetenible();
    final reloj = FakeClock();
    final alerts = AlertBus(now: reloj.call);
    final catalogo = catalogoPrueba();
    final store = await HostStateStore.load(
      diario,
      initial: () => HostSnapshot(
        mesas: mesasPrueba,
        catalogo: catalogo,
        catalogoVersion: CatalogService.versionDe(catalogo),
      ),
      alerts: alerts,
    );
    final catalog = CatalogService(
      store: store,
      alerts: alerts,
      now: reloj.call,
    );
    var ids = 0;
    final sala = SalaService(
      store: store,
      alerts: alerts,
      catalog: catalog,
      now: reloj.call,
      newId: () => 'h-${++ids}',
    );
    final efectos = _MarchasImpresas();
    sala.addEffects(efectos);
    final red = HostNetworkService(
      sala: sala,
      catalog: catalog,
      alerts: alerts,
      config: HostNetworkConfig(
        hostId: 'host-1',
        hostName: 'Barra principal',
        tcpPort: await freeTcpPort(),
        bindAddress: InternetAddress.loopbackIPv4,
        discoveryEnabled: false,
        serverOptions: _opcionesServidor,
      ),
    );
    await red.start();
    return _Host._(
      diario: diario,
      alerts: alerts,
      store: store,
      catalog: catalog,
      sala: sala,
      efectos: efectos,
      red: red,
    );
  }

  final _DiarioRetenible diario;
  final AlertBus alerts;
  final HostStateStore store;
  final CatalogService catalog;
  final SalaService sala;
  final _MarchasImpresas efectos;
  final HostNetworkService red;

  Future<void> parar() async {
    diario.soltar();
    await red.dispose();
    await sala.dispose();
    await catalog.dispose();
    await store.dispose();
    await alerts.dispose();
  }
}

void main() {
  late _Host host;
  late ComanderoController comandero;
  var ids = 0;

  setUp(() async {
    host = await _Host.arrancar();
    comandero = ComanderoController(
      config: _config,
      clientOptions: _opcionesComandero,
      reintentoCargaSala: const Duration(milliseconds: 50),
      reintentoCatalogo: const Duration(milliseconds: 50),
      newId: () => 'c-${++ids}',
      clientFactory: (identity, options, rediscover) => TcpComanderoClient(
        identity: identity,
        options: options,
        rediscover: rediscover,
        random: Random(7),
      ),
    );
    comandero.conectar(
      HostObjetivo(
        endpoint: HostEndpoint(host: '127.0.0.1', port: host.red.tcpPort!),
      ),
    );
  });

  tearDown(() async {
    await comandero.dispose();
    await host.parar();
  });

  /// Espera a que el comandero tenga la sala cargada, sin nada pendiente y,
  /// si se da, con una sala que cumpla [condicion].
  Future<Conectado> conectado([bool Function(SalaSnapshot sala)? condicion]) =>
      waitState<Conectado>(
        comandero.states,
        comandero.state,
        (s) => s.pendientes == 0 && (condicion?.call(s.sala) ?? true),
        what: 'Conectado',
      );

  /// Para la red del host y espera a que el comandero lo note.
  Future<void> cortarRed() async {
    await host.red.stop();
    await waitState<Reconectando>(
      comandero.states,
      comandero.state,
      (_) => true,
      what: 'Reconectando',
    );
  }

  /// Pide en la mesa 1 dos cañas de primero y una paella de segundo y
  /// devuelve la comanda que responde el host.
  Future<Comanda> pedirConPases() async {
    comandero
      ..anadirReferencia('m1', 'CANA', cantidad: 2, pase: 1)
      ..anadirReferencia('m1', 'PAELLA', pase: 2);
    return (await comandero.enviar('m1')).comanda;
  }

  /// Rechazo de sala tipado en el comandero, con la mesa 1.
  Matcher rechazo(String que, bool Function(ComanderoSalaException e) es) =>
      throwsA(
        isA<ComanderoSalaException>()
            .having(es, que, isTrue)
            .having((e) => e.mesaId, 'mesaId', 'm1')
            .having((e) => e.retryable, 'retryable', isFalse),
      );

  test('pedir con pases: el host conserva el pase de cada línea, numera el '
      'envío, lo firma con el nombre del dispositivo y marcha el 1.º '
      'solo', () async {
    final sesion = await conectado();
    expect(sesion.sala.pases, const PasesConfig());
    expect(comandero.pases?.activos, isTrue);

    comandero
      ..anadirReferencia('m1', 'CANA', cantidad: 2, pase: 1)
      ..anadirReferencia('m1', 'PAELLA', pase: 2)
      ..anadirReferencia('m1', 'AGUA');
    final enviado = await comandero.enviar('m1');
    expect(enviado.lineasNuevas, 3);

    final enHost = host.sala.comandaDeMesa('m1')!;
    expect(enviado.comanda, enHost);
    expect(comandero.comandaDe('m1'), enHost);
    expect(enHost.camarero, _dispositivo);
    expect(
      [
        for (final l in enHost.lineas)
          (l.referencia, l.pase, l.envio, l.camarero),
      ],
      [
        ('CANA', 1, 1, _dispositivo),
        ('PAELLA', 2, 1, _dispositivo),
        ('AGUA', null, 1, _dispositivo),
      ],
    );
    final automatica = enHost.marchas.single;
    expect(
      (automatica.pase, automatica.automatica, automatica.camarero),
      (1, true, _dispositivo),
    );
    expect(
      host.efectos.marchas,
      isEmpty,
      reason: 'la marcha automática sale con la comanda del envío',
    );

    // El envío siguiente lleva el número siguiente.
    comandero.anadirReferencia('m1', 'CAFE', pase: 3);
    final segundo = await comandero.enviar('m1');
    expect(segundo.comanda.lineas.last.envio, 2);
    expect(host.store.snapshot.numeroEnvioSiguiente, 3);
  });

  test('marchar: sale con el comandaId de la comanda vista, el host la firma '
      'con el nombre del dispositivo y sus rechazos llegan tipados', () async {
    await conectado();
    final abierta = await pedirConPases();

    final marchada = await comandero.marcharPase('m1', 2);
    expect(marchada.id, abierta.id);
    expect(host.sala.comandaDeMesa('m1'), marchada);
    expect(comandero.comandaDe('m1'), marchada);
    final marcha = marchada.marchas.last;
    expect(
      (marcha.pase, marcha.automatica, marcha.repetida, marcha.camarero),
      (2, false, false, _dispositivo),
    );
    expect(marcha.id, startsWith('c-'), reason: 'lo genera el comandero');
    expect(host.efectos.marchas, [marcha]);

    // Otra pulsación es otra marcha, que sale «repetida».
    final otra = await comandero.marcharPase('m1', 2);
    expect(otra.marchas.last.repetida, isTrue);
    expect(host.efectos.marchas, hasLength(2));

    await expectLater(
      comandero.marcharPase('m1', 3),
      rechazo('paseSinLineas', (e) => e.paseSinLineas),
    );
    await expectLater(
      comandero.marcharPase('m1', 7),
      rechazo('paseNoValido', (e) => e.paseNoValido),
    );
    expect(host.efectos.marchas, hasLength(2));
    expect(comandero.pendientes, 0);
  });

  test('reconectar con retransmisión no duplica la marcha, aunque el host '
      'pierda al reiniciarse su caché de respuestas', () async {
    await conectado();
    final abierta = await pedirConPases();

    // El host registra la marcha, pero su respuesta no llega: la red se
    // reinicia mientras guarda el diario.
    host.diario.retener();
    final marchando = comandero.marcharPase('m1', 2);
    await host.diario.retenido.future.timeout(kWait);
    await cortarRed();
    expect(comandero.pendientes, 1);
    final guardada = host.sala.changes.first;
    host.diario.soltar();
    final registrada = (await guardada.timeout(kWait)).comanda!.marchas.last;
    expect((registrada.pase, registrada.automatica), (2, false));
    expect(host.efectos.marchas, [registrada]);

    // La red vuelve sin la caché del transporte: la cola fiable del
    // comandero retransmite el mismo mensaje (mismo marchaId) y el host lo
    // reconoce por la marcha guardada en el diario.
    await host.red.start();
    final comanda = await marchando.timeout(kWait);
    expect(comanda.id, abierta.id);
    expect(comanda.marchas.where((m) => !m.automatica), [registrada]);
    expect(host.sala.comandaDeMesa('m1'), comanda);
    expect(host.efectos.marchas, [
      registrada,
    ], reason: 'ni se repite ni se reimprime');
    await conectado();
    expect(comandero.comandaDe('m1'), comanda);
  });

  test('un comandaId de una comanda ya cobrada da el error de orden caducada: '
      'no marcha ni cambia los comensales de los clientes nuevos', () async {
    await conectado();
    final vista = await pedirConPases();

    // Sin red, el comandero marcha el 2.º y fija comensales sobre la
    // comanda que ve; los errores se esperan desde ya.
    await cortarRed();
    final marchaCaducada = expectLater(
      comandero.marcharPase('m1', 2),
      rechazo('mesaSinComanda', (e) => e.mesaSinComanda),
    );
    final comensalesCaducados = expectLater(
      comandero.fijarComensales('m1', 6),
      rechazo('mesaSinComanda', (e) => e.mesaSinComanda),
    );
    expect(comandero.pendientes, 2);

    // Mientras, en la tablet se cobra la mesa y otros clientes piden.
    await host.sala.cobrar('m1', MetodoPago.tarjeta);
    final nueva = (await host.sala.aceptarLineas(
      submit('m1', [
        linea('t1', 'CAFE', 1, pase: 1),
        linea('t2', 'PAELLA', 1, pase: 2),
      ], camarero: 'Barra'),
    )).comanda;
    expect(nueva.id, isNot(vista.id));

    await host.red.start();
    await marchaCaducada;
    await comensalesCaducados;
    final enHost = host.sala.comandaDeMesa('m1')!;
    expect(enHost.id, nueva.id);
    expect(enHost.pasesMarchados, {1}, reason: 'su 2.º sigue esperando');
    expect(enHost.comensales, isNull);
    expect(host.efectos.marchas, isEmpty);
    // El comandero acaba viendo la comanda nueva.
    await conectado((s) => s.comandaDeMesa('m1')?.id == nueva.id);
  });

  test('comensales: con la comanda abierta vuelve la MISMA comanda; con la '
      'mesa ya cobrada el comandero lo rechaza y el host no deja una comanda '
      'fantasma', () async {
    await conectado();
    final abierta = await pedirConPases();
    final envioSiguiente = host.store.snapshot.numeroEnvioSiguiente;

    final conComensales = await comandero.fijarComensales('m1', 4);
    expect(conComensales.id, abierta.id);
    expect(conComensales.comensales, 4);
    expect(host.sala.comandaDeMesa('m1'), conComensales);
    expect(comandero.comandaDe('m1'), conComensales);
    expect(
      host.store.snapshot.numeroEnvioSiguiente,
      envioSiguiente,
      reason: 'un envío sin líneas no consume número',
    );

    // Sin red, el comandero fija 6 comensales; mientras, la mesa se cobra.
    await cortarRed();
    final tarde = expectLater(
      comandero.fijarComensales('m1', 6),
      rechazo('mesaSinComanda', (e) => e.mesaSinComanda),
    );
    await host.sala.cobrar('m1', MetodoPago.efectivo);
    await host.red.start();
    await tarde;
    expect(host.sala.comandaDeMesa('m1'), isNull);
    await conectado((s) => s.comandaDeMesa('m1') == null);
    expect(comandero.comandaDe('m1'), isNull);
  });
}
