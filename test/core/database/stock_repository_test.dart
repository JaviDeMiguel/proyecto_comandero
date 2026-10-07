import 'package:proyecto_comandero/core/database/mysql_database.dart';
import 'package:proyecto_comandero/core/database/repositories/stock_repository.dart';
import 'package:proyecto_comandero/core/database/sql_executor.dart';
import 'package:proyecto_comandero/core/errors/app_exception.dart';
import 'package:proyecto_comandero/core/inventory/inventory_models.dart';
import 'package:test/test.dart';

import 'fakes/fake_sql_connection.dart';

final ahora = DateTime(2026, 10, 7, 13, 45, 10);

/// Simula el catálogo de FS: referencia -> (idproducto, nostock, descripción).
const catalogo = {
  'ARROZ': (id: 11, nostock: false, descripcion: 'Arroz bomba'),
  'POLLO': (id: 12, nostock: false, descripcion: 'Pollo'),
  'PAELLA': (id: 10, nostock: true, descripcion: 'Paella'),
};

/// Conexión falsa que responde a las lecturas de la secuencia de stock.
void programarCatalogo(
  FakeSqlConnection c, {
  Map<String, double> stock = const {},
}) {
  c.on(RegExp('^SELECT v.idproducto, p.nostock, p.descripcion'), (_, params) {
    final entry = catalogo[params['referencia']];
    if (entry == null) return SqlResult.empty;
    return SqlResult(
      rows: [
        {
          'idproducto': entry.id,
          'nostock': entry.nostock,
          'descripcion': entry.descripcion,
        },
      ],
    );
  });
  c.on(RegExp('^SELECT cantidad, reservada, disponible'), (_, params) {
    final cantidad = stock[params['referencia']] ?? 0;
    return SqlResult(
      rows: [
        {
          'cantidad': cantidad,
          'reservada': 0.0,
          'disponible': cantidad < 0 ? 0.0 : cantidad,
          'pterecibir': 0.0,
          'stockmin': 10.0,
          'stockmax': 50.0,
        },
      ],
    );
  });
}

void main() {
  late FakeConnectionFactory factory;
  late MysqlDatabase db;
  late StockRepository repo;

  void build({void Function(FakeSqlConnection c)? extra}) {
    factory = FakeConnectionFactory(
      configure: (c, _) {
        extra?.call(c);
        programarCatalogo(c, stock: {'ARROZ': 24.88, 'POLLO': 7.8});
      },
    );
    db = MysqlDatabase(
      testConfig,
      connectionFactory: factory.call,
      retry: const TransactionRetryPolicy(
        baseDelay: Duration.zero,
        maxDelay: Duration.zero,
      ),
    );
    repo = StockRepository(db, now: () => ahora);
  }

  setUp(build);
  tearDown(() => db.close());

  group('aplicarConsumos: secuencia SQL', () {
    test('una transacción con la secuencia exacta por referencia, en orden '
        'alfabético', () async {
      final result = await repo.aplicarConsumos(
        operacion: 'L-1',
        consumos: const [
          ConsumoStock(referencia: 'POLLO', cantidad: 0.2),
          ConsumoStock(referencia: 'ARROZ', cantidad: 0.12),
        ],
        codalmacen: 'ALG',
        motivo: 'comanda',
        origen: 'mesa 4',
      );

      final log = factory.current.log;
      final statements = factory.current.statements;
      expect(statements.first, 'START TRANSACTION');
      expect(statements.last, 'COMMIT');
      expect(statements, hasLength(2 + 6 * 2));

      // ARROZ primero (orden alfabético), después POLLO.
      for (final (offset, ref, id, delta) in [
        (1, 'ARROZ', 11, -0.12),
        (7, 'POLLO', 12, -0.2),
      ]) {
        final diario = log[offset];
        expect(
          diario.normalized,
          'INSERT INTO tpv_movimientos_stock (operacion, referencia, codalmacen, cantidad, motivo, origen, creado) VALUES (:operacion, :referencia, :codalmacen, :cantidad, :motivo, :origen, :creado)',
        );
        expect(diario.params, {
          'operacion': 'L-1',
          'referencia': ref,
          'codalmacen': 'ALG',
          'cantidad': delta,
          'motivo': 'comanda',
          'origen': 'mesa 4',
          'creado': ahora,
        });

        final resolver = log[offset + 1];
        expect(
          resolver.normalized,
          'SELECT v.idproducto, p.nostock, p.descripcion FROM variantes v JOIN productos p ON p.idproducto = v.idproducto WHERE v.referencia = :referencia',
        );
        expect(resolver.normalized, isNot(contains('FOR UPDATE')));
        expect(resolver.params, {'referencia': ref});

        final upsert = log[offset + 2];
        expect(
          upsert.normalized,
          'INSERT INTO stocks (codalmacen, referencia, idproducto, cantidad, disponible, reservada, pterecibir, stockmin, stockmax) VALUES (:codalmacen, :referencia, :idproducto, ROUND(:delta, 3), GREATEST(0, ROUND(:delta, 3)), 0, 0, 0, 0) ON DUPLICATE KEY UPDATE disponible = GREATEST(0, ROUND(COALESCE(cantidad, 0) + :delta, 3) - COALESCE(reservada, 0)), cantidad = ROUND(COALESCE(cantidad, 0) + :delta, 3)',
        );
        // disponible se asigna ANTES que cantidad.
        expect(
          upsert.normalized.indexOf('UPDATE disponible'),
          lessThan(upsert.normalized.indexOf(', cantidad =')),
        );
        expect(upsert.params, {
          'codalmacen': 'ALG',
          'referencia': ref,
          'idproducto': id,
          'delta': delta,
        });

        final productos = log[offset + 3];
        expect(
          productos.normalized,
          'UPDATE productos SET stockfis = (SELECT ROUND(COALESCE(SUM(s.cantidad), 0), 3) FROM stocks s WHERE s.idproducto = :idproducto), actualizado = :ahora WHERE idproducto = :idproducto',
        );
        expect(productos.params, {'idproducto': id, 'ahora': ahora});

        final variantes = log[offset + 4];
        expect(
          variantes.normalized,
          'UPDATE variantes SET stockfis = (SELECT ROUND(COALESCE(SUM(s.cantidad), 0), 3) FROM stocks s WHERE s.idproducto = :idproducto AND s.referencia = :referencia) WHERE referencia = :referencia',
        );
        expect(variantes.params, {'idproducto': id, 'referencia': ref});

        final nivel = log[offset + 5];
        expect(
          nivel.normalized,
          'SELECT cantidad, reservada, disponible, pterecibir, stockmin, stockmax FROM stocks WHERE codalmacen = :codalmacen AND referencia = :referencia',
        );
        expect(nivel.params, {'codalmacen': 'ALG', 'referencia': ref});
      }

      expect(result.yaAplicada, isFalse);
      expect(result.avisos, isEmpty);
      expect(result.niveles, const [
        NivelStock(
          referencia: 'ARROZ',
          codalmacen: 'ALG',
          cantidad: 24.88,
          disponible: 24.88,
          stockmin: 10,
          stockmax: 50,
          descripcion: 'Arroz bomba',
        ),
        NivelStock(
          referencia: 'POLLO',
          codalmacen: 'ALG',
          cantidad: 7.8,
          disponible: 7.8,
          stockmin: 10,
          stockmax: 50,
          descripcion: 'Pollo',
        ),
      ]);
    });

    test('agrega consumos repetidos y redondea a 3 decimales', () async {
      await repo.aplicarConsumos(
        operacion: 'L-2',
        consumos: const [
          ConsumoStock(referencia: 'ARROZ', cantidad: 0.1),
          ConsumoStock(referencia: 'ARROZ', cantidad: 0.2),
          ConsumoStock(referencia: 'ARROZ', cantidad: 0.0004),
        ],
        codalmacen: 'ALG',
        motivo: 'comanda',
      );
      final diarios = factory.current.log
          .where(
            (s) => s.normalized.startsWith('INSERT INTO tpv_movimientos_stock'),
          )
          .toList();
      expect(diarios, hasLength(1));
      expect(diarios.single.params['cantidad'], -0.3);
      expect(diarios.single.params['origen'], isNull);
      final upsert = factory.current.log.firstWhere(
        (s) => s.normalized.startsWith('INSERT INTO stocks'),
      );
      expect(upsert.params['delta'], -0.3);
    });

    test(
      'cantidad negativa = reversión (delta positivo en el diario)',
      () async {
        await repo.aplicarConsumos(
          operacion: 'L-1:anulacion',
          consumos: const [ConsumoStock(referencia: 'ARROZ', cantidad: -0.12)],
          codalmacen: 'ALG',
          motivo: 'anulacion',
        );
        final diario = factory.current.log[1];
        expect(diario.params['cantidad'], 0.12);
        expect(factory.current.log[3].params['delta'], 0.12);
        expect(factory.current.statements.last, 'COMMIT');
      },
    );

    test(
      '1062 en el diario: ROLLBACK, yaAplicada y sin tocar stocks',
      () async {
        build(
          extra: (c) => c.failOn(
            'INSERT INTO tpv_movimientos_stock',
            mysqlError(1062, 'Duplicate entry'),
          ),
        );
        final result = await repo.aplicarConsumos(
          operacion: 'L-1',
          consumos: const [ConsumoStock(referencia: 'ARROZ', cantidad: 0.12)],
          codalmacen: 'ALG',
          motivo: 'comanda',
        );
        expect(result.yaAplicada, isTrue);
        final statements = factory.current.statements;
        expect(statements.take(3), [
          'START TRANSACTION',
          startsWith('INSERT INTO tpv_movimientos_stock'),
          'ROLLBACK',
        ]);
        expect(statements, isNot(contains(startsWith('INSERT INTO stocks'))));
        expect(statements, isNot(contains(startsWith('UPDATE'))));
        expect(statements, isNot(contains('COMMIT')));
        // Tras el ROLLBACK se leen los niveles actuales fuera de transacción.
        expect(statements.last, startsWith('SELECT s.referencia'));
      },
    );

    test('1062 en la segunda referencia también deshace la primera', () async {
      build(
        extra: (c) {
          c.on('INSERT INTO tpv_movimientos_stock', (_, params) {
            if (params['referencia'] == 'POLLO') throw mysqlError(1062);
            return SqlResult.empty;
          });
        },
      );
      final result = await repo.aplicarConsumos(
        operacion: 'L-3',
        consumos: const [
          ConsumoStock(referencia: 'ARROZ', cantidad: 1),
          ConsumoStock(referencia: 'POLLO', cantidad: 1),
        ],
        codalmacen: 'ALG',
        motivo: 'comanda',
      );
      expect(result.yaAplicada, isTrue);
      final statements = factory.current.statements;
      expect(statements.where((s) => s == 'ROLLBACK'), hasLength(1));
      expect(statements, isNot(contains('COMMIT')));
    });

    test('referencia desconocida: ValidationException y ROLLBACK total', () async {
      await expectLater(
        repo.aplicarConsumos(
          operacion: 'L-4',
          consumos: const [
            ConsumoStock(referencia: 'ARROZ', cantidad: 1),
            ConsumoStock(referencia: 'FANTASMA', cantidad: 1),
          ],
          codalmacen: 'ALG',
          motivo: 'comanda',
        ),
        throwsA(
          isA<ValidationException>().having(
            (e) => e.message,
            'message',
            contains('FANTASMA'),
          ),
        ),
      );
      final statements = factory.current.statements;
      // ARROZ se procesó entero, FANTASMA falló al resolver y todo se deshizo.
      expect(
        statements.where((s) => s.startsWith('INSERT INTO stocks')),
        hasLength(1),
      );
      expect(statements.last, 'ROLLBACK');
      expect(statements, isNot(contains('COMMIT')));
    });

    test(
      'nostock = 1: se omite stocks, se registra en el diario y se avisa',
      () async {
        final result = await repo.aplicarConsumos(
          operacion: 'L-5',
          consumos: const [
            ConsumoStock(referencia: 'PAELLA', cantidad: 1),
            ConsumoStock(referencia: 'ARROZ', cantidad: 0.12),
          ],
          codalmacen: 'ALG',
          motivo: 'comanda',
        );
        expect(result.yaAplicada, isFalse);
        expect(result.avisos.single, contains('PAELLA'));
        expect(result.avisos.single, contains('nostock'));
        expect(result.niveles.map((n) => n.referencia), ['ARROZ']);
        final statements = factory.current.statements;
        expect(
          statements.where(
            (s) => s.startsWith('INSERT INTO tpv_movimientos_stock'),
          ),
          hasLength(2),
        );
        expect(
          statements.where((s) => s.startsWith('INSERT INTO stocks')),
          hasLength(1),
        );
        expect(
          statements.where((s) => s.startsWith('UPDATE productos')),
          hasLength(1),
        );
        expect(statements.last, 'COMMIT');
      },
    );

    test(
      'deadlock 1213 en stocks: reintento de TODA la operación y éxito',
      () async {
        build(
          extra: (c) => c.failOnceOn('INSERT INTO stocks', mysqlError(1213)),
        );
        final result = await repo.aplicarConsumos(
          operacion: 'L-6',
          consumos: const [ConsumoStock(referencia: 'ARROZ', cantidad: 1)],
          codalmacen: 'ALG',
          motivo: 'comanda',
        );
        expect(result.yaAplicada, isFalse);
        final statements = factory.current.statements;
        expect(statements.where((s) => s == 'START TRANSACTION'), hasLength(2));
        expect(statements.where((s) => s == 'ROLLBACK'), hasLength(1));
        expect(
          statements.where(
            (s) => s.startsWith('INSERT INTO tpv_movimientos_stock'),
          ),
          hasLength(2),
        );
        expect(statements.last, 'COMMIT');
      },
    );

    test('sin consumos (o todos a 0) no toca la base de datos', () async {
      final result = await repo.aplicarConsumos(
        operacion: 'L-7',
        consumos: const [
          ConsumoStock(referencia: 'ARROZ', cantidad: 0.0001),
          ConsumoStock(referencia: 'ARROZ', cantidad: -0.0001),
        ],
        codalmacen: 'ALG',
        motivo: 'comanda',
      );
      expect(result.yaAplicada, isFalse);
      expect(result.niveles, isEmpty);
      expect(result.avisos, hasLength(2));
      expect(factory.connectCalls, 0);
    });

    test(
      'valida operacion, codalmacen, motivo, origen y referencias',
      () async {
        Future<void> call({
          String operacion = 'op',
          String codalmacen = 'ALG',
          String motivo = 'm',
          String? origen,
          List<ConsumoStock> consumos = const [
            ConsumoStock(referencia: 'ARROZ', cantidad: 1),
          ],
        }) => repo.aplicarConsumos(
          operacion: operacion,
          consumos: consumos,
          codalmacen: codalmacen,
          motivo: motivo,
          origen: origen,
        );
        final v = throwsA(isA<ValidationException>());
        await expectLater(call(operacion: ''), v);
        await expectLater(call(operacion: 'x' * 65), v);
        await expectLater(call(codalmacen: 'ALGEC'), v);
        await expectLater(call(motivo: 'x' * 21), v);
        await expectLater(call(origen: 'x' * 101), v);
        await expectLater(
          call(consumos: const [ConsumoStock(referencia: '', cantidad: 1)]),
          v,
        );
        await expectLater(
          call(
            consumos: const [
              ConsumoStock(referencia: 'A', cantidad: double.nan),
            ],
          ),
          v,
        );
        expect(factory.connectCalls, 0);
      },
    );
  });

  group('agregarConsumos / round3', () {
    test('agrega, ordena y redondea mitad hacia fuera de cero', () {
      final avisos = <String>[];
      final out = StockRepository.agregarConsumos(const [
        ConsumoStock(referencia: 'B', cantidad: 0.0005),
        ConsumoStock(referencia: 'A', cantidad: 1.0004),
        ConsumoStock(referencia: 'B', cantidad: 1),
        ConsumoStock(referencia: 'C', cantidad: -0.0005),
      ], avisos: avisos);
      expect(out, const [
        ConsumoStock(referencia: 'A', cantidad: 1.0),
        ConsumoStock(referencia: 'B', cantidad: 1.001),
        ConsumoStock(referencia: 'C', cantidad: -0.001),
      ]);
      expect(avisos, isEmpty);
    });

    test('round3', () {
      expect(StockRepository.round3(2.0005), 2.001);
      expect(StockRepository.round3(-2.0005), -2.001);
      expect(StockRepository.round3(0.1 + 0.2), 0.3);
      expect(StockRepository.round3(-0.0), 0);
      expect(StockRepository.round3(24.88), 24.88);
    });
  });

  group('lecturas', () {
    test(
      'leerNiveles: JOIN con variantes y productos, filtros y orden',
      () async {
        build(
          extra: (c) => c.rowsOn('SELECT s.referencia', [
            {
              'referencia': 'ARROZ',
              'codalmacen': 'ALG',
              'cantidad': 25.0,
              'reservada': 1.0,
              'disponible': 24.0,
              'pterecibir': 5.0,
              'stockmin': 10.0,
              'stockmax': 50.0,
              'descripcion': 'Arroz bomba',
            },
          ]),
        );
        final niveles = await repo.leerNiveles(
          codalmacen: 'ALG',
          referencias: {'POLLO', 'ARROZ'},
          soloConMinimo: true,
        );
        expect(
          niveles.single,
          const NivelStock(
            referencia: 'ARROZ',
            codalmacen: 'ALG',
            cantidad: 25,
            reservada: 1,
            disponible: 24,
            pterecibir: 5,
            stockmin: 10,
            stockmax: 50,
            descripcion: 'Arroz bomba',
          ),
        );
        final stmt = factory.current.log.single;
        expect(
          stmt.normalized,
          'SELECT s.referencia, s.codalmacen, s.cantidad, s.reservada, s.disponible, s.pterecibir, s.stockmin, s.stockmax, p.descripcion FROM stocks s JOIN variantes v ON v.referencia = s.referencia JOIN productos p ON p.idproducto = v.idproducto WHERE s.codalmacen = :codalmacen AND s.referencia IN (:r0, :r1) AND s.stockmin > 0 ORDER BY s.referencia',
        );
        expect(stmt.params, {
          'codalmacen': 'ALG',
          'r0': 'ARROZ',
          'r1': 'POLLO',
        });
      },
    );

    test('h4: leerConsumosAplicados devuelve lo registrado en el diario, por '
        'almacén y con signo de consumo', () async {
      build(
        extra: (c) => c.rowsOn('SELECT referencia, codalmacen, cantidad', [
          {'referencia': 'ARROZ', 'codalmacen': 'ALG', 'cantidad': -0.1},
          {'referencia': 'POLLO', 'codalmacen': 'ALG', 'cantidad': '-0.25'},
          {'referencia': 'SAL', 'codalmacen': 'ALG', 'cantidad': 0.0},
          {'referencia': 'ARROZ', 'codalmacen': 'B2', 'cantidad': 0.3},
        ]),
      );
      final aplicados = await repo.leerConsumosAplicados('p1');
      expect(aplicados, {
        'ALG': const [
          ConsumoStock(referencia: 'ARROZ', cantidad: 0.1),
          ConsumoStock(referencia: 'POLLO', cantidad: 0.25),
        ],
        'B2': const [ConsumoStock(referencia: 'ARROZ', cantidad: -0.3)],
      });
      final stmt = factory.current.log.single;
      expect(
        stmt.normalized,
        'SELECT referencia, codalmacen, cantidad FROM tpv_movimientos_stock '
        'WHERE operacion = :operacion ORDER BY codalmacen, referencia',
      );
      expect(stmt.params, {'operacion': 'p1'});
    });

    test(
      'h4: leerConsumosAplicados sin filas devuelve un mapa vacío',
      () async {
        expect(await repo.leerConsumosAplicados('nunca'), isEmpty);
        await expectLater(
          repo.leerConsumosAplicados(''),
          throwsA(isA<ValidationException>()),
        );
      },
    );

    test('leerNiveles sin filtro de referencias ni mínimo', () async {
      await repo.leerNiveles(codalmacen: 'ALG');
      final sql = factory.current.statements.single;
      expect(
        sql,
        endsWith('WHERE s.codalmacen = :codalmacen ORDER BY s.referencia'),
      );
      expect(
        await repo.leerNiveles(codalmacen: 'ALG', referencias: const {}),
        isEmpty,
      );
      expect(factory.current.statements, hasLength(1));
    });

    test(
      'leerOfertas: proveedores activos, neto o precio como respaldo',
      () async {
        build(
          extra: (c) => c.rowsOn('SELECT pp.referencia', [
            {
              'referencia': 'ARROZ',
              'codproveedor': 'PROV1',
              'nombre': 'Arroces SL',
              'precio': 2.0,
              'neto': 1.8,
              'actualizado': DateTime(2026, 1, 2),
            },
            {
              'referencia': 'ARROZ',
              'codproveedor': 'PROV2',
              'nombre': 'Otro',
              'precio': 1.9,
              'neto': 0.0,
              'actualizado': null,
            },
            {
              'referencia': 'POLLO',
              'codproveedor': 'PROV2',
              'nombre': null,
              'precio': null,
              'neto': null,
              'actualizado': null,
            },
          ]),
        );
        final ofertas = await repo.leerOfertas({'POLLO', 'ARROZ'});
        expect(ofertas, [
          OfertaProveedor(
            referencia: 'ARROZ',
            codproveedor: 'PROV1',
            nombreProveedor: 'Arroces SL',
            precioNeto: 1.8,
            actualizado: DateTime(2026, 1, 2),
          ),
          const OfertaProveedor(
            referencia: 'ARROZ',
            codproveedor: 'PROV2',
            nombreProveedor: 'Otro',
            precioNeto: 1.9,
          ),
          const OfertaProveedor(
            referencia: 'POLLO',
            codproveedor: 'PROV2',
            precioNeto: 0,
          ),
        ]);
        final stmt = factory.current.log.single;
        expect(
          stmt.normalized,
          'SELECT pp.referencia, pp.codproveedor, pr.nombre, pp.precio, pp.neto, pp.actualizado FROM productosprov pp JOIN proveedores pr ON pr.codproveedor = pp.codproveedor WHERE pr.fechabaja IS NULL AND pp.referencia IN (:r0, :r1) ORDER BY pp.referencia, pp.codproveedor',
        );
        expect(stmt.params, {'r0': 'ARROZ', 'r1': 'POLLO'});
        expect(await repo.leerOfertas(const {}), isEmpty);
      },
    );

    test(
      'leerArticulos: flags con defectos del modelo cuando son NULL',
      () async {
        build(
          extra: (c) => c.rowsOn('SELECT v.referencia, v.idproducto', [
            {
              'referencia': 'ARROZ',
              'idproducto': 11,
              'descripcion': 'Arroz',
              'nostock': false,
              'ventasinstock': true,
              'secompra': true,
              'sevende': false,
            },
            {
              'referencia': 'NUEVO',
              'idproducto': 99,
              'descripcion': null,
              'nostock': null,
              'ventasinstock': null,
              'secompra': null,
              'sevende': null,
            },
          ]),
        );
        final articulos = await repo.leerArticulos({'ARROZ', 'NUEVO'});
        expect(articulos, const [
          ArticuloStockInfo(
            referencia: 'ARROZ',
            idproducto: 11,
            descripcion: 'Arroz',
            nostock: false,
            ventasinstock: true,
            secompra: true,
            sevende: false,
          ),
          ArticuloStockInfo(
            referencia: 'NUEVO',
            idproducto: 99,
            descripcion: '',
            nostock: false,
            ventasinstock: false,
            secompra: true,
            sevende: true,
          ),
        ]);
        expect(
          factory.current.statements.single,
          'SELECT v.referencia, v.idproducto, p.descripcion, p.nostock, p.ventasinstock, p.secompra, p.sevende FROM variantes v JOIN productos p ON p.idproducto = v.idproducto WHERE v.referencia IN (:r0, :r1) ORDER BY v.referencia',
        );
      },
    );
  });
}
