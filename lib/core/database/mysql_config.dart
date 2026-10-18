import 'package:equatable/equatable.dart';

import '../utils/json_map.dart';

/// Parámetros de conexión a la base de datos MySQL de FacturaScripts.
///
/// Es un valor inmutable y serializable (ajustes del TPV). La contraseña
/// nunca aparece en [toString] para que no acabe en logs o informes de error.
final class MysqlConfig extends Equatable {
  const MysqlConfig({
    required this.host,
    this.port = 3306,
    required this.user,
    required this.password,
    required this.database,
    this.secure = true,
    this.connectTimeout = const Duration(seconds: 5),
    this.queryTimeout = const Duration(seconds: 15),
  });

  /// Lee la configuración persistida. Lanza [FormatException] si falta un
  /// campo obligatorio o su tipo no es el esperado (la capa de ajustes la
  /// traduce a `ConfigException`).
  factory MysqlConfig.fromJson(Map<String, Object?> json) => MysqlConfig(
    host: json.requireString('host'),
    port: json.optionalInt('port') ?? 3306,
    user: json.requireString('user'),
    password: json.optionalString('password') ?? '',
    database: json.requireString('database'),
    // `toJson` escribe siempre `secure`, así que todo ajuste guardado por la
    // app conserva su valor. Si falta (JSON escrito a mano o anterior a este
    // campo) se lee `false`, como antes de que TLS fuera el valor por defecto:
    // no se cambia en silencio el comportamiento de una configuración ya hecha.
    secure: json.optionalBool('secure') ?? false,
    connectTimeout: Duration(
      milliseconds: json.optionalInt('connectTimeoutMs') ?? 5000,
    ),
    queryTimeout: Duration(
      milliseconds: json.optionalInt('queryTimeoutMs') ?? 15000,
    ),
  );

  final String host;
  final int port;
  final String user;
  final String password;

  /// Nombre de la base de datos de FacturaScripts (`FS_DB_NAME`).
  final String database;

  /// Usar TLS (por defecto, sí). Con MySQL 8 y el plugin
  /// `caching_sha2_password`, la primera autenticación de un usuario (sin
  /// contraseña en la caché del servidor) solo es posible con TLS; con la
  /// caché caliente funciona sin TLS. El usuario que crea el asistente del
  /// plugin Hosteleria exige además `REQUIRE SSL`.
  final bool secure;

  /// Tiempo máximo para abrir el socket y completar la autenticación.
  final Duration connectTimeout;

  /// Tiempo máximo de espera de la respuesta de una sentencia. Al vencer, la
  /// conexión se da por perdida (el protocolo no permite cancelar la consulta
  /// en curso) y se reabrirá en la siguiente operación.
  final Duration queryTimeout;

  Map<String, Object?> toJson() => {
    'host': host,
    'port': port,
    'user': user,
    'password': password,
    'database': database,
    'secure': secure,
    'connectTimeoutMs': connectTimeout.inMilliseconds,
    'queryTimeoutMs': queryTimeout.inMilliseconds,
  };

  MysqlConfig copyWith({
    String? host,
    int? port,
    String? user,
    String? password,
    String? database,
    bool? secure,
    Duration? connectTimeout,
    Duration? queryTimeout,
  }) => MysqlConfig(
    host: host ?? this.host,
    port: port ?? this.port,
    user: user ?? this.user,
    password: password ?? this.password,
    database: database ?? this.database,
    secure: secure ?? this.secure,
    connectTimeout: connectTimeout ?? this.connectTimeout,
    queryTimeout: queryTimeout ?? this.queryTimeout,
  );

  @override
  List<Object?> get props => [
    host,
    port,
    user,
    password,
    database,
    secure,
    connectTimeout,
    queryTimeout,
  ];

  /// Sin contraseña: apto para logs.
  @override
  String toString() =>
      'MysqlConfig($user@$host:$port/$database'
      '${secure ? ', TLS' : ''})';
}
