import 'dart:io';

import 'package:proyecto_comandero/core/database/mysql_database.dart';
import 'package:proyecto_comandero/core/database/schema/tpv_schema.dart';
import 'package:proyecto_comandero/core/database/sql_executor.dart';
import 'package:proyecto_comandero/core/errors/app_exception.dart';
import 'package:test/test.dart';

import 'fakes/fake_sql_connection.dart';

/// Quita comentarios `--`, normaliza espacios y pone en minúsculas para
/// comparar DDL sin depender del formato.
String normalizeSql(String sql) => sql
    .split('\n')
    .where((line) => !line.trimLeft().startsWith('--'))
    .join('\n')
    .replaceAll(RegExp(r'\s+'), ' ')
    .replaceAll(RegExp(r'\s*([(),;])\s*'), r'$1')
    .trim()
    .toLowerCase();

void main() {
  group('TpvSchema', () {
    test('el DDL canónico coincide con sql/tpv_schema.sql', () {
      final file = File('sql/tpv_schema.sql');
      expect(file.existsSync(), isTrue, reason: 'falta sql/tpv_schema.sql');
      final expected = normalizeSql(file.readAsStringSync());
      final generated = normalizeSql(const TpvSchema().script);
      expect(generated, expected);
    });

    test('parametriza charset y collation en columnas de referencia y tabla', () {
      const schema = TpvSchema(charset: 'utf8', collation: 'utf8_bin');
      final ddl = schema.createEscandallos;
      expect(
        ddl,
        contains(
          'ref_plato VARCHAR(30) CHARACTER SET utf8 COLLATE utf8_bin NOT NULL',
        ),
      );
      expect(
        ddl,
        contains(
          'ref_ingrediente VARCHAR(30) CHARACTER SET utf8 COLLATE utf8_bin NOT NULL',
        ),
      );
      expect(
        ddl,
        endsWith('ENGINE=InnoDB DEFAULT CHARSET=utf8 COLLATE=utf8_bin;'),
      );
      expect(
        schema.createMovimientos,
        contains(
          'referencia VARCHAR(30) CHARACTER SET utf8 COLLATE utf8_bin NOT NULL',
        ),
      );
      expect(ddl, isNot(contains('utf8mb4')));
    });

    test(
      'reglas del DESIGN_BRIEF: IF NOT EXISTS, InnoDB, prefijo tpv_, FK',
      () {
        const schema = TpvSchema();
        for (final ddl in schema.statements) {
          expect(ddl, startsWith('CREATE TABLE IF NOT EXISTS tpv_'));
          expect(ddl, contains('ENGINE=InnoDB'));
          expect(ddl, isNot(contains('fs_')));
        }
        final esc = schema.createEscandallos;
        expect(
          esc,
          contains(
            'UNIQUE KEY tpv_uniq_escandallos_plato_ingrediente (ref_plato, ref_ingrediente)',
          ),
        );
        expect(esc, contains('CHECK (cantidad > 0)'));
        expect(esc, contains('CHECK (merma >= 0 AND merma < 100)'));
        expect(
          esc,
          contains(
            'REFERENCES variantes (referencia) ON DELETE CASCADE ON UPDATE CASCADE',
          ),
        );
        expect(
          esc,
          contains(
            'REFERENCES variantes (referencia) ON DELETE RESTRICT ON UPDATE CASCADE',
          ),
        );
        // MySQL 8 (errno 3823) prohíbe este CHECK sobre columnas con cascada.
        expect(esc, isNot(contains('ref_plato <> ref_ingrediente')));
        final mov = schema.createMovimientos;
        expect(
          mov,
          contains(
            'UNIQUE KEY tpv_uniq_movimientos_operacion (operacion, referencia, codalmacen)',
          ),
        );
        expect(mov, isNot(contains('FOREIGN KEY')));
        final names = RegExp(r'(?:CONSTRAINT|KEY) (\w+)')
            .allMatches(esc + mov)
            .map((m) => m.group(1)!)
            .where((n) => n != 'KEY');
        expect(names, isNotEmpty);
        for (final name in names) {
          expect(name, startsWith('tpv_'), reason: name);
        }
      },
    );
  });

  group('TpvSchemaMigrator', () {
    late FakeConnectionFactory factory;
    late MysqlDatabase db;

    /// Programa la conexión falsa con la "instalación" descrita.
    void install({
      required bool variantes,
      String charset = 'utf8mb4',
      String collation = 'utf8mb4_unicode_520_ci',
      String columnType = 'varchar(30)',
      bool unique = true,
      Set<String> existing = const {},
    }) {
      factory = FakeConnectionFactory(
        configure: (c, _) {
          c.rowsOn(
            RegExp('^SELECT COLUMN_TYPE'),
            variantes
                ? [
                    {
                      'COLUMN_TYPE': columnType,
                      'CHARACTER_SET_NAME': charset,
                      'COLLATION_NAME': collation,
                    },
                  ]
                : const [],
          );
          c.on(
            RegExp('^SELECT TABLE_NAME'),
            (_, _) => SqlResult(
              rows: [
                for (final t in existing) {'TABLE_NAME': t},
              ],
            ),
          );
          c.rowsOn(RegExp(r'^SELECT COUNT\(\*\) AS n'), [
            {'n': unique ? 1 : 0},
          ]);
          c.on(RegExp('^CREATE TABLE'), (sql, _) {
            final name = RegExp(r'IF NOT EXISTS (\w+)')
                .firstMatch(sql)!
                .group(1)!;
            existing = {...existing, name};
            return SqlResult.empty;
          });
        },
      );
      db = MysqlDatabase(testConfig, connectionFactory: factory.call);
    }

    tearDown(() => db.close());

    test('inspect en una instalación limpia: sin avisos, sin tablas', () async {
      install(variantes: true);
      final report = await TpvSchemaMigrator(db).inspect();
      expect(report.variantesExists, isTrue);
      expect(
        report.referencia,
        const ReferenciaColumnInfo(
          columnType: 'varchar(30)',
          charset: 'utf8mb4',
          collation: 'utf8mb4_unicode_520_ci',
          hasUniqueIndex: true,
        ),
      );
      expect(report.existingTables, isEmpty);
      expect(report.missingTables, {
        'tpv_escandallos',
        'tpv_movimientos_stock',
      });
      expect(report.isComplete, isFalse);
      expect(report.warnings, isEmpty);
      expect(report.schema.collation, 'utf8mb4_unicode_520_ci');
      // Solo lecturas en information_schema.
      expect(factory.current.statements, isNot(contains(startsWith('CREATE'))));
      final params = factory.current.log.first.params;
      expect(params, {'tabla': 'variantes', 'columna': 'referencia'});
    });

    test('inspect avisa si no existe variantes', () async {
      install(variantes: false);
      final report = await TpvSchemaMigrator(db).inspect();
      expect(report.variantesExists, isFalse);
      expect(report.warnings.single, contains('variantes'));
    });

    test('inspect avisa de collation distinta y ajusta el esquema', () async {
      install(variantes: true, charset: 'utf8', collation: 'utf8_bin');
      final report = await TpvSchemaMigrator(db).inspect();
      expect(report.warnings.single, contains('utf8/utf8_bin'));
      expect(report.schema.charset, 'utf8');
      expect(report.schema.collation, 'utf8_bin');
    });

    test('inspect avisa si referencia no es UNIQUE o cambió de tipo', () async {
      install(variantes: true, unique: false, columnType: 'varchar(50)');
      final report = await TpvSchemaMigrator(db).inspect();
      expect(report.warnings, hasLength(2));
      expect(report.warnings[0], contains('UNIQUE'));
      expect(report.warnings[1], contains('varchar(50)'));
    });

    test(
      'inspect detecta tablas ya creadas (sin distinguir mayúsculas)',
      () async {
        install(variantes: true, existing: {'TPV_ESCANDALLOS'});
        final report = await TpvSchemaMigrator(db).inspect();
        expect(report.existingTables, {'tpv_escandallos'});
        expect(report.missingTables, {'tpv_movimientos_stock'});
      },
    );

    test(
      'ensure crea lo que falta con el DDL ajustado y reinspecciona',
      () async {
        install(variantes: true, charset: 'utf8', collation: 'utf8_bin');
        final report = await TpvSchemaMigrator(db).ensure();
        expect(report.isComplete, isTrue);
        expect(report.existingTables, {
          'tpv_escandallos',
          'tpv_movimientos_stock',
        });
        final creates = factory.current.statements
            .where((s) => s.startsWith('CREATE'))
            .toList();
        expect(creates, hasLength(2));
        expect(
          creates[0],
          startsWith('CREATE TABLE IF NOT EXISTS tpv_escandallos'),
        );
        expect(creates[0], contains('COLLATE utf8_bin'));
        expect(
          creates[1],
          startsWith('CREATE TABLE IF NOT EXISTS tpv_movimientos_stock'),
        );
        expect(creates[1], contains('COLLATE utf8_bin'));
      },
    );

    test('ensure no ejecuta DDL si todo existe', () async {
      install(
        variantes: true,
        existing: {'tpv_escandallos', 'tpv_movimientos_stock'},
      );
      final report = await TpvSchemaMigrator(db).ensure();
      expect(report.isComplete, isTrue);
      expect(factory.current.statements, isNot(contains(startsWith('CREATE'))));
    });

    test('ensure sin variantes -> ConfigException', () async {
      install(variantes: false);
      await expectLater(
        TpvSchemaMigrator(db).ensure(),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains('variantes'),
          ),
        ),
      );
      expect(factory.current.statements, isNot(contains(startsWith('CREATE'))));
    });

    test('ensure sin UNIQUE en referencia -> ConfigException', () async {
      install(variantes: true, unique: false);
      await expectLater(
        TpvSchemaMigrator(db).ensure(),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains('UNIQUE'),
          ),
        ),
      );
    });

    test(
      'un error del servidor al crear se propaga como DatabaseException',
      () async {
        install(variantes: true);
        db = MysqlDatabase(
          testConfig,
          connectionFactory: (config) async {
            final c = await factory.call(config);
            // Regla previa a las del install: manda la primera que coincide.
            return _FailingCreate(c);
          },
        );
        await expectLater(
          TpvSchemaMigrator(db).ensure(),
          throwsA(
            isA<DatabaseException>().having((e) => e.errorCode, 'errno', 1142),
          ),
        );
      },
    );
  });
}

/// Envoltura que hace fallar todo CREATE con 1142 (sin privilegio CREATE).
final class _FailingCreate implements SqlConnection {
  _FailingCreate(this._inner);
  final SqlConnection _inner;

  @override
  Future<void> close() => _inner.close();

  @override
  bool get isOpen => _inner.isOpen;

  @override
  Future<SqlResult> execute(
    String sql, [
    Map<String, Object?> params = const {},
  ]) {
    if (sql.trimLeft().toUpperCase().startsWith('CREATE')) {
      throw mysqlError(1142, 'CREATE command denied');
    }
    return _inner.execute(sql, params);
  }
}
