import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../../errors/app_exception.dart';
import '../../logging/app_logger.dart';

/// Puerto estándar de impresión en crudo (RAW / JetDirect / AppSocket).
const int kRawPrintPort = 9100;

final Logger _log = appLogger('network.printing');

/// Dirección de red de una impresora térmica.
///
/// Es la clave por la que `PrintQueue` serializa los trabajos, así que la
/// igualdad ignora mayúsculas en [host]: `Cocina.local` y `cocina.local` son la
/// misma impresora y no deben acabar en dos colas que intercalen bytes. Lo que
/// no puede detectarse es que un nombre y una IP apunten al mismo equipo:
/// configura cada impresora siempre con la misma dirección.
@immutable
final class PrinterEndpoint {
  /// Lanza [ValidationException] si [host] está vacío o contiene espacios, o
  /// si [port] no está entre 1 y 65535. Validar aquí garantiza que cualquier
  /// instancia que llegue al transporte o a la cola es utilizable.
  PrinterEndpoint(String host, {this.port = kRawPrintPort})
    : host = host.trim() {
    if (this.host.isEmpty) {
      throw const ValidationException(
        'La dirección de la impresora está vacía',
      );
    }
    if (this.host.contains(RegExp(r'\s'))) {
      throw ValidationException(
        "La dirección de la impresora no puede contener espacios: '$host'",
      );
    }
    if (port < 1 || port > 65535) {
      throw ValidationException(
        'Puerto de impresora fuera de rango (1-65535): $port',
      );
    }
  }

  /// Nombre de host o IP, sin espacios alrededor.
  final String host;
  final int port;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PrinterEndpoint &&
          other.port == port &&
          other.host.toLowerCase() == host.toLowerCase();

  @override
  int get hashCode => Object.hash(host.toLowerCase(), port);

  /// `host:port` (un literal IPv6 se escribe `[host]:port`).
  @override
  String toString() => host.contains(':') ? '[$host]:$port' : '$host:$port';
}

/// Temporizadores y troceado del envío a la impresora.
@immutable
final class PrinterTransportOptions {
  const PrinterTransportOptions({
    this.connectTimeout = const Duration(seconds: 5),
    this.writeTimeout = const Duration(seconds: 10),
    this.closeTimeout = const Duration(seconds: 3),
    this.chunkBytes = 4096,
    this.awaitPeerClose = true,
  }) : assert(chunkBytes > 0, 'chunkBytes debe ser positivo');

  /// Tiempo máximo para establecer la conexión TCP (resolución de nombre
  /// incluida).
  final Duration connectTimeout;

  /// Tiempo máximo **sin progreso** al escribir: se aplica a cada trozo de
  /// [chunkBytes], no al trabajo completo. Un ticket largo se imprime a la
  /// velocidad del mecanismo y su duración total depende de su longitud; lo
  /// que delata un problema (sin papel, tapa abierta, cable desconectado) es
  /// que la impresora deje de aceptar datos.
  final Duration writeTimeout;

  /// Tiempo máximo del cierre ordenado: enviar el FIN y, si [awaitPeerClose],
  /// esperar a que la impresora cierre su lado.
  final Duration closeTimeout;

  /// Tamaño de cada escritura. Trocear permite medir el progreso (y por tanto
  /// detectar el atasco con [writeTimeout]) sin volcar megas de golpe en el
  /// búfer del socket.
  final int chunkBytes;

  /// Tras enviar el FIN, esperar (hasta [closeTimeout]) a que la impresora
  /// cierre su lado de la conexión.
  ///
  /// RAW 9100 no tiene acuse de recibo de aplicación; el cierre de la
  /// impresora es la mejor señal disponible de que ha consumido el trabajo y
  /// está lista para aceptar la siguiente conexión (atienden una a la vez). Si
  /// en esa espera la impresora **corta** la conexión (RST), el envío se da por
  /// fallido. Si simplemente no cierra a tiempo se da por bueno: hay firmwares
  /// que mantienen la conexión hasta su propio temporizador de inactividad.
  ///
  /// Desactívalo para impresoras que cierran siempre de forma abrupta (cada
  /// trabajo se reportaría como fallido y se reimprimiría) o que nunca cierran
  /// (cada trabajo tardaría [closeTimeout] de más).
  final bool awaitPeerClose;
}

/// Transporte de bytes ya generados hacia una impresora. No interpreta ni
/// genera comandos ESC/POS.
abstract interface class RawPrinterTransport {
  /// Entrega [bytes] a la impresora de [endpoint]. Completa cuando el trabajo
  /// se ha entregado; falla con [PrinterConnectException] si no se llegó a
  /// conectar (no salió ningún byte) y con [PrinterException] en cualquier
  /// otro caso (escritura o cierre: parte del trabajo pudo haber salido).
  ///
  /// [bytes] no se copia: no debe modificarse hasta que el `Future` complete.
  Future<void> send(PrinterEndpoint endpoint, Uint8List bytes);
}

/// Abre la conexión TCP con la impresora. Tiene la forma de [Socket.connect]
/// para poder inyectar en los tests conexiones que tardan, fallan o se cuelgan.
typedef SocketConnector = Future<Socket> Function(
  String host,
  int port, {
  Duration? timeout,
});

/// Envía ESC/POS en crudo por TCP (puerto 9100) abriendo **una conexión por
/// trabajo**.
///
/// Las impresoras térmicas de red atienden una sola conexión a la vez y
/// cierran las que quedan inactivas, así que mantener un socket abierto entre
/// tickets solo aporta estados rotos difíciles de detectar. Esta clase no
/// serializa llamadas concurrentes al mismo destino: de eso se encarga
/// `PrintQueue`.
///
/// Qué significa que [send] complete sin error: la pila TCP aceptó todos los
/// bytes y la conexión se cerró sin que la impresora la cortase. El protocolo
/// no permite saber si el papel salió; un fallo, a la inversa, no garantiza
/// que no se imprimiera nada (el corte pudo llegar a mitad de ticket), de modo
/// que reintentar puede duplicar parte de un ticket. En cocina eso es
/// preferible a perder una comanda. La única excepción segura es el fallo al
/// conectar ([PrinterConnectException]): no salió ningún byte, y es lo único
/// que `PrintQueue` reintenta para una factura.
final class EscPosSocketPrinter implements RawPrinterTransport {
  EscPosSocketPrinter({
    this.options = const PrinterTransportOptions(),
    SocketConnector? connector,
  }) : _connector = connector ?? Socket.connect;

  final PrinterTransportOptions options;
  final SocketConnector _connector;

  /// Con [bytes] vacío no abre conexión y completa sin error: no hay nada que
  /// entregar y conectarse ocuparía la única conexión que admite la impresora.
  @override
  Future<void> send(PrinterEndpoint endpoint, Uint8List bytes) async {
    if (bytes.isEmpty) return;

    final elapsed = Stopwatch()..start();
    final socket = await _connect(endpoint);
    _SocketWatch? watch;
    try {
      watch = _SocketWatch(socket);
      _disableNagle(socket, endpoint);
      await _write(socket, watch, endpoint, bytes);
      await _closeGracefully(socket, watch, endpoint);
      _log.fine(
        'Enviados ${bytes.length} bytes a $endpoint '
        'en ${elapsed.elapsedMilliseconds} ms',
      );
    } finally {
      // destroy() siempre: tras un timeout o un error el cierre ordenado ya no
      // es posible y no puede quedar un descriptor abierto ocupando la única
      // conexión de la impresora.
      watch?.stop();
      socket.destroy();
    }
  }

  Future<Socket> _connect(PrinterEndpoint endpoint) async {
    final limit = options.connectTimeout;
    try {
      final pending = _connector(endpoint.host, endpoint.port, timeout: limit);
      // El `timeout` nativo no cubre la resolución de nombres y un conector
      // inyectado puede ignorarlo: esta guarda acota el total.
      return await pending.timeout(
        limit,
        onTimeout: () {
          // Si la conexión llega a establecerse después, nadie la usaría.
          unawaited(
            pending.then<void>(
              (late) => late.destroy(),
              onError: (Object _) {},
            ),
          );
          throw TimeoutException('Conexión no establecida', limit);
        },
      );
    } on TimeoutException catch (error) {
      throw PrinterConnectException(
        _connectTimeoutMessage(endpoint),
        cause: error,
      );
    } on SocketException catch (error) {
      throw PrinterConnectException(
        _looksLikeTimeout(error)
            ? _connectTimeoutMessage(endpoint)
            : 'No se pudo conectar con la impresora $endpoint: '
                  '${_reason(error)}',
        cause: error,
      );
    } on Object catch (error) {
      throw PrinterConnectException(
        'No se pudo conectar con la impresora $endpoint: ${_reason(error)}',
        cause: error,
      );
    }
  }

  String _connectTimeoutMessage(PrinterEndpoint endpoint) =>
      'La impresora $endpoint no responde: sin conexión tras '
      '${_formatDuration(options.connectTimeout)}. '
      'Compruebe que está encendida y en la misma red';

  /// Un ticket son pocos kilobytes: con Nagle activo el último segmento
  /// parcial puede retenerse hasta 200 ms esperando un ACK.
  void _disableNagle(Socket socket, PrinterEndpoint endpoint) {
    try {
      socket.setOption(SocketOption.tcpNoDelay, true);
    } on Exception catch (error) {
      // Es solo una optimización; si el socket está roto lo dirá la escritura.
      _log.fine('No se pudo activar tcpNoDelay en $endpoint', error);
    }
  }

  Future<void> _write(
    Socket socket,
    _SocketWatch watch,
    PrinterEndpoint endpoint,
    Uint8List bytes,
  ) async {
    final chunkBytes = math.max(1, options.chunkBytes);
    final total = bytes.length;
    var sent = 0;
    try {
      while (sent < total) {
        if (watch.peerClosed) {
          throw PrinterException(
            'La impresora $endpoint cerró la conexión antes de recibir el '
            'trabajo completo ($sent de $total bytes enviados)',
          );
        }
        final end = math.min(sent + chunkBytes, total);
        socket.add(Uint8List.sublistView(bytes, sent, end));
        // flush() solo completa cuando el sistema operativo ha aceptado el
        // trozo: si la impresora deja de leer, su ventana TCP se cierra y la
        // espera se alarga hasta el timeout.
        await _orFailure(socket.flush(), watch, options.writeTimeout);
        sent = end;
      }
    } on PrinterException {
      rethrow;
    } on TimeoutException catch (error) {
      throw PrinterException(
        'La impresora $endpoint dejó de aceptar datos: sin progreso durante '
        '${_formatDuration(options.writeTimeout)} ($sent de $total bytes '
        'enviados). Compruebe el papel y la tapa',
        cause: error,
      );
    } on Object catch (error) {
      throw PrinterException(
        'Se perdió la conexión con la impresora $endpoint durante el envío '
        '($sent de $total bytes enviados): ${_reason(error)}',
        cause: error,
      );
    }
  }

  /// Cierre ordenado: FIN y, opcionalmente, espera al cierre de la impresora.
  ///
  /// Aquí todos los bytes están ya en manos de la pila TCP, así que solo un
  /// corte explícito de la conexión cuenta como fallo. Agotar [closeTimeout]
  /// no lo es: reintentar por un simple silencio duplicaría el ticket.
  Future<void> _closeGracefully(
    Socket socket,
    _SocketWatch watch,
    PrinterEndpoint endpoint,
  ) async {
    final budget = Stopwatch()..start();
    try {
      await _orFailure(socket.close(), watch, options.closeTimeout);
      if (!options.awaitPeerClose || watch.peerClosed) return;
      final remaining = options.closeTimeout - budget.elapsed;
      if (remaining <= Duration.zero) return;
      await _orFailure(watch.peerEof, watch, remaining);
    } on TimeoutException {
      _log.fine(
        'La impresora $endpoint no cerró la conexión en '
        '${_formatDuration(options.closeTimeout)}; el trabajo se da por '
        'entregado',
      );
    } on Object catch (error) {
      throw PrinterException(
        'La impresora $endpoint cortó la conexión al terminar el envío; el '
        'ticket puede haber salido incompleto: ${_reason(error)}',
        cause: error,
      );
    }
  }
}

/// Espera [operation] como máximo [limit], adelantándose si el socket falla
/// mientras tanto (lanza ese error, o [TimeoutException]).
Future<void> _orFailure(
  Future<void> operation,
  _SocketWatch watch,
  Duration limit,
) => Future.any<void>([operation, watch.failure]).timeout(limit);

/// Observa el socket durante todo el trabajo.
///
/// Cumple dos funciones:
///  * Da un manejador a `socket.done` y a los errores de lectura. Sin él, un
///    RST de la impresora sería un error asíncrono sin capturar que tumba la
///    zona.
///  * Lee y descarta lo que envíe la impresora (bytes de estado). Cerrar un
///    socket con datos recibidos sin leer provoca un RST en lugar de un FIN, y
///    la impresora puede tirar lo que aún tenía en su búfer: tickets cortados.
final class _SocketWatch {
  _SocketWatch(Socket socket) {
    // Los `Future` internos siempre tienen manejador aunque nadie los espere.
    _failure.future.ignore();
    unawaited(socket.done.then<void>((_) {}, onError: _onFailure));
    _incoming = socket.listen(
      (_) {},
      onError: _onFailure,
      onDone: () {
        if (!_peerEof.isCompleted) _peerEof.complete();
      },
      cancelOnError: true,
    );
  }

  final Completer<void> _failure = Completer<void>();
  final Completer<void> _peerEof = Completer<void>();
  StreamSubscription<Uint8List>? _incoming;

  /// Nunca completa con valor: solo con el primer error del socket.
  Future<void> get failure => _failure.future;

  /// Completa cuando la impresora cierra ordenadamente su lado (FIN).
  Future<void> get peerEof => _peerEof.future;

  bool get peerClosed => _peerEof.isCompleted;

  void _onFailure(Object error, StackTrace stackTrace) {
    if (!_failure.isCompleted) _failure.completeError(error, stackTrace);
  }

  void stop() {
    final incoming = _incoming;
    _incoming = null;
    if (incoming != null) incoming.cancel().ignore();
  }
}

/// Texto breve de la causa para el mensaje de la excepción.
String _reason(Object error) {
  if (error is SocketException) {
    final osMessage = error.osError?.message.trim() ?? '';
    final code = error.osError?.errorCode;
    if (osMessage.isNotEmpty) {
      return code == null ? osMessage : '$osMessage (errno $code)';
    }
    return error.message.isEmpty ? 'error de socket' : error.message;
  }
  if (error is TimeoutException) return 'tiempo de espera agotado';
  if (error is AppException) return error.message;
  return error.toString();
}

/// Solo afina el texto del mensaje: el timeout nativo de `Socket.connect` llega
/// como `SocketException`, igual que una conexión rechazada.
bool _looksLikeTimeout(SocketException error) {
  // ETIMEDOUT en Linux/Android (110), macOS/iOS (60) y Windows (10060).
  const timeoutCodes = {110, 60, 10060};
  return timeoutCodes.contains(error.osError?.errorCode) ||
      error.message.toLowerCase().contains('timed out');
}

String _formatDuration(Duration duration) {
  final ms = duration.inMilliseconds;
  if (ms < 1000) return '$ms ms';
  return ms % 1000 == 0
      ? '${ms ~/ 1000} s'
      : '${(ms / 1000).toStringAsFixed(1)} s';
}
