import 'mysql_config.dart';

/// Fila de resultado con los valores YA convertidos según el tipo de la
/// columna: `int`, `double`, `String`, `DateTime`, `bool` (`TINYINT(1)`) o
/// `null`. Las claves son los nombres (o alias) de columna tal como los
/// devuelve el servidor.
typedef SqlRow = Map<String, Object?>;

/// Resultado de una sentencia.
final class SqlResult {
  const SqlResult({
    this.rows = const [],
    this.affectedRows = 0,
    this.lastInsertId,
  });

  static const empty = SqlResult();

  final List<SqlRow> rows;

  /// Filas afectadas por INSERT / UPDATE / DELETE (0 en un SELECT). En un
  /// `INSERT ... ON DUPLICATE KEY UPDATE` MySQL devuelve 1 si insertó, 2 si
  /// actualizó y 0 si la fila no cambió.
  final int affectedRows;

  /// `LAST_INSERT_ID()` tras un INSERT en una tabla con AUTO_INCREMENT; nulo
  /// cuando no aplica.
  final int? lastInsertId;

  bool get isEmpty => rows.isEmpty;

  /// Primera fila o `null`.
  SqlRow? get firstOrNull => rows.isEmpty ? null : rows.first;
}

/// Ejecutor de SQL con parámetros con nombre (`:nombre`).
///
/// Los valores de [SqlExecutor.execute] se escapan SIEMPRE en el adaptador:
/// nunca se interpola texto del usuario en la sentencia. Los parámetros
/// admitidos son `null`, `int`, `double`, `bool`, `String` y `DateTime`
/// (se envía como `yyyy-MM-dd HH:mm:ss` en hora local).
///
/// Dentro de [SqlExecutor.execute] todo error nativo se traduce a
/// `DatabaseException` (error del servidor o del cliente MySQL) o a
/// `NetworkException` (socket, timeout, conexión perdida).
abstract interface class SqlExecutor {
  Future<SqlResult> execute(String sql, [Map<String, Object?> params]);
}

/// Conexión física con la base de datos.
abstract interface class SqlConnection implements SqlExecutor {
  /// Cierra la conexión. Es idempotente y no lanza.
  Future<void> close();

  /// `false` cuando el servidor cerró el socket, hubo un timeout de consulta
  /// o se llamó a [close].
  bool get isOpen;
}

/// Fábrica de conexiones: abre y autentica una conexión nueva para [config].
/// `MysqlDatabase` la usa para la conexión perezosa y la reconexión; los tests
/// inyectan una que devuelve dobles en memoria.
typedef SqlConnectionFactory = Future<SqlConnection> Function(
  MysqlConfig config,
);
