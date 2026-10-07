import 'package:proyecto_comandero/core/database/mysql_database.dart';
import 'package:proyecto_comandero/core/database/repositories/escandallo_repository.dart';
import 'package:proyecto_comandero/core/errors/app_exception.dart';
import 'package:proyecto_comandero/core/inventory/inventory_models.dart';
import 'package:test/test.dart';

import 'fakes/fake_sql_connection.dart';

const paella = RecetaLinea(
  refPlato: 'PAELLA',
  refIngrediente: 'ARROZ',
  cantidadNeta: 0.12,
  mermaPct: 0,
);

void main() {
  late FakeConnectionFactory factory;
  late MysqlDatabase db;
  late EscandalloRepository repo;

  setUp(() {
    factory = FakeConnectionFactory();
    db = MysqlDatabase(
      testConfig,
      connectionFactory: factory.call,
      retry: const TransactionRetryPolicy(
        baseDelay: Duration.zero,
        maxDelay: Duration.zero,
      ),
    );
    repo = EscandalloRepository(db);
  });

  tearDown(() => db.close());

  Matcher validation(String fragment) => throwsA(
    isA<ValidationException>().having(
      (e) => e.message,
      'message',
      contains(fragment),
    ),
  );

  group('validaciones (antes de tocar la BD)', () {
    test('cantidadNeta debe ser > 0', () async {
      await expectLater(
        repo.upsert(
          const RecetaLinea(
            refPlato: 'A',
            refIngrediente: 'B',
            cantidadNeta: 0,
          ),
        ),
        validation('mayor que 0'),
      );
      await expectLater(
        repo.upsert(
          const RecetaLinea(
            refPlato: 'A',
            refIngrediente: 'B',
            cantidadNeta: -1,
          ),
        ),
        validation('mayor que 0'),
      );
      await expectLater(
        repo.upsert(
          const RecetaLinea(
            refPlato: 'A',
            refIngrediente: 'B',
            cantidadNeta: double.nan,
          ),
        ),
        validation('mayor que 0'),
      );
      expect(factory.connectCalls, 0);
    });

    test('merma en [0, 100)', () async {
      await expectLater(
        repo.upsert(
          const RecetaLinea(
            refPlato: 'A',
            refIngrediente: 'B',
            cantidadNeta: 1,
            mermaPct: 100,
          ),
        ),
        validation('[0, 100)'),
      );
      await expectLater(
        repo.upsert(
          const RecetaLinea(
            refPlato: 'A',
            refIngrediente: 'B',
            cantidadNeta: 1,
            mermaPct: -0.1,
          ),
        ),
        validation('[0, 100)'),
      );
      await repo.upsert(
        const RecetaLinea(
          refPlato: 'A',
          refIngrediente: 'B',
          cantidadNeta: 1,
          mermaPct: 99.9,
        ),
      );
      await repo.upsert(
        const RecetaLinea(refPlato: 'A', refIngrediente: 'B', cantidadNeta: 1),
      );
    });

    test('plato e ingrediente distintos', () async {
      await expectLater(
        repo.upsert(
          const RecetaLinea(
            refPlato: 'A',
            refIngrediente: 'A',
            cantidadNeta: 1,
          ),
        ),
        validation('sí mismo'),
      );
    });

    test('referencias no vacías y de 30 caracteres como máximo', () async {
      await expectLater(
        repo.upsert(
          const RecetaLinea(refPlato: '', refIngrediente: 'A', cantidadNeta: 1),
        ),
        validation('refPlato'),
      );
      await expectLater(
        repo.upsert(
          const RecetaLinea(
            refPlato: 'A',
            refIngrediente: '  ',
            cantidadNeta: 1,
          ),
        ),
        validation('refIngrediente'),
      );
      final larga = 'X' * 31;
      await expectLater(
        repo.upsert(
          RecetaLinea(refPlato: larga, refIngrediente: 'A', cantidadNeta: 1),
        ),
        validation('30 caracteres'),
      );
      await expectLater(repo.byPlato(''), validation('refPlato'));
      await expectLater(repo.delete('A', larga), validation('refIngrediente'));
      await repo.upsert(
        RecetaLinea(refPlato: 'X' * 30, refIngrediente: 'A', cantidadNeta: 1),
      );
      expect(factory.connectCalls, 1);
    });

    test(
      'replacePlato exige que todas las líneas sean del plato y sin repetidos',
      () async {
        await expectLater(
          repo.replacePlato('PAELLA', const [
            RecetaLinea(
              refPlato: 'BRAVAS',
              refIngrediente: 'PATATA',
              cantidadNeta: 1,
            ),
          ]),
          validation('no pertenece'),
        );
        await expectLater(
          repo.replacePlato('PAELLA', const [
            paella,
            RecetaLinea(
              refPlato: 'PAELLA',
              refIngrediente: 'ARROZ',
              cantidadNeta: 2,
            ),
          ]),
          validation('repetido'),
        );
        expect(factory.connectCalls, 0);
      },
    );
  });

  group('SQL', () {
    test(
      'upsert usa INSERT ... ON DUPLICATE KEY UPDATE con parámetros',
      () async {
        await repo.upsert(
          const RecetaLinea(
            refPlato: 'PAELLA',
            refIngrediente: 'POLLO',
            cantidadNeta: 0.2,
            mermaPct: 15,
          ),
        );
        final stmt = factory.current.log.single;
        expect(
          stmt.normalized,
          startsWith(
            'INSERT INTO tpv_escandallos (ref_plato, ref_ingrediente, cantidad, merma) VALUES (:plato, :ingrediente, :cantidad, :merma) ON DUPLICATE KEY UPDATE',
          ),
        );
        expect(stmt.params, {
          'plato': 'PAELLA',
          'ingrediente': 'POLLO',
          'cantidad': 0.2,
          'merma': 15.0,
        });
        // Fuera de transacción: una sola sentencia.
        expect(factory.current.statements, hasLength(1));
      },
    );

    test('listAll y byPlato convierten filas a RecetaLinea', () async {
      factory = FakeConnectionFactory(
        configure: (c, _) => c.rowsOn('SELECT ref_plato', [
          {
            'ref_plato': 'PAELLA',
            'ref_ingrediente': 'ARROZ',
            'cantidad': 0.12,
            'merma': 0.0,
          },
          {
            'ref_plato': 'PAELLA',
            'ref_ingrediente': 'POLLO',
            'cantidad': 0.2,
            'merma': 15.0,
          },
        ]),
      );
      db = MysqlDatabase(testConfig, connectionFactory: factory.call);
      repo = EscandalloRepository(db);
      final all = await repo.listAll();
      expect(all, const [
        paella,
        RecetaLinea(
          refPlato: 'PAELLA',
          refIngrediente: 'POLLO',
          cantidadNeta: 0.2,
          mermaPct: 15,
        ),
      ]);
      expect(
        factory.current.statements.single,
        endsWith('ORDER BY ref_plato, ref_ingrediente'),
      );
      final byPlato = await repo.byPlato('PAELLA');
      expect(byPlato, hasLength(2));
      expect(factory.current.log.last.params, {'plato': 'PAELLA'});
      expect(
        factory.current.statements.last,
        contains('WHERE ref_plato = :plato'),
      );
    });

    test('delete por plato e ingrediente', () async {
      await repo.delete('PAELLA', 'ARROZ');
      final stmt = factory.current.log.single;
      expect(
        stmt.normalized,
        'DELETE FROM tpv_escandallos WHERE ref_plato = :plato AND ref_ingrediente = :ingrediente',
      );
      expect(stmt.params, {'plato': 'PAELLA', 'ingrediente': 'ARROZ'});
    });

    test('replacePlato es transaccional: DELETE + INSERTs + COMMIT', () async {
      await repo.replacePlato('PAELLA', const [
        paella,
        RecetaLinea(
          refPlato: 'PAELLA',
          refIngrediente: 'POLLO',
          cantidadNeta: 0.2,
          mermaPct: 15,
        ),
      ]);
      final statements = factory.current.statements;
      expect(statements, hasLength(5));
      expect(statements[0], 'START TRANSACTION');
      expect(
        statements[1],
        'DELETE FROM tpv_escandallos WHERE ref_plato = :plato',
      );
      expect(statements[2], startsWith('INSERT INTO tpv_escandallos'));
      expect(statements[3], startsWith('INSERT INTO tpv_escandallos'));
      expect(statements[4], 'COMMIT');
      expect(factory.current.log[2].params['ingrediente'], 'ARROZ');
      expect(factory.current.log[3].params['ingrediente'], 'POLLO');
    });

    test('replacePlato con lista vacía solo borra', () async {
      await repo.replacePlato('PAELLA', const []);
      expect(factory.current.statements, [
        'START TRANSACTION',
        'DELETE FROM tpv_escandallos WHERE ref_plato = :plato',
        'COMMIT',
      ]);
    });
  });

  group('errores de integridad del servidor', () {
    test('1452 (FK) -> ValidationException con mensaje útil', () async {
      factory = FakeConnectionFactory(
        configure: (c, _) => c.failOn(
          'INSERT',
          mysqlError(1452, 'Cannot add or update a child row'),
        ),
      );
      db = MysqlDatabase(testConfig, connectionFactory: factory.call);
      repo = EscandalloRepository(db);
      await expectLater(
        repo.upsert(paella),
        validation('no existe en variantes'),
      );
    });

    test('1452 dentro de replacePlato hace ROLLBACK', () async {
      factory = FakeConnectionFactory(
        configure: (c, _) => c.failOn('INSERT', mysqlError(1452)),
      );
      db = MysqlDatabase(testConfig, connectionFactory: factory.call);
      repo = EscandalloRepository(db);
      await expectLater(
        repo.replacePlato('PAELLA', const [paella]),
        validation('no existe'),
      );
      expect(factory.current.statements.last, 'ROLLBACK');
    });

    test('1451 (RESTRICT) -> ValidationException', () async {
      factory = FakeConnectionFactory(
        configure: (c, _) => c.failOn('DELETE', mysqlError(1451)),
      );
      db = MysqlDatabase(testConfig, connectionFactory: factory.call);
      repo = EscandalloRepository(db);
      await expectLater(repo.delete('A', 'B'), validation('en uso'));
    });

    test('3819 (CHECK) -> ValidationException', () async {
      factory = FakeConnectionFactory(
        configure: (c, _) => c.failOn('INSERT', mysqlError(3819)),
      );
      db = MysqlDatabase(testConfig, connectionFactory: factory.call);
      repo = EscandalloRepository(db);
      await expectLater(repo.upsert(paella), validation('fuera de rango'));
    });

    test('otros errores se propagan como DatabaseException', () async {
      factory = FakeConnectionFactory(
        configure: (c, _) =>
            c.failOn('INSERT', mysqlError(1146, 'no such table')),
      );
      db = MysqlDatabase(testConfig, connectionFactory: factory.call);
      repo = EscandalloRepository(db);
      await expectLater(
        repo.upsert(paella),
        throwsA(
          isA<DatabaseException>().having((e) => e.errorCode, 'errno', 1146),
        ),
      );
    });
  });
}
