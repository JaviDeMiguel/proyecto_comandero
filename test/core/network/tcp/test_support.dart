/// Utilidades compartidas por los tests del transporte TCP.
///
/// Todos los pares "crudos" se construyen sobre `Socket`/`ServerSocket` de
/// `dart:io` para probar cada extremo real contra un interlocutor controlado
/// (malicioso, mudo o defectuoso) sin depender del otro extremo real.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:proyecto_comandero/core/network/protocol/frame_codec.dart';
import 'package:proyecto_comandero/core/network/protocol/message.dart';
import 'package:proyecto_comandero/core/network/protocol/transport_messages.dart';
import 'package:test/test.dart';

/// Plazo genérico de espera de un evento en los tests: amplio frente a los
/// temporizadores de las opciones (decenas de ms) pero corto frente al timeout
/// del test, para que un fallo se diagnostique por el mensaje y no por cuelgue.
const Duration kWait = Duration(seconds: 5);

/// Buzón de elementos con espera asíncrona del siguiente.
///
/// Sustituye a `StreamQueue` (package:async no está en pubspec): permite
/// consumir eventos de un stream uno a uno con timeout y mensaje descriptivo.
final class Inbox<T> {
  Inbox(Stream<T> stream, {this.describe}) {
    _subscription = stream.listen(
      _push,
      onError: (Object error, StackTrace stackTrace) {
        if (_waiters.isNotEmpty) {
          _waiters.removeFirst().completeError(error, stackTrace);
        } else {
          _errors.add(error);
        }
      },
      onDone: () {
        _done = true;
        while (_waiters.isNotEmpty) {
          _waiters.removeFirst().completeError(StateError('Stream cerrado'));
        }
      },
    );
  }

  final String Function(T item)? describe;
  late final StreamSubscription<T> _subscription;
  final Queue<T> _items = Queue<T>();
  final Queue<Object> _errors = Queue<Object>();
  final Queue<Completer<T>> _waiters = Queue<Completer<T>>();
  bool _done = false;

  /// Elementos recibidos y aún no consumidos.
  List<T> get buffered => _items.toList();
  bool get isDone => _done;

  void _push(T item) {
    if (_waiters.isNotEmpty) {
      _waiters.removeFirst().complete(item);
    } else {
      _items.add(item);
    }
  }

  /// Siguiente elemento, o falla si no llega en [timeout].
  Future<T> next({Duration timeout = kWait, String? what}) {
    if (_items.isNotEmpty) return Future<T>.value(_items.removeFirst());
    if (_errors.isNotEmpty) return Future<T>.error(_errors.removeFirst());
    if (_done) return Future<T>.error(StateError('Stream cerrado'));
    final completer = Completer<T>();
    _waiters.add(completer);
    return completer.future.timeout(
      timeout,
      onTimeout: () {
        _waiters.remove(completer);
        throw TimeoutException(
          'No llegó ${what ?? 'el siguiente elemento'} en $timeout',
        );
      },
    );
  }

  /// Consume elementos hasta que uno cumpla [test] y lo devuelve.
  Future<T> nextWhere(
    bool Function(T item) test, {
    Duration timeout = kWait,
    String? what,
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (true) {
      final remaining = deadline.difference(DateTime.now());
      if (remaining.isNegative) {
        throw TimeoutException('No llegó ${what ?? 'el elemento'} en $timeout');
      }
      final item = await next(timeout: remaining, what: what);
      if (test(item)) return item;
    }
  }

  /// Comprueba que NO llega nada durante [quiet].
  Future<void> expectSilence(Duration quiet) async {
    await expectLater(
      next(timeout: quiet, what: 'nada'),
      throwsA(isA<TimeoutException>()),
    );
  }

  Future<void> cancel() => _subscription.cancel();
}

/// Mensajes recibidos de un socket crudo, ya decodificados.
///
/// Las tramas inválidas se cuentan en [failures] en lugar de interrumpir.
final class RawPeer {
  RawPeer._(this.socket) {
    _inbox = Inbox<ProtocolMessage>(
      const JsonLineDecoder().bind(socket).expand<ProtocolMessage>((event) {
        switch (event) {
          case FrameData(:final json):
            return [ProtocolMessage.fromJson(json)];
          case FrameFailure():
            failures++;
            return const [];
        }
      }),
    );
    // El cierre remoto también se observa por el buzón (onDone); `done` del
    // socket se escucha para que un error de escritura no quede sin manejar.
    unawaited(socket.done.then<void>((Object? _) {}, onError: (Object _) {}));
  }

  /// Conecta con el servidor en loopback.
  static Future<RawPeer> connect(int port) async {
    final socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
    socket.setOption(SocketOption.tcpNoDelay, true);
    return RawPeer._(socket);
  }

  /// Envuelve un socket aceptado por un `ServerSocket` crudo.
  factory RawPeer.accepted(Socket socket) => RawPeer._(socket);

  final Socket socket;
  late final Inbox<ProtocolMessage> _inbox;
  int failures = 0;

  Inbox<ProtocolMessage> get inbox => _inbox;

  /// `true` cuando el otro extremo ha cerrado su lado de la conexión.
  bool get remoteClosed => _inbox.isDone;

  void send(ProtocolMessage message) =>
      socket.add(encodeFrame(message.toJson()));

  void sendJson(Map<String, Object?> json) => socket.add(encodeFrame(json));

  void sendRaw(List<int> bytes) => socket.add(bytes);

  Future<ProtocolMessage> next({Duration timeout = kWait, String? what}) =>
      _inbox.next(timeout: timeout, what: what);

  Future<ProtocolMessage> nextOfType(String type, {Duration timeout = kWait}) =>
      _inbox.nextWhere(
        (m) => m.type == type,
        timeout: timeout,
        what: "un mensaje '$type'",
      );

  /// Siguiente mensaje de aplicación (ignora `ping` y demás tipos reservados).
  Future<ProtocolMessage> nextApplication({Duration timeout = kWait}) =>
      _inbox.nextWhere(
        (m) => !TransportMessageTypes.isReserved(m.type),
        timeout: timeout,
        what: 'un mensaje de aplicación',
      );

  /// Espera a que el otro extremo cierre la conexión.
  Future<void> waitClosed({Duration timeout = kWait}) async {
    if (_inbox.isDone) return;
    final deadline = DateTime.now().add(timeout);
    while (!_inbox.isDone) {
      final remaining = deadline.difference(DateTime.now());
      if (remaining.isNegative) {
        throw TimeoutException('El otro extremo no cerró en $timeout');
      }
      try {
        await _inbox.next(timeout: remaining);
      } on StateError {
        return;
      }
    }
  }

  /// Envía un `hello` estándar y devuelve la respuesta (`welcome` o `reject`).
  Future<ProtocolMessage> hello({
    required String deviceId,
    String deviceName = 'Comandero test',
    int protocolVersion = kProtocolVersion,
    String? pairingCode,
    String? appVersion,
  }) {
    final hello = ProtocolMessage.create(
      TransportMessageTypes.hello,
      payload: HelloPayload(
        deviceId: deviceId,
        deviceName: deviceName,
        protocolVersion: protocolVersion,
        pairingCode: pairingCode,
        appVersion: appVersion,
      ).toJson(),
    );
    send(hello);
    return next(what: 'la respuesta al hello');
  }

  /// Handshake completo: envía `hello` y exige un `welcome`.
  Future<WelcomePayload> handshake({required String deviceId}) async {
    final reply = await hello(deviceId: deviceId);
    expect(reply.type, TransportMessageTypes.welcome);
    return WelcomePayload.fromJson(reply.payload);
  }

  /// Envía una petición de aplicación y devuelve su respuesta (`ack`/`error`).
  Future<ProtocolMessage> request(
    String type,
    Map<String, Object?> payload, {
    String? id,
    Duration timeout = kWait,
  }) {
    final message = ProtocolMessage.create(type, payload: payload, id: id);
    send(message);
    return _inbox.nextWhere(
      (m) => m.replyTo == message.id,
      timeout: timeout,
      what: 'la respuesta a ${message.id}',
    );
  }

  void destroy() {
    socket.destroy();
    unawaited(_inbox.cancel());
  }

  Future<void> close() async {
    try {
      await socket.close();
    } on Object catch (_) {
      // El otro extremo ya puede haber cerrado.
    }
    socket.destroy();
  }
}

/// Servidor crudo que hace de "host" controlado para probar el cliente.
///
/// Cada conexión aceptada se entrega como [RawPeer] por [connections].
final class FakeHost {
  FakeHost._(this._server) {
    connections = Inbox<RawPeer>(
      _server.map((socket) {
        socket.setOption(SocketOption.tcpNoDelay, true);
        final peer = RawPeer.accepted(socket);
        _peers.add(peer);
        return peer;
      }),
    );
  }

  static Future<FakeHost> start() async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    return FakeHost._(server);
  }

  final ServerSocket _server;
  final List<RawPeer> _peers = [];
  late final Inbox<RawPeer> connections;

  int get port => _server.port;

  /// Espera la siguiente conexión entrante.
  Future<RawPeer> accept({Duration timeout = kWait}) =>
      connections.next(timeout: timeout, what: 'una conexión entrante');

  /// Acepta una conexión, espera el `hello` y responde `welcome`.
  Future<(RawPeer, ProtocolMessage)> acceptAndWelcome({
    int heartbeatIntervalMs = 50,
    int idleTimeoutMs = 300,
    String sessionId = 'sesion-falsa',
  }) async {
    final peer = await accept();
    final hello = await peer.nextOfType(TransportMessageTypes.hello);
    peer.send(
      hello.reply(
        TransportMessageTypes.welcome,
        payload: WelcomePayload(
          hostId: 'host-falso',
          hostName: 'Host falso',
          sessionId: sessionId,
          serverTimeMs: DateTime.now().millisecondsSinceEpoch,
          heartbeatIntervalMs: heartbeatIntervalMs,
          idleTimeoutMs: idleTimeoutMs,
        ).toJson(),
      ),
    );
    return (peer, hello);
  }

  Future<void> close() async {
    for (final peer in _peers) {
      peer.destroy();
    }
    await _server.close();
    await connections.cancel();
  }
}

/// Puerto efímero que queda ocupado por un `ServerSocket` ajeno.
Future<ServerSocket> occupyPort() =>
    ServerSocket.bind(InternetAddress.loopbackIPv4, 0);

/// Comprueba que un puerto de loopback está libre intentando abrirlo.
Future<bool> isPortFree(int port) async {
  try {
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
    await probe.close();
    return true;
  } on SocketException {
    return false;
  }
}
