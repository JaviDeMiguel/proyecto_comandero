/// Configuración de conexión con la API de FacturaScripts.
library;

import 'package:meta/meta.dart';

import '../errors/app_exception.dart';
import '../utils/json_map.dart';

/// Parámetros de conexión: URL base, clave de API y tiempos de espera.
///
/// Es inmutable. El constructor no es `const` porque normaliza [baseUrl] (quita
/// barras finales y un sufijo `/api/3` pegado por error): así cualquier
/// instancia es válida y el cliente HTTP no tiene que volver a comprobarla.
@immutable
final class FsApiConfig {
  /// Lanza [ConfigException] si [baseUrl] no es una URL `http(s)` absoluta.
  FsApiConfig({
    required String baseUrl,
    required this.token,
    this.connectTimeout = defaultConnectTimeout,
    this.requestTimeout = defaultRequestTimeout,
  }) : baseUrl = normalizeBaseUrl(baseUrl);

  /// Reconstruye la configuración guardada con [toJson]. Lanza
  /// [ConfigException] si faltan campos o la URL no es válida.
  factory FsApiConfig.fromJson(Map<String, Object?> json) {
    try {
      return FsApiConfig(
        baseUrl: json.requireString('baseUrl'),
        token: json.requireString('token'),
        connectTimeout: Duration(
          milliseconds:
              json.optionalInt('connectTimeoutMs') ??
              defaultConnectTimeout.inMilliseconds,
        ),
        requestTimeout: Duration(
          milliseconds:
              json.optionalInt('requestTimeoutMs') ??
              defaultRequestTimeout.inMilliseconds,
        ),
      );
    } on FormatException catch (error) {
      throw ConfigException(
        'Configuración del ERP no válida: ${error.message}',
        cause: error,
      );
    }
  }

  static const Duration defaultConnectTimeout = Duration(seconds: 5);
  static const Duration defaultRequestTimeout = Duration(seconds: 20);

  /// URL de la instalación, sin barra final (p. ej.
  /// `http://192.168.1.10/facturascripts`). Las rutas `/api/3/...` se añaden
  /// en el cliente.
  final String baseUrl;

  /// Clave de API (cabecera `Token`). Nunca se incluye en [toString].
  final String token;

  /// Tiempo máximo para establecer la conexión TCP.
  final Duration connectTimeout;

  /// Tiempo máximo para recibir la respuesta completa (desde el envío).
  final Duration requestTimeout;

  /// Raíz de la API v3: `<baseUrl>/api/3`.
  String get apiRoot => '$baseUrl/api/3';

  /// Normaliza una URL base escrita por el usuario: recorta espacios, quita
  /// barras finales y un sufijo `/api/3` o `/api`. Lanza [ConfigException] si
  /// no es una URL `http(s)` absoluta con host.
  static String normalizeBaseUrl(String raw) {
    var text = raw.trim();
    text = text.replaceFirst(RegExp(r'/+$'), '');
    text = text.replaceFirst(RegExp(r'/api(/3)?$'), '');
    text = text.replaceFirst(RegExp(r'/+$'), '');

    final uri = Uri.tryParse(text);
    if (uri == null ||
        !(uri.scheme == 'http' || uri.scheme == 'https') ||
        uri.host.isEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw ConfigException(
        "La URL de FacturaScripts no es válida: '$raw' "
        '(se espera http://host[:puerto][/ruta])',
      );
    }
    return text;
  }

  Map<String, Object?> toJson() => {
    'baseUrl': baseUrl,
    'token': token,
    'connectTimeoutMs': connectTimeout.inMilliseconds,
    'requestTimeoutMs': requestTimeout.inMilliseconds,
  };

  FsApiConfig copyWith({
    String? baseUrl,
    String? token,
    Duration? connectTimeout,
    Duration? requestTimeout,
  }) => FsApiConfig(
    baseUrl: baseUrl ?? this.baseUrl,
    token: token ?? this.token,
    connectTimeout: connectTimeout ?? this.connectTimeout,
    requestTimeout: requestTimeout ?? this.requestTimeout,
  );

  @override
  bool operator ==(Object other) =>
      other is FsApiConfig &&
      other.baseUrl == baseUrl &&
      other.token == token &&
      other.connectTimeout == connectTimeout &&
      other.requestTimeout == requestTimeout;

  @override
  int get hashCode =>
      Object.hash(baseUrl, token, connectTimeout, requestTimeout);

  /// Sin la clave: este texto acaba en logs y pantallas de diagnóstico.
  @override
  String toString() =>
      'FsApiConfig(baseUrl: $baseUrl, token: ***, '
      'connectTimeout: ${connectTimeout.inSeconds}s, '
      'requestTimeout: ${requestTimeout.inSeconds}s)';
}
