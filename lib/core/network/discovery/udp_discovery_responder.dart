import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../../errors/app_exception.dart';
import '../../logging/app_logger.dart';
import 'discovery_protocol.dart';

/// Abre el socket UDP del respondedor. Existe para que los tests puedan
/// observar o sustituir el socket real; en producción es
/// `RawDatagramSocket.bind`.
typedef DatagramSocketBinder = Future<RawDatagramSocket> Function(
  InternetAddress address,
  int port, {
  required bool reuseAddress,
});

/// Lo que el host anuncia de sí mismo a los comanderos que lo buscan.
@immutable
final class HostAnnouncement {
  const HostAnnouncement({
    required this.hostId,
    required this.hostName,
    required this.tcpPort,
    this.requiresPairing = false,
  });

  /// Identificador estable de la instalación (el mismo del `welcome` TCP).
  final String hostId;

  /// Nombre visible. Si supera [kMaxDiscoveryHostNameLength] se anuncia
  /// recortado.
  final String hostName;

  /// Puerto real del servidor TCP del host.
  final int tcpPort;

  /// El host tiene código de emparejamiento configurado.
  final bool requiresPairing;

  @override
  bool operator ==(Object other) =>
      other is HostAnnouncement &&
      other.hostId == hostId &&
      other.hostName == hostName &&
      other.tcpPort == tcpPort &&
      other.requiresPairing == requiresPairing;

  @override
  int get hashCode => Object.hash(hostId, hostName, tcpPort, requiresPairing);

  @override
  String toString() =>
      'HostAnnouncement($hostName [$hostId] tcp:$tcpPort'
      '${requiresPairing ? ', emparejamiento' : ''})';
}

/// Lado host del descubrimiento: escucha sondas UDP y responde por unicast al
/// origen con la identidad del host y su puerto TCP.
///
/// Decisiones no obvias:
///
/// * **Respuesta unicast desde el mismo socket.** La respuesta sale del puerto
///   de descubrimiento hacia `origen:puerto` de la sonda; así atraviesa los
///   cortafuegos con estado del comandero y no se inunda la LAN.
/// * **Autorreparación.** `dart:io` cierra un socket UDP ante *cualquier*
///   error, incluido un envío fallido (p. ej. la ruta hacia el comandero
///   desaparece entre la sonda y la respuesta). Un respondedor que debe vivir
///   todo el turno no puede morir por eso: si el socket se cierra sin que se
///   haya llamado a [stop], se vuelve a enlazar al mismo puerto cada
///   `rebindDelay` hasta conseguirlo.
/// * **Límite por IP de origen.** UDP permite falsificar el origen, así que un
///   respondedor sin límite serviría para reflejar tráfico contra un tercero.
///   Se responde como mucho `maxResponsesPerSource` veces por
///   `rateLimitWindow` a cada IP; el resto de sondas se descartan en silencio.
/// * **Cola de salida.** En Windows `dart:io` solo admite un envío UDP en
///   vuelo por socket: `send` devuelve 0 (y descarta el datagrama) si el
///   anterior aún no ha terminado, cosa habitual cuando varias sondas llegan
///   en el mismo evento `read` (tres comanderos a la vez, o las sondas
///   repetidas de uno). Lo que no cabe se encola y se reenvía en el evento
///   `write`, que el sistema emite al quedar libre el socket.
final class UdpDiscoveryResponder {
  /// [announcement] se consulta en cada respuesta para que los cambios de
  /// nombre, puerto o emparejamiento se apliquen sin reiniciar el respondedor.
  ///
  /// [reuseAddress] (activo por defecto) permite volver a enlazar el puerto
  /// justo después de cerrarlo. Efecto secundario a conocer: con él activo,
  /// Windows y Linux dejan que **otro** socket que también lo pida se enlace
  /// al mismo puerto, y entonces solo uno de los dos recibe cada sonda
  /// unicast. Con `false`, [start] falla si el puerto ya está en uso.
  ///
  /// [monotonicClock] y [binder] existen para los tests.
  UdpDiscoveryResponder({
    required this.announcement,
    int port = kDiscoveryPort,
    InternetAddress? bindAddress,
    this.reuseAddress = true,
    this.maxResponsesPerSource = 10,
    this.rateLimitWindow = const Duration(seconds: 1),
    this.rebindDelay = const Duration(seconds: 1),
    Duration Function()? monotonicClock,
    @visibleForTesting DatagramSocketBinder? binder,
  }) : _configuredPort = RangeError.checkValueInInterval(
         port,
         0,
         65535,
         'port',
       ),
       _bindAddress = bindAddress ?? InternetAddress.anyIPv4,
       _binder = binder ?? _defaultBinder {
    if (maxResponsesPerSource < 1) {
      throw ArgumentError.value(
        maxResponsesPerSource,
        'maxResponsesPerSource',
        'debe ser al menos 1',
      );
    }
    if (rateLimitWindow <= Duration.zero) {
      throw ArgumentError.value(
        rateLimitWindow,
        'rateLimitWindow',
        'debe ser positiva',
      );
    }
    _rateLimiter = _SourceRateLimiter(
      maxPerWindow: maxResponsesPerSource,
      window: rateLimitWindow,
      clock: monotonicClock ?? _stopwatchClock(),
    );
  }

  static final Logger _log = appLogger('network.discovery.responder');

  /// Margen para que el sistema operativo confirme el cierre del socket.
  static const Duration _closeGrace = Duration(seconds: 1);

  /// Tope de respuestas encoladas. Cubre de sobra una sala llena de
  /// comanderos sondeando a la vez; más allá, el socket no da abasto.
  static const int _maxQueuedResponses = 256;

  /// Fuente del anuncio; se invoca en cada respuesta.
  final HostAnnouncement Function() announcement;

  final int _configuredPort;
  final InternetAddress _bindAddress;
  final DatagramSocketBinder _binder;

  /// Ver el constructor.
  final bool reuseAddress;

  /// Respuestas máximas por IP de origen en cada [rateLimitWindow].
  final int maxResponsesPerSource;

  /// Ventana del límite anti-abuso.
  final Duration rateLimitWindow;

  /// Espera entre reintentos de enlace cuando el socket se cierra solo.
  final Duration rebindDelay;

  late final _SourceRateLimiter _rateLimiter;

  /// Cambia en cada [start] y [stop]: lo que quede en vuelo de una generación
  /// anterior (un `bind` pendiente, un temporizador de reenlace) se descarta.
  int _generation = 0;
  Future<void>? _startFuture;
  _BoundSocket? _bound;
  Timer? _rebindTimer;
  int? _boundPort;

  int _probesAnswered = 0;
  int _probesRateLimited = 0;
  int _datagramsIgnored = 0;
  int _announcementFailures = 0;
  int _responsesDropped = 0;

  /// `true` mientras hay un socket escuchando. Es `false` antes de [start],
  /// tras [stop] y durante un reenlace tras un cierre inesperado.
  bool get isRunning => _bound != null;

  /// Puerto real de escucha tras [start] (relevante si se pidió el `0`).
  /// Antes de [start] y tras [stop] devuelve el puerto configurado.
  int get port => _boundPort ?? _configuredPort;

  /// Sondas válidas a las que se ha intentado responder.
  int get probesAnswered => _probesAnswered;

  /// Sondas válidas descartadas por el límite anti-abuso.
  int get probesRateLimited => _probesRateLimited;

  /// Datagramas descartados por no ser una sonda válida.
  int get datagramsIgnored => _datagramsIgnored;

  /// Sondas válidas sin responder porque [announcement] lanzó o devolvió un
  /// anuncio que no cabe en el protocolo (p. ej. `tcpPort` 0 antes de que
  /// arranque el servidor TCP).
  int get announcementFailures => _announcementFailures;

  /// Respuestas descartadas por desbordar la cola de salida.
  int get responsesDropped => _responsesDropped;

  /// Empieza a escuchar. Idempotente: si ya está en marcha (o arrancando)
  /// devuelve el mismo futuro y no abre un segundo socket.
  ///
  /// Lanza [NetworkException] si no puede enlazar el puerto; en ese caso el
  /// respondedor queda parado y se puede volver a llamar a [start].
  Future<void> start() {
    return _startFuture ??= _open(++_generation);
  }

  /// Deja de escuchar y espera a que el sistema libere el puerto.
  /// Idempotente; también cancela un arranque o un reenlace en curso.
  Future<void> stop() async {
    _generation++;
    _startFuture = null;
    _rebindTimer?.cancel();
    _rebindTimer = null;
    _boundPort = null;
    final bound = _bound;
    _bound = null;
    if (bound == null) return;
    bound.socket.close();
    await bound.closed.future.timeout(_closeGrace, onTimeout: () {});
  }

  Future<void> _open(int generation) async {
    final RawDatagramSocket socket;
    try {
      socket = await _binder(
        _bindAddress,
        _configuredPort,
        reuseAddress: reuseAddress,
      );
    } on Object catch (error) {
      if (generation == _generation) _startFuture = null;
      if (error is SocketException || error is OSError) {
        throw NetworkException(
          'No se pudo abrir el puerto UDP $_configuredPort de descubrimiento '
          'en ${_bindAddress.address}',
          cause: error,
        );
      }
      rethrow;
    }
    if (generation != _generation) {
      // stop() llegó mientras se enlazaba.
      socket.close();
      return;
    }
    _attach(socket, generation);
    _log.info('Descubrimiento UDP escuchando en ${_bindAddress.address}:$port');
  }

  void _attach(RawDatagramSocket socket, int generation) {
    final bound = _BoundSocket(socket);
    _bound = bound;
    _boundPort = socket.port;
    // Los eventos `write` solo se piden cuando hay respuestas encoladas; si
    // no, despertarían el bucle por cada respuesta enviada.
    socket.writeEventsEnabled = false;
    socket.listen(
      (event) {
        if (event == RawSocketEvent.read) {
          _drain(bound);
        } else if (event == RawSocketEvent.write) {
          _flush(bound);
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        _log.warning(
          'Error en el socket de descubrimiento: $error',
          error,
          stackTrace,
        );
      },
      onDone: () {
        bound.closed.complete();
        _onSocketClosed(bound, generation);
      },
    );
  }

  void _onSocketClosed(_BoundSocket bound, int generation) {
    if (!identical(_bound, bound) || generation != _generation) return;
    _bound = null;
    _log.warning(
      'El socket de descubrimiento se cerró de forma inesperada; '
      'reintentando en ${rebindDelay.inMilliseconds} ms',
    );
    _scheduleRebind(generation);
  }

  void _scheduleRebind(int generation) {
    _rebindTimer?.cancel();
    _rebindTimer = Timer(rebindDelay, () => unawaited(_rebind(generation)));
  }

  Future<void> _rebind(int generation) async {
    if (generation != _generation) return;
    final RawDatagramSocket socket;
    try {
      // Mismo puerto que antes aunque se pidiera uno efímero: los comanderos
      // que ya conocen el puerto deben seguir encontrando al host.
      socket = await _binder(_bindAddress, port, reuseAddress: reuseAddress);
    } on Object catch (error) {
      if (generation != _generation) return;
      _log.warning('No se pudo reabrir el puerto UDP $port: $error');
      _scheduleRebind(generation);
      return;
    }
    if (generation != _generation) {
      socket.close();
      return;
    }
    _attach(socket, generation);
    _log.info('Descubrimiento UDP restablecido en el puerto $port');
  }

  void _drain(_BoundSocket bound) {
    // Un evento `read` puede cubrir varios datagramas: hay que vaciar la cola.
    while (true) {
      final datagram = bound.socket.receive();
      if (datagram == null) return;
      _handle(bound, datagram);
    }
  }

  void _handle(_BoundSocket bound, Datagram datagram) {
    final probe = DiscoveryProbe.tryParse(datagram.data);
    if (probe == null) {
      _datagramsIgnored++;
      return;
    }
    if (!_rateLimiter.allow(datagram.address.address)) {
      _probesRateLimited++;
      _log.fine(
        'Sonda de ${datagram.address.address} descartada por límite de '
        'respuestas',
      );
      return;
    }
    final Uint8List response;
    try {
      response = _buildResponse(probe);
    } catch (error, stackTrace) {
      // El anuncio lo calcula código del host: ni un fallo suyo ni un anuncio
      // inválido deben tumbar el respondedor.
      _announcementFailures++;
      _log.warning(
        'Anuncio del host inválido; no se responde: $error',
        error,
        stackTrace,
      );
      return;
    }
    _probesAnswered++;
    _enqueue(bound, _Outgoing(response, datagram.address, datagram.port));
    _flush(bound);
  }

  void _enqueue(_BoundSocket bound, _Outgoing outgoing) {
    if (bound.outgoing.length >= _maxQueuedResponses) {
      // Si el socket no da abasto, la más antigua es la que menos
      // probabilidades tiene de que su comandero siga escuchando.
      bound.outgoing.removeFirst();
      _responsesDropped++;
    }
    bound.outgoing.add(outgoing);
  }

  /// Envía lo encolado hasta vaciar la cola o hasta que el socket deje de
  /// admitir envíos; en ese caso pide un evento `write` para continuar.
  void _flush(_BoundSocket bound) {
    while (bound.outgoing.isNotEmpty) {
      final next = bound.outgoing.first;
      final int sent;
      try {
        // Si el envío falla con error, dart:io lo notifica por el stream y
        // cierra el socket: lo recoge `onDone` y se reenlaza.
        sent = bound.socket.send(next.data, next.address, next.port);
      } catch (error, stackTrace) {
        bound.outgoing.removeFirst();
        _log.warning(
          'No se pudo responder a ${next.address.address}:${next.port}: $error',
          error,
          stackTrace,
        );
        continue;
      }
      if (sent != next.data.length) {
        bound.socket.writeEventsEnabled = true;
        return;
      }
      bound.outgoing.removeFirst();
    }
  }

  Uint8List _buildResponse(DiscoveryProbe probe) {
    final current = announcement();
    return DiscoveryResponse(
      nonce: probe.nonce,
      hostId: current.hostId,
      hostName: _fitHostName(current.hostName),
      tcpPort: current.tcpPort,
      requiresPairing: current.requiresPairing,
    ).toBytes();
  }

  /// Un nombre largo se recorta en vez de dejar al host sin anunciarse.
  static String _fitHostName(String name) {
    final trimmed = name.trim();
    if (trimmed.length <= kMaxDiscoveryHostNameLength) return trimmed;
    var end = kMaxDiscoveryHostNameLength;
    // No partir un par subrogado (emoji) por la mitad.
    final last = trimmed.codeUnitAt(end - 1);
    if (last >= 0xD800 && last <= 0xDBFF) end--;
    return trimmed.substring(0, end).trimRight();
  }

  static Future<RawDatagramSocket> _defaultBinder(
    InternetAddress address,
    int port, {
    required bool reuseAddress,
  }) => RawDatagramSocket.bind(address, port, reuseAddress: reuseAddress);

  static Duration Function() _stopwatchClock() {
    final stopwatch = Stopwatch()..start();
    return () => stopwatch.elapsed;
  }
}

final class _BoundSocket {
  _BoundSocket(this.socket);

  final RawDatagramSocket socket;

  /// Se completa cuando el sistema confirma el cierre (puerto liberado).
  final Completer<void> closed = Completer<void>();

  /// Respuestas pendientes de envío (ver la nota sobre la cola de salida en
  /// [UdpDiscoveryResponder]).
  final Queue<_Outgoing> outgoing = Queue();
}

final class _Outgoing {
  const _Outgoing(this.data, this.address, this.port);

  final Uint8List data;
  final InternetAddress address;
  final int port;
}

/// Contador de ventana fija por IP de origen.
///
/// Una ventana fija es suficiente para acotar la amplificación (el peor caso
/// es el doble del máximo a caballo entre dos ventanas) y no necesita
/// temporizadores: todo se evalúa al llegar cada sonda.
final class _SourceRateLimiter {
  _SourceRateLimiter({
    required this.maxPerWindow,
    required this.window,
    required this.clock,
  });

  /// Tope de orígenes distintos en memoria. Con orígenes falsificados un
  /// atacante podría hacer crecer la tabla sin límite; al llenarse se deja de
  /// responder a orígenes nuevos hasta la siguiente purga.
  static const int _maxTrackedSources = 4096;

  final int maxPerWindow;
  final Duration window;
  final Duration Function() clock;

  final Map<String, _RateWindow> _windows = {};
  Duration _lastPurge = Duration.zero;

  bool allow(String source) {
    final now = clock();
    _purgeIfDue(now);
    final current = _windows[source];
    if (current == null || now - current.start >= window) {
      if (current == null && _windows.length >= _maxTrackedSources) {
        return false;
      }
      _windows[source] = _RateWindow(now);
      return true;
    }
    if (current.count >= maxPerWindow) return false;
    current.count++;
    return true;
  }

  /// Purga amortizada: como mucho un recorrido de la tabla por ventana.
  void _purgeIfDue(Duration now) {
    if (now - _lastPurge < window) return;
    _lastPurge = now;
    _windows.removeWhere((_, entry) => now - entry.start >= window);
  }
}

final class _RateWindow {
  _RateWindow(this.start);

  final Duration start;
  int count = 1;
}
