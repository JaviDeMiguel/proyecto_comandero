import 'dart:async';
import 'dart:math';

import 'package:proyecto_comandero/core/database/mysql_database.dart';
import 'package:proyecto_comandero/core/database/sql_executor.dart';
import 'package:proyecto_comandero/core/errors/app_exception.dart';
import 'package:test/test.dart';

import 'fakes/fake_sql_connection.dart';

/// Política sin esperas para que los tests de reintento sean instantáneos.
const noDelay = TransactionRetryPolicy(
  baseDelay: Duration.zero,
  maxDelay: Duration.zero,
);

void main() {
  late FakeConnectionFactory factory;
  late MysqlDatabase db;

  setUp(() {
    factory = FakeConnectionFactory();
    db = MysqlDatabase(
      testConfig,
      connectionFactory: factory.call,
      retry: noDelay,
      random: Random(1),
    );
  });

  tearDown(() => db.close());

  group('open / close / ping', () {
    test(
      'la conexión es perezosa: no se abre hasta la primera operación',
      () async {
        expect(db.isOpen, isFalse);
        expect(factory.connectCalls, 0);
        await db.ping();
        expect(db.isOpen, isTrue);
        expect(factory.connectCalls, 1);
        expect(factory.current.statements, ['SELECT 1 AS ok']);
      },
    );

    test('open() abre y es idempotente; close() cierra', () async {
      await db.open();
      await db.open();
      expect(factory.connectCalls, 1);
      expect(db.isOpen, isTrue);
      await db.close();
      expect(db.isOpen, isFalse);
      expect(factory.connections.single.closeCalls, 1);
      await db.close();
      expect(factory.connections.single.closeCalls, 1);
    });

    test('tras close() la siguiente operación reabre', () async {
      await db.open();
      await db.close();
      await db.ping();
      expect(factory.connectCalls, 2);
      expect(db.isOpen, isTrue);
    });

    test(
      'ping() lanza DatabaseException si el servidor no devuelve filas',
      () async {
        factory = FakeConnectionFactory(
          configure: (c, _) => c.on('SELECT 1', (_, _) => SqlResult.empty),
        );
        db = MysqlDatabase(testConfig, connectionFactory: factory.call);
        await expectLater(db.ping(), throwsA(isA<DatabaseException>()));
      },
    );

    test('un fallo al conectar se propaga y no deja conexión', () async {
      factory.nextConnectError = const NetworkException('rechazada');
      await expectLater(db.ping(), throwsA(isA<NetworkException>()));
      expect(db.isOpen, isFalse);
      // La siguiente llamada vuelve a intentarlo.
      await db.ping();
      expect(factory.connectCalls, 2);
    });
  });

  group('reconexión', () {
    test(
      'si el servidor cerró el socket se reconecta en la siguiente llamada',
      () async {
        await db.ping();
        factory.current.dropConnection();
        expect(db.isOpen, isFalse);
        await db.ping();
        expect(factory.connectCalls, 2);
        expect(factory.connections[1].statements, ['SELECT 1 AS ok']);
      },
    );

    test('una consulta que pierde la conexión lanza NetworkException y la '
        'siguiente operación reconecta', () async {
      factory = FakeConnectionFactory(
        configure: (c, index) {
          if (index == 0) c.dropConnectionOn('SELECT caer');
        },
      );
      db = MysqlDatabase(testConfig, connectionFactory: factory.call);
      await expectLater(
        db.run((x) => x.execute('SELECT caer')),
        throwsA(isA<NetworkException>()),
      );
      expect(db.isOpen, isFalse);
      await db.ping();
      expect(factory.connectCalls, 2);
      expect(factory.connections[0].closeCalls, 1);
    });
  });

  group('run', () {
    test('devuelve el resultado del cuerpo', () async {
      factory = FakeConnectionFactory(
        configure: (c, _) => c.rowsOn('SELECT n', [
          {'n': 7},
        ]),
      );
      db = MysqlDatabase(testConfig, connectionFactory: factory.call);
      final n = await db.run((x) async {
        final r = await x.execute('SELECT n');
        return r.rows.single['n'];
      });
      expect(n, 7);
    });

    test('serializa: dos run concurrentes no se intercalan', () async {
      final order = <String>[];
      Future<void> work(String tag) => db.run((x) async {
        order.add('$tag:in');
        await x.execute('SELECT $tag');
        await Future<void>.delayed(const Duration(milliseconds: 5));
        await x.execute('SELECT $tag bis');
        order.add('$tag:out');
      });
      await Future.wait([work('a'), work('b'), work('c')]);
      expect(order, ['a:in', 'a:out', 'b:in', 'b:out', 'c:in', 'c:out']);
      expect(factory.current.statements, [
        'SELECT a',
        'SELECT a bis',
        'SELECT b',
        'SELECT b bis',
        'SELECT c',
        'SELECT c bis',
      ]);
    });

    test('un error en un run no bloquea a los siguientes', () async {
      await expectLater(
        db.run((_) async => throw const ValidationException('x')),
        throwsA(isA<ValidationException>()),
      );
      await db.ping();
      expect(db.isOpen, isTrue);
    });

    test('el SqlExecutor no puede usarse fuera del cuerpo', () async {
      late SqlExecutor leaked;
      await db.run((x) async => leaked = x);
      await expectLater(leaked.execute('SELECT 1'), throwsStateError);
    });

    test('la reentrada se detecta en lugar de bloquearse', () async {
      await expectLater(
        db.run((_) => db.run((_) async => 1)),
        throwsStateError,
      );
      await expectLater(
        db.transaction((_) => db.transaction((_) async => 1)),
        throwsStateError,
      );
    });
  });

  group('transaction', () {
    test('camino feliz: START TRANSACTION, cuerpo, COMMIT', () async {
      final value = await db.transaction((tx) async {
        await tx.execute('INSERT INTO t VALUES (:v)', {'v': 1});
        return 'ok';
      });
      expect(value, 'ok');
      expect(factory.current.statements, [
        'START TRANSACTION',
        'INSERT INTO t VALUES (:v)',
        'COMMIT',
      ]);
      expect(factory.current.log[1].params, {'v': 1});
    });

    test('error del cuerpo: ROLLBACK y se relanza sin reintentar', () async {
      var calls = 0;
      await expectLater(
        db.transaction((tx) async {
          calls++;
          await tx.execute('UPDATE t SET a = 1');
          throw const ValidationException('datos malos');
        }),
        throwsA(isA<ValidationException>()),
      );
      expect(calls, 1);
      expect(factory.current.statements, [
        'START TRANSACTION',
        'UPDATE t SET a = 1',
        'ROLLBACK',
      ]);
    });

    test(
      'un DatabaseException no reintentable se relanza tras ROLLBACK',
      () async {
        factory = FakeConnectionFactory(
          configure: (c, _) => c.failOn('INSERT', mysqlError(1062)),
        );
        db = MysqlDatabase(
          testConfig,
          connectionFactory: factory.call,
          retry: noDelay,
        );
        await expectLater(
          db.transaction((tx) => tx.execute('INSERT INTO t VALUES (1)')),
          throwsA(
            isA<DatabaseException>().having((e) => e.errorCode, 'errno', 1062),
          ),
        );
        expect(factory.current.statements, [
          'START TRANSACTION',
          'INSERT INTO t VALUES (1)',
          'ROLLBACK',
        ]);
      },
    );

    test(
      '1213 en el primer intento: ROLLBACK, reintento completo y éxito',
      () async {
        factory = FakeConnectionFactory(
          configure: (c, _) => c.failOnceOn('UPDATE', mysqlError(1213)),
        );
        db = MysqlDatabase(
          testConfig,
          connectionFactory: factory.call,
          retry: noDelay,
        );
        var attempts = 0;
        final result = await db.transaction((tx) async {
          attempts++;
          await tx.execute('UPDATE stocks SET cantidad = 1');
          return attempts;
        });
        expect(result, 2);
        expect(factory.current.statements, [
          'START TRANSACTION',
          'UPDATE stocks SET cantidad = 1',
          'ROLLBACK',
          'START TRANSACTION',
          'UPDATE stocks SET cantidad = 1',
          'COMMIT',
        ]);
      },
    );

    test('1205 también se reintenta', () async {
      factory = FakeConnectionFactory(
        configure: (c, _) => c.failOnceOn('UPDATE', mysqlError(1205)),
      );
      db = MysqlDatabase(
        testConfig,
        connectionFactory: factory.call,
        retry: noDelay,
      );
      await db.transaction((tx) => tx.execute('UPDATE t SET a = 1'));
      expect(
        factory.current.statements.where((s) => s == 'COMMIT'),
        hasLength(1),
      );
      expect(
        factory.current.statements.where((s) => s == 'ROLLBACK'),
        hasLength(1),
      );
    });

    test('agotados los intentos se relanza el último error', () async {
      factory = FakeConnectionFactory(
        configure: (c, _) => c.failOn('UPDATE', mysqlError(1213)),
      );
      db = MysqlDatabase(
        testConfig,
        connectionFactory: factory.call,
        retry: noDelay,
      );
      var attempts = 0;
      await expectLater(
        db.transaction((tx) async {
          attempts++;
          await tx.execute('UPDATE t SET a = 1');
        }),
        throwsA(
          isA<DatabaseException>().having(
            (e) => e.isDeadlock,
            'deadlock',
            isTrue,
          ),
        ),
      );
      expect(attempts, 3);
      expect(
        factory.current.statements.where((s) => s == 'START TRANSACTION'),
        hasLength(3),
      );
      expect(
        factory.current.statements.where((s) => s == 'ROLLBACK'),
        hasLength(3),
      );
      expect(factory.current.statements, isNot(contains('COMMIT')));
    });

    test(
      'fallo de conexión en el COMMIT: outcomeUnknown y sin reintento',
      () async {
        factory = FakeConnectionFactory(
          configure: (c, index) {
            if (index == 0) c.dropConnectionOn('COMMIT');
          },
        );
        db = MysqlDatabase(
          testConfig,
          connectionFactory: factory.call,
          retry: noDelay,
        );
        var attempts = 0;
        await expectLater(
          db.transaction((tx) async {
            attempts++;
            await tx.execute('INSERT INTO diario VALUES (1)');
          }),
          throwsA(
            isA<TransactionException>()
                .having((e) => e.outcomeUnknown, 'outcomeUnknown', isTrue)
                .having((e) => e.isRetryable, 'isRetryable', isFalse),
          ),
        );
        expect(attempts, 1);
        expect(factory.connections[0].statements, [
          'START TRANSACTION',
          'INSERT INTO diario VALUES (1)',
          'COMMIT',
        ]);
        expect(db.isOpen, isFalse);
        // La base sigue utilizable: reconecta.
        await db.ping();
        expect(factory.connectCalls, 2);
      },
    );

    test(
      'si la conexión cae durante el cuerpo no se intenta ROLLBACK',
      () async {
        factory = FakeConnectionFactory(
          configure: (c, index) {
            if (index == 0) c.dropConnectionOn('UPDATE');
          },
        );
        db = MysqlDatabase(
          testConfig,
          connectionFactory: factory.call,
          retry: noDelay,
        );
        await expectLater(
          db.transaction((tx) => tx.execute('UPDATE t SET a = 1')),
          throwsA(isA<NetworkException>()),
        );
        expect(factory.connections[0].statements, [
          'START TRANSACTION',
          'UPDATE t SET a = 1',
        ]);
      },
    );

    test('un error no tipado del cuerpo también hace ROLLBACK', () async {
      await expectLater(
        db.transaction((tx) async {
          await tx.execute('SELECT 1');
          throw StateError('bug');
        }),
        throwsStateError,
      );
      expect(factory.current.statements.last, 'ROLLBACK');
    });

    test('transacciones concurrentes se serializan', () async {
      await Future.wait([
        db.transaction((tx) async {
          await tx.execute('SELECT a');
          await Future<void>.delayed(const Duration(milliseconds: 5));
          await tx.execute('SELECT a bis');
        }),
        db.transaction((tx) => tx.execute('SELECT b')),
      ]);
      expect(factory.current.statements, [
        'START TRANSACTION',
        'SELECT a',
        'SELECT a bis',
        'COMMIT',
        'START TRANSACTION',
        'SELECT b',
        'COMMIT',
      ]);
    });
  });

  group('TransactionRetryPolicy', () {
    test('backoff exponencial acotado con jitter en [0.5, 1]', () {
      const policy = TransactionRetryPolicy(
        baseDelay: Duration(milliseconds: 100),
        maxDelay: Duration(milliseconds: 250),
      );
      final random = Random(42);
      for (var i = 0; i < 50; i++) {
        final d1 = policy.delayFor(1, random).inMilliseconds;
        final d2 = policy.delayFor(2, random).inMilliseconds;
        final d3 = policy.delayFor(3, random).inMilliseconds;
        expect(d1, inInclusiveRange(50, 100));
        expect(d2, inInclusiveRange(100, 200));
        expect(d3, inInclusiveRange(125, 250));
      }
    });

    test('los valores por defecto son 3 intentos, 100 ms y 1 s', () {
      const policy = TransactionRetryPolicy();
      expect(policy.maxAttempts, 3);
      expect(policy.baseDelay, const Duration(milliseconds: 100));
      expect(policy.maxDelay, const Duration(seconds: 1));
    });
  });

  test('TransactionException sin outcomeUnknown conserva isRetryable', () {
    const e = TransactionException('x', errorCode: 1213);
    expect(e.isRetryable, isTrue);
    expect(e.outcomeUnknown, isFalse);
  });
}
