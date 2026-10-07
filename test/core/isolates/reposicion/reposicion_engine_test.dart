import 'package:proyecto_comandero/core/errors/app_exception.dart';
import 'package:proyecto_comandero/core/isolates/isolate_runner.dart';
import 'package:proyecto_comandero/core/isolates/reposicion/reposicion_engine.dart';
import 'package:test/test.dart';

NivelStock _nivel(
  String referencia, {
  String codalmacen = 'ALG',
  double cantidad = 0,
  double reservada = 0,
  double? disponible,
  double pterecibir = 0,
  double stockmin = 0,
  double stockmax = 0,
  String? descripcion,
}) => NivelStock(
  referencia: referencia,
  codalmacen: codalmacen,
  cantidad: cantidad,
  reservada: reservada,
  disponible: disponible ?? (cantidad - reservada).clamp(0, double.infinity),
  pterecibir: pterecibir,
  stockmin: stockmin,
  stockmax: stockmax,
  descripcion: descripcion,
);

OfertaProveedor _oferta(
  String referencia,
  String codproveedor,
  double precio, {
  DateTime? actualizado,
  String? nombre,
}) => OfertaProveedor(
  referencia: referencia,
  codproveedor: codproveedor,
  nombreProveedor: nombre,
  precioNeto: precio,
  actualizado: actualizado,
);

ReposicionResult _auditar(
  List<NivelStock> niveles, {
  List<OfertaProveedor> ofertas = const [],
  PoliticaReposicion politica = const PoliticaReposicion(),
  Set<String> excluidas = const {},
}) => auditarReposicion(
  ReposicionRequest(
    niveles: niveles,
    ofertas: ofertas,
    politica: politica,
    referenciasExcluidas: excluidas,
  ),
);

Matcher _validacion(Pattern mensaje) => throwsA(
  isA<ValidationException>().having(
    (e) => e.message,
    'message',
    contains(mensaje),
  ),
);

void main() {
  group('detección de roturas', () {
    test('sin roturas: stock por encima del mínimo o sin mínimo', () {
      final r = _auditar(
        [
          _nivel('ARROZ', cantidad: 10, stockmin: 5, stockmax: 20),
          _nivel('SAL', cantidad: 0, stockmin: 0),
          _nivel('AZUCAR', cantidad: 5, stockmin: 5, stockmax: 10),
        ],
        ofertas: [_oferta('ARROZ', 'P1', 1)],
      );
      expect(r.roturas, isEmpty);
      expect(r.pedidos, isEmpty);
      expect(r.sinProveedor, isEmpty);
      expect(r.avisos, isEmpty);
    });

    test('rotura con stockmax: se repone hasta el máximo', () {
      final r = _auditar(
        [
          _nivel(
            'ARROZ',
            cantidad: 2,
            stockmin: 5,
            stockmax: 20,
            descripcion: 'Arroz bomba',
          ),
        ],
        ofertas: [_oferta('ARROZ', 'P1', 1.5, nombre: 'Arrocera SL')],
      );
      expect(r.roturas, [
        const RoturaStock(
          referencia: 'ARROZ',
          descripcion: 'Arroz bomba',
          codalmacen: 'ALG',
          disponible: 2,
          pterecibir: 0,
          stockmin: 5,
          stockmax: 20,
          cantidadNecesaria: 18,
          codproveedor: 'P1',
        ),
      ]);
      expect(r.roturas.single.cobertura, 2);
      expect(r.pedidos, [
        const PedidoPropuesto(
          codproveedor: 'P1',
          nombreProveedor: 'Arrocera SL',
          lineas: [
            LineaPedidoPropuesta(
              referencia: 'ARROZ',
              descripcion: 'Arroz bomba',
              cantidad: 18,
              precioNeto: 1.5,
              importeEstimadoCents: 2700,
            ),
          ],
          importeEstimadoCents: 2700,
        ),
      ]);
      expect(r.sinProveedor, isEmpty);
    });

    test('sin stockmax: objetivo = stockmin × factor (2.0 por defecto)', () {
      final r = _auditar(
        [_nivel('ARROZ', cantidad: 1, stockmin: 5)],
        ofertas: [_oferta('ARROZ', 'P1', 1)],
      );
      // Objetivo 10, cobertura 1 -> 9.
      expect(r.roturas.single.cantidadNecesaria, 9);
      expect(r.avisos, isEmpty);
    });

    test('factor personalizado', () {
      final r = _auditar(
        [_nivel('ARROZ', cantidad: 1, stockmin: 4)],
        ofertas: [_oferta('ARROZ', 'P1', 1)],
        politica: const PoliticaReposicion(factorSinMaximo: 1.5),
      );
      expect(r.roturas.single.cantidadNecesaria, 5);
    });

    test('stockmax no superior al mínimo se trata como sin máximo y avisa', () {
      final r = _auditar(
        [_nivel('ARROZ', cantidad: 1, stockmin: 5, stockmax: 5)],
        ofertas: [_oferta('ARROZ', 'P1', 1)],
      );
      expect(r.roturas.single.cantidadNecesaria, 9);
      expect(r.avisos.single, contains('no supera el mínimo'));
    });

    test('la cobertura con pterecibir evita el pedido', () {
      final r = _auditar(
        [
          _nivel(
            'ARROZ',
            cantidad: 2,
            pterecibir: 3,
            stockmin: 5,
            stockmax: 20,
          ),
        ],
        ofertas: [_oferta('ARROZ', 'P1', 1)],
      );
      expect(r.roturas, isEmpty);
    });

    test('pterecibir parcial reduce la cantidad a pedir', () {
      final r = _auditar(
        [
          _nivel(
            'ARROZ',
            cantidad: 2,
            pterecibir: 2,
            stockmin: 5,
            stockmax: 20,
          ),
        ],
        ofertas: [_oferta('ARROZ', 'P1', 1)],
      );
      // Objetivo 20, cobertura 4 -> 16.
      expect(r.roturas.single.cantidadNecesaria, 16);
      expect(r.roturas.single.pterecibir, 2);
    });

    test('usa disponible, no cantidad: todo reservado es rotura', () {
      final r = _auditar(
        [
          _nivel(
            'ARROZ',
            cantidad: 10,
            reservada: 10,
            stockmin: 5,
            stockmax: 12,
          ),
        ],
        ofertas: [_oferta('ARROZ', 'P1', 1)],
      );
      expect(r.roturas.single.disponible, 0);
      expect(r.roturas.single.cantidadNecesaria, 12);
    });

    test('la rotura justo en el mínimo no se considera rotura', () {
      final r = _auditar([
        _nivel('ARROZ', cantidad: 5, stockmin: 5, stockmax: 20),
      ]);
      expect(r.roturas, isEmpty);
    });

    test('las roturas se ordenan por referencia y almacén', () {
      final r = _auditar([
        _nivel('ZANAHORIA', codalmacen: 'B', cantidad: 0, stockmin: 1),
        _nivel('ARROZ', codalmacen: 'B', cantidad: 0, stockmin: 1),
        _nivel('ARROZ', codalmacen: 'A', cantidad: 0, stockmin: 1),
      ]);
      expect(r.roturas.map((x) => '${x.referencia}@${x.codalmacen}'), [
        'ARROZ@A',
        'ARROZ@B',
        'ZANAHORIA@B',
      ]);
    });
  });

  group('múltiplos de pedido', () {
    test('múltiplo 6 (cajas): redondeo hacia arriba', () {
      final r = _auditar(
        [_nivel('CERVEZA', cantidad: 2, stockmin: 12, stockmax: 15)],
        ofertas: [_oferta('CERVEZA', 'P1', 0.5)],
        politica: const PoliticaReposicion(multiploPedido: 6),
      );
      // Necesita 13 -> 3 cajas = 18.
      expect(r.roturas.single.cantidadNecesaria, 18);
      expect(r.pedidos.single.lineas.single.cantidad, 18);
      expect(r.pedidos.single.lineas.single.importeEstimadoCents, 900);
    });

    test('múltiplo 6 con necesidad exacta no añade una caja de más', () {
      final r = _auditar([
        _nivel('CERVEZA', cantidad: 3, stockmin: 12, stockmax: 15),
      ], politica: const PoliticaReposicion(multiploPedido: 6));
      expect(r.roturas.single.cantidadNecesaria, 12);
    });

    test('múltiplo 0.5', () {
      final r = _auditar([
        _nivel('QUESO', cantidad: 0.3, stockmin: 1, stockmax: 2.1),
      ], politica: const PoliticaReposicion(multiploPedido: 0.5));
      // Necesita 1.8 -> 2.0.
      expect(r.roturas.single.cantidadNecesaria, 2);
    });

    test('múltiplo 0.001 permite cualquier fracción', () {
      final r = _auditar([
        _nivel('AZAFRAN', cantidad: 0.004, stockmin: 0.01, stockmax: 0.05),
      ], politica: const PoliticaReposicion(multiploPedido: 0.001));
      expect(r.roturas.single.cantidadNecesaria, 0.046);
    });

    test('un cociente exacto en coma flotante no suma un múltiplo extra', () {
      // 0.3 / 0.1 = 2.9999999999999996 en IEEE 754.
      final r = _auditar([
        _nivel('X', cantidad: 0, stockmin: 0.2, stockmax: 0.3),
      ], politica: const PoliticaReposicion(multiploPedido: 0.1));
      expect(r.roturas.single.cantidadNecesaria, 0.3);
    });

    test('mínimo un múltiplo aunque la necesidad sea ínfima', () {
      final r = _auditar([
        _nivel('ARROZ', cantidad: 4.999, stockmin: 5, stockmax: 5.0001),
      ], politica: const PoliticaReposicion(multiploPedido: 6));
      expect(r.roturas.single.cantidadNecesaria, 6);
    });
  });

  group('elección de proveedor', () {
    test('gana el precio neto más bajo', () {
      final r = _auditar(
        [_nivel('ARROZ', cantidad: 0, stockmin: 1, stockmax: 10)],
        ofertas: [
          _oferta('ARROZ', 'CARO', 2.0, nombre: 'Caro SA'),
          _oferta('ARROZ', 'BARATO', 1.2, nombre: 'Barato SL'),
          _oferta('ARROZ', 'MEDIO', 1.5),
        ],
      );
      expect(r.roturas.single.codproveedor, 'BARATO');
      expect(r.pedidos.single.codproveedor, 'BARATO');
      expect(r.pedidos.single.nombreProveedor, 'Barato SL');
      expect(r.pedidos.single.lineas.single.precioNeto, 1.2);
      expect(r.pedidos.single.importeEstimadoCents, 1200);
    });

    test('empate de precio: gana la oferta actualizada más recientemente', () {
      final r = _auditar(
        [_nivel('ARROZ', cantidad: 0, stockmin: 1, stockmax: 10)],
        ofertas: [
          _oferta('ARROZ', 'P1', 1, actualizado: DateTime(2026, 1, 10)),
          _oferta('ARROZ', 'P2', 1, actualizado: DateTime(2026, 3, 1)),
          _oferta('ARROZ', 'P3', 1),
        ],
      );
      expect(r.pedidos.single.codproveedor, 'P2');
    });

    test('sin fecha pierde frente a cualquier fecha', () {
      final r = _auditar(
        [_nivel('ARROZ', cantidad: 0, stockmin: 1, stockmax: 10)],
        ofertas: [
          _oferta('ARROZ', 'A', 1),
          _oferta('ARROZ', 'B', 1, actualizado: DateTime(2020)),
        ],
      );
      expect(r.pedidos.single.codproveedor, 'B');
    });

    test('doble empate: gana el codproveedor menor, sea cual sea el orden', () {
      final ofertas = [
        _oferta('ARROZ', 'P9', 1, actualizado: DateTime(2026)),
        _oferta('ARROZ', 'P2', 1, actualizado: DateTime(2026)),
      ];
      expect(
        _auditar([
          _nivel('ARROZ', cantidad: 0, stockmin: 1),
        ], ofertas: ofertas).pedidos.single.codproveedor,
        'P2',
      );
      expect(
        _auditar([
          _nivel('ARROZ', cantidad: 0, stockmin: 1),
        ], ofertas: ofertas.reversed.toList()).pedidos.single.codproveedor,
        'P2',
      );
    });

    test('sin proveedor: la rotura va a sinProveedor y no se pide', () {
      final r = _auditar(
        [
          _nivel('ARROZ', cantidad: 0, stockmin: 1, stockmax: 10),
          _nivel('SAL', cantidad: 0, stockmin: 1, stockmax: 10),
        ],
        ofertas: [_oferta('OTRA_COSA', 'P1', 1), _oferta('SAL', 'P1', 0.2)],
      );
      expect(r.roturas, hasLength(2));
      expect(r.sinProveedor.single.referencia, 'ARROZ');
      expect(r.sinProveedor.single.codproveedor, isNull);
      expect(r.pedidos.single.lineas.single.referencia, 'SAL');
    });

    test('precio cero es válido (muestras gratuitas)', () {
      final r = _auditar(
        [_nivel('ARROZ', cantidad: 0, stockmin: 1, stockmax: 10)],
        ofertas: [_oferta('ARROZ', 'P1', 0)],
      );
      expect(r.pedidos.single.importeEstimadoCents, 0);
    });
  });

  group('agrupación de pedidos', () {
    test('varias referencias del mismo proveedor, ordenadas', () {
      final r = _auditar(
        [
          _nivel('ZANAHORIA', cantidad: 0, stockmin: 2, stockmax: 5),
          _nivel('ARROZ', cantidad: 0, stockmin: 1, stockmax: 10),
          _nivel('LECHE', cantidad: 0, stockmin: 6, stockmax: 12),
        ],
        ofertas: [
          _oferta('ZANAHORIA', 'VERD', 0.8, nombre: 'Verduras'),
          _oferta('ARROZ', 'VERD', 1.1),
          _oferta('LECHE', 'LACT', 0.95, nombre: 'Lácteos'),
          _oferta('LECHE', 'VERD', 1.3),
        ],
      );
      expect(r.pedidos.map((p) => p.codproveedor), ['LACT', 'VERD']);
      final verd = r.pedidos.last;
      expect(verd.nombreProveedor, 'Verduras');
      expect(verd.lineas.map((l) => l.referencia), ['ARROZ', 'ZANAHORIA']);
      expect(verd.lineas.map((l) => l.importeEstimadoCents), [1100, 400]);
      expect(verd.importeEstimadoCents, 1500);
      expect(r.pedidos.first.importeEstimadoCents, 1140);
    });

    test('el importe de línea se redondea al céntimo (mitad hacia fuera)', () {
      final r = _auditar(
        [_nivel('X', cantidad: 0, stockmin: 1, stockmax: 3)],
        ofertas: [_oferta('X', 'P1', 0.335)],
      );
      // 3 × 0.335 = 1.005 -> 101 céntimos (no 100).
      expect(r.pedidos.single.importeEstimadoCents, 101);
    });

    test(
      'misma referencia rota en dos almacenes: una línea sumada y aviso',
      () {
        final r = _auditar(
          [
            _nivel(
              'ARROZ',
              codalmacen: 'A',
              cantidad: 0,
              stockmin: 1,
              stockmax: 4,
            ),
            _nivel(
              'ARROZ',
              codalmacen: 'B',
              cantidad: 1,
              stockmin: 2,
              stockmax: 7,
            ),
          ],
          ofertas: [_oferta('ARROZ', 'P1', 1)],
        );
        expect(r.roturas, hasLength(2));
        expect(r.pedidos.single.lineas.single.cantidad, 10);
        expect(r.avisos.single, contains('varios almacenes (A, B)'));
      },
    );
  });

  group('política', () {
    test('referencias excluidas no se auditan', () {
      final r = _auditar(
        [
          _nivel('ARROZ', cantidad: 0, stockmin: 1),
          _nivel('SAL', cantidad: 0, stockmin: 1),
        ],
        ofertas: [_oferta('ARROZ', 'P1', 1)],
        excluidas: {'ARROZ'},
      );
      expect(r.roturas.single.referencia, 'SAL');
      expect(r.pedidos, isEmpty);
    });

    test('incluirSinMinimo: solo el stock negativo sin mínimo es rotura', () {
      final niveles = [
        _nivel('NEG', cantidad: -3, disponible: -3, stockmin: 0),
        _nivel('CERO', cantidad: 0, stockmin: 0),
        _nivel('NEG_PEDIDO', cantidad: -2, disponible: -2, pterecibir: 2),
      ];
      expect(_auditar(niveles).roturas, isEmpty);

      final r = _auditar(
        niveles,
        politica: const PoliticaReposicion(incluirSinMinimo: true),
        ofertas: [_oferta('NEG', 'P1', 1)],
      );
      expect(r.roturas.single.referencia, 'NEG');
      // Objetivo 0 × factor = 0; cobertura -3 -> pedir 3.
      expect(r.roturas.single.cantidadNecesaria, 3);
      expect(r.pedidos.single.lineas.single.cantidad, 3);
    });

    test('valores por defecto de la política', () {
      const politica = PoliticaReposicion();
      expect(politica.factorSinMaximo, 2.0);
      expect(politica.multiploPedido, 1.0);
      expect(politica.incluirSinMinimo, isFalse);
      expect(
        const ReposicionRequest(niveles: [], ofertas: []).politica,
        politica,
      );
    });
  });

  group('validaciones', () {
    test('factor no positivo', () {
      expect(
        () => _auditar(
          const [],
          politica: const PoliticaReposicion(factorSinMaximo: 0),
        ),
        _validacion('factorSinMaximo inválido (0.0)'),
      );
      expect(
        () => _auditar(
          const [],
          politica: const PoliticaReposicion(factorSinMaximo: -1),
        ),
        _validacion('factorSinMaximo'),
      );
    });

    test('múltiplo no positivo o por debajo de la precisión de stock', () {
      expect(
        () => _auditar(
          const [],
          politica: const PoliticaReposicion(multiploPedido: 0),
        ),
        _validacion('multiploPedido inválido (0.0)'),
      );
      expect(
        () => _auditar(
          const [],
          politica: const PoliticaReposicion(multiploPedido: 0.0001),
        ),
        _validacion('al menos 0.001'),
      );
    });

    test('niveles duplicados (misma referencia y almacén)', () {
      expect(
        () => _auditar([
          _nivel('ARROZ', codalmacen: 'A'),
          _nivel('ARROZ', codalmacen: 'B'),
          _nivel('ARROZ', codalmacen: 'A'),
        ]),
        _validacion('Nivel de stock duplicado: ARROZ en A'),
      );
    });

    test('referencia o almacén vacíos', () {
      expect(() => _auditar([_nivel('')]), _validacion('referencia vacía'));
      expect(
        () => _auditar([_nivel('ARROZ', codalmacen: ' ')]),
        _validacion('almacén vacío'),
      );
    });

    test('mínimo negativo y valores no finitos', () {
      expect(
        () => _auditar([_nivel('ARROZ', stockmin: -1)]),
        _validacion('Mínimo/máximo de ARROZ en ALG negativos'),
      );
      expect(
        () => _auditar([_nivel('ARROZ', pterecibir: double.nan)]),
        _validacion('pterecibir de ARROZ en ALG no es un número finito'),
      );
    });

    test('ofertas inválidas', () {
      expect(
        () => _auditar(const [], ofertas: [_oferta('', 'P1', 1)]),
        _validacion('Oferta del proveedor P1 con referencia vacía'),
      );
      expect(
        () => _auditar(const [], ofertas: [_oferta('ARROZ', '', 1)]),
        _validacion('código de proveedor vacío'),
      );
      expect(
        () => _auditar(const [], ofertas: [_oferta('ARROZ', 'P1', -0.5)]),
        _validacion('Precio neto de ARROZ en P1 inválido (-0.5)'),
      );
    });
  });

  group('propiedades', () {
    final niveles = [
      for (var i = 0; i < 40; i++)
        _nivel(
          'REF${i.toString().padLeft(2, '0')}',
          codalmacen: i % 5 == 0 ? 'B' : 'A',
          cantidad: i % 7 * 1.5,
          reservada: i % 3 == 0 ? 1 : 0,
          pterecibir: i % 4 == 0 ? 2 : 0,
          stockmin: i % 6 == 0 ? 0 : 5,
          stockmax: i % 2 == 0 ? 12 : 0,
        ),
    ];
    final ofertas = [
      for (var i = 0; i < 40; i += 3)
        _oferta('REF${i.toString().padLeft(2, '0')}', 'P${i % 4}', 1 + i / 10),
      for (var i = 0; i < 40; i += 5)
        _oferta('REF${i.toString().padLeft(2, '0')}', 'P9', 0.5),
    ];

    test(
      'toda rotura está en pedidos o en sinProveedor exactamente una vez',
      () {
        final r = _auditar(niveles, ofertas: ofertas);
        expect(r.roturas, isNotEmpty);
        expect(r.sinProveedor, isNotEmpty);
        expect(r.pedidos, isNotEmpty);

        final enPedidos = <String>[
          for (final p in r.pedidos)
            for (final l in p.lineas) l.referencia,
        ];
        final enSinProveedor = r.sinProveedor.map((x) => x.referencia).toList();
        expect(enPedidos.toSet().length, enPedidos.length);
        expect(enSinProveedor.toSet().length, enSinProveedor.length);
        expect(enPedidos.toSet().intersection(enSinProveedor.toSet()), isEmpty);
        expect({
          ...enPedidos,
          ...enSinProveedor,
        }, r.roturas.map((x) => x.referencia).toSet());
        for (final rotura in r.roturas) {
          expect(
            rotura.codproveedor == null,
            enSinProveedor.contains(rotura.referencia),
          );
        }
      },
    );

    test('invariantes: cantidades positivas, múltiplos, orden e importes', () {
      final r = _auditar(
        niveles,
        ofertas: ofertas,
        politica: const PoliticaReposicion(multiploPedido: 0.5),
      );
      for (final rotura in r.roturas) {
        expect(rotura.cantidadNecesaria, greaterThan(0));
        expect(
          (rotura.cantidadNecesaria * 2) % 1,
          0,
          reason: 'múltiplo de 0.5',
        );
        expect(rotura.cobertura, lessThan(rotura.stockmin));
      }
      final codigos = r.pedidos.map((p) => p.codproveedor).toList();
      expect(codigos, [...codigos]..sort());
      for (final pedido in r.pedidos) {
        final refs = pedido.lineas.map((l) => l.referencia).toList();
        expect(refs, [...refs]..sort());
        expect(
          pedido.importeEstimadoCents,
          pedido.lineas.fold(0, (s, l) => s + l.importeEstimadoCents),
        );
      }
    });

    test('determinismo e independencia del orden de entrada', () {
      final a = _auditar(niveles, ofertas: ofertas);
      final b = _auditar(
        niveles.reversed.toList(),
        ofertas: ofertas.reversed.toList(),
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });
  });

  group('isolates', () {
    test('ejecuta en un isolate real', () async {
      final request = ReposicionRequest(
        niveles: [
          for (var i = 0; i < 2000; i++)
            _nivel('R$i', cantidad: i % 10 * 1.0, stockmin: 5, stockmax: 20),
        ],
        ofertas: [
          for (var i = 0; i < 2000; i += 2)
            _oferta(
              'R$i',
              'P${i % 7}',
              1 + i % 13 / 10,
              actualizado: DateTime(2026),
            ),
        ],
        politica: const PoliticaReposicion(multiploPedido: 6),
      );
      final r = await auditarReposicionEnIsolate(request);
      expect(r, auditarReposicion(request));
      expect(r.roturas, hasLength(1000));
      expect(r.pedidos, hasLength(7));
      // Roturas: i % 10 < 5; con oferta solo las de i par -> {0, 2, 4}.
      expect(r.sinProveedor, hasLength(400));
    });

    test('los errores de validación atraviesan el isolate real', () async {
      await expectLater(
        auditarReposicionEnIsolate(
          ReposicionRequest(
            niveles: [_nivel('ARROZ'), _nivel('ARROZ')],
            ofertas: const [],
          ),
        ),
        _validacion('duplicado'),
      );
    });

    test(
      'con InlineIsolateRunner devuelve lo mismo que la función pura',
      () async {
        final request = ReposicionRequest(
          niveles: [_nivel('ARROZ', cantidad: 0, stockmin: 1, stockmax: 10)],
          ofertas: [_oferta('ARROZ', 'P1', 1)],
        );
        final r = await auditarReposicionEnIsolate(
          request,
          runner: const InlineIsolateRunner(),
        );
        expect(r, auditarReposicion(request));
      },
    );
  });
}
