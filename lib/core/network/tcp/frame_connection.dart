import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../../errors/app_exception.dart';
import '../../logging/app_logger.dart';
import '../protocol/frame_codec.dart';
import '../protocol/message.dart';

final Logger _log = appLogger('network.tcp.link');

enum _Phase { open, closing, closed }

/// Conexión TCP ya establecida que intercambia tramas JSON-line.
///
/// Es la pieza común del servidor del host y del cliente del comandero: ambos
/// necesitan exactamente las mismas garantías sobre el `Socket` de `dart:io`,
/// que tiene varias trampas:
///
/// * Los errores de escritura no salen por el stream de lectura sino por
///   `socket.done`; si nadie escucha ese `Future`, el error acaba en la zona
///   como excepción no manejada. Aquí todos los `Future` del socket (`done`,
///   `flush`, `close`) tienen manejador.
/// * `add` lanza `StateError` si el sink ya está cerrado o hay un `flush` en
///   curso. [sendFrame] nunca lanza por el estado del socket: devuelve `false`.
/// * Los métodos del socket (`remoteAddress`, `setOption`) lanzan si el socket
///   ya murió, así que la dirección remota se captura una sola vez al crear la
///   conexión.
///
/// Ciclo de vida: abierta → (cerrándose) → cerrada. Los callbacks de [start]
/// dejan de invocarse en cuanto el cierre lo inicia este extremo ([close] o
/// [destroy]): quien cierra ya sabe por qué.
final class FrameConnection {
  FrameConnection(Socket socket, {int maxFrameBytes = kDefaultMaxFrameBytes})
    : _socket = socket,
      _maxFrameBytes = maxFrameBytes,
      _framer = JsonLineFramer(maxFrameBytes: maxFrameBytes) {
    // Las tramas son pequeñas e interactivas (una comanda, un ping): con el
    // algoritmo de Nagle activo cada una podría esperar al ACK de la anterior.
    try {
      socket.setOption(SocketOption.tcpNoDelay, true);
    } on Exception catch (error) {
      _log.fine('No se pudo activar TCP_NODELAY', error);
    }
    var address = '';
    var port = 0;
    try {
      address = socket.remoteAddress.address;
      port = socket.remotePort;
    } on Exception catch (error) {
      _log.fine('Socket cerrado antes de leer su dirección remota', error);
    }
    remoteAddress = address;
    remotePort = port;

    unawaited(
      socket.done.then<void>(
        (Object? _) {},
        onError: (Object error) => _fail(_translate(error)),
      ),
    );
  }

  final Socket _socket;
  final int _maxFrameBytes;
  final JsonLineFramer _framer;

  /// Dirección IP del otro extremo (cadena vacía si el socket ya estaba roto).
  late final String remoteAddress;
  late final int remotePort;

  _Phase _phase = _Phase.open;
  StreamSubscription<Uint8List>? _subscription;
  void Function(FrameEvent event)? _onFrame;
  void Function(NetworkException reason)? _onClosed;
  Completer<void>? _closeCompleter;
  Timer? _closeTimer;

  /// `true` mientras se pueden enviar y recibir tramas.
  bool get isOpen => _phase == _Phase.open;

  /// Empieza a leer del socket.
  ///
  /// [onFrame] recibe cada trama (válida o fallida) en orden de llegada.
  /// [onClosed] se invoca como mucho una vez, y solo si la conexión termina
  /// por causa ajena a este extremo (cierre remoto, error de E/S); después de
  /// [close] o [destroy] no se invoca ninguno de los dos.
  void start({
    required void Function(FrameEvent event) onFrame,
    required void Function(NetworkException reason) onClosed,
  }) {
    if (_subscription != null) {
      throw StateError('FrameConnection.start solo puede llamarse una vez');
    }
    _onFrame = onFrame;
    _onClosed = onClosed;
    if (_phase != _Phase.open) return;
    _subscription = _socket.listen(
      _handleData,
      onError: (Object error) => _fail(_translate(error)),
      onDone: _handleDone,
    );
  }

  /// Serializa y envía [message]. Devuelve `false` si la conexión ya no está
  /// abierta.
  ///
  /// Lanza [ProtocolException] si el mensaje no es serializable o supera el
  /// tamaño máximo de trama (es un error de quien construye el mensaje, no de
  /// la red).
  bool send(ProtocolMessage message) =>
      sendFrame(encodeFrame(message.toJson(), maxFrameBytes: _maxFrameBytes));

  /// Envía una trama ya codificada con `encodeFrame`. Las tramas salen en el
  /// orden de las llamadas. Devuelve `false` si la conexión ya no está abierta.
  bool sendFrame(Uint8List frame) {
    if (_phase != _Phase.open) return false;
    try {
      _socket.add(frame);
      return true;
    } on Object catch (error) {
      // El aviso se difiere para que `onClosed` nunca se ejecute reentrando en
      // quien está llamando a `sendFrame` (p. ej. a mitad de un bucle de
      // retransmisión).
      _fail(_translate(error), deferNotification: true);
      return false;
    }
  }

  /// Cierre ordenado: envía [farewell] (si lo hay), vacía el buffer de salida,
  /// cierra el lado de escritura y espera a que el otro extremo cierre el suyo
  /// o a que venza [timeout]; al final destruye el socket.
  ///
  /// Se sigue leyendo (y descartando) hasta el final porque cerrar un socket
  /// con datos entrantes sin leer hace que el sistema envíe RST en lugar de
  /// FIN, y el otro extremo podría perder el [farewell]. Además, en Windows el
  /// puerto de escucha no puede volver a abrirse mientras queden conexiones
  /// aceptadas sin cerrar del todo.
  ///
  /// El `Future` devuelto nunca falla y se completa cuando el socket está
  /// destruido. Es idempotente.
  Future<void> close({
    ProtocolMessage? farewell,
    Duration timeout = const Duration(seconds: 1),
  }) {
    switch (_phase) {
      case _Phase.closed:
        return Future<void>.value();
      case _Phase.closing:
        return _closeCompleter!.future;
      case _Phase.open:
        break;
    }
    _phase = _Phase.closing;
    final completer = _closeCompleter = Completer<void>();
    _closeTimer = Timer(timeout, _finishClose);
    try {
      if (farewell != null) {
        _socket.add(
          encodeFrame(farewell.toJson(), maxFrameBytes: _maxFrameBytes),
        );
      }
      unawaited(
        _socket
            .flush()
            .then<Object?>((Object? _) => _socket.close())
            .then<void>((Object? _) {}, onError: (Object _) => _finishClose()),
      );
    } on Object catch (error) {
      _log.fine('Cierre ordenado imposible; se destruye el socket', error);
      _finishClose();
    }
    return completer.future;
  }

  /// Cierre inmediato (por error, timeout o conexión dada por muerta). No
  /// invoca `onClosed`. Es idempotente.
  void destroy() => _finishClose();

  void _handleData(Uint8List chunk) {
    if (_phase != _Phase.open) return;
    for (final event in _framer.add(chunk)) {
      // Una trama anterior del mismo segmento puede haber cerrado la conexión.
      if (_phase != _Phase.open) return;
      try {
        _onFrame?.call(event);
      } on Object catch (error, stackTrace) {
        _log.severe(
          'Error no controlado al procesar una trama',
          error,
          stackTrace,
        );
        _fail(
          NetworkException('Fallo interno al procesar una trama', cause: error),
        );
        return;
      }
    }
  }

  void _handleDone() {
    if (_phase != _Phase.open) {
      _finishClose();
      return;
    }
    final tail = _framer.close();
    _fail(
      NetworkException(
        tail == null
            ? 'El otro extremo cerró la conexión'
            : 'El otro extremo cerró la conexión a mitad de una trama',
        cause: tail?.error,
      ),
    );
  }

  void _fail(NetworkException reason, {bool deferNotification = false}) {
    if (_phase != _Phase.open) {
      // Durante un cierre ordenado cualquier error solo adelanta el final.
      _finishClose();
      return;
    }
    _release();
    final onClosed = _onClosed;
    if (onClosed == null) return;
    if (deferNotification) {
      scheduleMicrotask(() => onClosed(reason));
    } else {
      onClosed(reason);
    }
  }

  void _finishClose() {
    if (_phase == _Phase.closed) return;
    _release();
    final completer = _closeCompleter;
    if (completer != null && !completer.isCompleted) completer.complete();
  }

  void _release() {
    _phase = _Phase.closed;
    _closeTimer?.cancel();
    _closeTimer = null;
    final subscription = _subscription;
    if (subscription != null) {
      unawaited(subscription.cancel().catchError((Object _) {}));
    }
    try {
      _socket.destroy();
    } on Object catch (error) {
      _log.fine('Error al destruir el socket', error);
    }
  }

  static NetworkException _translate(Object error) => switch (error) {
    NetworkException() => error,
    SocketException(:final message, :final osError) => NetworkException(
      'Error de socket: ${osError?.message ?? message}',
      cause: error,
    ),
    _ => NetworkException('Error de conexión', cause: error),
  };
}
