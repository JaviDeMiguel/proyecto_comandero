import 'dart:async';
import 'dart:io';

import 'package:mysql_client/exception.dart';
import 'package:mysql_client/mysql_client.dart';
import 'package:mysql_client/mysql_protocol.dart';

import '../errors/app_exception.dart';
import '../logging/app_logger.dart';
import 'mysql_config.dart';
import 'sql_executor.dart';

/// Adaptador de `package:mysql_client` 0.0.27 al contrato [SqlConnection].
///
/// Hechos del paquete que condicionan este adaptador (leídos en su código):
///
/// * Usa el protocolo de TEXTO (`COM_QUERY`): todos los valores llegan como
///   `String?` y el paquete solo conoce el tipo de columna y su longitud de
///   presentación, no los flags. La conversión a tipos Dart se hace aquí
///   ([decodeMysqlTextValue]).
/// * Los parámetros con nombre `:nombre` se sustituyen en el cliente
///   escapando `'` y `\`; `bool` viaja como `TRUE/FALSE` y cualquier otro
///   objeto como su `toString()` entre comillas. Por eso [encodeMysqlParam]
///   convierte antes `DateTime` → `yyyy-MM-dd HH:mm:ss` y `bool` → `1/0`.
/// * Autenticación: `mysql_native_password` siempre; `caching_sha2_password`
///   sin TLS solo cuando el servidor ya tiene la contraseña en caché (fast
///   auth); si pide "full auth" sin TLS lanza `MySQLClientException` y hay
///   que usar `secure: true` (el paquete acepta cualquier certificado).
/// * Errores: `MySQLServerException(errorCode)` para errores del servidor
///   (sin SQLSTATE: el paquete no lo decodifica), `MySQLClientException` /
///   `MySQLProtocolException` para fallos del cliente, `SocketException` /
///   `TimeoutException` para la red.
/// * Si el servidor cierra el socket mientras hay una consulta en vuelo, el
///   `Future` del paquete NO se completa nunca: este adaptador escucha
///   `onClose` y aplica `queryTimeout` para no colgarse.
/// * No se puede cancelar una consulta ni cerrar a la fuerza una conexión
///   con consulta pendiente (`close()` del paquete exige estado "ready"): tras
///   un timeout la conexión se marca cerrada y se abandona; el socket lo
///   cerrará el servidor al terminar.
final class MysqlClientConnection implements SqlConnection {
  MysqlClientConnection._(this._conn, this._config) {
    _conn.onClose(() {
      _open = false;
      if (!_closed.isCompleted) _closed.complete();
    });
  }

  /// Abre y autentica una conexión nueva. Es el [SqlConnectionFactory] por
  /// defecto de `MysqlDatabase`.
  static Future<SqlConnection> connect(MysqlConfig config) async {
    _log.fine('Conectando a $config');
    try {
      final conn = await MySQLConnection.createConnection(
        host: config.host,
        port: config.port,
        userName: config.user,
        password: config.password,
        databaseName: config.database,
        secure: config.secure,
      ).timeout(config.connectTimeout);
      await conn
          .connect(timeoutMs: config.connectTimeout.inMilliseconds)
          .timeout(config.connectTimeout);
      return MysqlClientConnection._(conn, config);
    } on Object catch (error, stackTrace) {
      Error.throwWithStackTrace(
        translateMysqlError(error, context: 'conectar con ${config.host}'),
        stackTrace,
      );
    }
  }

  static final _log = appLogger('database.mysql');

  final MySQLConnection _conn;
  final MysqlConfig _config;
  final Completer<void> _closed = Completer<void>();
  bool _open = true;

  @override
  bool get isOpen => _open && _conn.connected;

  @override
  Future<SqlResult> execute(
    String sql, [
    Map<String, Object?> params = const {},
  ]) async {
    if (!isOpen) {
      throw const NetworkException('La conexión MySQL está cerrada');
    }
    final Map<String, dynamic> encoded;
    try {
      encoded = {
        for (final entry in params.entries)
          entry.key: encodeMysqlParam(entry.value),
      };
    } on ArgumentError catch (error) {
      throw DatabaseException(
        'Parámetro SQL no representable: ${error.message}',
        cause: error,
      );
    }
    try {
      final result = await _race(
        _conn.execute(sql, encoded),
        timeout: _config.queryTimeout,
      );
      return _toSqlResult(result);
    } on Object catch (error, stackTrace) {
      final translated = translateMysqlError(error, context: _describe(sql));
      if (translated is NetworkException) {
        // La conexión ya no es fiable (socket caído o respuesta perdida).
        _open = false;
      }
      Error.throwWithStackTrace(translated, stackTrace);
    }
  }

  /// Espera la respuesta del paquete, el cierre del socket o el timeout, lo
  /// que ocurra antes. Necesario porque el paquete no completa su `Future`
  /// cuando el servidor cierra la conexión a mitad de una consulta.
  Future<IResultSet> _race(
    Future<IResultSet> pending, {
    required Duration timeout,
  }) {
    final completer = Completer<IResultSet>();
    pending.then(
      (value) {
        if (!completer.isCompleted) completer.complete(value);
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!completer.isCompleted) completer.completeError(error, stackTrace);
      },
    );
    unawaited(
      _closed.future.then((_) {
        if (!completer.isCompleted) {
          completer.completeError(
            const SocketException('Conexión cerrada por el servidor'),
          );
        }
      }),
    );
    return completer.future.timeout(timeout);
  }

  @override
  Future<void> close() async {
    if (!_open) return;
    _open = false;
    try {
      await _conn.close();
    } on Object catch (error) {
      // close() del paquete lanza si hay una consulta pendiente; no hay nada
      // mejor que hacer: la conexión se abandona.
      _log.fine('Cierre de conexión con incidencia: $error');
    }
  }

  static SqlResult _toSqlResult(IResultSet result) {
    final rows = <SqlRow>[];
    if (result.numOfColumns > 0) {
      final columns = result.cols.toList();
      for (final row in result.rows) {
        final values = <String, Object?>{};
        for (var i = 0; i < columns.length; i++) {
          final column = columns[i];
          values[column.name] = decodeMysqlTextValue(
            row.colAt(i),
            typeCode: column.type.intVal,
            columnLength: column.length,
          );
        }
        rows.add(values);
      }
    }
    final lastInsertId = result.lastInsertID.toInt();
    return SqlResult(
      rows: rows,
      affectedRows: result.affectedRows.toInt(),
      lastInsertId: lastInsertId == 0 ? null : lastInsertId,
    );
  }

  static String _describe(String sql) {
    final compact = sql.replaceAll(RegExp(r'\s+'), ' ').trim();
    return compact.length <= 60 ? compact : '${compact.substring(0, 60)}…';
  }
}

/// Convierte un valor del protocolo de texto de MySQL al tipo Dart que
/// corresponde a la columna.
///
/// Reglas (el `typeCode` es el `MYSQL_TYPE_*` de la definición de columna):
///
/// * `TINYINT(1)` (tipo TINY con longitud de presentación 1) → `bool`. Es
///   el `boolean` de FacturaScripts (`nostock`, `sevende`...). Un `TINYINT`
///   de otra anchura → `int`.
/// * `SMALLINT`, `INT`, `MEDIUMINT`, `BIGINT`, `YEAR` → `int`. Un BIGINT
///   UNSIGNED fuera del rango de `int` se devuelve como `String`.
/// * `FLOAT`, `DOUBLE`, `DECIMAL` → `double`.
/// * `DATE`, `DATETIME`, `TIMESTAMP` → `DateTime` en hora local (MySQL ya
///   entrega el TIMESTAMP convertido a la `time_zone` de la sesión). Las
///   fechas cero (`0000-00-00`) → `null`.
/// * `NULL` → `null`. Todo lo demás (`VARCHAR`, `TEXT`, `TIME`, `BIT`,
///   `JSON`...) → `String` tal cual.
Object? decodeMysqlTextValue(
  String? raw, {
  required int typeCode,
  required int columnLength,
}) {
  if (raw == null) return null;
  switch (typeCode) {
    case mysqlColumnTypeNull:
      return null;
    case mysqlColumnTypeTiny:
      if (columnLength == 1) {
        final value = int.tryParse(raw);
        return value == null ? raw : value != 0;
      }
      return int.tryParse(raw) ?? raw;
    case mysqlColumnTypeShort:
    case mysqlColumnTypeLong:
    case mysqlColumnTypeInt24:
    case mysqlColumnTypeLongLong:
    case mysqlColumnTypeYear:
      return int.tryParse(raw) ?? raw;
    case mysqlColumnTypeFloat:
    case mysqlColumnTypeDouble:
    case mysqlColumnTypeDecimal:
    case mysqlColumnTypeNewDecimal:
      return double.tryParse(raw) ?? raw;
    case mysqlColumnTypeDate:
    case mysqlColumnTypeNewDate:
    case mysqlColumnTypeDateTime:
    case mysqlColumnTypeDateTime2:
    case mysqlColumnTypeTimestamp:
    case mysqlColumnTypeTimestamp2:
      if (raw.startsWith('0000-00-00')) return null;
      return DateTime.tryParse(raw) ?? raw;
    default:
      return raw;
  }
}

/// Prepara un parámetro para `mysql_client`: `DateTime` → texto
/// `yyyy-MM-dd HH:mm:ss` (hora local, lo que espera un DATETIME/TIMESTAMP),
/// `bool` → `1/0` (TINYINT), números y cadenas tal cual, `null` → NULL.
///
/// Lanza [ArgumentError] con números no finitos (MySQL no tiene NaN) y con
/// tipos no admitidos: nunca se envía un `toString()` arbitrario.
Object? encodeMysqlParam(Object? value) => switch (value) {
  null => null,
  final bool b => b ? 1 : 0,
  final int i => i,
  final double d =>
    d.isFinite ? d : throw ArgumentError.value(d, 'value', 'número no finito'),
  final String s => s,
  final DateTime dt => formatMysqlDateTime(dt),
  _ => throw ArgumentError.value(
    value,
    'value',
    'tipo ${value.runtimeType} no admitido como parámetro SQL',
  ),
};

/// Formato `yyyy-MM-dd HH:mm:ss` (hora local, sin fracción): el que escribe
/// FacturaScripts en `productos.actualizado`.
String formatMysqlDateTime(DateTime dt) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${dt.year.toString().padLeft(4, '0')}-${two(dt.month)}-${two(dt.day)}'
      ' ${two(dt.hour)}:${two(dt.minute)}:${two(dt.second)}';
}

/// SQLSTATE de los errores que el módulo distingue. `mysql_client` no
/// decodifica el SQLSTATE del paquete de error, así que se deduce del errno
/// para los códigos conocidos; en el resto queda nulo.
const Map<int, String> mysqlSqlStates = {
  1062: '23000', // ER_DUP_ENTRY
  1451: '23000', // ER_ROW_IS_REFERENCED_2
  1452: '23000', // ER_NO_REFERENCED_ROW_2
  1146: '42S02', // ER_NO_SUCH_TABLE
  1054: '42S22', // ER_BAD_FIELD_ERROR
  1064: '42000', // ER_PARSE_ERROR
  1045: '28000', // ER_ACCESS_DENIED_ERROR
  1044: '42000', // ER_DBACCESS_DENIED_ERROR
  1049: '42000', // ER_BAD_DB_ERROR
  1142: '42000', // ER_TABLEACCESS_DENIED_ERROR
  1205: 'HY000', // ER_LOCK_WAIT_TIMEOUT
  1213: '40001', // ER_LOCK_DEADLOCK
  3819: 'HY000', // ER_CHECK_CONSTRAINT_VIOLATED
  3823: 'HY000', // ER_CHECK_CONSTRAINT_REFERS_FK_COLUMN
};

/// Traduce cualquier error de `mysql_client` o de `dart:io` a la jerarquía
/// tipada. Una [AppException] se devuelve tal cual.
AppException translateMysqlError(Object error, {String? context}) {
  final where = context == null ? '' : ' al $context';
  return switch (error) {
    final AppException e => e,
    final MySQLServerException e => DatabaseException(
      'MySQL [${e.errorCode}]$where: ${e.message}',
      cause: e,
      errorCode: e.errorCode,
      sqlState: mysqlSqlStates[e.errorCode],
    ),
    final MySQLClientException e when _isConnectionLoss(e.message) =>
      NetworkException('Conexión MySQL perdida$where: ${e.message}', cause: e),
    final MySQLClientException e
        when e.message.contains('caching_sha2_password') =>
      DatabaseException(
        'El servidor exige autenticación caching_sha2_password completa, '
        'que mysql_client solo admite con TLS: active "secure" en la '
        'configuración o use un usuario mysql_native_password',
        cause: e,
      ),
    final MySQLClientException e => DatabaseException(
      'Cliente MySQL$where: ${e.message}',
      cause: e,
    ),
    final TimeoutException e => NetworkException(
      'Tiempo de espera agotado$where',
      cause: e,
    ),
    final SocketException e => NetworkException(
      'Error de red$where: ${e.message}',
      cause: e,
    ),
    final HandshakeException e => NetworkException(
      'Fallo TLS$where: ${e.message}',
      cause: e,
    ),
    final IOException e => NetworkException('Error de E/S$where: $e', cause: e),
    final ArgumentError e => DatabaseException(
      'Parámetro SQL no representable: ${e.message}',
      cause: e,
    ),
    _ => DatabaseException(
      'Error MySQL inesperado$where: $error',
      cause: error,
    ),
  };
}

bool _isConnectionLoss(String message) =>
    message.contains('connection closed') ||
    message.contains('Connection closed') ||
    message.contains('bad state');
