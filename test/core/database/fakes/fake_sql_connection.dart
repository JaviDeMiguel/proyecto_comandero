import 'dart:async';

import 'package:proyecto_comandero/core/database/mysql_config.dart';
import 'package:proyecto_comandero/core/database/sql_executor.dart';
import 'package:proyecto_comandero/core/errors/app_exception.dart';

/// Sentencia registrada por [FakeSqlConnection].
final class ExecutedStatement {
  const ExecutedStatement(this.sql, this.params);

  final String sql;
  final Map<String, Object?> params;

  /// SQL con los espacios normalizados, para comparar sin depender del
  /// formato.
  String get normalized => sql.replaceAll(RegExp(r'\s+'), ' ').trim();

  @override
  String toString() => '$normalized $params';
}

/// Respuesta programada para una sentencia.
typedef StatementHandler = FutureOr<SqlResult> Function(
  String sql,
  Map<String, Object?> params,
);

/// Regla: a qué sentencias se aplica y qué hace.
final class _Rule {
  _Rule(this.matches, this.handler, {this.times});

  final bool Function(String normalizedSql, Map<String, Object?> params)
  matches;
  final StatementHandler handler;

  /// Número de veces que la regla se aplica antes de desactivarse (`null` =
  /// siempre).
  int? times;
}

/// Conexión SQL programable en memoria.
///
/// Registra la secuencia exacta de sentencias y parámetros en [log]. Las
/// reglas ([on], [onceOn], [failOn], [failOnceOn], [dropConnectionOn]) se
/// evalúan en orden de inserción; la primera que coincide responde. Sin
/// regla aplicable devuelve [SqlResult.empty].
final class FakeSqlConnection implements SqlConnection {
  FakeSqlConnection({this.name = 'fake'});

  final String name;
  final List<ExecutedStatement> log = [];
  final List<_Rule> _rules = [];
  bool _open = true;
  int closeCalls = 0;

  /// Sentencias normalizadas, en orden.
  List<String> get statements => [for (final s in log) s.normalized];

  @override
  bool get isOpen => _open;

  /// Simula que el servidor cerró el socket.
  void dropConnection() => _open = false;

  void on(Pattern sql, StatementHandler handler) =>
      _rules.add(_Rule(_matcher(sql), handler));

  void onceOn(Pattern sql, StatementHandler handler) =>
      _rules.add(_Rule(_matcher(sql), handler, times: 1));

  /// Devuelve filas fijas para las sentencias que coincidan.
  void rowsOn(Pattern sql, List<SqlRow> rows) =>
      on(sql, (_, _) => SqlResult(rows: rows));

  void failOn(Pattern sql, Exception error) => on(sql, (_, _) => throw error);

  void failOnceOn(Pattern sql, Exception error) =>
      onceOn(sql, (_, _) => throw error);

  /// La sentencia falla con [NetworkException] y la conexión queda cerrada
  /// (como cuando el servidor corta el socket a mitad de consulta).
  void dropConnectionOn(Pattern sql, {int? times}) => _rules.add(
    _Rule(_matcher(sql), (_, _) {
      _open = false;
      throw const NetworkException('Conexión cerrada por el servidor (fake)');
    }, times: times),
  );

  @override
  Future<SqlResult> execute(
    String sql, [
    Map<String, Object?> params = const {},
  ]) async {
    if (!_open) {
      throw const NetworkException('La conexión está cerrada (fake)');
    }
    log.add(ExecutedStatement(sql, Map.unmodifiable(params)));
    final normalized = ExecutedStatement(sql, params).normalized;
    // Cede el turno para que la serialización sea observable en tests de
    // concurrencia.
    await Future<void>.delayed(Duration.zero);
    for (final rule in _rules) {
      final remaining = rule.times;
      if (remaining != null && remaining <= 0) continue;
      if (!rule.matches(normalized, params)) continue;
      if (remaining != null) rule.times = remaining - 1;
      return await rule.handler(sql, params);
    }
    return SqlResult.empty;
  }

  @override
  Future<void> close() async {
    closeCalls++;
    _open = false;
  }

  static bool Function(String, Map<String, Object?>) _matcher(Pattern sql) =>
      (normalized, _) => switch (sql) {
        final String s => normalized.toUpperCase().startsWith(s.toUpperCase()),
        final RegExp re => re.hasMatch(normalized),
        _ => sql.allMatches(normalized).isNotEmpty,
      };
}

/// Fábrica que entrega conexiones falsas y las conserva para inspección.
final class FakeConnectionFactory {
  FakeConnectionFactory({this.configure});

  /// Permite programar cada conexión nueva antes de entregarla.
  final void Function(FakeSqlConnection connection, int index)? configure;

  final List<FakeSqlConnection> connections = [];

  /// Si está definido, la siguiente conexión falla con este error.
  Exception? nextConnectError;

  int get connectCalls => connections.length + _failedConnects;
  int _failedConnects = 0;

  Future<SqlConnection> call(MysqlConfig config) async {
    final error = nextConnectError;
    if (error != null) {
      nextConnectError = null;
      _failedConnects++;
      throw error;
    }
    final connection = FakeSqlConnection(name: 'conn${connections.length}');
    configure?.call(connection, connections.length);
    // Respuesta por defecto al ping (tras las reglas del test, que mandan).
    connection.rowsOn('SELECT 1 AS ok', [
      {'ok': 1},
    ]);
    connections.add(connection);
    return connection;
  }

  /// La conexión viva (la última creada).
  FakeSqlConnection get current => connections.last;

  /// Secuencia de sentencias de todas las conexiones, en orden.
  List<String> get allStatements => [
    for (final c in connections) ...c.statements,
  ];
}

const testConfig = MysqlConfig(
  host: 'localhost',
  user: 'tpv',
  password: 'secreto',
  database: 'fs',
);

DatabaseException mysqlError(int errno, [String? message]) => DatabaseException(
  message ?? 'MySQL [$errno]',
  errorCode: errno,
  sqlState: switch (errno) {
    1213 => '40001',
    1062 || 1451 || 1452 => '23000',
    _ => null,
  },
);
