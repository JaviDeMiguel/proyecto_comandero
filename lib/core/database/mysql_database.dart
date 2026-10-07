import 'dart:async';
import 'dart:math';

import '../errors/app_exception.dart';
import '../logging/app_logger.dart';
import 'mysql_client_connection.dart';
import 'mysql_config.dart';
import 'sql_executor.dart';

/// Política de reintento de una transacción completa ante errores que
/// InnoDB declara seguros de repetir (1213 deadlock, 1205 lock wait timeout).
///
/// Backoff exponencial con jitter: `baseDelay × 2^(intento-1)` acotado por
/// [maxDelay] y multiplicado por un factor aleatorio en `[0.5, 1]`, para que
/// dos comanderos que se interbloquearon no vuelvan a chocar al mismo tiempo.
final class TransactionRetryPolicy {
  const TransactionRetryPolicy({
    this.maxAttempts = 3,
    this.baseDelay = const Duration(milliseconds: 100),
    this.maxDelay = const Duration(seconds: 1),
  }) : assert(maxAttempts >= 1, 'maxAttempts debe ser >= 1');

  final int maxAttempts;
  final Duration baseDelay;
  final Duration maxDelay;

  /// Espera antes del reintento número [attempt] (1 = primer reintento).
  Duration delayFor(int attempt, Random random) {
    final exponential = baseDelay.inMicroseconds * (1 << (attempt - 1));
    final capped = min(exponential, maxDelay.inMicroseconds);
    final jitter = 0.5 + random.nextDouble() * 0.5;
    return Duration(microseconds: (capped * jitter).round());
  }
}

/// `DatabaseException` lanzada por [MysqlDatabase.transaction] cuando se
/// perdió la conexión mientras se esperaba la respuesta del `COMMIT`: el
/// servidor pudo haber confirmado la transacción o no. No se reintenta; el
/// llamador debe comprobar el estado (p. ej. el diario idempotente) antes
/// de repetir.
final class TransactionException extends DatabaseException {
  const TransactionException(
    super.message, {
    super.cause,
    super.errorCode,
    super.sqlState,
    this.outcomeUnknown = false,
  });

  /// `true` si el resultado del COMMIT es desconocido.
  final bool outcomeUnknown;

  /// Un resultado incierto nunca se reintenta a ciegas.
  @override
  bool get isRetryable => !outcomeUnknown && super.isRetryable;
}

/// Punto de acceso único a la base de datos de FacturaScripts.
///
/// * Conexión única y perezosa: se abre en la primera operación (o en
///   [open]) y se reabre sola si el servidor la cerró, hubo un timeout o
///   falló la red. `mysql_client` no multiplexa consultas en una conexión,
///   por eso todas las operaciones pasan por un mutex: nunca hay dos
///   sentencias en vuelo y una transacción ocupa la conexión de principio a
///   fin.
/// * [transaction] envuelve el cuerpo en `START TRANSACTION` / `COMMIT`,
///   hace `ROLLBACK` si falla y repite la transacción entera ante errores
///   reintentables según [TransactionRetryPolicy].
/// * Reentrada: llamar a [run] o [transaction] desde dentro del cuerpo de
///   otra llamada esperaría el mutex para siempre; se detecta y se lanza
///   [StateError] (es un error de programación, no de infraestructura).
final class MysqlDatabase {
  MysqlDatabase(
    this.config, {
    SqlConnectionFactory? connectionFactory,
    this.retry = const TransactionRetryPolicy(),
    Random? random,
  }) : _connect = connectionFactory ?? MysqlClientConnection.connect,
       _random = random ?? Random();

  static final _log = appLogger('database');
  static const _reentryKey = #tpv_mysql_database_body;

  final MysqlConfig config;
  final TransactionRetryPolicy retry;
  final SqlConnectionFactory _connect;
  final Random _random;
  final _Mutex _mutex = _Mutex();

  SqlConnection? _connection;

  /// Hay una conexión abierta y utilizable en este momento.
  bool get isOpen => _connection?.isOpen ?? false;

  /// Abre la conexión ahora (útil para validar la configuración al
  /// arrancar). No es necesario: las operaciones abren la conexión solas.
  Future<void> open() => _mutex.synchronized(_ensureConnection);

  /// Cierra la conexión. Las operaciones posteriores vuelven a abrirla.
  Future<void> close() => _mutex.synchronized(_dropConnection);

  /// Comprueba que el servidor responde (`SELECT 1`), reconectando si hace
  /// falta. Lanza [NetworkException] o [DatabaseException] si no.
  Future<void> ping() => run((db) async {
    final result = await db.execute('SELECT 1 AS ok');
    if (result.rows.isEmpty) {
      throw const DatabaseException('El servidor no respondió al ping');
    }
  });

  /// Ejecuta [body] fuera de transacción (autocommit) con la conexión en
  /// exclusiva. El [SqlExecutor] recibido solo es válido mientras dura
  /// [body]: usarlo después lanza [StateError].
  Future<T> run<T>(Future<T> Function(SqlExecutor db) body) {
    _checkReentry();
    return _mutex.synchronized(() async {
      final connection = await _ensureConnection();
      final executor = _ScopedExecutor(connection, _onConnectionLost);
      try {
        return await _inBody(() => body(executor));
      } finally {
        executor.dispose();
      }
    });
  }

  /// Ejecuta [body] dentro de una transacción.
  ///
  /// Secuencia: `START TRANSACTION` → [body] → `COMMIT`. Si [body] lanza, se
  /// intenta `ROLLBACK` (solo si la conexión sigue viva) y:
  ///
  /// * si la excepción es una [DatabaseException] con `isRetryable`
  ///   (1213 / 1205) y quedan intentos, se repite TODA la transacción tras
  ///   el backoff de [retry]; agotados los intentos se relanza la última;
  /// * en cualquier otro caso se relanza tal cual.
  ///
  /// Si la conexión se pierde durante el `COMMIT`, el resultado es incierto:
  /// se lanza [TransactionException] con `outcomeUnknown = true` y NO se
  /// reintenta. Un error del servidor en el `COMMIT` (p. ej. 1213 al
  /// confirmar) sí implica que el servidor deshizo la transacción, así que
  /// se trata como un error del cuerpo.
  Future<T> transaction<T>(Future<T> Function(SqlExecutor tx) body) {
    _checkReentry();
    return _mutex.synchronized(() async {
      var attempt = 0;
      while (true) {
        attempt++;
        try {
          return await _attemptTransaction(body);
        } on DatabaseException catch (error) {
          if (!error.isRetryable || attempt >= retry.maxAttempts) rethrow;
          final delay = retry.delayFor(attempt, _random);
          _log.info(
            'Transacción reintentable (errno ${error.errorCode}); '
            'intento $attempt/${retry.maxAttempts}, espera $delay',
          );
          await Future<void>.delayed(delay);
        }
      }
    });
  }

  Future<T> _attemptTransaction<T>(
    Future<T> Function(SqlExecutor tx) body,
  ) async {
    final connection = await _ensureConnection();
    final executor = _ScopedExecutor(connection, _onConnectionLost);
    try {
      await executor.execute('START TRANSACTION');
      final T result;
      try {
        result = await _inBody(() => body(executor));
      } on Object {
        await _rollbackQuietly(executor, connection);
        rethrow;
      }
      try {
        await executor.execute('COMMIT');
      } on NetworkException catch (error, stackTrace) {
        Error.throwWithStackTrace(
          TransactionException(
            'Conexión perdida durante el COMMIT: resultado desconocido '
            '(${error.message})',
            cause: error,
            outcomeUnknown: true,
          ),
          stackTrace,
        );
      }
      return result;
    } finally {
      executor.dispose();
    }
  }

  Future<void> _rollbackQuietly(
    SqlExecutor executor,
    SqlConnection connection,
  ) async {
    if (!connection.isOpen) return;
    try {
      await executor.execute('ROLLBACK');
    } on Object catch (error) {
      // El error original es el que importa; este solo se registra. Si la
      // conexión quedó inservible, _onConnectionLost ya la descartó.
      _log.warning('ROLLBACK fallido: $error');
    }
  }

  Future<SqlConnection> _ensureConnection() async {
    final current = _connection;
    if (current != null && current.isOpen) return current;
    if (current != null) {
      _log.info('Conexión MySQL perdida: reconectando');
      await _dropConnection();
    }
    final connection = await _connect(config);
    _connection = connection;
    return connection;
  }

  Future<void> _dropConnection() async {
    final current = _connection;
    _connection = null;
    if (current != null) await current.close();
  }

  void _onConnectionLost() {
    // Se descarta de forma perezosa: la siguiente operación reconecta.
    final current = _connection;
    if (current != null && !current.isOpen) {
      _connection = null;
      unawaited(current.close());
    }
  }

  void _checkReentry() {
    if (Zone.current[_reentryKey] == true) {
      throw StateError(
        'MysqlDatabase.run/transaction no admite reentrada: use el '
        'SqlExecutor recibido por el cuerpo en curso',
      );
    }
  }

  Future<T> _inBody<T>(Future<T> Function() body) =>
      runZoned(body, zoneValues: {_reentryKey: true});
}

/// Ejecutor entregado al cuerpo de [MysqlDatabase.run] / `transaction`.
/// Se invalida al terminar el cuerpo para detectar fugas (usar el ejecutor
/// fuera de su ámbito rompería la serialización).
final class _ScopedExecutor implements SqlExecutor {
  _ScopedExecutor(this._connection, this._onConnectionLost);

  final SqlConnection _connection;
  final void Function() _onConnectionLost;
  bool _active = true;

  void dispose() => _active = false;

  @override
  Future<SqlResult> execute(
    String sql, [
    Map<String, Object?> params = const {},
  ]) async {
    if (!_active) {
      throw StateError(
        'SqlExecutor usado fuera del cuerpo de run()/transaction()',
      );
    }
    try {
      return await _connection.execute(sql, params);
    } on NetworkException {
      _onConnectionLost();
      rethrow;
    }
  }
}

/// Mutex asíncrono FIFO: cada `synchronized` espera a que termine el
/// anterior (incluido su error) antes de empezar.
final class _Mutex {
  Future<void> _last = Future<void>.value();

  Future<T> synchronized<T>(Future<T> Function() action) {
    final previous = _last;
    final completer = Completer<void>();
    _last = completer.future;
    return previous.then((_) => action()).whenComplete(completer.complete);
  }
}
