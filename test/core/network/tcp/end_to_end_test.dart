import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:proyecto_comandero/core/errors/app_exception.dart';
import 'package:proyecto_comandero/core/network/protocol/message.dart';
import 'package:proyecto_comandero/core/network/protocol/transport_messages.dart';
import 'package:proyecto_comandero/core/network/tcp/tcp_comandero_client.dart';
import 'package:proyecto_comandero/core/network/tcp/tcp_host_server.dart';
import 'package:test/test.dart';

import 'test_support.dart';

const HostServerOptions _serverOptions = HostServerOptions(
  port: 0,
  handshakeTimeout: Duration(seconds: 1),
  heartbeatInterval: Duration(milliseconds: 50),
  idleTimeout: Duration(milliseconds: 500),
  closeTimeout: Duration(milliseconds: 100),
);

const ClientOptions _clientOptions = ClientOptions(
  connectTimeout: Duration(seconds: 1),
  handshakeTimeout: Duration(seconds: 1),
  requestTimeout: Duration(seconds: 1),
  reconnectBaseDelay: Duration(milliseconds: 10),
  reconnectMaxDelay: Duration(milliseconds: 50),
  reconnectJitter: 0.2,
  closeTimeout: Duration(milliseconds: 100),
);

void main() {
  late TcpHostServer server;
  final clients = <TcpComanderoClient>[];

  /// Peticiones vistas por el manejador, por dispositivo y en orden.
  final seen = <String, List<String>>{};
  final handlerStarted = StreamController<String>.broadcast();
  final random = Random(2026);

  Future<Map<String, Object?>> handler(
    ClientSessionInfo session,
    ProtocolMessage request,
  ) async {
    seen.putIfAbsent(session.deviceId, () => []).add(request.id);
    handlerStarted.add(session.deviceId);
    if (request.payload['delayMs'] case final int delay when delay > 0) {
      await Future<void>.delayed(Duration(milliseconds: delay));
    }
    return {'id': request.id, 'n': request.payload['n']};
  }

  HostEndpoint endpoint() => HostEndpoint(host: '127.0.0.1', port: server.port);

  TcpComanderoClient newClient(String deviceId) {
    final client = TcpComanderoClient(
      identity: ClientIdentity(
        deviceId: deviceId,
        deviceName: 'Móvil $deviceId',
      ),
      options: _clientOptions,
      random: Random(deviceId.hashCode),
    );
    clients.add(client);
    return client;
  }

  Future<void> waitConnected(TcpComanderoClient client) async {
    if (client.state is Connected) return;
    await client.states
        .firstWhere((s) => s is Connected)
        .timeout(kWait, onTimeout: () => throw TimeoutException('No conectó'));
  }

  setUp(() async {
    seen.clear();
    server = TcpHostServer(
      identity: const HostIdentity(hostId: 'host', hostName: 'Barra'),
      onRequest: handler,
      options: _serverOptions,
    );
    await server.start();
  });

  tearDown(() async {
    for (final client in clients) {
      await client.dispose();
    }
    clients.clear();
    await server.dispose();
  });

  test(
    'handshake, petición, broadcast y sendTo entre extremos reales',
    () async {
      final events = Inbox<HostSessionEvent>(server.events);
      addTearDown(events.cancel);
      final a = newClient('a');
      final b = newClient('b');
      final messagesA = Inbox<ProtocolMessage>(a.messages);
      final messagesB = Inbox<ProtocolMessage>(b.messages);
      addTearDown(messagesA.cancel);
      addTearDown(messagesB.cancel);

      a.connect(endpoint());
      b.connect(endpoint());
      await waitConnected(a);
      await waitConnected(b);
      expect((await events.next()), isA<ClientConnected>());
      expect((await events.next()), isA<ClientConnected>());
      expect(
        server.sessions.map((s) => s.deviceId),
        unorderedEquals(['a', 'b']),
      );
      final welcome = (a.state as Connected).welcome;
      expect(welcome.hostName, 'Barra');
      expect(welcome.heartbeatIntervalMs, 50);

      final reply = await a.request('mesa.open', {'n': 1});
      expect(reply.type, TransportMessageTypes.ack);
      expect(reply.payload['n'], 1);
      expect(seen['a'], hasLength(1));

      expect(server.broadcast('sala.update', {'v': 1}, exceptDeviceId: 'a'), 1);
      expect((await messagesB.next()).type, 'sala.update');
      expect(server.sendTo('a', 'aviso', {'v': 2}), isTrue);
      expect((await messagesA.next()).payload, {'v': 2});
      await messagesA.expectSilence(const Duration(milliseconds: 50));

      await a.disconnect();
      final gone = await events.next();
      expect((gone as ClientDisconnected).reason, ByeReasons.clientClosing);
      expect(server.sessions.map((s) => s.deviceId), ['b']);
    },
  );

  test('el servidor expulsa (disconnect) y el cliente vuelve solo', () async {
    final client = newClient('a');
    final states = Inbox<ClientConnectionState>(client.states);
    addTearDown(states.cancel);
    client.connect(endpoint());
    await waitConnected(client);
    final firstSession = (client.state as Connected).welcome.sessionId;

    await server.disconnect('a');
    await states.nextWhere((s) => s is Reconnecting);
    final reconnected = await states.nextWhere((s) => s is Connected);
    expect((reconnected as Connected).welcome.sessionId, isNot(firstSession));
    expect(server.sessions.map((s) => s.deviceId), ['a']);
  });

  test(
    'caos: 5 clientes x 40 peticiones fiables con cortes aleatorios',
    () async {
      const clientCount = 5;
      const perClient = 40;
      final futures = <String, List<Future<ProtocolMessage>>>{};
      for (var c = 0; c < clientCount; c++) {
        final deviceId = 'dev-$c';
        final client = newClient(deviceId);
        client.connect(endpoint());
        futures[deviceId] = [
          for (var n = 0; n < perClient; n++)
            client.request('comanda.submit', {
              'n': n,
              'delayMs': 2 + random.nextInt(6),
            }, reliable: true),
        ];
      }

      // Bucle de caos: cada pocos ms expulsa a una sesión al azar.
      var cuts = 0;
      final chaos = Timer.periodic(const Duration(milliseconds: 5), (_) {
        final sessions = server.sessions;
        if (sessions.isEmpty) return;
        final victim = sessions[random.nextInt(sessions.length)];
        cuts++;
        unawaited(server.disconnect(victim.deviceId, reason: 'chaos'));
      });

      final all = <Future<void>>[];
      for (final entry in futures.entries) {
        all.add(() async {
          final replies = await Future.wait(entry.value);
          // Cada cliente recibió todos sus acks, en el orden de envío.
          expect(
            replies.map((r) => r.type),
            everyElement(TransportMessageTypes.ack),
          );
          expect(
            replies.map((r) => r.payload['n']),
            List<int>.generate(perClient, (i) => i),
          );
        }());
      }
      try {
        await Future.wait(all).timeout(const Duration(seconds: 90));
      } finally {
        chaos.cancel();
      }
      expect(
        cuts,
        greaterThanOrEqualTo(10),
        reason: 'el caos debe haber actuado',
      );
      printOnFailure('cortes de caos: $cuts');

      // El manejador vio cada id exactamente una vez y en orden por
      // dispositivo.
      for (final entry in futures.entries) {
        final ids = [for (final f in entry.value) (await f).replyTo];
        expect(
          seen[entry.key],
          ids,
          reason: 'orden/duplicados en ${entry.key}',
        );
      }
      final total = seen.values.fold<int>(0, (sum, l) => sum + l.length);
      expect(total, clientCount * perClient);
      for (final client in clients) {
        expect(client.pendingReliableCount, 0);
      }
    },
    timeout: const Timeout(Duration(seconds: 120)),
  );

  test(
    'reinicio del host en el mismo puerto: los clientes vuelven solos',
    () async {
      // Con `port: 0` cada start() daría un puerto distinto: se fija uno libre.
      await server.dispose();
      final probe = await occupyPort();
      final fixedPort = probe.port;
      await probe.close();
      server = TcpHostServer(
        identity: const HostIdentity(hostId: 'host', hostName: 'Barra'),
        onRequest: handler,
        options: HostServerOptions(
          port: fixedPort,
          bindAddress: InternetAddress.loopbackIPv4,
          heartbeatInterval: _serverOptions.heartbeatInterval,
          idleTimeout: _serverOptions.idleTimeout,
          closeTimeout: _serverOptions.closeTimeout,
        ),
      );
      await server.start();
      final a = newClient('a');
      final b = newClient('b');
      final statesA = Inbox<ClientConnectionState>(a.states);
      addTearDown(statesA.cancel);
      a.connect(endpoint());
      b.connect(endpoint());
      await waitConnected(a);
      await waitConnected(b);
      final port = server.port;
      // Esperar a que el manejador haya recibido la petición antes de parar.
      final started = handlerStarted.stream.firstWhere((d) => d == 'a');
      final inFlight = a.request('op', {
        'n': 1,
        'delayMs': 200,
      }, reliable: true);
      await started.timeout(kWait);

      await server.stop();
      expect(server.isRunning, isFalse);
      await statesA.nextWhere((s) => s is Reconnecting);
      // Mientras el host está parado se pueden encolar peticiones fiables.
      final queuedA = a.request('op', {'n': 2}, reliable: true);
      final queuedB = b.request('op', {'n': 3}, reliable: true);
      expect(a.pendingReliableCount, 2);
      await expectLater(a.request('op', {}), throwsA(isA<NetworkException>()));

      // Volver a arrancar en el MISMO puerto (la misma instancia).
      await server.start();
      expect(server.port, port);

      expect((await inFlight).payload['n'], 1);
      expect((await queuedA).payload['n'], 2);
      expect((await queuedB).payload['n'], 3);
      expect(
        server.sessions.map((s) => s.deviceId),
        unorderedEquals(['a', 'b']),
      );
      // La petición en vuelo durante la parada se ejecutó una sola vez.
      expect(seen['a'], hasLength(2));
      expect(seen['b'], hasLength(1));
    },
  );

  test(
    'reemplazo de sesión real: el cliente antiguo queda Rejected(replaced)',
    () async {
      final old = newClient('same');
      final oldStates = Inbox<ClientConnectionState>(old.states);
      addTearDown(oldStates.cancel);
      old.connect(endpoint());
      await waitConnected(old);

      final fresh = newClient('same');
      fresh.connect(endpoint());
      await waitConnected(fresh);

      final rejected = await oldStates.nextWhere((s) => s is Rejected);
      expect((rejected as Rejected).code, ByeReasons.replaced);
      expect(server.sessions, hasLength(1));
      // El nuevo sigue operativo.
      expect((await fresh.request('op', {'n': 9})).payload['n'], 9);
    },
  );

  test(
    'puerto fijo: ocupado por otro -> NetworkException para el segundo',
    () async {
      final other = TcpHostServer(
        identity: const HostIdentity(hostId: 'h2', hostName: 'Otro'),
        onRequest: handler,
        options: HostServerOptions(
          port: server.port,
          bindAddress: InternetAddress.loopbackIPv4,
        ),
      );
      await expectLater(other.start(), throwsA(isA<NetworkException>()));
      await other.dispose();
    },
  );
}
