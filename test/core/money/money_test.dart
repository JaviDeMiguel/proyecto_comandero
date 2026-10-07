import 'package:proyecto_comandero/core/money/money.dart';
import 'package:test/test.dart';

void main() {
  group('roundHalfAwayFromZero', () {
    test(
      'corrige el error binario de coma flotante como el round() de PHP',
      () {
        // 1.005 * 100 == 100.49999999999999 en IEEE 754.
        expect(roundHalfAwayFromZero(1.005 * 100), 101);
        expect(roundHalfAwayFromZero(-1.005 * 100), -101);
        expect(roundHalfAwayFromZero(0.285 * 100), 29);
      },
    );

    test('redondea la mitad hacia fuera de cero', () {
      expect(roundHalfAwayFromZero(0.5), 1);
      expect(roundHalfAwayFromZero(-0.5), -1);
      expect(roundHalfAwayFromZero(2.4), 2);
      expect(roundHalfAwayFromZero(-2.6), -3);
    });

    test('devuelve los enteros tal cual', () {
      expect(roundHalfAwayFromZero(7), 7);
    });

    test('rechaza valores no finitos', () {
      expect(() => roundHalfAwayFromZero(double.nan), throwsArgumentError);
      expect(() => roundHalfAwayFromZero(double.infinity), throwsArgumentError);
    });
  });

  group('divideRounding', () {
    test('redondea al más cercano', () {
      expect(divideRounding(7, 2), 4);
      expect(divideRounding(5, 2), 3);
      expect(divideRounding(4, 3), 1);
      expect(divideRounding(5, 3), 2);
    });

    test('respeta el signo', () {
      expect(divideRounding(-7, 2), -4);
      expect(divideRounding(7, -2), -4);
      expect(divideRounding(-7, -2), 4);
    });

    test('rechaza la división por cero', () {
      expect(() => divideRounding(1, 0), throwsArgumentError);
    });
  });

  group('conversiones', () {
    test('centsFromDecimal absorbe el ruido de coma flotante', () {
      expect(centsFromDecimal(0.1 + 0.2), 30);
      expect(centsFromDecimal(12.34), 1234);
      expect(centsFromDecimal(-1.005), -101);
      expect(centsFromDecimal(3), 300);
    });

    test('centsToDecimal', () {
      expect(centsToDecimal(1234), 12.34);
      expect(centsToDecimal(-5), -0.05);
    });

    test('puntos básicos de IVA', () {
      expect(basisPointsFromPercent(10), 1000);
      expect(basisPointsFromPercent(21), 2100);
      expect(basisPointsFromPercent(5.2), 520);
      expect(basisPointsToPercent(400), 4.0);
    });
  });

  group('lineTotalCents', () {
    test('cantidades enteras', () {
      expect(lineTotalCents(95, 7), 665);
    });

    test('cantidades fraccionarias redondean al céntimo', () {
      expect(lineTotalCents(333, 0.5), 167);
      expect(lineTotalCents(1290, 0.25), 323);
    });
  });

  group('splitTaxIncluded', () {
    test('base + cuota siempre suma el total', () {
      for (final total in [1, 95, 250, 665, 999, 12345]) {
        for (final rate in [0, 400, 1000, 2100]) {
          final split = splitTaxIncluded(total, rate);
          expect(split.baseCents + split.taxCents, total);
        }
      }
    });

    test('casos conocidos', () {
      expect(splitTaxIncluded(250, 1000), (baseCents: 227, taxCents: 23));
      expect(splitTaxIncluded(665, 1000), (baseCents: 605, taxCents: 60));
      expect(splitTaxIncluded(1210, 2100), (baseCents: 1000, taxCents: 210));
      expect(splitTaxIncluded(500, 0), (baseCents: 500, taxCents: 0));
    });

    test('rechaza tipos negativos', () {
      expect(() => splitTaxIncluded(100, -1), throwsArgumentError);
    });
  });

  group('formato', () {
    test('formatCents usa el formato español', () {
      expect(formatCents(0), '0,00 €');
      expect(formatCents(5), '0,05 €');
      expect(formatCents(123456), '1.234,56 €');
      expect(formatCents(100000000), '1.000.000,00 €');
      expect(formatCents(-995), '-9,95 €');
      expect(formatCents(1250, symbol: false), '12,50');
    });

    test('formatQuantity elimina decimales superfluos', () {
      expect(formatQuantity(2), '2');
      expect(formatQuantity(2.0), '2');
      expect(formatQuantity(0.5), '0,5');
      expect(formatQuantity(1.250), '1,25');
      expect(formatQuantity(0.3333333), '0,333');
    });
  });
}
