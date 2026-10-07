import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:proyecto_comandero/core/errors/app_exception.dart';
import 'package:proyecto_comandero/core/network/protocol/message.dart';
import 'package:proyecto_comandero/core/network/protocol/transport_messages.dart';
import 'package:proyecto_comandero/core/network/tcp/tcp_comandero_client.dart';
import 'package:test/test.dart';

import 'test_support.dart';

const ClientIdentity _identity = ClientIdentity(
  deviceId: 'movil-1',
  deviceName: 'Comandero 1',
  appVersion: '0.1.0',
);

/// Sin jitter: los retrasos de backoff son exactos y comprobables.
const ClientOptions _fastOptions = ClientOptions(
  connectTimeout: Duration(milliseconds: 500),
  handshakeTimeout: Duration(milliseconds: 200),
  requestTimeout: Duration(milliseconds: 200),
  reconnectBaseDelay: Duration(milliseconds: 20),
  reconnectMaxDelay: Duration(milliseconds: 100),
  reconnectJitter: 0,
  rediscoverAfterFailures: 2,
  closeTimeout: Duration(milliseconds: 200),
);

/// Puerto de loopback sin nadie escuchando.
Future<int> closedPort() async {
  final socket = await occupyPort();
  final port = socket.port;
  await socket.close();
  return port;
}

void main() {
  late FakeHost host;
  late TcpComanderoClient client;
  late Inbox<ClientConnectionState> states;
  late Inbox<ProtocolMessage> messages;

  HostEndpoint endpointOf(FakeHost host) =>
      HostEndpoint(host: '127.0.0.1', port: host.port);

  TcpComanderoClient makeClient({
    ClientOptions options = _fastOptions,
    Future<HostEndpoint?> Function()? rediscover,
    Random? random,
  }) {
    client = TcpComanderoClient(
      identity: _identity,
      options: options,
      rediscover: rediscover,
      random: random,
    );
    states = Inbox<ClientConnectionState>(client.states);
    messages = Inbox<ProtocolMessage>(client.messages);
    return client;
  }

  /// Conecta el cliente con [host] y completa el handshake desde el lado
  /// falso. Devuelve el par del servidor y el `hello` recibido.
  Future<(RawPeer, ProtocolMessage)> connectAndWelcome({
    int heartbeatIntervalMs = 1000,
    int idleTimeoutMs = 5000,
  }) async {
    client.connect(endpointOf(host));
    final accepted = await host.acceptAndWelcome(
      heartbeatIntervalMs: heartbeatIntervalMs,
      idleTimeoutMs: idleTimeoutMs,
    );
    await states.nextWhere((s) => s is Connected, what: 'Connected');
    return accepted;
  }

  setUp(() async {
    host = await FakeHost.start();
    makeClient();
  });

  tearDown(() async {
    await client.dispose();
    await states.cancel();
    await messages.cancel();
    await host.close();
  });

  group('conexión y estados', () {
    test('conecta, envía hello y recorre Connecting -> Connected', () async {
      expect(client.state, const Disconnected());
      client.connect(endpointOf(host));
      expect(
        await states.next(),
        Connecting(endpoint: endpointOf(host), attempt: 1),
      );

      final (peer, hello) = await host.acceptAndWelcome(sessionId: 's-1');
      final payload = HelloPayload.fromJson(hello.payload);
      expect(payload.deviceId, 'movil-1');
      expect(payload.deviceName, 'Comandero 1');
      expect(payload.appVersion, '0.1.0');
      expect(payload.protocolVersion, kProtocolVersion);
      expect(payload.pairingCode, isNull);

      final connected = await states.next();
      expect(connected, isA<Connected>());
      expect((connected as Connected).welcome.sessionId, 's-1');
      expect(connected.endpoint, endpointOf(host));
      expect(client.state, connected);
      expect(peer.remoteClosed, isFalse);
    });

    test('el hello lleva el código de emparejamiento configurado', () async {
      makeClient(options: const ClientOptions(pairingCode: '4321'));
      client.connect(endpointOf(host));
      final peer = await host.accept();
      final hello = await peer.nextOfType(TransportMessageTypes.hello);
      expect(HelloPayload.fromJson(hello.payload).pairingCode, '4321');
    });

    test('envía ping cada heartbeatIntervalMs y acepta el pong', () async {
      final (peer, _) = await connectAndWelcome(heartbeatIntervalMs: 30);
      for (var i = 0; i < 3; i++) {
        final ping = await peer.nextOfType(TransportMessageTypes.ping);
        peer.send(ping.reply(TransportMessageTypes.pong));
      }
      expect(client.state, isA<Connected>());
      await messages.expectSilence(const Duration(milliseconds: 50));
    });

    test('connect() repetido al mismo host conectado no hace nada', () async {
      await connectAndWelcome();
      client.connect(endpointOf(host));
      await host.connections.expectSilence(const Duration(milliseconds: 100));
      expect(states.buffered, isEmpty);
    });

    test('connect() a otro host se despide del actual y cambia', () async {
      final (peer, _) = await connectAndWelcome();
      final other = await FakeHost.start();
      addTearDown(other.close);

      client.connect(endpointOf(other));
      final bye = await peer.nextOfType(TransportMessageTypes.bye);
      expect(bye.payload['reason'], ByeReasons.clientClosing);
      expect(
        await states.next(),
        Connecting(endpoint: endpointOf(other), attempt: 1),
      );
      await other.acceptAndWelcome();
      final connected = await states.next();
      expect((connected as Connected).endpoint, endpointOf(other));
    });

    test('disconnect(): bye, estado Disconnected y sin reconexión', () async {
      final (peer, _) = await connectAndWelcome();
      final pending = client.request('op', {}, reliable: true);
      await peer.nextApplication(); // la petición llega al host falso
      final failing = expectLater(pending, throwsA(isA<NetworkException>()));

      await client.disconnect();
      expect(client.state, const Disconnected());
      expect(await states.next(), const Disconnected());
      await failing;
      expect(client.pendingReliableCount, 0);
      final bye = await peer.nextOfType(TransportMessageTypes.bye);
      expect(bye.payload['reason'], ByeReasons.clientClosing);
      await peer.waitClosed();
      await host.connections.expectSilence(const Duration(milliseconds: 150));

      // disconnect() repetido es inocuo.
      await client.disconnect();
    });

    test('dispose(): cierra los streams y rechaza más llamadas', () async {
      await connectAndWelcome();
      await client.dispose();
      await states.nextWhere((s) => s is Disconnected);
      await expectLater(states.next(), throwsStateError);
      await expectLater(messages.next(), throwsStateError);
      expect(() => client.connect(endpointOf(host)), throwsStateError);
      expect(() => client.request('op', {}), throwsStateError);
    });
  });

  group('peticiones no fiables', () {
    test('request -> ack con el mensaje de respuesta', () async {
      final (peer, _) = await connectAndWelcome();
      final future = client.request('mesa.list', {'sala': 'terraza'});
      final received = await peer.nextApplication();
      expect(received.type, 'mesa.list');
      expect(received.payload, {'sala': 'terraza'});
      peer.send(received.reply(TransportMessageTypes.ack, payload: {'n': 3}));
      final reply = await future;
      expect(reply.type, TransportMessageTypes.ack);
      expect(reply.replyTo, received.id);
      expect(reply.payload, {'n': 3});
    });

    test('error -> RemoteRequestException con código y retryable', () async {
      final (peer, _) = await connectAndWelcome();
      final future = client.request('op', {});
      final received = await peer.nextApplication();
      peer.send(
        received.reply(
          TransportMessageTypes.error,
          payload: const ErrorPayload(
            code: 'mesa_cobrada',
            message: 'Ya cobrada',
            retryable: false,
          ).toJson(),
        ),
      );
      await expectLater(
        future,
        throwsA(
          isA<RemoteRequestException>()
              .having((e) => e.code, 'code', 'mesa_cobrada')
              .having((e) => e.retryable, 'retryable', isFalse)
              .having((e) => e.message, 'message', 'Ya cobrada'),
        ),
      );
    });

    test(
      'timeout -> NetworkException y la respuesta tardía se ignora',
      () async {
        final (peer, _) = await connectAndWelcome();
        final future = client.request(
          'op',
          {},
          timeout: const Duration(milliseconds: 50),
        );
        final received = await peer.nextApplication();
        await expectLater(future, throwsA(isA<NetworkException>()));
        peer.send(received.reply(TransportMessageTypes.ack));

        // El cliente sigue operativo tras la respuesta tardía.
        final next = client.request('op2', {});
        peer.send(
          (await peer.nextOfType('op2')).reply(TransportMessageTypes.ack),
        );
        expect((await next).type, TransportMessageTypes.ack);
        expect(client.state, isA<Connected>());
      },
    );

    test('sin conexión falla de inmediato con NetworkException', () async {
      await expectLater(
        client.request('op', {}),
        throwsA(isA<NetworkException>()),
      );
      client.connect(endpointOf(host));
      await host.accept(); // sin welcome: todavía no está Connected
      await expectLater(
        client.request('op', {}),
        throwsA(isA<NetworkException>()),
      );
    });

    test('la caída de la conexión falla las pendientes', () async {
      final (peer, _) = await connectAndWelcome();
      final future = client.request('op', {});
      await peer.nextApplication();
      peer.destroy();
      await expectLater(future, throwsA(isA<NetworkException>()));
    });

    test('tipo reservado -> ArgumentError', () async {
      await connectAndWelcome();
      expect(() => client.request('ping', {}), throwsArgumentError);
    });
  });

  group('peticiones fiables', () {
    test('encolada sin conexión y entregada al conectar', () async {
      final future = client.request('comanda.submit', {'m': 1}, reliable: true);
      expect(client.pendingReliableCount, 1);
      final (peer, _) = await connectAndWelcome();
      final received = await peer.nextApplication();
      expect(received.type, 'comanda.submit');
      peer.send(received.reply(TransportMessageTypes.ack, payload: {'ok': 1}));
      expect((await future).payload, {'ok': 1});
      expect(client.pendingReliableCount, 0);
    });

    test(
      'en vuelo cuando el servidor corta: se retransmite con el MISMO id',
      () async {
        final (peer, _) = await connectAndWelcome();
        final future = client.request('comanda.submit', {}, reliable: true);
        final first = await peer.nextApplication();
        peer.destroy();

        await states.nextWhere((s) => s is Reconnecting, what: 'Reconnecting');
        final (peer2, _) = await host.acceptAndWelcome(sessionId: 's-2');
        final second = await peer2.nextApplication();
        expect(second.id, first.id);
        expect(second.type, 'comanda.submit');
        peer2.send(second.reply(TransportMessageTypes.ack, payload: {'n': 1}));
        final reply = await future;
        expect(reply.payload, {'n': 1});
        expect(client.pendingReliableCount, 0);
        // Un ack duplicado no tiene efectos.
        peer2.send(second.reply(TransportMessageTypes.ack, payload: {'n': 2}));
        await messages.expectSilence(const Duration(milliseconds: 50));
      },
    );

    test('varias en cola se retransmiten en el orden original', () async {
      final futures = [
        for (var i = 0; i < 3; i++)
          client.request('op', {'i': i}, reliable: true),
      ];
      expect(client.pendingReliableCount, 3);
      final (peer, _) = await connectAndWelcome();
      final ids = [
        for (var i = 0; i < 3; i++) (await peer.nextApplication()).id,
      ];
      peer.destroy();

      final (peer2, _) = await host.acceptAndWelcome();
      final again = [for (var i = 0; i < 3; i++) await peer2.nextApplication()];
      expect(again.map((m) => m.id), ids);
      expect(again.map((m) => m.payload['i']), [0, 1, 2]);
      for (final message in again) {
        peer2.send(message.reply(TransportMessageTypes.ack));
      }
      await Future.wait(futures);
    });

    test('error no reintentable -> RemoteRequestException', () async {
      final (peer, _) = await connectAndWelcome();
      final future = client.request('op', {}, reliable: true);
      final received = await peer.nextApplication();
      peer.send(
        received.reply(
          TransportMessageTypes.error,
          payload: const ErrorPayload(
            code: ErrorCodes.validation,
            message: 'mal',
          ).toJson(),
        ),
      );
      await expectLater(future, throwsA(isA<RemoteRequestException>()));
      expect(client.pendingReliableCount, 0);
    });

    test(
      'error reintentable -> se reenvía con el mismo id tras backoff',
      () async {
        final (peer, _) = await connectAndWelcome();
        final future = client.request('op', {}, reliable: true);
        final first = await peer.nextApplication();
        peer.send(
          first.reply(
            TransportMessageTypes.error,
            payload: const ErrorPayload(
              code: ErrorCodes.internal,
              message: 'ahora no',
              retryable: true,
            ).toJson(),
          ),
        );
        final second = await peer.nextApplication();
        expect(second.id, first.id);
        expect(client.pendingReliableCount, 1);
        peer.send(second.reply(TransportMessageTypes.ack));
        await future;
      },
    );

    test(
      'sobrevive a un Rejected y sale al reconectar con connect()',
      () async {
        final future = client.request('op', {}, reliable: true);
        client.connect(endpointOf(host));
        final peer = await host.accept();
        final hello = await peer.nextOfType(TransportMessageTypes.hello);
        peer.send(
          hello.reply(
            TransportMessageTypes.reject,
            payload: const RejectPayload(
              code: RejectCodes.unauthorized,
              message: 'código',
            ).toJson(),
          ),
        );
        await states.nextWhere((s) => s is Rejected);
        expect(client.pendingReliableCount, 1);

        client.connect(endpointOf(host));
        final (peer2, _) = await host.acceptAndWelcome();
        final received = await peer2.nextApplication();
        peer2.send(received.reply(TransportMessageTypes.ack));
        await future;
      },
    );
  });

  group('reconexión', () {
    test('backoff exponencial acotado tras cortes del servidor', () async {
      final (first, _) = await connectAndWelcome();
      first.destroy();
      final expected = [20, 40, 80, 100, 100];
      for (var attempt = 1; attempt <= expected.length; attempt++) {
        // Cada corte (el primero de la sesión establecida; los siguientes,
        // aceptar y cortar sin welcome) cuenta como un fallo seguido.
        if (attempt > 1) (await host.accept()).destroy();
        final reconnecting = await states.nextWhere(
          (s) => s is Reconnecting,
          what: 'Reconnecting $attempt',
        );
        expect(
          reconnecting,
          isA<Reconnecting>()
              .having((s) => s.attempt, 'attempt', attempt)
              .having(
                (s) => s.retryIn.inMilliseconds,
                'retryIn',
                expected[attempt - 1],
              )
              .having((s) => s.lastError, 'lastError', isA<NetworkException>()),
        );
        expect(
          await states.next(),
          Connecting(endpoint: endpointOf(host), attempt: attempt + 1),
        );
      }
      // Un handshake correcto reinicia el contador.
      final (peer, _) = await host.acceptAndWelcome();
      await states.nextWhere((s) => s is Connected);
      peer.destroy();
      final again = await states.nextWhere((s) => s is Reconnecting);
      expect((again as Reconnecting).attempt, 1);
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('el jitter usa el Random inyectado', () async {
      makeClient(
        options: const ClientOptions(
          connectTimeout: Duration(milliseconds: 500),
          reconnectBaseDelay: Duration(milliseconds: 100),
          reconnectMaxDelay: Duration(seconds: 1),
          reconnectJitter: 0.5,
        ),
        random: _FixedRandom(1.0), // jitter máximo positivo: +50 %
      );
      client.connect(endpointOf(host));
      (await host.accept()).destroy();
      final reconnecting = await states.nextWhere((s) => s is Reconnecting);
      expect((reconnecting as Reconnecting).retryIn.inMilliseconds, 150);
    });

    test('host mudo tras el welcome: idle detectado y reconexión', () async {
      final stopwatch = Stopwatch()..start();
      final (peer, _) = await connectAndWelcome(
        heartbeatIntervalMs: 30,
        idleTimeoutMs: 120,
      );
      // Se reciben pings pero no se contestan.
      await peer.nextOfType(TransportMessageTypes.ping);
      final reconnecting = await states.nextWhere((s) => s is Reconnecting);
      expect(stopwatch.elapsedMilliseconds, greaterThanOrEqualTo(120));
      expect(
        (reconnecting as Reconnecting).lastError.toString(),
        contains('Sin tramas'),
      );
      await peer.waitClosed();
      await host.acceptAndWelcome();
      await states.nextWhere((s) => s is Connected);
    });

    test('timeout de handshake -> reconexión', () async {
      client.connect(endpointOf(host));
      await host.accept(); // nunca responde al hello
      final reconnecting = await states.nextWhere((s) => s is Reconnecting);
      expect(
        (reconnecting as Reconnecting).lastError.toString(),
        contains('handshake'),
      );
      await host.acceptAndWelcome();
      await states.nextWhere((s) => s is Connected);
    });

    test(
      'host inalcanzable -> Reconnecting y conecta cuando aparece',
      () async {
        final port = await closedPort();
        client.connect(HostEndpoint(host: '127.0.0.1', port: port));
        final reconnecting = await states.nextWhere((s) => s is Reconnecting);
        expect(
          (reconnecting as Reconnecting).lastError,
          isA<NetworkException>(),
        );
        // El host "aparece" en ese puerto.
        final late = await ServerSocket.bind(
          InternetAddress.loopbackIPv4,
          port,
        );
        addTearDown(late.close);
        final socket = await late.first;
        final peer = RawPeer.accepted(socket);
        addTearDown(peer.destroy);
        await peer.nextOfType(TransportMessageTypes.hello);
      },
    );

    test('bye del host (no replaced) -> reconexión con backoff', () async {
      final (peer, _) = await connectAndWelcome();
      peer.send(
        ProtocolMessage.create(
          TransportMessageTypes.bye,
          payload: const {'reason': ByeReasons.serverShuttingDown},
        ),
      );
      await states.nextWhere((s) => s is Reconnecting);
      await host.acceptAndWelcome();
      await states.nextWhere((s) => s is Connected);
    });

    test('bye replaced -> Rejected(replaced) sin reconexión', () async {
      final (peer, _) = await connectAndWelcome();
      peer.send(
        ProtocolMessage.create(
          TransportMessageTypes.bye,
          payload: const {'reason': ByeReasons.replaced},
        ),
      );
      final rejected = await states.nextWhere((s) => s is Rejected);
      expect((rejected as Rejected).code, ByeReasons.replaced);
      await host.connections.expectSilence(const Duration(milliseconds: 200));
      expect(client.state, rejected);
    });

    test('reject unauthorized -> Rejected sin más intentos', () async {
      client.connect(endpointOf(host));
      final peer = await host.accept();
      final hello = await peer.nextOfType(TransportMessageTypes.hello);
      peer.send(
        hello.reply(
          TransportMessageTypes.reject,
          payload: const RejectPayload(
            code: RejectCodes.unauthorized,
            message: 'Código incorrecto',
          ).toJson(),
        ),
      );
      final rejected = await states.nextWhere((s) => s is Rejected);
      expect(
        rejected,
        const Rejected(code: 'unauthorized', message: 'Código incorrecto'),
      );
      await host.connections.expectSilence(const Duration(milliseconds: 200));
      await peer.waitClosed();
    });

    test('reject server_full -> sigue reintentando', () async {
      client.connect(endpointOf(host));
      final peer = await host.accept();
      final hello = await peer.nextOfType(TransportMessageTypes.hello);
      peer.send(
        hello.reply(
          TransportMessageTypes.reject,
          payload: const RejectPayload(
            code: RejectCodes.serverFull,
            message: 'lleno',
          ).toJson(),
        ),
      );
      final reconnecting = await states.nextWhere((s) => s is Reconnecting);
      expect((reconnecting as Reconnecting).attempt, 1);
      await host.acceptAndWelcome();
      await states.nextWhere((s) => s is Connected);
    });

    test('rediscover se usa tras N fallos y sus errores se ignoran', () async {
      final moved = await FakeHost.start();
      addTearDown(moved.close);
      var calls = 0;
      makeClient(
        rediscover: () async {
          calls++;
          if (calls == 1) throw StateError('UDP caído');
          return endpointOf(moved);
        },
      );
      final deadPort = await closedPort();
      final dead = HostEndpoint(host: '127.0.0.1', port: deadPort);
      client.connect(dead);

      // Fallos 1 y 2 reintentan contra el endpoint original (rediscover a
      // partir del segundo fallo, que lanza y se ignora).
      await states.nextWhere((s) => s is Reconnecting && s.attempt == 2);
      expect(await states.next(), Connecting(endpoint: dead, attempt: 3));
      expect(calls, 1);
      await states.nextWhere((s) => s is Reconnecting && s.attempt == 3);
      expect(
        await states.next(),
        Connecting(endpoint: endpointOf(moved), attempt: 4),
      );
      expect(calls, 2);
      await moved.acceptAndWelcome();
      final connected = await states.nextWhere((s) => s is Connected);
      expect((connected as Connected).endpoint, endpointOf(moved));
    });

    test('rediscover que devuelve null mantiene el endpoint', () async {
      makeClient(rediscover: () async => null);
      final deadPort = await closedPort();
      final dead = HostEndpoint(host: '127.0.0.1', port: deadPort);
      client.connect(dead);
      await states.nextWhere((s) => s is Reconnecting && s.attempt == 3);
      expect(await states.next(), Connecting(endpoint: dead, attempt: 4));
    });
  });

  group('mensajes del host', () {
    test(
      'los de aplicación salen por messages; los de transporte no',
      () async {
        final (peer, _) = await connectAndWelcome();
        peer.send(ProtocolMessage.create(TransportMessageTypes.pong));
        peer.send(ProtocolMessage.create('sala.update', payload: {'mesa': 2}));
        peer.send(
          ProtocolMessage.create(TransportMessageTypes.ack, replyTo: 'nadie'),
        );
        peer.send(ProtocolMessage.create('otro'));
        final first = await messages.next();
        expect(first.type, 'sala.update');
        expect(first.payload, {'mesa': 2});
        expect((await messages.next()).type, 'otro');
        await messages.expectSilence(const Duration(milliseconds: 50));
        expect(client.state, isA<Connected>());
      },
    );

    test('tramas corruptas del servidor se descartan sin errores', () async {
      final (peer, _) = await connectAndWelcome();
      peer.sendRaw('esto no es json\n'.codeUnits);
      peer.sendRaw('{"v":1}\n'.codeUnits);
      peer.sendRaw([0xFF, 0xFE, 0x0A]);
      peer.sendRaw('{"v":1,"id":"x","type":"ping","ts":1}\n'.codeUnits);
      final future = client.request('op', {});
      peer.send(
        (await peer.nextApplication()).reply(TransportMessageTypes.ack),
      );
      await future;
      expect(client.state, isA<Connected>());
    });

    test('trama gigante del servidor -> reconexión', () async {
      makeClient(
        options: const ClientOptions(
          maxFrameBytes: 512,
          reconnectBaseDelay: Duration(milliseconds: 20),
          reconnectJitter: 0,
        ),
      );
      final (peer, _) = await connectAndWelcome();
      peer.sendRaw(List<int>.filled(2048, 0x61));
      await states.nextWhere((s) => s is Reconnecting);
      await host.acceptAndWelcome();
      await states.nextWhere((s) => s is Connected);
    });
  });
}

/// `Random` cuyo `nextDouble` devuelve siempre el mismo valor.
final class _FixedRandom implements Random {
  _FixedRandom(this.value);

  final double value;

  @override
  bool nextBool() => value >= 0.5;

  @override
  double nextDouble() => value;

  @override
  int nextInt(int max) => (value * max).floor().clamp(0, max - 1);
}
