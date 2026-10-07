import 'package:meta/meta.dart';

import '../../errors/app_exception.dart';
import '../../utils/json_map.dart';
import 'message.dart';

/// Tipos de mensaje reservados por la capa de transporte.
///
/// Cualquier otro `type` (p. ej. `comanda.submit`, `sala.snapshot`) es un
/// mensaje de aplicación y la capa de transporte lo entrega sin interpretarlo.
abstract final class TransportMessageTypes {
  /// Comandero → host: primera trama de la conexión ([HelloPayload]).
  static const String hello = 'hello';

  /// Host → comandero: handshake aceptado ([WelcomePayload]).
  static const String welcome = 'welcome';

  /// Host → comandero: handshake rechazado ([RejectPayload]); después cierra.
  static const String reject = 'reject';

  /// Comandero → host: latido periódico.
  static const String ping = 'ping';

  /// Host → comandero: respuesta al latido (`replyTo` = id del ping).
  static const String pong = 'pong';

  /// Respuesta correcta a una petición (`replyTo` = id de la petición); el
  /// `payload` es el resultado que devuelve el manejador.
  static const String ack = 'ack';

  /// Respuesta de error a una petición ([ErrorPayload]).
  static const String error = 'error';

  /// Cierre ordenado por cualquiera de los extremos (`payload.reason`).
  static const String bye = 'bye';

  static const Set<String> all = {
    hello,
    welcome,
    reject,
    ping,
    pong,
    ack,
    error,
    bye,
  };

  static bool isReserved(String type) => all.contains(type);
}

/// Motivos por los que el host rechaza un handshake.
abstract final class RejectCodes {
  static const String unsupportedVersion = 'unsupported_version';
  static const String unauthorized = 'unauthorized';
  static const String serverFull = 'server_full';
  static const String badHandshake = 'bad_handshake';
}

/// Códigos de error de las respuestas a peticiones.
abstract final class ErrorCodes {
  /// Datos de negocio inválidos. Definitivo: reintentar no cambia el resultado.
  static const String validation = 'validation';

  /// El host no conoce ese tipo de mensaje. Definitivo.
  static const String unknownType = 'unknown_type';

  /// Fallo inesperado del host al procesar. Reintentable.
  static const String internal = 'internal';
}

/// Motivos de cierre enviados en `bye`.
abstract final class ByeReasons {
  static const String clientClosing = 'client_closing';
  static const String serverShuttingDown = 'server_shutting_down';

  /// El mismo dispositivo abrió una conexión más reciente.
  static const String replaced = 'replaced';
  static const String idleTimeout = 'idle_timeout';
  static const String protocolError = 'protocol_error';
}

/// `hello`: identificación del comandero al conectar.
@immutable
final class HelloPayload {
  const HelloPayload({
    required this.deviceId,
    required this.deviceName,
    this.protocolVersion = kProtocolVersion,
    this.appVersion,
    this.pairingCode,
  });

  factory HelloPayload.fromJson(Map<String, Object?> json) => _parse(
    'hello',
    () => HelloPayload(
      deviceId: _nonEmpty(json.requireString('deviceId'), 'deviceId'),
      deviceName: json.requireString('deviceName'),
      protocolVersion: json.requireInt('protocolVersion'),
      appVersion: json.optionalString('appVersion'),
      pairingCode: json.optionalString('pairingCode'),
    ),
  );

  /// Identificador estable de la instalación (sobrevive a reconexiones).
  final String deviceId;

  /// Nombre visible (p. ej. "Comandero terraza").
  final String deviceName;
  final int protocolVersion;
  final String? appVersion;

  /// Código de emparejamiento, obligatorio si el host tiene uno configurado.
  final String? pairingCode;

  Map<String, Object?> toJson() => {
    'deviceId': deviceId,
    'deviceName': deviceName,
    'protocolVersion': protocolVersion,
    if (appVersion != null) 'appVersion': appVersion,
    if (pairingCode != null) 'pairingCode': pairingCode,
  };
}

/// `welcome`: el host acepta la sesión y comunica los temporizadores.
@immutable
final class WelcomePayload {
  const WelcomePayload({
    required this.hostId,
    required this.hostName,
    required this.sessionId,
    required this.serverTimeMs,
    required this.heartbeatIntervalMs,
    required this.idleTimeoutMs,
  });

  factory WelcomePayload.fromJson(Map<String, Object?> json) => _parse(
    'welcome',
    () => WelcomePayload(
      hostId: _nonEmpty(json.requireString('hostId'), 'hostId'),
      hostName: json.requireString('hostName'),
      sessionId: _nonEmpty(json.requireString('sessionId'), 'sessionId'),
      serverTimeMs: json.requireInt('serverTimeMs'),
      heartbeatIntervalMs: _positive(
        json.requireInt('heartbeatIntervalMs'),
        'heartbeatIntervalMs',
      ),
      idleTimeoutMs: _positive(
        json.requireInt('idleTimeoutMs'),
        'idleTimeoutMs',
      ),
    ),
  );

  final String hostId;
  final String hostName;

  /// Identificador de esta conexión concreta (cambia en cada reconexión).
  final String sessionId;
  final int serverTimeMs;

  /// Cada cuánto debe enviar `ping` el comandero.
  final int heartbeatIntervalMs;

  /// Silencio máximo tolerado antes de dar la conexión por muerta.
  final int idleTimeoutMs;

  Map<String, Object?> toJson() => {
    'hostId': hostId,
    'hostName': hostName,
    'sessionId': sessionId,
    'serverTimeMs': serverTimeMs,
    'heartbeatIntervalMs': heartbeatIntervalMs,
    'idleTimeoutMs': idleTimeoutMs,
  };
}

/// `reject`: handshake rechazado.
@immutable
final class RejectPayload {
  const RejectPayload({required this.code, required this.message});

  factory RejectPayload.fromJson(Map<String, Object?> json) => _parse(
    'reject',
    () => RejectPayload(
      code: json.requireString('code'),
      message: json.optionalString('message') ?? '',
    ),
  );

  /// Uno de [RejectCodes].
  final String code;
  final String message;

  Map<String, Object?> toJson() => {'code': code, 'message': message};
}

/// `error`: la petición llegó pero no pudo completarse.
@immutable
final class ErrorPayload {
  const ErrorPayload({
    required this.code,
    required this.message,
    this.retryable = false,
  });

  factory ErrorPayload.fromJson(Map<String, Object?> json) => _parse(
    'error',
    () => ErrorPayload(
      code: json.requireString('code'),
      message: json.optionalString('message') ?? '',
      retryable: json.optionalBool('retryable') ?? false,
    ),
  );

  /// Uno de [ErrorCodes] o un código propio de la aplicación.
  final String code;
  final String message;
  final bool retryable;

  Map<String, Object?> toJson() => {
    'code': code,
    'message': message,
    'retryable': retryable,
  };

  RemoteRequestException toException() =>
      RemoteRequestException(message, code: code, retryable: retryable);
}

/// Compara dos códigos de emparejamiento en tiempo constante (no revela por
/// temporización cuántos caracteres coinciden).
bool pairingCodesMatch(String expected, String? received) {
  if (received == null) return false;
  final a = expected.codeUnits;
  final b = received.codeUnits;
  var difference = a.length ^ b.length;
  for (var i = 0; i < a.length; i++) {
    difference |= a[i] ^ (i < b.length ? b[i] : 0);
  }
  return difference == 0;
}

T _parse<T>(String messageType, T Function() build) {
  try {
    return build();
  } on FormatException catch (error) {
    throw ProtocolException(
      "Mensaje '$messageType' inválido: ${error.message}",
      cause: error,
    );
  }
}

String _nonEmpty(String value, String field) {
  if (value.isEmpty) throw FormatException("Campo '$field' vacío");
  return value;
}

int _positive(int value, String field) {
  if (value <= 0) throw FormatException("Campo '$field' debe ser positivo");
  return value;
}
