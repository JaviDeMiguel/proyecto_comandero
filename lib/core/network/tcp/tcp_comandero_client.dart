import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../../errors/app_exception.dart';
import '../../logging/app_logger.dart';
import '../../utils/streams.dart';
import '../protocol/frame_codec.dart';
import '../protocol/message.dart';
import '../protocol/transport_messages.dart';
import 'frame_connection.dart';

final Logger _log = appLogger('network.tcp.client');

/// Identidad que el comandero envía en el `hello`.
@immutable
final class ClientIdentity {
  const ClientIdentity({
    required this.deviceId,
    required this.deviceName,
    this.appVersion,
  });

  /// Identificador estable de la instalación; el host deduplica por él.
  final String deviceId;
  final String deviceName;
  final String? appVersion;

  @override
  String toString() => 'ClientIdentity($deviceId, $deviceName)';
}

/// Dirección TCP del host.
@immutable
final class HostEndpoint {
  const HostEndpoint({required this.host, required this.port});

  /// IP o nombre de host.
  final String host;
  final int port;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is HostEndpoint && other.host == host && other.port == port;

  @override
  int get hashCode => Object.hash(host, port);

  @override
  String toString() => host.contains(':') ? '[$host]:$port' : '$host:$port';
}

/// Temporizadores y política de reconexión del comandero.
@immutable
final class ClientOptions {
  const ClientOptions({
    this.connectTimeout = const Duration(seconds: 4),
    this.handshakeTimeout = const Duration(seconds: 5),
    this.requestTimeout = const Duration(seconds: 10),
    this.reconnectBaseDelay = const Duration(milliseconds: 500),
    this.reconnectMaxDelay = const Duration(seconds: 10),
    this.reconnectJitter = 0.2,
    this.rediscoverAfterFailures = 3,
    this.maxFrameBytes = kDefaultMaxFrameBytes,
    this.pairingCode,
    this.closeTimeout = const Duration(seconds: 1),
  }) : assert(
         reconnectJitter >= 0 && reconnectJitter <= 1,
         'reconnectJitter debe estar entre 0 y 1',
       ),
       assert(
         rediscoverAfterFailures > 0,
         'rediscoverAfterFailures debe ser positivo',
       ),
       assert(maxFrameBytes > 0, 'maxFrameBytes debe ser positivo');

  /// Tiempo máximo para establecer la conexión TCP.
  final Duration connectTimeout;

  /// Tiempo máximo entre el envío del `hello` y el `welcome`/`reject`.
  final Duration handshakeTimeout;

  /// Plazo por defecto de las peticiones no fiables.
  final Duration requestTimeout;

  /// Espera antes del primer reintento; se duplica en cada fallo seguido.
  final Duration reconnectBaseDelay;

  /// Tope del backoff (antes de aplicar el jitter).
  final Duration reconnectMaxDelay;

  /// Fracción de variación aleatoria (±) del retraso, para que varios
  /// comanderos no reconecten todos a la vez tras una caída del host.
  final double reconnectJitter;

  /// Fallos seguidos a partir de los cuales se consulta `rediscover` antes de
  /// cada intento (el host puede haber cambiado de IP).
  final int rediscoverAfterFailures;
  final int maxFrameBytes;

  /// Código de emparejamiento a enviar en el `hello`.
  final String? pairingCode;

  /// Plazo del cierre ordenado (`bye` + flush) en [TcpComanderoClient.disconnect].
  final Duration closeTimeout;
}

/// Estado de la conexión con el host, tal como lo ve la interfaz.
sealed class ClientConnectionState {
  const ClientConnectionState();
}

/// Sin conexión y sin intención de conectar (estado inicial y tras
/// [TcpComanderoClient.disconnect]).
final class Disconnected extends ClientConnectionState {
  const Disconnected();

  @override
  bool operator ==(Object other) => other is Disconnected;

  @override
  int get hashCode => (Disconnected).hashCode;

  @override
  String toString() => 'Disconnected';
}

/// Intento de conexión y handshake en curso. [attempt] empieza en 1 y crece
/// con cada fallo seguido.
final class Connecting extends ClientConnectionState {
  const Connecting({required this.endpoint, required this.attempt});

  final HostEndpoint endpoint;
  final int attempt;

  @override
  bool operator ==(Object other) =>
      other is Connecting &&
      other.endpoint == endpoint &&
      other.attempt == attempt;

  @override
  int get hashCode => Object.hash(endpoint, attempt);

  @override
  String toString() => 'Connecting($endpoint, intento $attempt)';
}

/// Sesión establecida: el `welcome` trae los temporizadores acordados.
final class Connected extends ClientConnectionState {
  const Connected({required this.endpoint, required this.welcome});

  final HostEndpoint endpoint;
  final WelcomePayload welcome;

  @override
  bool operator ==(Object other) =>
      other is Connected &&
      other.endpoint == endpoint &&
      other.welcome.sessionId == welcome.sessionId;

  @override
  int get hashCode => Object.hash(endpoint, welcome.sessionId);

  @override
  String toString() => 'Connected($endpoint, sesión ${welcome.sessionId})';
}

/// Conexión perdida o fallida; se reintentará en [retryIn]. [attempt] es el
/// número de fallos seguidos (1 = primer fallo).
final class Reconnecting extends ClientConnectionState {
  const Reconnecting({
    required this.endpoint,
    required this.attempt,
    required this.retryIn,
    this.lastError,
  });

  final HostEndpoint endpoint;
  final int attempt;
  final Duration retryIn;
  final Object? lastError;

  @override
  bool operator ==(Object other) =>
      other is Reconnecting &&
      other.endpoint == endpoint &&
      other.attempt == attempt &&
      other.retryIn == retryIn &&
      identical(other.lastError, lastError);

  @override
  int get hashCode => Object.hash(endpoint, attempt, retryIn, lastError);

  @override
  String toString() =>
      'Reconnecting($endpoint, fallo $attempt, reintento en $retryIn)';
}

/// El host no admite a este comandero y reintentar no lo arreglaría: código
/// incorrecto, versión incompatible, handshake inválido o
/// [ByeReasons.replaced]. Hace falta acción del usuario (y un nuevo
/// [TcpComanderoClient.connect]).
final class Rejected extends ClientConnectionState {
  const Rejected({required this.code, required this.message});

  /// Uno de [RejectCodes] o [ByeReasons.replaced].
  final String code;
  final String message;

  @override
  bool operator ==(Object other) =>
      other is Rejected && other.code == code && other.message == message;

  @override
  int get hashCode => Object.hash(code, message);

  @override
  String toString() => 'Rejected($code: $message)';
}

/// Cliente TCP del comandero (móvil).
///
/// Mantiene la conexión con el host: handshake, latido, reconexión automática
/// con backoff y, opcionalmente, redescubrimiento del host. Ofrece dos tipos
/// de petición:
///
/// * No fiable ([request] con `reliable: false`): exige estar conectado y
///   falla si la conexión cae o vence el plazo. Para consultas que la UI
///   repetirá por sí misma.
/// * Fiable (`reliable: true`): se encola en memoria con un `id` fijo y se
///   retransmite tras cada reconexión hasta recibir respuesta; el host
///   deduplica por ese `id`. Para comandas, que no pueden ni perderse ni
///   duplicarse. La cola no se persiste: una comanda que no haya salido antes
///   de cerrar la app se pierde, y la capa de aplicación debe avisarlo.
final class TcpComanderoClient {
  TcpComanderoClient({
    required this.identity,
    this.options = const ClientOptions(),
    Future<HostEndpoint?> Function()? rediscover,
    Random? random,
  }) : _rediscoverHost = rediscover,
       _random = random ?? Random();

  final ClientIdentity identity;
  final ClientOptions options;

  /// Localiza de nuevo al host (normalmente por UDP) cuando lleva varios
  /// intentos sin responder: puede haber cambiado de IP.
  final Future<HostEndpoint?> Function()? _rediscoverHost;
  final Random _random;

  final StreamController<ClientConnectionState> _states =
      StreamController<ClientConnectionState>.broadcast();
  final StreamController<ProtocolMessage> _messages =
      StreamController<ProtocolMessage>.broadcast();

  ClientConnectionState _state = const Disconnected();
  HostEndpoint? _endpoint;

  /// `true` entre [connect] y [disconnect] (o un rechazo definitivo): mientras
  /// lo sea, toda pérdida de conexión programa una reconexión.
  bool _keepConnected = false;
  bool _disposed = false;

  /// Fallos de conexión seguidos desde el último handshake correcto.
  int _failures = 0;

  /// Invalida los callbacks asíncronos (conexión en curso, redescubrimiento)
  /// de una generación anterior tras [connect]/[disconnect].
  int _generation = 0;
  _Link? _link;
  Timer? _reconnectTimer;

  final Map<String, _UnreliableRequest> _unreliable = {};
  final List<_ReliableRequest> _reliable = [];

  ClientConnectionState get state => _state;

  /// Cambios de estado (broadcast); se cierra en [dispose].
  Stream<ClientConnectionState> get states => _states.stream;

  /// Mensajes de aplicación enviados por el host (`broadcast`/`sendTo`).
  /// Nunca incluye mensajes de transporte.
  Stream<ProtocolMessage> get messages => _messages.stream;

  /// Peticiones fiables en cola o esperando respuesta.
  int get pendingReliableCount => _reliable.length;

  /// Conecta con [endpoint] y mantiene la conexión hasta [disconnect].
  ///
  /// Si ya hay conexión con ese mismo host no hace nada; con otro host, se
  /// despide del actual y cambia. También reactiva al cliente tras un
  /// [Rejected]. Las peticiones fiables en cola se conservan y se envían al
  /// nuevo host.
  void connect(HostEndpoint endpoint) {
    _checkNotDisposed();
    final current = _link;
    if (current != null && current.handshakeDone && _endpoint == endpoint) {
      return;
    }
    _endpoint = endpoint;
    _keepConnected = true;
    _failures = 0;
    _cancelReconnect();
    if (current != null) {
      _link = null;
      unawaited(_closeLink(current, graceful: current.handshakeDone));
      _failUnreliable(
        const NetworkException('Conexión cerrada para cambiar de host'),
      );
    }
    _startAttempt();
  }

  /// Envía `bye`, cierra y cancela la reconexión. Las peticiones pendientes
  /// (fiables incluidas) fallan con [NetworkException]. Deja el estado en
  /// [Disconnected].
  Future<void> disconnect() async {
    if (_disposed) return;
    _keepConnected = false;
    _cancelReconnect();
    _generation++;
    final link = _link;
    _link = null;
    final closing = link == null
        ? Future<void>.value()
        : _closeLink(link, graceful: link.handshakeDone);
    const reason = NetworkException('Desconectado por el comandero');
    _failUnreliable(reason);
    _failReliable(reason);
    _setState(const Disconnected());
    await closing;
  }

  /// [disconnect] y cierre de los streams. Tras esto el cliente no emite nada
  /// más y no admite más llamadas.
  Future<void> dispose() async {
    if (_disposed) return;
    await disconnect();
    _disposed = true;
    cerrarSinEsperar(_states);
    cerrarSinEsperar(_messages);
  }

  /// Envía una petición de aplicación y espera su respuesta.
  ///
  /// Completa con el `ack`. Lanza [RemoteRequestException] si el host responde
  /// `error` (con `reliable`, solo si no es reintentable: los reintentables se
  /// reenvían con backoff) y [NetworkException] si no se pudo obtener
  /// respuesta: sin conexión o plazo vencido (no fiable), o [disconnect]/
  /// [dispose] (fiable). Lanza [ArgumentError] si [type] es un tipo reservado.
  ///
  /// [timeout] solo aplica a las peticiones no fiables (por defecto
  /// `options.requestTimeout`); una fiable espera lo que haga falta.
  Future<ProtocolMessage> request(
    String type,
    Map<String, Object?> payload, {
    Duration? timeout,
    bool reliable = false,
  }) {
    _checkNotDisposed();
    if (TransportMessageTypes.isReserved(type)) {
      throw ArgumentError.value(
        type,
        'type',
        'Es un tipo reservado del transporte',
      );
    }
    final message = ProtocolMessage.create(type, payload: payload);
    final Uint8List frame;
    try {
      frame = encodeFrame(
        message.toJson(),
        maxFrameBytes: options.maxFrameBytes,
      );
    } on ProtocolException catch (error, stackTrace) {
      return Future<ProtocolMessage>.error(error, stackTrace);
    }

    if (reliable) {
      final entry = _ReliableRequest(message, frame);
      _reliable.add(entry);
      final link = _link;
      if (link != null && link.handshakeDone) _sendReliable(link, entry);
      return entry.completer.future;
    }

    final link = _link;
    if (link == null || !link.handshakeDone) {
      return Future<ProtocolMessage>.error(
        NetworkException('Sin conexión con el host (estado: $_state)'),
      );
    }
    final entry = _UnreliableRequest(message);
    final limit = timeout ?? options.requestTimeout;
    entry.timer = Timer(limit, () {
      if (_unreliable.remove(message.id) == null) return;
      entry.completer.completeError(
        NetworkException('El host no respondió a ${message.type} en $limit'),
      );
    });
    _unreliable[message.id] = entry;
    link.connection!.sendFrame(frame);
    return entry.completer.future;
  }

  // ---------------------------------------------------------------------------
  // Conexión y handshake
  // ---------------------------------------------------------------------------

  void _startAttempt() {
    final endpoint = _endpoint!;
    final link = _Link();
    _link = link;
    _generation++;
    _setState(Connecting(endpoint: endpoint, attempt: _failures + 1));
    unawaited(_open(link, endpoint));
  }

  Future<void> _open(_Link link, HostEndpoint endpoint) async {
    final Socket socket;
    try {
      socket = await Socket.connect(
        endpoint.host,
        endpoint.port,
        timeout: options.connectTimeout,
      );
    } on Object catch (error) {
      if (!_isCurrent(link)) return;
      _onLinkFailed(link, _translateConnectError(error, endpoint));
      return;
    }
    if (!_isCurrent(link)) {
      // disconnect() o connect() a otro host mientras conectábamos.
      socket.destroy();
      return;
    }
    final connection = FrameConnection(
      socket,
      maxFrameBytes: options.maxFrameBytes,
    );
    link.connection = connection;
    connection.start(
      onFrame: (event) => _onFrame(link, event),
      onClosed: (reason) => _onLinkFailed(link, reason),
    );
    final hello = ProtocolMessage.create(
      TransportMessageTypes.hello,
      payload: HelloPayload(
        deviceId: identity.deviceId,
        deviceName: identity.deviceName,
        appVersion: identity.appVersion,
        pairingCode: options.pairingCode,
      ).toJson(),
    );
    link.helloId = hello.id;
    link.handshakeTimer = Timer(options.handshakeTimeout, () {
      _onLinkFailed(
        link,
        NetworkException(
          'El host $endpoint no completó el handshake en '
          '${options.handshakeTimeout}',
        ),
      );
    });
    connection.send(hello);
  }

  void _onFrame(_Link link, FrameEvent event) {
    if (!_isCurrent(link)) return;
    if (link.handshakeDone) _armIdle(link);

    switch (event) {
      case FrameFailure(fatal: true, :final error):
        _onLinkFailed(
          link,
          NetworkException(
            'El host envió una trama irrecuperable',
            cause: error,
          ),
        );
      case FrameFailure(:final error):
        _log.warning('Trama inválida del host; se descarta', error);
      case FrameData(:final json):
        final ProtocolMessage message;
        try {
          message = ProtocolMessage.fromJson(json);
        } on ProtocolException catch (error) {
          _log.warning('Mensaje inválido del host; se descarta', error);
          return;
        }
        if (link.handshakeDone) {
          _onSessionMessage(link, message);
        } else {
          _onHandshakeReply(link, message);
        }
    }
  }

  void _onHandshakeReply(_Link link, ProtocolMessage message) {
    switch (message.type) {
      case TransportMessageTypes.welcome:
        final WelcomePayload welcome;
        try {
          welcome = WelcomePayload.fromJson(message.payload);
        } on ProtocolException catch (error) {
          _onLinkFailed(
            link,
            NetworkException('welcome inválido del host', cause: error),
          );
          return;
        }
        _onWelcome(link, welcome);
      case TransportMessageTypes.reject:
        RejectPayload reject;
        try {
          reject = RejectPayload.fromJson(message.payload);
        } on ProtocolException {
          reject = const RejectPayload(
            code: RejectCodes.badHandshake,
            message: 'El host rechazó el handshake sin detallar el motivo',
          );
        }
        _onReject(link, reject);
      case TransportMessageTypes.bye:
        _onLinkFailed(
          link,
          NetworkException(
            'El host cerró la conexión durante el handshake '
            '(${message.payload['reason'] ?? 'sin motivo'})',
          ),
        );
      default:
        _log.warning(
          "Mensaje '${message.type}' antes del welcome; se descarta",
        );
    }
  }

  void _onWelcome(_Link link, WelcomePayload welcome) {
    link.handshakeTimer?.cancel();
    link.handshakeTimer = null;
    link
      ..handshakeDone = true
      ..welcome = welcome;
    _failures = 0;
    _log.info(
      'Conectado con ${welcome.hostName} (${welcome.hostId}), sesión '
      '${welcome.sessionId}',
    );
    _setState(Connected(endpoint: _endpoint!, welcome: welcome));

    link.heartbeatTimer = Timer.periodic(
      Duration(milliseconds: welcome.heartbeatIntervalMs),
      (_) => link.connection?.send(
        ProtocolMessage.create(TransportMessageTypes.ping),
      ),
    );
    _armIdle(link);

    // Retransmisión en el orden original de todo lo que no tiene respuesta;
    // el host deduplica por id lo que ya hubiera procesado.
    for (final entry in _reliable.toList()) {
      if (entry.retryTimer == null) _sendReliable(link, entry);
    }
  }

  void _onReject(_Link link, RejectPayload reject) {
    if (reject.code == RejectCodes.serverFull) {
      // Transitorio: alguien se irá. Se reintenta con backoff.
      _onLinkFailed(
        link,
        NetworkException('El host está lleno: ${reject.message}'),
      );
      return;
    }
    _log.warning(
      'El host rechazó la conexión (${reject.code}): ${reject.message}',
    );
    _giveUp(link, Rejected(code: reject.code, message: reject.message));
  }

  /// Rechazo definitivo: se corta la conexión y no se reintenta. Las fiables
  /// siguen en cola para cuando el usuario corrija el problema y reconecte.
  void _giveUp(_Link link, Rejected rejected) {
    _keepConnected = false;
    _link = null;
    unawaited(_closeLink(link, graceful: false));
    _failUnreliable(NetworkException(rejected.message));
    _setState(rejected);
  }

  void _armIdle(_Link link) {
    final welcome = link.welcome;
    if (welcome == null) return;
    link.idleTimer?.cancel();
    link.idleTimer = Timer(Duration(milliseconds: welcome.idleTimeoutMs), () {
      _onLinkFailed(
        link,
        NetworkException(
          'Sin tramas del host en ${welcome.idleTimeoutMs} ms; se da por '
          'caído',
        ),
      );
    });
  }

  // ---------------------------------------------------------------------------
  // Mensajes de sesión
  // ---------------------------------------------------------------------------

  void _onSessionMessage(_Link link, ProtocolMessage message) {
    switch (message.type) {
      case TransportMessageTypes.pong:
        break; // el temporizador de inactividad ya se rearmó
      case TransportMessageTypes.ack || TransportMessageTypes.error:
        _onReply(message);
      case TransportMessageTypes.bye:
        final reason = message.payload['reason'];
        _log.info('El host se despide (${reason ?? 'sin motivo'})');
        if (reason == ByeReasons.replaced) {
          // Otro dispositivo usa nuestro deviceId: reconectar provocaría un
          // bucle de reemplazos entre ambos.
          _giveUp(
            link,
            const Rejected(
              code: ByeReasons.replaced,
              message:
                  'Otro comandero con el mismo identificador se ha conectado '
                  'al host',
            ),
          );
        } else {
          _onLinkFailed(
            link,
            NetworkException('El host cerró la sesión ($reason)'),
          );
        }
      case TransportMessageTypes.hello ||
          TransportMessageTypes.welcome ||
          TransportMessageTypes.reject ||
          TransportMessageTypes.ping:
        _log.warning("Mensaje '${message.type}' fuera de lugar; se descarta");
      default:
        if (!_messages.isClosed) _messages.add(message);
    }
  }

  void _onReply(ProtocolMessage message) {
    final replyTo = message.replyTo;
    if (replyTo == null) {
      _log.warning("Respuesta '${message.type}' sin replyTo; se descarta");
      return;
    }
    final unreliable = _unreliable.remove(replyTo);
    if (unreliable != null) {
      unreliable.timer?.cancel();
      if (message.type == TransportMessageTypes.ack) {
        unreliable.completer.complete(message);
      } else {
        unreliable.completer.completeError(_toRemoteException(message));
      }
      return;
    }

    final index = _reliable.indexWhere((entry) => entry.message.id == replyTo);
    if (index < 0) return; // respuesta tardía o duplicada: sin efectos
    final entry = _reliable[index];
    if (message.type == TransportMessageTypes.ack) {
      _reliable.removeAt(index);
      entry.completer.complete(message);
      return;
    }
    final exception = _toRemoteException(message);
    if (!exception.retryable) {
      _reliable.removeAt(index);
      entry.completer.completeError(exception);
      return;
    }
    entry.retries++;
    final delay = _backoff(entry.retries);
    _log.info(
      'Error reintentable en ${entry.message.type} (${entry.message.id}); '
      'reintento ${entry.retries} en $delay',
    );
    entry.retryTimer = Timer(delay, () {
      entry.retryTimer = null;
      final link = _link;
      if (link != null && link.handshakeDone) _sendReliable(link, entry);
      // Sin conexión, saldrá en la retransmisión del próximo welcome.
    });
  }

  static RemoteRequestException _toRemoteException(ProtocolMessage message) {
    try {
      return ErrorPayload.fromJson(message.payload).toException();
    } on ProtocolException catch (error) {
      return RemoteRequestException(
        'El host respondió con un error sin detallar',
        code: ErrorCodes.internal,
        cause: error,
      );
    }
  }

  void _sendReliable(_Link link, _ReliableRequest entry) {
    // Un `false` significa que el socket acaba de morir: onClosed llegará y
    // la petición se retransmitirá en la próxima sesión.
    link.connection?.sendFrame(entry.frame);
  }

  // ---------------------------------------------------------------------------
  // Pérdida de conexión y reconexión
  // ---------------------------------------------------------------------------

  /// Cualquier final no deseado de [link]: error de conexión, cierre remoto,
  /// handshake sin respuesta, silencio, trama fatal, `bye` o `server_full`.
  void _onLinkFailed(_Link link, NetworkException error) {
    if (!_isCurrent(link)) return;
    _link = null;
    unawaited(_closeLink(link, graceful: false));
    _log.info('Conexión con el host perdida: ${error.message}');
    _failUnreliable(
      NetworkException(
        'Conexión perdida antes de recibir la respuesta',
        cause: error,
      ),
    );
    if (!_keepConnected) {
      _setState(const Disconnected());
      return;
    }
    _scheduleReconnect(error);
  }

  void _scheduleReconnect(Object error) {
    final attempt = ++_failures;
    final delay = _backoff(attempt);
    _setState(
      Reconnecting(
        endpoint: _endpoint!,
        attempt: attempt,
        retryIn: delay,
        lastError: error,
      ),
    );
    _reconnectTimer = Timer(delay, () {
      _reconnectTimer = null;
      unawaited(_reconnect());
    });
  }

  Future<void> _reconnect() async {
    final rediscover = _rediscoverHost;
    if (rediscover != null && _failures >= options.rediscoverAfterFailures) {
      final generation = _generation;
      HostEndpoint? found;
      try {
        found = await rediscover();
      } on Object catch (error, stackTrace) {
        _log.warning('El redescubrimiento del host falló', error, stackTrace);
      }
      // disconnect()/connect() durante la espera: ya no nos corresponde.
      if (_disposed || !_keepConnected || _generation != generation) return;
      if (found != null && found != _endpoint) {
        _log.info('Host redescubierto en $found (antes $_endpoint)');
        _endpoint = found;
      }
    }
    _startAttempt();
  }

  /// `min(max, base · 2^(n-1))` con jitter ±`reconnectJitter`.
  ///
  /// El exponente se acota: con `pow` entero, `2^64` desborda a cero y un
  /// comandero que llevase horas sin host pasaría a reintentar sin pausa.
  Duration _backoff(int attempt) {
    final base = options.reconnectBaseDelay.inMicroseconds.toDouble();
    final cap = options.reconnectMaxDelay.inMicroseconds.toDouble();
    final exponent = min(max(attempt - 1, 0), 30);
    final exponential = min(cap, base * (1 << exponent));
    final jitter = options.reconnectJitter * (2 * _random.nextDouble() - 1);
    return Duration(microseconds: (exponential * (1 + jitter)).round());
  }

  void _cancelReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
  }

  // ---------------------------------------------------------------------------
  // Utilidades
  // ---------------------------------------------------------------------------

  bool _isCurrent(_Link link) => identical(_link, link);

  /// Cierra [link] y sus temporizadores. Con [graceful] envía `bye` y espera
  /// el cierre remoto hasta `closeTimeout`; si no, destruye el socket.
  Future<void> _closeLink(_Link link, {required bool graceful}) {
    link.cancelTimers();
    final connection = link.connection;
    if (connection == null) return Future<void>.value();
    if (!graceful) {
      connection.destroy();
      return Future<void>.value();
    }
    return connection.close(
      farewell: ProtocolMessage.create(
        TransportMessageTypes.bye,
        payload: const {'reason': ByeReasons.clientClosing},
      ),
      timeout: options.closeTimeout,
    );
  }

  void _failUnreliable(NetworkException error) {
    if (_unreliable.isEmpty) return;
    final pending = _unreliable.values.toList();
    _unreliable.clear();
    for (final entry in pending) {
      entry.timer?.cancel();
      entry.completer.completeError(error);
    }
  }

  void _failReliable(NetworkException error) {
    if (_reliable.isEmpty) return;
    final pending = _reliable.toList();
    _reliable.clear();
    for (final entry in pending) {
      entry.retryTimer?.cancel();
      entry.retryTimer = null;
      entry.completer.completeError(error);
    }
  }

  void _setState(ClientConnectionState state) {
    if (_disposed || state == _state) return;
    _state = state;
    _log.fine('Estado: $state');
    if (!_states.isClosed) _states.add(state);
  }

  void _checkNotDisposed() {
    if (_disposed) {
      throw StateError('TcpComanderoClient ya está liberado (dispose)');
    }
  }

  static NetworkException _translateConnectError(
    Object error,
    HostEndpoint endpoint,
  ) => switch (error) {
    NetworkException() => error,
    SocketException(:final message, :final osError) => NetworkException(
      'No se pudo conectar con $endpoint: ${osError?.message ?? message}',
      cause: error,
    ),
    TimeoutException() => NetworkException(
      'Tiempo de conexión agotado con $endpoint',
      cause: error,
    ),
    _ => NetworkException('Fallo al conectar con $endpoint', cause: error),
  };
}

/// Una conexión concreta con el host, desde el intento hasta su final.
final class _Link {
  FrameConnection? connection;
  String? helloId;
  bool handshakeDone = false;
  WelcomePayload? welcome;
  Timer? handshakeTimer;
  Timer? heartbeatTimer;
  Timer? idleTimer;

  void cancelTimers() {
    handshakeTimer?.cancel();
    handshakeTimer = null;
    heartbeatTimer?.cancel();
    heartbeatTimer = null;
    idleTimer?.cancel();
    idleTimer = null;
  }
}

final class _UnreliableRequest {
  _UnreliableRequest(this.message);

  final ProtocolMessage message;
  final Completer<ProtocolMessage> completer = Completer<ProtocolMessage>();
  Timer? timer;
}

final class _ReliableRequest {
  _ReliableRequest(this.message, this.frame);

  /// Mensaje con el `id` fijado una sola vez: cada retransmisión lo repite
  /// para que el host la reconozca como duplicado.
  final ProtocolMessage message;
  final Uint8List frame;
  final Completer<ProtocolMessage> completer = Completer<ProtocolMessage>();

  /// Reintentos por `error` reintentable (no cuentan las retransmisiones por
  /// reconexión).
  int retries = 0;
  Timer? retryTimer;
}
