import 'dart:math';

import 'package:proyecto_comandero/core/errors/app_exception.dart';
import 'package:proyecto_comandero/core/fiscal/fs_totales_calculator.dart';
import 'package:test/test.dart';

void main() {
  group('roundFs', () {
    test('redondea como round() de PHP', () {
      expect(roundFs(1.005, 2), 1.01);
      expect(roundFs(2.675, 2), 2.68);
      expect(roundFs(0.285, 2), 0.29);
      expect(roundFs(-1.005, 2), -1.01);
      expect(roundFs(6.04548, 2), 6.05);
      expect(roundFs(0.604548, 2), 0.60);
      expect(roundFs(0.950004, 2), 0.95);
      expect(roundFs(0.863636363, 5), 0.86364);
      expect(roundFs(3, 2), 3.0);
    });

    test('rechaza valores no finitos y decimales fuera de rango', () {
      expect(() => roundFs(double.nan, 2), throwsArgumentError);
      expect(() => roundFs(1, -1), throwsArgumentError);
    });
  });

  group('conversiones de PVP', () {
    test('neto con 5 decimales desde el PVP con IVA', () {
      expect(pvpUnitarioDesdePvpConIva(95, 10), 0.86364);
      expect(pvpUnitarioDesdePvpConIva(1200, 10), 10.90909);
      expect(pvpUnitarioDesdePvpConIva(100, 21), 0.82645);
      expect(pvpUnitarioDesdePvpConIva(500, 0), 5.0);
    });

    test('PVP con IVA en céntimos desde el neto', () {
      expect(pvpConIvaCents(0.86364, 10), 95);
      expect(pvpConIvaCents(10.90909, 10), 1200);
      expect(pvpConIvaCents(0.82645, 21), 100);
    });
  });

  group('calcularTotalesFs (ejemplos verificados del informe)', () {
    test('ejemplo 1: 7 uds a 0.86364 al 10 %', () {
      final totales = calcularTotalesFs(const [
        LineaCalculo(cantidad: 7, pvpunitario: 0.86364, ivaPct: 10),
      ]);
      expect(totales.netoCents, 605);
      expect(totales.totalIvaCents, 60);
      expect(totales.totalCents, 665);
      expect(totales.grupos, hasLength(1));
      expect(totales.grupos.single.netoCents, 605);
      expect(totales.grupos.single.cuotaIvaCents, 60);
    });

    test('ejemplo 2: tres líneas, dos tipos de IVA y descuento de línea', () {
      final totales = calcularTotalesFs(const [
        LineaCalculo(cantidad: 2, pvpunitario: 4.54545, ivaPct: 10),
        LineaCalculo(
          cantidad: 1,
          pvpunitario: 12.39669,
          ivaPct: 21,
          dtopor: 10,
        ),
        LineaCalculo(cantidad: 3, pvpunitario: 1.36364, ivaPct: 10),
      ]);
      expect(totales.grupos.map((g) => g.ivaPct), [10, 21]);
      expect(totales.grupos[0].netoCents, 1318);
      expect(totales.grupos[0].cuotaIvaCents, 132);
      expect(totales.grupos[1].netoCents, 1116);
      expect(totales.grupos[1].cuotaIvaCents, 234);
      expect(totales.netoCents, 2434);
      expect(totales.netoSinDtoCents, 2434);
      expect(totales.totalIvaCents, 366);
      expect(totales.totalCents, 2800);
    });

    test('ejemplo 3: descuento global de cabecera del 10 %', () {
      final totales = calcularTotalesFs(const [
        LineaCalculo(cantidad: 3, pvpunitario: 0.86364, ivaPct: 10),
        LineaCalculo(cantidad: 1, pvpunitario: 2.47934, ivaPct: 21),
      ], dtopor1: 10);
      expect(totales.netoCents, 456);
      expect(totales.netoSinDtoCents, 507);
      expect(totales.totalIvaCents, 70);
      expect(totales.totalCents, 526);
    });

    test('ejemplo 4: IRPF y recargo de equivalencia', () {
      final totales = calcularTotalesFs(const [
        LineaCalculo(
          cantidad: 1,
          pvpunitario: 100,
          ivaPct: 21,
          recargoPct: 5.2,
          irpfPct: 15,
        ),
      ], dtopor1: 5);
      expect(totales.netoCents, 9500);
      expect(totales.totalIvaCents, 1995);
      expect(totales.totalRecargoCents, 494);
      expect(totales.totalIrpfCents, 1425);
      expect(totales.totalCents, 10564);
    });
  });

  group('método price-adjusted', () {
    test('coincide con classic en el ejemplo 1', () {
      final totales = calcularTotalesFs(const [
        LineaCalculo(cantidad: 7, pvpunitario: 0.86364, ivaPct: 10),
      ], metodo: MetodoIva.priceAdjusted);
      expect(totales.totalIvaCents, 60);
      expect(totales.totalCents, 665);
      expect(totales.metodo, MetodoIva.priceAdjusted);
    });

    test('redondea por línea: 3 uds de un PVP de 0,95 € al 4 %', () {
      // Neto 0.91346; con IVA 0.950 (round 0.95). classic: neto 2.74,
      // iva 0.1096 -> 0.11, total 2.85. price-adjusted: iva = 2.85 - 2.74
      // = 0.11 tambien. Se comprueba un caso que si difiere:
      // 13 uds a 0.11538 (PVP 0.12 al 4 %).
      final classic = calcularTotalesFs(const [
        LineaCalculo(cantidad: 13, pvpunitario: 0.11538, ivaPct: 4),
      ]);
      final adjusted = calcularTotalesFs(const [
        LineaCalculo(cantidad: 13, pvpunitario: 0.11538, ivaPct: 4),
      ], metodo: MetodoIva.priceAdjusted);
      // classic: neto 1.49994 -> 1.50; iva 0.0599976 -> 0.06; total 1.56
      expect(classic.netoCents, 150);
      expect(classic.totalIvaCents, 6);
      expect(classic.totalCents, 156);
      // price-adjusted: pvp_iva 0.12; conIva 1.56; iva = 1.56 - 1.50 = 0.06
      expect(adjusted.totalCents, 156);

      // Caso en el que difieren: 1 ud a 0.82645 al 21 % (PVP 1,00).
      final c = calcularTotalesFs(const [
        LineaCalculo(cantidad: 1, pvpunitario: 0.82645, ivaPct: 21),
      ]);
      final p = calcularTotalesFs(const [
        LineaCalculo(cantidad: 1, pvpunitario: 0.82645, ivaPct: 21),
      ], metodo: MetodoIva.priceAdjusted);
      // classic: neto 0.83, iva round(0.1735545) = 0.17, total 1.00
      expect(c.totalCents, 100);
      // price-adjusted: pvp_iva 1.00; iva = 1.00 - 0.83 = 0.17 -> total 1.00
      expect(p.totalCents, 100);
      expect(p.totalIvaCents, c.totalIvaCents);
    });

    test('parse del ajuste', () {
      expect(MetodoIva.parse('price-adjusted'), MetodoIva.priceAdjusted);
      expect(MetodoIva.parse('classic'), MetodoIva.classic);
      expect(MetodoIva.parse(null), MetodoIva.classic);
      expect(MetodoIva.parse('otro'), MetodoIva.classic);
    });
  });

  group('casos especiales', () {
    test('sin líneas', () {
      final totales = calcularTotalesFs(const []);
      expect(totales.totalCents, 0);
      expect(totales.grupos, isEmpty);
    });

    test('las líneas con importe cero se ignoran', () {
      final totales = calcularTotalesFs(const [
        LineaCalculo(cantidad: 0, pvpunitario: 10, ivaPct: 10),
        LineaCalculo(cantidad: 2, pvpunitario: 0, ivaPct: 21),
        LineaCalculo(cantidad: 1, pvpunitario: 1, ivaPct: 10, dtopor: 100),
      ]);
      expect(totales.grupos, isEmpty);
      expect(totales.totalCents, 0);
    });

    test('suplidos no llevan IVA', () {
      final totales = calcularTotalesFs(const [
        LineaCalculo(cantidad: 1, pvpunitario: 10, ivaPct: 21),
        LineaCalculo(cantidad: 1, pvpunitario: 5, ivaPct: 21, suplido: true),
      ]);
      expect(totales.netoCents, 1000);
      expect(totales.totalIvaCents, 210);
      expect(totales.totalSuplidosCents, 500);
      expect(totales.totalCents, 1710);
    });

    test('cantidades negativas (rectificativa)', () {
      final totales = calcularTotalesFs(const [
        LineaCalculo(cantidad: -7, pvpunitario: 0.86364, ivaPct: 10),
      ]);
      expect(totales.netoCents, -605);
      expect(totales.totalIvaCents, -60);
      expect(totales.totalCents, -665);
    });

    test('grupos ordenados por IVA y recargo', () {
      final totales = calcularTotalesFs(const [
        LineaCalculo(cantidad: 1, pvpunitario: 1, ivaPct: 21, recargoPct: 5.2),
        LineaCalculo(cantidad: 1, pvpunitario: 1, ivaPct: 10),
        LineaCalculo(cantidad: 1, pvpunitario: 1, ivaPct: 21),
        LineaCalculo(cantidad: 1, pvpunitario: 1, ivaPct: 4),
      ]);
      expect(totales.grupos.map((g) => '${g.ivaPct}|${g.recargoPct}'), [
        '4.0|0.0',
        '10.0|0.0',
        '21.0|0.0',
        '21.0|5.2',
      ]);
    });

    test('el codimpuesto del grupo es el de la primera línea', () {
      final totales = calcularTotalesFs(const [
        LineaCalculo(
          cantidad: 1,
          pvpunitario: 1,
          ivaPct: 10,
          codimpuesto: 'IVA10',
        ),
        LineaCalculo(cantidad: 1, pvpunitario: 1, ivaPct: 10),
      ]);
      expect(totales.grupos.single.codimpuesto, 'IVA10');
    });

    test('muchas líneas no acumulan error', () {
      final lineas = [
        for (var i = 0; i < 1000; i++)
          const LineaCalculo(cantidad: 1, pvpunitario: 0.86364, ivaPct: 10),
      ];
      final totales = calcularTotalesFs(lineas);
      // 1000 x 0.86364 = 863.64 ; IVA 86.364 -> 86.36 ; total 950.00
      expect(totales.netoCents, 86364);
      expect(totales.totalIvaCents, 8636);
      expect(totales.totalCents, 95000);
    });

    test('validaciones', () {
      expect(
        () => calcularTotalesFs(const [
          LineaCalculo(cantidad: 1, pvpunitario: 1, ivaPct: -1),
        ]),
        throwsA(isA<ValidationException>()),
      );
      expect(
        () => calcularTotalesFs(const [
          LineaCalculo(cantidad: 1, pvpunitario: 1, ivaPct: 10, dtopor: 101),
        ]),
        throwsA(isA<ValidationException>()),
      );
      expect(
        () => calcularTotalesFs(const [
          LineaCalculo(cantidad: double.nan, pvpunitario: 1, ivaPct: 10),
        ]),
        throwsA(isA<ValidationException>()),
      );
      expect(
        () => calcularTotalesFs(const [], dtopor1: -5),
        throwsA(isA<ValidationException>()),
      );
      expect(
        () => calcularTotalesFs(const [], decimales: 9),
        throwsA(isA<ValidationException>()),
      );
    });
  });

  group('propiedades', () {
    test(
      'total == neto + iva + recargo + suplidos - irpf y suma de grupos',
      () {
        final random = Random(20261006);
        for (var i = 0; i < 300; i++) {
          final lineas = [
            for (var j = 0; j < 1 + random.nextInt(6); j++)
              LineaCalculo(
                cantidad: 1 + random.nextInt(9).toDouble(),
                pvpunitario: roundFs(random.nextDouble() * 20, 5),
                ivaPct: [4.0, 10.0, 21.0][random.nextInt(3)],
                dtopor: [0.0, 5.0, 10.0][random.nextInt(3)],
                recargoPct: random.nextInt(10) == 0 ? 5.2 : 0,
                irpfPct: random.nextInt(10) == 0 ? 15 : 0,
                suplido: random.nextInt(12) == 0,
              ),
          ];
          for (final metodo in MetodoIva.values) {
            final totales = calcularTotalesFs(
              lineas,
              metodo: metodo,
              dtopor1: random.nextInt(4) == 0 ? 10 : 0,
            );
            expect(
              totales.totalCents,
              totales.netoCents +
                  totales.totalIvaCents +
                  totales.totalRecargoCents +
                  totales.totalSuplidosCents -
                  totales.totalIrpfCents,
              reason: 'iteración $i ($metodo)',
            );
            expect(
              totales.grupos.fold(0, (sum, g) => sum + g.netoCents),
              totales.netoCents,
            );
            expect(
              totales.grupos.fold(0, (sum, g) => sum + g.cuotaIvaCents),
              totales.totalIvaCents,
            );
          }
        }
      },
    );
  });
}
