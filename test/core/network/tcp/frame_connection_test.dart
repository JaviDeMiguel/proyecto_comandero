import 'dart:async';
import 'dart:io';

import 'package:proyecto_comandero/core/errors/app_exception.dart';
import 'package:proyecto_comandero/core/network/protocol/frame_codec.dart';
import 'package:proyecto_comandero/core/network/protocol/message.dart';
import 'package:proyecto_comandero/core/network/tcp/frame_connection.dart';
import 'package:test/test.dart';

import 'test_support.dart';

void main() {
  late ServerSocket server;
  late RawPeer peer;
  late FrameConnection connection;
  late Inbox<FrameEvent> frames;
  late Completer<NetworkException> closed;

  /// Conecta un par crudo (cliente) y envuelve el socket aceptado en una
  /// [FrameConnection] (servidor), que es la parte bajo prueba.
  setUp(() async {
    server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final accepted = server.first;
    peer = await RawPeer.connect(server.port);
    connection = FrameConnection(await accepted, maxFrameBytes: 1024);
    final controller = StreamController<FrameEvent>();
    frames = Inbox<FrameEvent>(controller.stream);
    closed = Completer<NetworkException>();
    connection.start(
      onFrame: controller.add,
      onClosed: (reason) {
        expect(closed.isCompleted, isFalse, reason: 'onClosed solo una vez');
        closed.complete(reason);
      },
    );
    addTearDown(() async {
      connection.destroy();
      peer.destroy();
      await frames.cancel();
      await controller.close();
      await server.close();
    });
  });

  test('captura la dirección remota y activa el intercambio', () async {
    expect(connection.isOpen, isTrue);
    expect(connection.remoteAddress, '127.0.0.1');
    expect(connection.remotePort, peer.socket.port);
    expect(connection.send(ProtocolMessage.create('hola')), isTrue);
    expect((await peer.next()).type, 'hola');
    peer.sendJson({'a': 1});
    final event = await frames.next();
    expect((event as FrameData).json, {'a': 1});
  });

  test('las tramas salen en orden', () async {
    for (var i = 0; i < 50; i++) {
      connection.send(ProtocolMessage.create('m$i'));
    }
    for (var i = 0; i < 50; i++) {
      expect((await peer.next()).type, 'm$i');
    }
  });

  test('start() solo puede llamarse una vez', () {
    expect(
      () => connection.start(onFrame: (_) {}, onClosed: (_) {}),
      throwsStateError,
    );
  });

  test(
    'cierre remoto -> onClosed una vez y sendFrame devuelve false',
    () async {
      await peer.close();
      final reason = await closed.future.timeout(kWait);
      expect(reason, isA<NetworkException>());
      expect(connection.isOpen, isFalse);
      expect(connection.send(ProtocolMessage.create('x')), isFalse);
    },
  );

  test('cierre remoto a mitad de trama -> onClosed con la causa', () async {
    peer.sendRaw('{"v":1,"id":"x"'.codeUnits);
    await peer.socket.flush();
    await peer.close();
    final reason = await closed.future.timeout(kWait);
    expect(reason.message, contains('mitad de una trama'));
    expect(reason.cause, isA<ProtocolException>());
  });

  test(
    'close() entrega la despedida y termina aunque el par no cierre',
    () async {
      final stopwatch = Stopwatch()..start();
      await connection.close(
        farewell: ProtocolMessage.create('bye'),
        timeout: const Duration(milliseconds: 100),
      );
      expect(
        stopwatch.elapsed,
        greaterThanOrEqualTo(const Duration(milliseconds: 90)),
      );
      expect(connection.isOpen, isFalse);
      expect((await peer.next()).type, 'bye');
      await peer.waitClosed();
      expect(
        closed.isCompleted,
        isFalse,
        reason: 'cierre propio: sin onClosed',
      );
      // Idempotente.
      await connection.close();
    },
  );

  test('close() acaba antes del plazo si el par cierra', () async {
    final closing = connection.close(
      farewell: ProtocolMessage.create('bye'),
      timeout: const Duration(seconds: 5),
    );
    await peer.nextOfType('bye');
    await peer.close();
    await closing.timeout(kWait);
  });

  test(
    'destroy() cierra sin onClosed y las tramas posteriores se ignoran',
    () async {
      connection.destroy();
      expect(connection.isOpen, isFalse);
      await peer.waitClosed();
      expect(closed.isCompleted, isFalse);
      expect(connection.sendFrame(encodeFrame({})), isFalse);
      connection.destroy();
    },
  );

  test('una excepción en onFrame cierra la conexión con onClosed', () async {
    final boom = await () async {
      final server2 = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server2.close);
      final accepted = server2.first;
      final peer2 = await RawPeer.connect(server2.port);
      addTearDown(peer2.destroy);
      final link = FrameConnection(await accepted);
      addTearDown(link.destroy);
      final closed2 = Completer<NetworkException>();
      link.start(
        onFrame: (_) => throw StateError('bum'),
        onClosed: closed2.complete,
      );
      peer2.sendJson({'x': 1});
      return closed2.future.timeout(kWait);
    }();
    expect(boom.cause, isA<StateError>());
  });

  test(
    'trama fatal (sin delimitador y gigante) llega como FrameFailure',
    () async {
      peer.sendRaw(List<int>.filled(4096, 0x61));
      final event = await frames.next();
      expect(
        event,
        isA<FrameFailure>().having((f) => f.fatal, 'fatal', isTrue),
      );
      expect(connection.isOpen, isTrue, reason: 'decide quien usa la conexión');
    },
  );

  test('send() con un mensaje no serializable lanza ProtocolException', () {
    expect(
      () => connection.send(
        ProtocolMessage.create('x', payload: {'when': DateTime(2026)}),
      ),
      throwsA(isA<ProtocolException>()),
    );
    expect(connection.isOpen, isTrue);
  });
}
