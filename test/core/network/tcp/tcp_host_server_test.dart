import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:proyecto_comandero/core/errors/app_exception.dart';
import 'package:proyecto_comandero/core/network/protocol/message.dart';
import 'package:proyecto_comandero/core/network/protocol/transport_messages.dart';
import 'package:proyecto_comandero/core/network/tcp/tcp_host_server.dart';
import 'package:test/test.dart';

import 'test_support.dart';

const HostIdentity _identity = HostIdentity(
  hostId: 'host-1',
  hostName: 'Barra',
);

const HostServerOptions _fastOptions = HostServerOptions(
  port: 0,
  handshakeTimeout: Duration(milliseconds: 200),
  heartbeatInterval: Duration(milliseconds: 50),
  idleTimeout: Duration(milliseconds: 300),
  closeTimeout: Duration(milliseconds: 200),
  maxConsecutiveBadFrames: 3,
);

/// Manejador que devuelve `{'echo': payload}` y registra lo que ve.
final class _Handler {
  final List<ProtocolMessage> seen = [];
  final List<ClientSessionInfo> sessions = [];
  FutureOr<Map<String, Object?>> Function(
    ClientSessionInfo session,
    ProtocolMessage request,
  )?
  impl;

  FutureOr<Map<String, Object?>> call(
    ClientSessionInfo session,
    ProtocolMessage request,
  ) {
    seen.add(request);
    sessions.add(session);
    final impl = this.impl;
    if (impl != null) return impl(session, request);
    return {'echo': request.payload};
  }
}

void main() {
  late _Handler handler;
  late TcpHostServer server;
  late Inbox<HostSessionEvent> events;
  final peers = <RawPeer>[];

  Future<RawPeer> connectPeer() async {
    final peer = await RawPeer.connect(server.port);
    peers.add(peer);
    return peer;
  }

  Future<TcpHostServer> startServer([
    HostServerOptions options = _fastOptions,
  ]) async {
    server = TcpHostServer(
      identity: _identity,
      onRequest: handler.call,
      options: options,
    );
    events = Inbox<HostSessionEvent>(server.events);
    await server.start();
    return server;
  }

  setUp(() {
    handler = _Handler();
  });

  tearDown(() async {
    for (final peer in peers) {
      peer.destroy();
    }
    peers.clear();
    await events.cancel();
    await server.dispose();
  });

  group('arranque y parada', () {
    test('start() asigna puerto efímero y stop() lo libera', () async {
      await startServer();
      expect(server.isRunning, isTrue);
      expect(server.port, greaterThan(0));
      final port = server.port;

      await server.stop();
      expect(server.isRunning, isFalse);
      expect(await isPortFree(port), isTrue);

      // stop() es idempotente.
      await server.stop();
    });

    test('start() sobre un puerto ocupado lanza NetworkException', () async {
      final blocker = await occupyPort();
      addTearDown(blocker.close);
      handler = _Handler();
      server = TcpHostServer(
        identity: _identity,
        onRequest: handler.call,
        options: HostServerOptions(
          port: blocker.port,
          bindAddress: InternetAddress.loopbackIPv4,
        ),
      );
      events = Inbox<HostSessionEvent>(server.events);
      await expectLater(server.start(), throwsA(isA<NetworkException>()));
      expect(server.isRunning, isFalse);
    });

    test('stop() despide a los clientes con bye y permite start() en el mismo puerto', () async {
      await startServer();
      final port = server.port;
      final a = await connectPeer();
      final b = await connectPeer();
      await a.handshake(deviceId: 'a');
      await b.handshake(deviceId: 'b');
      await events.next();
      await events.next();

      await server.stop();

      final byeA = await a.nextOfType(TransportMessageTypes.bye);
      final byeB = await b.nextOfType(TransportMessageTypes.bye);
      expect(byeA.payload['reason'], ByeReasons.serverShuttingDown);
      expect(byeB.payload['reason'], ByeReasons.serverShuttingDown);
      await a.waitClosed();
      await b.waitClosed();
      expect(server.sessions, isEmpty);

      final disconnected = [await events.next(), await events.next()];
      expect(
        disconnected.map((e) => (e as ClientDisconnected).reason),
        everyElement(ByeReasons.serverShuttingDown),
      );

      // Mismo puerto, nuevo arranque, nuevo cliente.
      server = TcpHostServer(
        identity: _identity,
        onRequest: handler.call,
        options: HostServerOptions(
          port: port,
          bindAddress: InternetAddress.loopbackIPv4,
        ),
      );
      await events.cancel();
      events = Inbox<HostSessionEvent>(server.events);
      await server.start();
      expect(server.port, port);
      final c = await connectPeer();
      await c.handshake(deviceId: 'c');
      expect(server.sessions.map((s) => s.deviceId), ['c']);
    });

    test(
      'la misma instancia puede reiniciarse con start() tras stop()',
      () async {
        await startServer();
        await server.stop();
        await server.start();
        expect(server.isRunning, isTrue);
        final peer = await connectPeer();
        await peer.handshake(deviceId: 'x');
      },
    );
  });

  group('handshake', () {
    test(
      'hello correcto -> welcome completo, sesión listada y evento',
      () async {
        await startServer();
        final peer = await connectPeer();
        final hello = ProtocolMessage.create(
          TransportMessageTypes.hello,
          payload: const HelloPayload(
            deviceId: 'dev-1',
            deviceName: 'Terraza',
            appVersion: '1.2.3',
          ).toJson(),
        );
        peer.send(hello);
        final reply = await peer.next();
        expect(reply.type, TransportMessageTypes.welcome);
        expect(reply.replyTo, hello.id);
        final welcome = WelcomePayload.fromJson(reply.payload);
        expect(welcome.hostId, 'host-1');
        expect(welcome.hostName, 'Barra');
        expect(welcome.sessionId, isNotEmpty);
        expect(welcome.heartbeatIntervalMs, 50);
        expect(welcome.idleTimeoutMs, 300);
        expect(
          (DateTime.now().millisecondsSinceEpoch - welcome.serverTimeMs).abs(),
          lessThan(5000),
        );

        final event = await events.next();
        expect(event, isA<ClientConnected>());
        final session = event.session;
        expect(session.sessionId, welcome.sessionId);
        expect(session.deviceId, 'dev-1');
        expect(session.deviceName, 'Terraza');
        expect(session.appVersion, '1.2.3');
        expect(session.remoteAddress, '127.0.0.1');
        expect(session.remotePort, peer.socket.port);
        expect(server.sessions, hasLength(1));
        expect(server.sessions.single.sessionId, welcome.sessionId);
      },
    );

    test('dos sesiones tienen sessionId distintos', () async {
      await startServer();
      final a = await connectPeer();
      final b = await connectPeer();
      final wa = await a.handshake(deviceId: 'a');
      final wb = await b.handshake(deviceId: 'b');
      expect(wa.sessionId, isNot(wb.sessionId));
    });

    test('versión incorrecta -> reject unsupported_version y cierre', () async {
      await startServer();
      final peer = await connectPeer();
      final reply = await peer.hello(deviceId: 'd', protocolVersion: 99);
      expect(reply.type, TransportMessageTypes.reject);
      expect(
        RejectPayload.fromJson(reply.payload).code,
        RejectCodes.unsupportedVersion,
      );
      await peer.waitClosed();
      expect(server.sessions, isEmpty);
      expect(events.buffered, isEmpty);
    });

    group('emparejamiento', () {
      test('sin código cuando se exige -> unauthorized', () async {
        await startServer(
          const HostServerOptions(port: 0, pairingCode: '1234'),
        );
        final peer = await connectPeer();
        final reply = await peer.hello(deviceId: 'd');
        expect(reply.type, TransportMessageTypes.reject);
        expect(
          RejectPayload.fromJson(reply.payload).code,
          RejectCodes.unauthorized,
        );
        await peer.waitClosed();
      });

      test('código incorrecto -> unauthorized', () async {
        await startServer(
          const HostServerOptions(port: 0, pairingCode: '1234'),
        );
        final peer = await connectPeer();
        final reply = await peer.hello(deviceId: 'd', pairingCode: '0000');
        expect(reply.type, TransportMessageTypes.reject);
        expect(
          RejectPayload.fromJson(reply.payload).code,
          RejectCodes.unauthorized,
        );
        await peer.waitClosed();
      });

      test('código correcto -> welcome', () async {
        await startServer(
          const HostServerOptions(port: 0, pairingCode: '1234'),
        );
        final peer = await connectPeer();
        final reply = await peer.hello(deviceId: 'd', pairingCode: '1234');
        expect(reply.type, TransportMessageTypes.welcome);
      });

      test('código vacío en el host desactiva el emparejamiento', () async {
        await startServer(const HostServerOptions(port: 0, pairingCode: ''));
        final peer = await connectPeer();
        final reply = await peer.hello(deviceId: 'd');
        expect(reply.type, TransportMessageTypes.welcome);
      });
    });

    test('primera trama distinta de hello -> reject bad_handshake', () async {
      await startServer();
      final peer = await connectPeer();
      peer.send(ProtocolMessage.create('mesa.list'));
      final reply = await peer.next();
      expect(reply.type, TransportMessageTypes.reject);
      expect(
        RejectPayload.fromJson(reply.payload).code,
        RejectCodes.badHandshake,
      );
      await peer.waitClosed();
    });

    test('hello con payload inválido -> reject bad_handshake', () async {
      await startServer();
      final peer = await connectPeer();
      peer.send(
        ProtocolMessage.create(
          TransportMessageTypes.hello,
          payload: const {'deviceName': 'sin deviceId'},
        ),
      );
      final reply = await peer.next();
      expect(reply.type, TransportMessageTypes.reject);
      expect(
        RejectPayload.fromJson(reply.payload).code,
        RejectCodes.badHandshake,
      );
      await peer.waitClosed();
    });

    test('sin hello hasta el timeout -> cierre sin evento', () async {
      await startServer();
      final peer = await connectPeer();
      await peer.waitClosed();
      expect(server.sessions, isEmpty);
      expect(events.buffered, isEmpty);
    });

    test('server_full rechaza al que sobra pero no a un reemplazo', () async {
      await startServer(
        const HostServerOptions(
          port: 0,
          maxClients: 2,
          closeTimeout: Duration(milliseconds: 200),
        ),
      );
      final a = await connectPeer();
      final b = await connectPeer();
      await a.handshake(deviceId: 'a');
      await b.handshake(deviceId: 'b');

      final c = await connectPeer();
      final reply = await c.hello(deviceId: 'c');
      expect(reply.type, TransportMessageTypes.reject);
      expect(
        RejectPayload.fromJson(reply.payload).code,
        RejectCodes.serverFull,
      );
      await c.waitClosed();

      // Un deviceId con sesión no consume plaza: es un reemplazo.
      final a2 = await connectPeer();
      final welcome = await a2.hello(deviceId: 'a');
      expect(welcome.type, TransportMessageTypes.welcome);
      expect(server.sessions, hasLength(2));
    });

    test('reemplazo de sesión: bye(replaced) y eventos en orden', () async {
      await startServer();
      final old = await connectPeer();
      final oldWelcome = await old.handshake(deviceId: 'dev');
      expect(await events.next(), isA<ClientConnected>());

      final fresh = await connectPeer();
      final freshWelcome = await fresh.handshake(deviceId: 'dev');
      expect(freshWelcome.sessionId, isNot(oldWelcome.sessionId));

      final bye = await old.nextOfType(TransportMessageTypes.bye);
      expect(bye.payload['reason'], ByeReasons.replaced);
      await old.waitClosed();

      final first = await events.next();
      final second = await events.next();
      expect(first, isA<ClientDisconnected>());
      expect((first as ClientDisconnected).reason, ByeReasons.replaced);
      expect(first.session.sessionId, oldWelcome.sessionId);
      expect(second, isA<ClientConnected>());
      expect(second.session.sessionId, freshWelcome.sessionId);
      expect(server.sessions.map((s) => s.sessionId), [freshWelcome.sessionId]);
    });
  });

  group('peticiones', () {
    test('petición -> ack con payload del manejador y replyTo', () async {
      await startServer();
      final peer = await connectPeer();
      await peer.handshake(deviceId: 'dev');
      final reply = await peer.request('mesa.open', {'mesa': 4});
      expect(reply.type, TransportMessageTypes.ack);
      expect(reply.payload, {
        'echo': {'mesa': 4},
      });
      expect(handler.seen.single.type, 'mesa.open');
      expect(handler.sessions.single.deviceId, 'dev');
    });

    test('ValidationException -> error validation no reintentable', () async {
      await startServer();
      handler.impl = (_, _) => throw const ValidationException('Mesa cobrada');
      final peer = await connectPeer();
      await peer.handshake(deviceId: 'dev');
      final reply = await peer.request('comanda.submit', {});
      expect(reply.type, TransportMessageTypes.error);
      final error = ErrorPayload.fromJson(reply.payload);
      expect(error.code, ErrorCodes.validation);
      expect(error.retryable, isFalse);
      expect(error.message, 'Mesa cobrada');
    });

    test(
      'RemoteRequestException -> error con su código y reintentable',
      () async {
        await startServer();
        handler.impl = (_, _) => throw const RemoteRequestException(
          'Ocupado',
          code: 'busy',
          retryable: true,
        );
        final peer = await connectPeer();
        await peer.handshake(deviceId: 'dev');
        final reply = await peer.request('x', {});
        final error = ErrorPayload.fromJson(reply.payload);
        expect(error.code, 'busy');
        expect(error.retryable, isTrue);
      },
    );

    test(
      'excepción genérica -> error internal reintentable; sigue vivo',
      () async {
        await startServer();
        handler.impl = (_, _) => throw StateError('bum');
        final peer = await connectPeer();
        await peer.handshake(deviceId: 'dev');
        final reply = await peer.request('x', {});
        expect(reply.type, TransportMessageTypes.error);
        final error = ErrorPayload.fromJson(reply.payload);
        expect(error.code, ErrorCodes.internal);
        expect(error.retryable, isTrue);

        handler.impl = null;
        final ok = await peer.request('y', {});
        expect(ok.type, TransportMessageTypes.ack);
      },
    );

    test('manejador asíncrono que falla tras await', () async {
      await startServer();
      handler.impl = (_, _) async {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        throw const ValidationException('tarde');
      };
      final peer = await connectPeer();
      await peer.handshake(deviceId: 'dev');
      final reply = await peer.request('x', {});
      expect(ErrorPayload.fromJson(reply.payload).code, ErrorCodes.validation);
    });

    test('respuesta no serializable -> error internal definitivo', () async {
      await startServer();
      handler.impl = (_, _) => {'when': DateTime(2026)};
      final peer = await connectPeer();
      await peer.handshake(deviceId: 'dev');
      final reply = await peer.request('x', {});
      expect(reply.type, TransportMessageTypes.error);
      final error = ErrorPayload.fromJson(reply.payload);
      expect(error.code, ErrorCodes.internal);
      expect(error.retryable, isFalse);
    });

    test(
      'ping se responde con pong aunque haya un manejador en curso',
      () async {
        await startServer();
        final release = Completer<void>();
        handler.impl = (_, _) async {
          await release.future;
          return const {};
        };
        final peer = await connectPeer();
        await peer.handshake(deviceId: 'dev');
        final request = ProtocolMessage.create('lento');
        peer.send(request);
        final ping = ProtocolMessage.create(TransportMessageTypes.ping);
        peer.send(ping);
        final pong = await peer.next();
        expect(pong.type, TransportMessageTypes.pong);
        expect(pong.replyTo, ping.id);

        release.complete();
        final ack = await peer.next();
        expect(ack.replyTo, request.id);
      },
    );

    test(
      'las peticiones de un dispositivo se procesan en serie y en orden',
      () async {
        await startServer();
        final order = <String>[];
        var active = 0;
        var maxActive = 0;
        final random = Random(7);
        handler.impl = (_, request) async {
          active++;
          maxActive = max(maxActive, active);
          order.add(request.payload['n'] as String);
          await Future<void>.delayed(
            Duration(milliseconds: random.nextInt(15)),
          );
          active--;
          return {'n': request.payload['n']};
        };
        final peer = await connectPeer();
        await peer.handshake(deviceId: 'dev');
        final ids = <String>[];
        for (var i = 0; i < 10; i++) {
          final message = ProtocolMessage.create('op', payload: {'n': '$i'});
          ids.add(message.id);
          peer.send(message);
        }
        final replies = <String>[];
        for (var i = 0; i < 10; i++) {
          replies.add((await peer.next()).replyTo!);
        }
        expect(order, List.generate(10, (i) => '$i'));
        expect(replies, ids);
        expect(maxActive, 1);
      },
    );

    test('dispositivos distintos se atienden concurrentemente', () async {
      await startServer();
      final gateA = Completer<void>();
      handler.impl = (session, _) async {
        if (session.deviceId == 'a') await gateA.future;
        return {'from': session.deviceId};
      };
      final a = await connectPeer();
      final b = await connectPeer();
      await a.handshake(deviceId: 'a');
      await b.handshake(deviceId: 'b');
      a.send(ProtocolMessage.create('op'));
      // b recibe su ack mientras a sigue bloqueado.
      final replyB = await b.request('op', {});
      expect(replyB.payload, {'from': 'b'});
      gateA.complete();
      expect((await a.next()).payload, {'from': 'a'});
    });

    test(
      'tipo reservado fuera de lugar -> bye(protocol_error) y cierre',
      () async {
        await startServer();
        final peer = await connectPeer();
        await peer.handshake(deviceId: 'dev');
        await events.next();
        peer.send(ProtocolMessage.create(TransportMessageTypes.welcome));
        final bye = await peer.nextOfType(TransportMessageTypes.bye);
        expect(bye.payload['reason'], ByeReasons.protocolError);
        await peer.waitClosed();
        final event = await events.next();
        expect((event as ClientDisconnected).reason, ByeReasons.protocolError);
      },
    );

    test('segundo hello -> protocol_error', () async {
      await startServer();
      final peer = await connectPeer();
      await peer.handshake(deviceId: 'dev');
      final reply = await peer.hello(deviceId: 'dev');
      expect(reply.type, TransportMessageTypes.bye);
      expect(reply.payload['reason'], ByeReasons.protocolError);
      await peer.waitClosed();
    });

    test('bye del cliente cierra la sesión con su motivo', () async {
      await startServer();
      final peer = await connectPeer();
      await peer.handshake(deviceId: 'dev');
      await events.next();
      peer.send(
        ProtocolMessage.create(
          TransportMessageTypes.bye,
          payload: const {'reason': ByeReasons.clientClosing},
        ),
      );
      final event = await events.next();
      expect((event as ClientDisconnected).reason, ByeReasons.clientClosing);
      await peer.waitClosed();
      expect(server.sessions, isEmpty);
    });
  });

  group('deduplicación', () {
    test(
      'mismo id dos veces -> una invocación y dos respuestas iguales',
      () async {
        await startServer();
        final peer = await connectPeer();
        await peer.handshake(deviceId: 'dev');
        final first = await peer.request('op', {'v': 1}, id: 'req-1');
        final second = await peer.request('op', {'v': 1}, id: 'req-1');
        expect(handler.seen, hasLength(1));
        expect(first.type, TransportMessageTypes.ack);
        expect(second.id, first.id);
        expect(second.payload, first.payload);
      },
    );

    test(
      'duplicado en vuelo -> una invocación, dos respuestas al terminar',
      () async {
        await startServer();
        final release = Completer<void>();
        handler.impl = (_, _) async {
          await release.future;
          return const {'done': true};
        };
        final peer = await connectPeer();
        await peer.handshake(deviceId: 'dev');
        final message = ProtocolMessage.create('op', id: 'dup');
        peer.send(message);
        peer.send(message);
        await peer.inbox.expectSilence(const Duration(milliseconds: 100));
        release.complete();
        final reply = await peer.next();
        expect(reply.replyTo, 'dup');
        expect(handler.seen, hasLength(1));
        // El duplicado en vuelo no genera una segunda respuesta: la respuesta
        // única llega cuando el manejador termina; una retransmisión posterior
        // sí obtiene la copia cacheada.
        final again = await peer.request('op', {}, id: 'dup');
        expect(again.payload, {'done': true});
        expect(handler.seen, hasLength(1));
      },
    );

    test(
      'retransmisión tras reconectar con otra sesión usa la caché',
      () async {
        await startServer();
        final first = await connectPeer();
        await first.handshake(deviceId: 'dev');
        final reply1 = await first.request('op', {'v': 1}, id: 'r1');
        first.destroy();

        final second = await connectPeer();
        await second.handshake(deviceId: 'dev');
        final reply2 = await second.request('op', {'v': 1}, id: 'r1');
        expect(handler.seen, hasLength(1));
        expect(reply2.id, reply1.id);
        expect(reply2.payload, reply1.payload);
      },
    );

    test(
      'sesión muerta durante el manejador: la respuesta queda cacheada',
      () async {
        await startServer();
        final started = Completer<void>();
        final release = Completer<void>();
        handler.impl = (_, _) async {
          started.complete();
          await release.future;
          return const {'late': true};
        };
        final first = await connectPeer();
        await first.handshake(deviceId: 'dev');
        await events.next();
        first.send(ProtocolMessage.create('op', id: 'slow'));
        await started.future.timeout(kWait);
        first.destroy();
        await events.next(); // ClientDisconnected(connection_lost)
        release.complete();

        final second = await connectPeer();
        await second.handshake(deviceId: 'dev');
        final reply = await second.request('op', {}, id: 'slow');
        expect(reply.payload, {'late': true});
        expect(handler.seen, hasLength(1));
      },
    );

    test(
      'error reintentable no se cachea; el reintento vuelve al manejador',
      () async {
        await startServer();
        var calls = 0;
        handler.impl = (_, _) {
          calls++;
          if (calls == 1) throw StateError('transitorio');
          return {'calls': calls};
        };
        final peer = await connectPeer();
        await peer.handshake(deviceId: 'dev');
        final first = await peer.request('op', {}, id: 'retry');
        expect(first.type, TransportMessageTypes.error);
        final second = await peer.request('op', {}, id: 'retry');
        expect(second.type, TransportMessageTypes.ack);
        expect(second.payload, {'calls': 2});
        // Ahora sí está cacheado.
        final third = await peer.request('op', {}, id: 'retry');
        expect(third.payload, {'calls': 2});
        expect(calls, 2);
      },
    );

    test('error de validación sí se cachea', () async {
      await startServer();
      handler.impl = (_, _) => throw const ValidationException('no');
      final peer = await connectPeer();
      await peer.handshake(deviceId: 'dev');
      await peer.request('op', {}, id: 'v');
      await peer.request('op', {}, id: 'v');
      expect(handler.seen, hasLength(1));
    });

    test('la caché es LRU por dispositivo con el tamaño configurado', () async {
      await startServer(const HostServerOptions(port: 0, dedupeCacheSize: 2));
      final peer = await connectPeer();
      await peer.handshake(deviceId: 'dev');
      await peer.request('op', {}, id: 'a');
      await peer.request('op', {}, id: 'b');
      await peer.request('op', {}, id: 'c'); // expulsa 'a'
      await peer.request('op', {}, id: 'a'); // vuelve a invocar
      expect(handler.seen.map((m) => m.id), ['a', 'b', 'c', 'a']);
    });
  });

  group('latido e inactividad', () {
    test('cliente silencioso expulsado por idle con su evento', () async {
      await startServer();
      final peer = await connectPeer();
      await peer.handshake(deviceId: 'dev');
      await events.next();
      final stopwatch = Stopwatch()..start();
      await peer.waitClosed();
      final event = await events.next();
      expect((event as ClientDisconnected).reason, ByeReasons.idleTimeout);
      expect(
        stopwatch.elapsed,
        greaterThanOrEqualTo(const Duration(milliseconds: 250)),
      );
      expect(server.sessions, isEmpty);
    });

    test('los pings mantienen viva la sesión', () async {
      await startServer();
      final peer = await connectPeer();
      await peer.handshake(deviceId: 'dev');
      await events.next();
      for (var i = 0; i < 6; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        peer.send(ProtocolMessage.create(TransportMessageTypes.ping));
        await peer.nextOfType(TransportMessageTypes.pong);
      }
      expect(server.sessions, hasLength(1));
      expect(events.buffered, isEmpty);
    });
  });

  group('broadcast y sendTo', () {
    test('broadcast llega a todos salvo exceptDeviceId', () async {
      await startServer();
      final a = await connectPeer();
      final b = await connectPeer();
      final c = await connectPeer();
      await a.handshake(deviceId: 'a');
      await b.handshake(deviceId: 'b');
      await c.handshake(deviceId: 'c');
      final pending = await connectPeer(); // sin handshake: no cuenta
      addTearDown(pending.destroy);

      final sent = server.broadcast('sala.update', {
        'mesa': 1,
      }, exceptDeviceId: 'b');
      expect(sent, 2);
      final ma = await a.next();
      final mc = await c.next();
      expect(ma.type, 'sala.update');
      expect(ma.payload, {'mesa': 1});
      expect(mc.type, 'sala.update');
      await b.inbox.expectSilence(const Duration(milliseconds: 100));
    });

    test(
      'sendTo entrega solo a ese dispositivo y devuelve false sin sesión',
      () async {
        await startServer();
        final a = await connectPeer();
        final b = await connectPeer();
        await a.handshake(deviceId: 'a');
        await b.handshake(deviceId: 'b');
        expect(server.sendTo('a', 'aviso', {'x': 1}), isTrue);
        expect((await a.next()).type, 'aviso');
        await b.inbox.expectSilence(const Duration(milliseconds: 100));
        expect(server.sendTo('nadie', 'aviso', {}), isFalse);
      },
    );

    test('broadcast/sendTo a un socket muerto no lanzan', () async {
      await startServer();
      final a = await connectPeer();
      await a.handshake(deviceId: 'a');
      await events.next();
      a.destroy();
      // Antes o después de que el host note la caída, ninguna llamada lanza.
      for (var i = 0; i < 20; i++) {
        server.broadcast('tick', {'i': i});
        server.sendTo('a', 'tick', {'i': i});
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      await events.next();
      expect(server.sendTo('a', 'tick', {}), isFalse);
      expect(server.broadcast('tick', {}), 0);
    });

    test('tipos reservados en broadcast/sendTo lanzan ArgumentError', () async {
      await startServer();
      expect(() => server.broadcast('ping', {}), throwsArgumentError);
      expect(() => server.sendTo('a', 'bye', {}), throwsArgumentError);
    });

    test('disconnect() envía bye con el motivo y emite el evento', () async {
      await startServer();
      final peer = await connectPeer();
      await peer.handshake(deviceId: 'dev');
      await events.next();
      await server.disconnect('dev', reason: 'kicked');
      final bye = await peer.nextOfType(TransportMessageTypes.bye);
      expect(bye.payload['reason'], 'kicked');
      await peer.waitClosed();
      expect((await events.next() as ClientDisconnected).reason, 'kicked');
      // Sin sesión no hace nada.
      await server.disconnect('dev');
    });
  });

  group('tramas inválidas', () {
    test('N tramas JSON inválidas seguidas -> protocol_error', () async {
      await startServer();
      final peer = await connectPeer();
      await peer.handshake(deviceId: 'dev');
      await events.next();
      peer.sendRaw('no es json\n'.codeUnits);
      peer.sendRaw('{"v":1}\n'.codeUnits); // sobre inválido
      peer.sendRaw('[1,2]\n'.codeUnits);
      final bye = await peer.nextOfType(TransportMessageTypes.bye);
      expect(bye.payload['reason'], ByeReasons.protocolError);
      await peer.waitClosed();
      expect(
        (await events.next() as ClientDisconnected).reason,
        ByeReasons.protocolError,
      );
    });

    test('una trama válida reinicia el contador de tramas inválidas', () async {
      await startServer();
      final peer = await connectPeer();
      await peer.handshake(deviceId: 'dev');
      for (var round = 0; round < 3; round++) {
        peer.sendRaw('basura\n'.codeUnits);
        peer.sendRaw('basura\n'.codeUnits);
        final reply = await peer.request('op', {});
        expect(reply.type, TransportMessageTypes.ack);
      }
      expect(server.sessions, hasLength(1));
    });

    test('basura antes del hello también cierra sin reject', () async {
      await startServer();
      final peer = await connectPeer();
      for (var i = 0; i < 3; i++) {
        peer.sendRaw('{{{\n'.codeUnits);
      }
      final bye = await peer.nextOfType(TransportMessageTypes.bye);
      expect(bye.payload['reason'], ByeReasons.protocolError);
      await peer.waitClosed();
    });

    test('trama gigante -> cierre inmediato', () async {
      await startServer(const HostServerOptions(port: 0, maxFrameBytes: 1024));
      final peer = await connectPeer();
      await peer.handshake(deviceId: 'dev');
      await events.next();
      peer.sendRaw(List<int>.filled(4096, 0x61));
      await peer.waitClosed();
      expect(
        (await events.next() as ClientDisconnected).reason,
        ByeReasons.protocolError,
      );
    });

    test(
      'binario aleatorio no tumba al servidor ni afecta a los demás',
      () async {
        await startServer(
          const HostServerOptions(port: 0, maxFrameBytes: 4096),
        );
        final good = await connectPeer();
        await good.handshake(deviceId: 'good');
        final bad = await connectPeer();
        final random = Random(42);
        bad.sendRaw(List<int>.generate(8192, (_) => random.nextInt(256)));
        await bad.waitClosed();
        final reply = await good.request('op', {'ok': true});
        expect(reply.type, TransportMessageTypes.ack);
        expect(server.sessions.map((s) => s.deviceId), ['good']);
      },
    );

    test('cliente destruido a mitad de trama -> connection_lost', () async {
      await startServer();
      final good = await connectPeer();
      await good.handshake(deviceId: 'good');
      await events.next();
      final bad = await connectPeer();
      await bad.handshake(deviceId: 'bad');
      await events.next();
      bad.sendRaw('{"v":1,"id":"x","type":"op","ts":1,"pay'.codeUnits);
      await bad.socket.flush();
      bad.destroy();
      final event = await events.next();
      expect((event as ClientDisconnected).reason, 'connection_lost');
      expect(event.session.deviceId, 'bad');
      final reply = await good.request('op', {});
      expect(reply.type, TransportMessageTypes.ack);
    });
  });
}
