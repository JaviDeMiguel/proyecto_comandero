import 'dart:io';

import 'package:proyecto_comandero/core/database/database.dart';
import 'package:proyecto_comandero/core/errors/app_exception.dart';
import 'package:proyecto_comandero/core/inventory/inventory_models.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

/// Tests contra el SANDBOX de FacturaScripts (nunca la instalación real).
///
/// Se saltan si faltan `TPV_MYSQL_HOST`, `TPV_MYSQL_PORT`, `TPV_MYSQL_USER`,
/// `TPV_MYSQL_PASSWORD` y `TPV_MYSQL_DATABASE`. `TPV_MYSQL_SECURE` (`true`
/// por defecto) activa TLS: con MySQL 8 y `caching_sha2_password`,
/// `mysql_client` solo autentica con TLS.
///
/// Referencias sembradas que se usan: `ARROZ` y `POLLO` (materias primas con
/// stock en `ALG`), `PAELLA` (plato). Todo lo que se escribe se revierte o
/// se borra al final; el stock queda como estaba.
MysqlConfig? configFromEnv() {
  final env = Platform.environment;
  final host = env['TPV_MYSQL_HOST'];
  final port = int.tryParse(env['TPV_MYSQL_PORT'] ?? '');
  final user = env['TPV_MYSQL_USER'];
  final password = env['TPV_MYSQL_PASSWORD'];
  final database = env['TPV_MYSQL_DATABASE'];
  if (host == null ||
      port == null ||
      user == null ||
      password == null ||
      database == null) {
    return null;
  }
  final secure = (env['TPV_MYSQL_SECURE'] ?? 'true').toLowerCase() != 'false';
  return MysqlConfig(
    host: host,
    port: port,
    user: user,
    password: password,
    database: database,
    secure: secure,
  );
}

const almacen = 'ALG';
const materiaPrima = 'ARROZ';
const materiaPrima2 = 'POLLO';
const plato = 'PAELLA';

void main() {
  final config = configFromEnv();
  final skip = config == null
      ? 'Define TPV_MYSQL_HOST/PORT/USER/PASSWORD/DATABASE para ejecutar '
            'los tests de integración MySQL'
      : null;

  group('sandbox MySQL', skip: skip, () {
    late MysqlDatabase db;

    setUpAll(() async {
      db = MysqlDatabase(config!);
      await db.open();
    });

    tearDownAll(() => db.close());

    group('conexión real con mysql_client', () {
      test(
        'con la configuración del entorno responde al ping y tipa valores',
        () async {
          await db.ping();
          final row = await db.run((x) async {
            final r = await x.execute(
              'SELECT 1 AS entero, 1.5 AS decimal_, NULL AS nulo, '
              "'txt' AS texto, CURRENT_TIMESTAMP AS ahora, "
              '@@collation_connection AS collation_connection',
            );
            return r.rows.single;
          });
          expect(row['entero'], 1);
          expect(row['decimal_'], 1.5);
          expect(row['nulo'], isNull);
          expect(row['texto'], 'txt');
          expect(row['ahora'], isA<DateTime>());
          stdout.writeln(
            '[info] collation_connection = ${row['collation_connection']}',
          );
        },
      );

      test('TLS y caching_sha2_password: documenta qué funciona', () async {
        for (final secure in [false, true]) {
          final c = config!.copyWith(secure: secure);
          try {
            final conn = await MysqlClientConnection.connect(c);
            await conn.close();
            stdout.writeln('[info] secure=$secure: conecta');
          } on DatabaseException catch (e) {
            stdout.writeln(
              '[info] secure=$secure: DatabaseException: ${e.message}',
            );
            if (secure) rethrow;
            // Sin TLS, el único fallo aceptable es el del plugin de
            // autenticación que mysql_client solo soporta con TLS.
            expect(e.message, contains('caching_sha2_password'));
          } on NetworkException catch (e) {
            stdout.writeln(
              '[info] secure=$secure: NetworkException: ${e.message}',
            );
            if (secure) rethrow;
            // Un servidor sin TLS activo rechaza el handshake TLS.
          }
        }
      });

      test('booleanos y fechas de tablas reales de FS', () async {
        final info = await StockRepository(db).leerArticulos({materiaPrima});
        expect(info.single.referencia, materiaPrima);
        expect(info.single.nostock, isFalse);
        final row = await db.run((x) async {
          final r = await x.execute(
            'SELECT actualizado, fechaalta, nostock FROM productos '
            'WHERE referencia = :r',
            {'r': materiaPrima},
          );
          return r.rows.single;
        });
        expect(row['nostock'], isA<bool>());
        expect(row['fechaalta'], anyOf(isNull, isA<DateTime>()));
      });

      test(
        'errores del servidor llegan como DatabaseException con errno',
        () async {
          await expectLater(
            db.run((x) => x.execute('SELECT * FROM tabla_que_no_existe_tpv')),
            throwsA(
              isA<DatabaseException>()
                  .having((e) => e.errorCode, 'errno', 1146)
                  .having((e) => e.sqlState, 'sqlState', '42S02'),
            ),
          );
          // La conexión sigue viva tras un error del servidor.
          await db.ping();
        },
      );
    });

    group('esquema tpv_*', () {
      test(
        'inspect lee variantes.referencia y ensure crea las tablas',
        () async {
          final migrator = TpvSchemaMigrator(db);
          final before = await migrator.inspect();
          expect(before.variantesExists, isTrue);
          expect(before.referencia?.hasUniqueIndex, isTrue);
          expect(before.referencia?.columnType.toLowerCase(), 'varchar(30)');
          stdout.writeln(
            '[info] variantes.referencia: ${before.referencia}; '
            'avisos: ${before.warnings}',
          );
          final after = await migrator.ensure();
          expect(after.isComplete, isTrue);
          expect(after.existingTables, {
            'tpv_escandallos',
            'tpv_movimientos_stock',
          });
          // Idempotente.
          final again = await migrator.ensure();
          expect(again.isComplete, isTrue);

          // Las tablas creadas tienen la collation de variantes.referencia.
          final cols = await db.run((x) async {
            final r = await x.execute(
              'SELECT TABLE_NAME, COLUMN_NAME, COLLATION_NAME '
              'FROM information_schema.COLUMNS '
              'WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME IN (:a, :b) '
              'AND COLUMN_NAME IN (:c1, :c2, :c3)',
              {
                'a': 'tpv_escandallos',
                'b': 'tpv_movimientos_stock',
                'c1': 'ref_plato',
                'c2': 'ref_ingrediente',
                'c3': 'referencia',
              },
            );
            return r.rows;
          });
          expect(cols, hasLength(3));
          for (final col in cols) {
            expect(col['COLLATION_NAME'], before.referencia!.collation);
          }
        },
      );

      test('transacción real: ROLLBACK deshace', () async {
        final op = 'IT-TX-${const Uuid().v4()}';
        await expectLater(
          db.transaction((tx) async {
            await tx.execute(
              'INSERT INTO tpv_movimientos_stock (operacion, referencia, '
              'codalmacen, cantidad, motivo, creado) VALUES (:op, :r, :a, 0, '
              ':m, :c)',
              {
                'op': op,
                'r': materiaPrima,
                'a': almacen,
                'm': 'test',
                'c': DateTime.now(),
              },
            );
            throw const ValidationException('abortar');
          }),
          throwsA(isA<ValidationException>()),
        );
        final count = await db.run((x) async {
          final r = await x.execute(
            'SELECT COUNT(*) AS n FROM tpv_movimientos_stock '
            'WHERE operacion = :op',
            {'op': op},
          );
          return r.rows.single['n'];
        });
        expect(count, 0);
      });
    });

    group('EscandalloRepository con FK real', () {
      late EscandalloRepository repo;
      late List<RecetaLinea> snapshot;

      setUpAll(() async {
        repo = EscandalloRepository(db);
        snapshot = await repo.byPlato(plato);
      });

      tearDownAll(() async {
        // Deja la receta del plato como estaba.
        await repo.replacePlato(plato, snapshot);
      });

      test('upsert / byPlato / listAll / delete', () async {
        const linea = RecetaLinea(
          refPlato: plato,
          refIngrediente: materiaPrima,
          cantidadNeta: 0.123,
          mermaPct: 5,
        );
        await repo.upsert(linea);
        expect(await repo.byPlato(plato), contains(linea));
        // Segundo upsert actualiza (clave única plato + ingrediente).
        const linea2 = RecetaLinea(
          refPlato: plato,
          refIngrediente: materiaPrima,
          cantidadNeta: 0.2,
          mermaPct: 10,
        );
        await repo.upsert(linea2);
        final lineas = await repo.byPlato(plato);
        expect(
          lineas.where((l) => l.refIngrediente == materiaPrima).single,
          linea2,
        );
        expect(await repo.listAll(), contains(linea2));
        await repo.delete(plato, materiaPrima);
        expect(
          (await repo.byPlato(plato))
              .where((l) => l.refIngrediente == materiaPrima),
          isEmpty,
        );
      });

      test('replacePlato sustituye la receta en una transacción', () async {
        await repo.replacePlato(plato, const [
          RecetaLinea(
            refPlato: plato,
            refIngrediente: materiaPrima,
            cantidadNeta: 0.12,
          ),
          RecetaLinea(
            refPlato: plato,
            refIngrediente: materiaPrima2,
            cantidadNeta: 0.2,
            mermaPct: 15,
          ),
        ]);
        final lineas = await repo.byPlato(plato);
        expect(lineas.map((l) => l.refIngrediente), [
          materiaPrima,
          materiaPrima2,
        ]);
      });

      test(
        'referencia inexistente -> ValidationException (errno 1452)',
        () async {
          await expectLater(
            repo.upsert(
              const RecetaLinea(
                refPlato: plato,
                refIngrediente: 'NO_EXISTE_TPV_IT',
                cantidadNeta: 1,
              ),
            ),
            throwsA(
              isA<ValidationException>()
                  .having((e) => e.message, 'message', contains('no existe'))
                  .having(
                    (e) => (e.cause! as DatabaseException).errorCode,
                    'errno',
                    1452,
                  ),
            ),
          );
          // replacePlato con una referencia mala no deja nada a medias.
          final antes = await repo.byPlato(plato);
          await expectLater(
            repo.replacePlato(plato, const [
              RecetaLinea(
                refPlato: plato,
                refIngrediente: materiaPrima,
                cantidadNeta: 1,
              ),
              RecetaLinea(
                refPlato: plato,
                refIngrediente: 'NO_EXISTE_TPV_IT',
                cantidadNeta: 1,
              ),
            ]),
            throwsA(isA<ValidationException>()),
          );
          expect(await repo.byPlato(plato), antes);
        },
      );

      test(
        'el CHECK de cantidad del servidor se traduce (errno 3819)',
        () async {
          // Saltando la validación local con SQL directo para probar el CHECK.
          await expectLater(
            db.run(
              (x) => x.execute(
                'INSERT INTO tpv_escandallos (ref_plato, ref_ingrediente, '
                'cantidad, merma) VALUES (:p, :i, 0, 0)',
                {'p': plato, 'i': materiaPrima2},
              ),
            ),
            throwsA(
              isA<DatabaseException>().having(
                (e) => e.errorCode,
                'errno',
                3819,
              ),
            ),
          );
        },
      );
    });

    group('StockRepository.aplicarConsumos sobre materia prima real', () {
      late StockRepository repo;
      final operaciones = <String>[];

      Future<Map<String, Object?>> snapshot(String referencia) =>
          db.run((x) async {
            final stock = await x.execute(
              'SELECT cantidad, reservada, disponible, pterecibir FROM stocks '
              'WHERE codalmacen = :a AND referencia = :r',
              {'a': almacen, 'r': referencia},
            );
            final variante = await x.execute(
              'SELECT v.stockfis AS v_stockfis, p.stockfis AS p_stockfis, '
              'p.actualizado FROM variantes v JOIN productos p '
              'ON p.idproducto = v.idproducto WHERE v.referencia = :r',
              {'r': referencia},
            );
            return {...?stock.firstOrNull, ...variante.rows.single};
          });

      setUpAll(() => repo = StockRepository(db));

      tearDownAll(() async {
        if (operaciones.isEmpty) return;
        await db.run((x) async {
          for (final op in operaciones) {
            await x.execute(
              'DELETE FROM tpv_movimientos_stock WHERE operacion = :op',
              {'op': op},
            );
          }
        });
      });

      test(
        'descuenta, es idempotente y se revierte dejando todo igual',
        () async {
          final op = 'IT-${const Uuid().v4()}';
          operaciones.addAll([op, '$op:anulacion']);
          final antes = await snapshot(materiaPrima);
          expect(
            antes['cantidad'],
            isNotNull,
            reason: 'ARROZ debe tener stock en ALG',
          );
          final cantidad0 = antes['cantidad']! as double;
          final reservada0 = (antes['reservada'] as double?) ?? 0;
          final vStock0 = antes['v_stockfis']! as double;
          final pStock0 = antes['p_stockfis']! as double;
          const q = 0.375;

          final r1 = await repo.aplicarConsumos(
            operacion: op,
            consumos: const [
              ConsumoStock(referencia: materiaPrima, cantidad: 0.125),
              ConsumoStock(referencia: materiaPrima, cantidad: 0.25),
            ],
            codalmacen: almacen,
            motivo: 'test-it',
            origen: 'integration',
          );
          expect(r1.yaAplicada, isFalse);
          expect(r1.avisos, isEmpty);
          final nivel = r1.niveles.single;
          expect(nivel.referencia, materiaPrima);
          expect(nivel.cantidad, closeTo(cantidad0 - q, 1e-9));
          expect(nivel.descripcion, isNotNull);

          final despues = await snapshot(materiaPrima);
          expect(despues['cantidad'], closeTo(cantidad0 - q, 1e-9));
          final disponibleEsperado = (cantidad0 - q - reservada0).clamp(
            0,
            double.infinity,
          );
          expect(despues['disponible'], closeTo(disponibleEsperado, 1e-9));
          expect(despues['v_stockfis'], closeTo(vStock0 - q, 1e-9));
          expect(despues['p_stockfis'], closeTo(pStock0 - q, 1e-9));
          expect(despues['actualizado'], isA<DateTime>());
          expect(despues['pterecibir'], antes['pterecibir']);

          // Idempotencia: misma operación -> yaAplicada y sin cambios.
          final r2 = await repo.aplicarConsumos(
            operacion: op,
            consumos: const [
              ConsumoStock(referencia: materiaPrima, cantidad: q),
            ],
            codalmacen: almacen,
            motivo: 'test-it',
          );
          expect(r2.yaAplicada, isTrue);
          expect(r2.niveles.single.cantidad, closeTo(cantidad0 - q, 1e-9));
          final tras2 = await snapshot(materiaPrima);
          expect(tras2['cantidad'], despues['cantidad']);
          expect(tras2['v_stockfis'], despues['v_stockfis']);

          // Reversión (anulación): cantidad negativa.
          final r3 = await repo.aplicarConsumos(
            operacion: '$op:anulacion',
            consumos: const [
              ConsumoStock(referencia: materiaPrima, cantidad: -q),
            ],
            codalmacen: almacen,
            motivo: 'anulacion',
          );
          expect(r3.yaAplicada, isFalse);
          final final_ = await snapshot(materiaPrima);
          expect(final_['cantidad'], closeTo(cantidad0, 1e-9));
          expect(final_['v_stockfis'], closeTo(vStock0, 1e-9));
          expect(final_['p_stockfis'], closeTo(pStock0, 1e-9));
          expect(
            final_['disponible'],
            closeTo(antes['disponible']! as double, 1e-9),
          );

          // El diario tiene las dos operaciones con el delta con signo.
          final diario = await db.run((x) async {
            final r = await x.execute(
              'SELECT operacion, cantidad FROM tpv_movimientos_stock '
              'WHERE operacion IN (:a, :b) ORDER BY id',
              {'a': op, 'b': '$op:anulacion'},
            );
            return r.rows;
          });
          expect(diario.map((r) => r['cantidad']), [-q, q]);
        },
      );

      test(
        'referencia desconocida: ValidationException y ROLLBACK total',
        () async {
          final op = 'IT-BAD-${const Uuid().v4()}';
          operaciones.add(op);
          final antes = await snapshot(materiaPrima);
          await expectLater(
            repo.aplicarConsumos(
              operacion: op,
              consumos: const [
                ConsumoStock(referencia: materiaPrima, cantidad: 1),
                ConsumoStock(referencia: 'ZZ_NO_EXISTE_TPV', cantidad: 1),
              ],
              codalmacen: almacen,
              motivo: 'test-it',
            ),
            throwsA(isA<ValidationException>()),
          );
          final despues = await snapshot(materiaPrima);
          expect(despues['cantidad'], antes['cantidad']);
          final n = await db.run((x) async {
            final r = await x.execute(
              'SELECT COUNT(*) AS n FROM tpv_movimientos_stock WHERE operacion = :op',
              {'op': op},
            );
            return r.rows.single['n'];
          });
          expect(n, 0, reason: 'el diario también se deshace');
        },
      );

      test(
        'h4: leerConsumosAplicados devuelve lo aplicado y permite revertirlo '
        'exactamente; una operación inexistente no devuelve nada',
        () async {
          final op = 'IT-H4-${const Uuid().v4()}';
          operaciones.addAll([op, '$op:anulacion']);
          expect(await repo.leerConsumosAplicados(op), isEmpty);
          final antes = await snapshot(materiaPrima);
          final cantidad0 = antes['cantidad']! as double;

          await repo.aplicarConsumos(
            operacion: op,
            consumos: const [
              ConsumoStock(referencia: materiaPrima, cantidad: 0.2),
            ],
            codalmacen: almacen,
            motivo: 'test-it',
          );
          final aplicados = await repo.leerConsumosAplicados(op);
          expect(aplicados, {
            almacen: const [
              ConsumoStock(referencia: materiaPrima, cantidad: 0.2),
            ],
          });

          await repo.aplicarConsumos(
            operacion: '$op:anulacion',
            consumos: [
              for (final c in aplicados[almacen]!)
                ConsumoStock(referencia: c.referencia, cantidad: -c.cantidad),
            ],
            codalmacen: almacen,
            motivo: 'anulacion',
          );
          final despues = await snapshot(materiaPrima);
          expect(despues['cantidad'], closeTo(cantidad0, 1e-9));
          expect(await repo.leerConsumosAplicados('$op:anulacion'), {
            almacen: const [
              ConsumoStock(referencia: materiaPrima, cantidad: -0.2),
            ],
          });
        },
      );

      test('producto nostock: se omite con aviso', () async {
        final articulos = await repo.leerArticulos({plato});
        if (articulos.isEmpty || !articulos.single.nostock) {
          markTestSkipped('$plato no es nostock en este sandbox');
          return;
        }
        final op = 'IT-NS-${const Uuid().v4()}';
        operaciones.add(op);
        final r = await repo.aplicarConsumos(
          operacion: op,
          consumos: const [ConsumoStock(referencia: plato, cantidad: 1)],
          codalmacen: almacen,
          motivo: 'test-it',
        );
        expect(r.yaAplicada, isFalse);
        expect(r.niveles, isEmpty);
        expect(r.avisos.single, contains('nostock'));
      });

      test('lecturas: niveles, ofertas y artículos', () async {
        final niveles = await repo.leerNiveles(codalmacen: almacen);
        expect(niveles.map((n) => n.referencia), contains(materiaPrima));
        final conMinimo = await repo.leerNiveles(
          codalmacen: almacen,
          soloConMinimo: true,
        );
        expect(conMinimo.every((n) => n.stockmin > 0), isTrue);
        final ofertas = await repo.leerOfertas({materiaPrima, materiaPrima2});
        stdout.writeln('[info] ofertas: $ofertas');
        for (final o in ofertas) {
          expect(o.codproveedor, isNotEmpty);
        }
        final articulos = await repo.leerArticulos({
          materiaPrima,
          plato,
          'NADA_TPV',
        });
        expect(
          articulos.map((a) => a.referencia),
          containsAll([materiaPrima, plato]),
        );
        expect(articulos.map((a) => a.referencia), isNot(contains('NADA_TPV')));
        stdout.writeln('[info] artículos: $articulos');
      });
    });
  });
}
