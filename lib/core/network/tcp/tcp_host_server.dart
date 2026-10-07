import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:uuid/uuid.dart';

import '../../errors/app_exception.dart';
import '../../logging/app_logger.dart';
import '../protocol/frame_codec.dart';
import '../protocol/message.dart';
import '../protocol/transport_messages.dart';
import 'frame_connection.dart';

final Logger _log = appLogger('network.tcp.server');
const Uuid _uuid = Uuid();

/// Puerto TCP por defecto del host (el que anuncia el descubrimiento UDP).
const int kDefaultHostPort = 4040;

/// Motivo de [ClientDisconnected] cuando la conexión se perdió sin `bye`:
/// cierre remoto brusco, error de socket o trama final incompleta.
const String kConnectionLostReason = 'connection_lost';

/// Motivo por defecto de [TcpHostServer.disconnect]: expulsión decidida por el
/// host sin que el servidor se apague. No figura en [ByeReasons] porque no lo
/// genera el protocolo por sí solo; el comandero lo trata como cualquier `bye`
/// distinto de `replaced` y vuelve a conectar con backoff.
const String kDisconnectedByHostReason = 'disconnected_by_host';

/// Identidad que el host comunica en el `welcome`.
@immutable
final class HostIdentity {
  const HostIdentity({required this.hostId, required this.hostName});

  /// Identificador estable de la instalación del host.
  final String hostId;

  /// Nombre visible (p. ej. "Barra").
  final String hostName;

  @override
  String toString() => 'HostIdentity($hostId, $hostName)';
}

/// Ajustes del servidor. Todos tienen valor por defecto de producción; los
/// tests los acortan.
@immutable
final class HostServerOptions {
  const HostServerOptions({
    this.port = kDefaultHostPort,
    this.bindAddress,
    this.handshakeTimeout = const Duration(seconds: 5),
    this.heartbeatInterval = const Duration(seconds: 5),
    this.idleTimeout = const Duration(seconds: 15),
    this.maxClients = 32,
    this.maxFrameBytes = kDefaultMaxFrameBytes,
    this.pairingCode,
    this.dedupeCacheSize = 512,
    this.maxConsecutiveBadFrames = 3,
    this.closeTimeout = const Duration(seconds: 1),
  }) : assert(port >= 0 && port <= 65535, 'port fuera de rango'),
       assert(maxClients > 0, 'maxClients debe ser positivo'),
       assert(maxFrameBytes > 0, 'maxFrameBytes debe ser positivo'),
       assert(dedupeCacheSize >= 0, 'dedupeCacheSize no puede ser negativo'),
       assert(
         maxConsecutiveBadFrames > 0,
         'maxConsecutiveBadFrames debe ser positivo',
       );

  /// Puerto de escucha; `0` pide uno efímero (ver [TcpHostServer.port]).
  final int port;

  /// Interfaz de escucha; `null` equivale a todas las IPv4.
  final InternetAddress? bindAddress;

  /// Tiempo máximo entre la conexión TCP y el `hello`.
  final Duration handshakeTimeout;

  /// Cadencia de `ping` que se comunica al comandero en el `welcome`.
  final Duration heartbeatInterval;

  /// Silencio máximo tolerado a un comandero antes de darlo por caído.
  final Duration idleTimeout;

  /// Sesiones simultáneas con handshake completado.
  final int maxClients;
  final int maxFrameBytes;

  /// Código de emparejamiento exigido en el `hello`; `null` o vacío lo
  /// desactiva.
  final String? pairingCode;

  /// Respuestas recordadas por dispositivo para deduplicar retransmisiones.
  final int dedupeCacheSize;

  /// Tramas inválidas seguidas que se toleran antes de cerrar la conexión.
  final int maxConsecutiveBadFrames;

  /// Plazo del cierre ordenado (`bye` + flush + espera del cierre remoto)
  /// antes de destruir el socket.
  final Duration closeTimeout;

  bool get requiresPairing {
    final code = pairingCode;
    return code != null && code.isNotEmpty;
  }
}

/// Datos de una sesión de comandero con handshake completado.
@immutable
final class ClientSessionInfo {
  const ClientSessionInfo({
    required this.sessionId,
    required this.deviceId,
    required this.deviceName,
    required this.remoteAddress,
    required this.remotePort,
    required this.connectedAt,
    this.appVersion,
  });

  /// Identificador único de esta conexión concreta (el del `welcome`).
  final String sessionId;

  /// Identificador estable del dispositivo; sobrevive a reconexiones.
  final String deviceId;
  final String deviceName;
  final String? appVersion;
  final String remoteAddress;
  final int remotePort;
  final DateTime connectedAt;

  @override
  String toString() =>
      'ClientSessionInfo($deviceId "$deviceName" sesión $sessionId desde '
      '$remoteAddress:$remotePort)';
}

/// Cambios en el conjunto de sesiones del servidor.
sealed class HostSessionEvent {
  const HostSessionEvent(this.session);

  final ClientSessionInfo session;
}

/// Un comandero completó el handshake.
final class ClientConnected extends HostSessionEvent {
  const ClientConnected(super.session);

  @override
  String toString() => 'ClientConnected(${session.deviceId})';
}

/// Una sesión terminó. [reason] es uno de [ByeReasons],
/// [kConnectionLostReason] o el motivo pasado a [TcpHostServer.disconnect].
final class ClientDisconnected extends HostSessionEvent {
  const ClientDisconnected(super.session, this.reason);

  final String reason;

  @override
  String toString() => 'ClientDisconnected(${session.deviceId}, $reason)';
}

/// Manejador de peticiones de aplicación. Devuelve el payload del `ack`.
///
/// Puede lanzar [ValidationException] (→ `error` definitivo con código
/// `validation`) o [RemoteRequestException] (→ `error` con su código y su
/// marca de reintentable). Cualquier otra excepción se traduce a `error`
/// `internal` reintentable y se registra; nunca tumba el servidor.
typedef HostRequestHandler = FutureOr<Map<String, Object?>> Function(
  ClientSessionInfo session,
  ProtocolMessage request,
);

/// Servidor TCP del host (tablet).
///
/// Acepta conexiones de comanderos, valida el handshake `hello`/`welcome`,
/// responde a los latidos, entrega cada petición de aplicación al manejador en
/// serie por dispositivo y deduplica retransmisiones por `deviceId` + `id`.
/// La lógica de negocio no vive aquí: los mensajes de aplicación son opacos.
final class TcpHostServer {
  TcpHostServer({
    required this.identity,
    required this.onRequest,
    this.options = const HostServerOptions(),
  });

  final HostIdentity identity;
  final HostRequestHandler onRequest;
  final HostServerOptions options;

  ServerSocket? _serverSocket;
  StreamSubscription<Socket>? _acceptSubscription;
  Future<void>? _stopping;

  /// Conexiones aceptadas y aún abiertas, con o sin handshake.
  final Set<_Connection> _connections = {};

  /// Estado por dispositivo. Sobrevive a la sesión (y a `stop()`) a propósito:
  /// la caché de deduplicación debe responder a retransmisiones que llegan
  /// por una conexión nueva, y la cola serie debe seguir vaciándose aunque el
  /// dispositivo se haya caído a mitad.
  final Map<String, _Device> _devices = {};

  final StreamController<HostSessionEvent> _events =
      StreamController<HostSessionEvent>.broadcast();

  bool get isRunning => _serverSocket != null;

  /// Puerto real de escucha tras [start] (relevante con `port = 0`); el
  /// configurado si el servidor está parado.
  int get port => _serverSocket?.port ?? options.port;

  /// Sesiones con handshake completado, en orden de conexión.
  List<ClientSessionInfo> get sessions => [
    for (final connection in _connections) ?connection.session,
  ];

  /// Altas y bajas de sesiones (broadcast). No se cierra en [stop]: el
  /// servidor puede volver a arrancar; se cierra en [dispose].
  Stream<HostSessionEvent> get events => _events.stream;

  /// Abre el puerto y empieza a aceptar conexiones. Es idempotente; si hay un
  /// [stop] en curso espera a que termine.
  ///
  /// Lanza [NetworkException] si el puerto está ocupado o la interfaz no es
  /// válida.
  Future<void> start() async {
    await _stopping;
    if (_serverSocket != null) return;
    final ServerSocket serverSocket;
    try {
      serverSocket = await ServerSocket.bind(
        options.bindAddress ?? InternetAddress.anyIPv4,
        options.port,
      );
    } on SocketException catch (error) {
      throw NetworkException(
        'No se pudo abrir el puerto ${options.port}: '
        '${error.osError?.message ?? error.message}',
        cause: error,
      );
    } on ArgumentError catch (error) {
      throw NetworkException(
        'Dirección de escucha inválida: ${error.message}',
        cause: error,
      );
    }
    _serverSocket = serverSocket;
    _acceptSubscription = serverSocket.listen(
      _accept,
      // Un fallo al aceptar una conexión concreta no debe parar el servidor.
      onError: (Object error) =>
          _log.warning('Error al aceptar una conexión', error),
    );
    _log.info('Servidor TCP escuchando en ${serverSocket.port}');
  }

  /// Deja de aceptar, despide a todos los comanderos con
  /// `bye(server_shutting_down)` y libera el puerto. Idempotente.
  ///
  /// Espera a que todos los sockets aceptados estén destruidos: en Windows el
  /// puerto no puede volver a abrirse mientras quede alguno vivo.
  Future<void> stop() {
    final inProgress = _stopping;
    if (inProgress != null) return inProgress;
    final serverSocket = _serverSocket;
    if (serverSocket == null) return Future<void>.value();
    return _stopping = _stop(serverSocket).whenComplete(() => _stopping = null);
  }

  /// [stop] y cierre del stream de eventos. Tras esto el servidor no puede
  /// volver a arrancar.
  Future<void> dispose() async {
    await stop();
    await _events.close();
  }

  /// Envía un evento de aplicación a todas las sesiones (menos la de
  /// [exceptDeviceId]). Devuelve a cuántas se escribió; las sesiones muertas
  /// no cuentan y no lanzan.
  ///
  /// Lanza [ArgumentError] si [type] es un tipo reservado del transporte y
  /// [ProtocolException] si el payload no es serializable.
  int broadcast(
    String type,
    Map<String, Object?> payload, {
    String? exceptDeviceId,
  }) {
    final frame = _encodeEvent(type, payload);
    var sent = 0;
    for (final connection in _connections.toList()) {
      final session = connection.session;
      if (session == null || session.deviceId == exceptDeviceId) continue;
      if (connection.link.sendFrame(frame)) sent++;
    }
    return sent;
  }

  /// Envía un evento de aplicación a un dispositivo. Devuelve `false` si no
  /// tiene sesión viva (el mensaje se pierde: la aplicación pedirá un
  /// snapshot al reconectar).
  bool sendTo(String deviceId, String type, Map<String, Object?> payload) {
    final frame = _encodeEvent(type, payload);
    final connection = _devices[deviceId]?.connection;
    if (connection == null) return false;
    return connection.link.sendFrame(frame);
  }

  /// Cierra ordenadamente la sesión de [deviceId] con `bye(reason)` y emite
  /// [ClientDisconnected]. No hace nada si no hay sesión.
  Future<void> disconnect(
    String deviceId, {
    String reason = kDisconnectedByHostReason,
  }) {
    final connection = _devices[deviceId]?.connection;
    if (connection == null) return Future<void>.value();
    return _terminate(connection, reason: reason, farewell: _bye(reason));
  }

  // ---------------------------------------------------------------------------
  // Ciclo de vida de las conexiones
  // ---------------------------------------------------------------------------

  Future<void> _stop(ServerSocket serverSocket) async {
    _serverSocket = null;
    final subscription = _acceptSubscription;
    _acceptSubscription = null;
    try {
      await serverSocket.close();
    } on Object catch (error) {
      _log.fine('Error al cerrar el socket de escucha', error);
    }
    await subscription?.cancel();

    final closing = <Future<void>>[
      for (final connection in _connections.toList())
        if (connection.session == null)
          _terminate(connection, reason: kConnectionLostReason, graceful: false)
        else
          _terminate(
            connection,
            reason: ByeReasons.serverShuttingDown,
            farewell: _bye(ByeReasons.serverShuttingDown),
          ),
    ];
    await Future.wait(closing);
    _log.info('Servidor TCP detenido');
  }

  void _accept(Socket socket) {
    if (_serverSocket == null) {
      // Conexión colada durante la parada.
      socket.destroy();
      return;
    }
    final connection = _Connection(
      FrameConnection(socket, maxFrameBytes: options.maxFrameBytes),
    );
    _connections.add(connection);
    connection.handshakeTimer = Timer(options.handshakeTimeout, () {
      _log.fine(
        'Sin hello en ${options.handshakeTimeout} desde '
        '${connection.link.remoteAddress}',
      );
      unawaited(
        _terminate(connection, reason: kConnectionLostReason, graceful: false),
      );
    });
    connection.link.start(
      onFrame: (event) => _onFrame(connection, event),
      onClosed: (reason) {
        _log.fine('Conexión perdida con ${connection.describe()}', reason);
        unawaited(
          _terminate(
            connection,
            reason: kConnectionLostReason,
            graceful: false,
          ),
        );
      },
    );
  }

  /// Cierra una conexión y la retira de la contabilidad. Como mucho una vez
  /// por conexión; si tenía sesión emite [ClientDisconnected].
  ///
  /// Con [graceful] se envía [farewell] (si lo hay), se vacía el buffer y se
  /// espera al cierre remoto hasta `closeTimeout`; sin él se destruye el
  /// socket de inmediato. El `Future` nunca falla.
  Future<void> _terminate(
    _Connection connection, {
    required String reason,
    ProtocolMessage? farewell,
    bool graceful = true,
  }) {
    if (connection.closed) return Future<void>.value();
    connection.closed = true;
    connection.cancelTimers();
    _connections.remove(connection);

    final session = connection.session;
    final device = connection.device;
    if (device != null && identical(device.connection, connection)) {
      device.connection = null;
    }
    if (session != null) {
      _emit(ClientDisconnected(session, reason));
    }
    if (!graceful) {
      connection.link.destroy();
      return Future<void>.value();
    }
    return connection.link.close(
      farewell: farewell,
      timeout: options.closeTimeout,
    );
  }

  void _onFrame(_Connection connection, FrameEvent event) {
    if (connection.closed) return;
    // Cualquier trama, válida o no, demuestra que el otro extremo sigue ahí.
    if (connection.session != null) _armIdle(connection);

    switch (event) {
      case FrameFailure(fatal: true, :final error):
        _log.warning(
          'Trama fatal de ${connection.describe()}; se cierra la conexión',
          error,
        );
        unawaited(
          _terminate(
            connection,
            reason: ByeReasons.protocolError,
            graceful: false,
          ),
        );
      case FrameFailure(:final error):
        _onBadFrame(connection, error);
      case FrameData(:final json):
        final ProtocolMessage message;
        try {
          message = ProtocolMessage.fromJson(json);
        } on ProtocolException catch (error) {
          _onBadFrame(connection, error);
          return;
        }
        connection.badFrames = 0;
        if (connection.session == null) {
          _onHandshake(connection, message);
        } else {
          _onSessionMessage(connection, message);
        }
    }
  }

  void _onBadFrame(_Connection connection, ProtocolException error) {
    connection.badFrames++;
    _log.fine(
      'Trama inválida ${connection.badFrames}/'
      '${options.maxConsecutiveBadFrames} de ${connection.describe()}',
      error,
    );
    if (connection.badFrames < options.maxConsecutiveBadFrames) return;
    // También antes del hello: quien manda basura no es un comandero en
    // handshake, así que no merece un `reject` (que el cliente real trataría
    // como definitivo) sino el mismo cierre por error de protocolo.
    _protocolError(connection, 'Demasiadas tramas inválidas seguidas');
  }

  void _protocolError(_Connection connection, String detail) {
    _log.warning('Error de protocolo de ${connection.describe()}: $detail');
    unawaited(
      _terminate(
        connection,
        reason: ByeReasons.protocolError,
        farewell: _bye(ByeReasons.protocolError),
      ),
    );
  }

  void _reject(
    _Connection connection,
    String code,
    String message, {
    String? replyTo,
  }) {
    _log.info(
      'Handshake rechazado ($code) a ${connection.describe()}: $message',
    );
    final reject = ProtocolMessage.create(
      TransportMessageTypes.reject,
      payload: RejectPayload(code: code, message: message).toJson(),
      replyTo: replyTo,
    );
    unawaited(_terminate(connection, reason: code, farewell: reject));
  }

  // ---------------------------------------------------------------------------
  // Handshake
  // ---------------------------------------------------------------------------

  void _onHandshake(_Connection connection, ProtocolMessage message) {
    if (message.type != TransportMessageTypes.hello) {
      _reject(
        connection,
        RejectCodes.badHandshake,
        "Se esperaba 'hello' y llegó '${message.type}'",
      );
      return;
    }
    final HelloPayload hello;
    try {
      hello = HelloPayload.fromJson(message.payload);
    } on ProtocolException catch (error) {
      _reject(
        connection,
        RejectCodes.badHandshake,
        error.message,
        replyTo: message.id,
      );
      return;
    }
    if (hello.protocolVersion != kProtocolVersion) {
      _reject(
        connection,
        RejectCodes.unsupportedVersion,
        'El host habla la versión $kProtocolVersion del protocolo y el '
        'comandero la ${hello.protocolVersion}',
        replyTo: message.id,
      );
      return;
    }
    if (options.requiresPairing &&
        !pairingCodesMatch(options.pairingCode!, hello.pairingCode)) {
      _reject(
        connection,
        RejectCodes.unauthorized,
        'Código de emparejamiento incorrecto',
        replyTo: message.id,
      );
      return;
    }

    final device = _devices.putIfAbsent(
      hello.deviceId,
      () => _Device(hello.deviceId, options.dedupeCacheSize),
    );
    final previous = device.connection;
    // Un dispositivo que ya tiene sesión no consume otra plaza: es el mismo
    // comandero volviendo antes de que detectáramos su caída.
    if (previous == null && sessions.length >= options.maxClients) {
      _reject(
        connection,
        RejectCodes.serverFull,
        'El host ya atiende a ${options.maxClients} comanderos',
        replyTo: message.id,
      );
      return;
    }
    if (previous != null) {
      _log.info(
        'Sesión de ${hello.deviceId} reemplazada por una conexión nueva',
      );
      unawaited(
        _terminate(
          previous,
          reason: ByeReasons.replaced,
          farewell: _bye(ByeReasons.replaced),
        ),
      );
    }

    connection.handshakeTimer?.cancel();
    connection.handshakeTimer = null;
    final session = ClientSessionInfo(
      sessionId: _uuid.v4(),
      deviceId: hello.deviceId,
      deviceName: hello.deviceName,
      appVersion: hello.appVersion,
      remoteAddress: connection.link.remoteAddress,
      remotePort: connection.link.remotePort,
      connectedAt: DateTime.now(),
    );
    connection
      ..session = session
      ..device = device;
    device.connection = connection;
    _armIdle(connection);

    final welcome = WelcomePayload(
      hostId: identity.hostId,
      hostName: identity.hostName,
      sessionId: session.sessionId,
      serverTimeMs: DateTime.now().millisecondsSinceEpoch,
      heartbeatIntervalMs: options.heartbeatInterval.inMilliseconds,
      idleTimeoutMs: options.idleTimeout.inMilliseconds,
    );
    connection.link.send(
      message.reply(TransportMessageTypes.welcome, payload: welcome.toJson()),
    );
    _log.info('Comandero conectado: $session');
    _emit(ClientConnected(session));
  }

  void _armIdle(_Connection connection) {
    connection.idleTimer?.cancel();
    connection.idleTimer = Timer(options.idleTimeout, () {
      _log.warning(
        'Sin tramas de ${connection.describe()} en ${options.idleTimeout}; '
        'se da por caído',
      );
      // El otro extremo no responde: un bye no llegaría a ningún sitio.
      unawaited(
        _terminate(connection, reason: ByeReasons.idleTimeout, graceful: false),
      );
    });
  }

  // ---------------------------------------------------------------------------
  // Mensajes de sesión
  // ---------------------------------------------------------------------------

  void _onSessionMessage(_Connection connection, ProtocolMessage message) {
    switch (message.type) {
      case TransportMessageTypes.ping:
        // Fuera de la cola de peticiones: el latido no debe esperar a que un
        // manejador lento termine, o el comandero daría al host por caído.
        connection.link.send(message.reply(TransportMessageTypes.pong));
      case TransportMessageTypes.bye:
        final reason = message.payload['reason'];
        _log.info(
          'El comandero ${connection.describe()} se despide '
          '(${reason ?? 'sin motivo'})',
        );
        unawaited(
          _terminate(
            connection,
            reason: reason is String && reason.isNotEmpty
                ? reason
                : ByeReasons.clientClosing,
          ),
        );
      case TransportMessageTypes.hello ||
          TransportMessageTypes.welcome ||
          TransportMessageTypes.reject ||
          TransportMessageTypes.pong ||
          TransportMessageTypes.ack ||
          TransportMessageTypes.error:
        _protocolError(connection, "mensaje '${message.type}' fuera de lugar");
      default:
        _enqueueRequest(connection, message);
    }
  }

  // ---------------------------------------------------------------------------
  // Peticiones: cola serie por dispositivo y deduplicación
  // ---------------------------------------------------------------------------

  void _enqueueRequest(_Connection connection, ProtocolMessage request) {
    final device = connection.device!;
    final cached = device.responses.get(request.id);
    if (cached != null) {
      _log.fine('Retransmisión de ${request.id}: se reenvía la respuesta');
      connection.link.sendFrame(cached);
      return;
    }
    // Ya en cola o en el manejador: la respuesta saldrá cuando termine, hacia
    // la sesión que esté viva en ese momento.
    if (!device.inFlight.add(request.id)) return;

    device.queue.add(_QueuedRequest(connection.session!, request));
    if (!device.pumping) unawaited(_pump(device));
  }

  /// Vacía la cola de un dispositivo en orden, esperando a cada manejador
  /// antes de pasar al siguiente. Dispositivos distintos tienen bombas
  /// independientes y por tanto se atienden en paralelo.
  Future<void> _pump(_Device device) async {
    device.pumping = true;
    try {
      while (device.queue.isNotEmpty) {
        final item = device.queue.removeFirst();
        final response = await _respond(item.session, item.request);
        device.inFlight.remove(item.request.id);
        if (response.cacheable) {
          device.responses.put(item.request.id, response.frame);
        }
        // Si la sesión murió, la respuesta queda solo en la caché a la espera
        // de la retransmisión.
        device.connection?.link.sendFrame(response.frame);
      }
    } finally {
      device.pumping = false;
    }
  }

  Future<({Uint8List frame, bool cacheable})> _respond(
    ClientSessionInfo session,
    ProtocolMessage request,
  ) async {
    ProtocolMessage reply;
    var cacheable = true;
    try {
      final result = await onRequest(session, request);
      reply = request.reply(TransportMessageTypes.ack, payload: result);
    } on ValidationException catch (error) {
      reply = _errorReply(
        request,
        ErrorPayload(code: ErrorCodes.validation, message: error.message),
      );
    } on RemoteRequestException catch (error) {
      reply = _errorReply(
        request,
        ErrorPayload(
          code: error.code,
          message: error.message,
          retryable: error.retryable,
        ),
      );
      // Un error reintentable no se recuerda: el reintento debe volver a
      // ejecutar el manejador.
      cacheable = !error.retryable;
    } on Object catch (error, stackTrace) {
      _log.severe(
        'El manejador de ${request.type} (${request.id}) falló',
        error,
        stackTrace,
      );
      reply = _errorReply(
        request,
        const ErrorPayload(
          code: ErrorCodes.internal,
          message: 'Error interno del host',
          retryable: true,
        ),
      );
      cacheable = false;
    }

    try {
      return (
        frame: encodeFrame(
          reply.toJson(),
          maxFrameBytes: options.maxFrameBytes,
        ),
        cacheable: cacheable,
      );
    } on ProtocolException catch (error, stackTrace) {
      // El manejador devolvió algo no serializable o enorme: es un fallo del
      // host, pero determinista, así que no tiene sentido reintentar.
      _log.severe(
        'La respuesta a ${request.type} (${request.id}) no es serializable',
        error,
        stackTrace,
      );
      final fallback = _errorReply(
        request,
        const ErrorPayload(
          code: ErrorCodes.internal,
          message: 'El host no pudo serializar la respuesta',
        ),
      );
      return (frame: encodeFrame(fallback.toJson()), cacheable: true);
    }
  }

  // ---------------------------------------------------------------------------
  // Utilidades
  // ---------------------------------------------------------------------------

  Uint8List _encodeEvent(String type, Map<String, Object?> payload) {
    if (TransportMessageTypes.isReserved(type)) {
      throw ArgumentError.value(
        type,
        'type',
        'Es un tipo reservado del transporte',
      );
    }
    return encodeFrame(
      ProtocolMessage.create(type, payload: payload).toJson(),
      maxFrameBytes: options.maxFrameBytes,
    );
  }

  static ProtocolMessage _bye(String reason) => ProtocolMessage.create(
    TransportMessageTypes.bye,
    payload: {'reason': reason},
  );

  static ProtocolMessage _errorReply(
    ProtocolMessage request,
    ErrorPayload error,
  ) => request.reply(TransportMessageTypes.error, payload: error.toJson());

  void _emit(HostSessionEvent event) {
    if (!_events.isClosed) _events.add(event);
  }
}

/// Una conexión TCP aceptada, antes o después del handshake.
final class _Connection {
  _Connection(this.link);

  final FrameConnection link;
  Timer? handshakeTimer;
  Timer? idleTimer;
  ClientSessionInfo? session;
  _Device? device;
  int badFrames = 0;
  bool closed = false;

  void cancelTimers() {
    handshakeTimer?.cancel();
    handshakeTimer = null;
    idleTimer?.cancel();
    idleTimer = null;
  }

  String describe() {
    final session = this.session;
    return session == null
        ? '${link.remoteAddress}:${link.remotePort} (sin handshake)'
        : '${session.deviceId}@${link.remoteAddress}:${link.remotePort}';
  }
}

/// Estado persistente de un dispositivo, común a todas sus sesiones.
final class _Device {
  _Device(this.deviceId, int cacheSize) : responses = _ResponseCache(cacheSize);

  final String deviceId;

  /// Sesión viva, o `null` si está desconectado.
  _Connection? connection;

  /// Respuestas ya emitidas, por `id` de petición.
  final _ResponseCache responses;

  /// Ids en cola o en el manejador: un duplicado no se vuelve a encolar.
  final Set<String> inFlight = {};
  final Queue<_QueuedRequest> queue = Queue<_QueuedRequest>();
  bool pumping = false;
}

final class _QueuedRequest {
  const _QueuedRequest(this.session, this.request);

  /// Sesión por la que llegó la petición (la que ve el manejador).
  final ClientSessionInfo session;
  final ProtocolMessage request;
}

/// Caché LRU de tramas de respuesta ya codificadas: reenviar una
/// retransmisión no cuesta volver a serializar.
final class _ResponseCache {
  _ResponseCache(this.capacity);

  final int capacity;
  final LinkedHashMap<String, Uint8List> _entries =
      LinkedHashMap<String, Uint8List>();

  Uint8List? get(String id) {
    final frame = _entries.remove(id);
    if (frame != null) _entries[id] = frame;
    return frame;
  }

  void put(String id, Uint8List frame) {
    if (capacity == 0) return;
    _entries.remove(id);
    _entries[id] = frame;
    if (_entries.length > capacity) _entries.remove(_entries.keys.first);
  }
}
