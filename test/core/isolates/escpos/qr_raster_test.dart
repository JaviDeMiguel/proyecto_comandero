import 'package:proyecto_comandero/core/errors/app_exception.dart';
import 'package:proyecto_comandero/core/fiscal/verifactu_qr.dart';
import 'package:proyecto_comandero/core/isolates/escpos/qr_raster.dart';
import 'package:qr/qr.dart';
import 'package:test/test.dart';

/// Fila de la tabla de §6.3: puntos por módulo y lado del símbolo en mm a
/// 203 y a 180 ppp.
typedef _Tamano = ({int m203, double mm203, int m180, double mm180});

const Map<int, _Tamano> _tabla = {
  6: (m203: 7, mm203: 35.9, m180: 6, mm180: 34.7),
  7: (m203: 6, mm203: 33.8, m180: 6, mm180: 38.1),
  8: (m203: 6, mm203: 36.8, m180: 5, mm180: 34.6),
  9: (m203: 5, mm203: 33.1, m180: 5, mm180: 37.4),
  10: (m203: 5, mm203: 35.6, m180: 4, mm180: 32.2),
  11: (m203: 5, mm203: 38.1, m180: 4, mm180: 34.4),
  12: (m203: 4, mm203: 32.5, m180: 4, mm180: 36.7),
  13: (m203: 4, mm203: 34.5, m180: 4, mm180: 38.9),
};

/// 58 mm, 80 mm a 180 ppp y 80 mm a 203 ppp.
const List<int> _anchos = [384, 512, 576];

double _ppmm(int dpi) => dpi / 25.4;

/// URL real con el NIF `B12345678` y la fecha 09-10-2026 (§6.3).
String _url({
  String numSerie = 'F2026S12',
  int importeCents = 6700,
  bool verifactu = true,
  bool pruebas = false,
}) => QrTributario(
  nif: 'B12345678',
  numSerie: numSerie,
  fecha: DateTime(2026, 10, 9),
  importeCents: importeCents,
  verifactu: verifactu,
  pruebas: pruebas,
).url;

Matcher _validacion(String fragmento) => throwsA(
  isA<ValidationException>().having(
    (e) => e.message,
    'message',
    contains(fragmento),
  ),
);

/// Compara la imagen punto a punto con el símbolo que genera el paquete:
/// dentro del símbolo cada punto vale lo que su módulo (`isDark`); fuera,
/// blanco. Devuelve las primeras discrepancias (vacío si es fiel).
List<String> _discrepancias(String datos, QrRasterizado r) {
  final simbolo = QrImage(
    QrCode(
      payload: QrPayload.fromString(datos),
      errorCorrectLevel: QrErrorCorrectLevel.medium,
    ),
  );
  expect(simbolo.moduleCount, r.modulos);
  final m = r.puntosPorModulo;
  final izquierda = r.margenIzquierdo;
  final arriba = r.margenSuperior;
  final lado = r.ladoPuntos;
  final errores = <String>[];
  for (var y = 0; y < r.imagen.height && errores.length < 10; y++) {
    for (var x = 0; x < r.imagen.width && errores.length < 10; x++) {
      final dentro =
          x >= izquierda &&
          x < izquierda + lado &&
          y >= arriba &&
          y < arriba + lado;
      final esperado =
          dentro && simbolo.isDark((y - arriba) ~/ m, (x - izquierda) ~/ m);
      if (r.imagen.isBlack(x, y) != esperado) {
        errores.add('($x, $y): se esperaba ${esperado ? 'negro' : 'blanco'}');
      }
    }
  }
  return errores;
}

void main() {
  group('elegirModulo', () {
    for (final MapEntry(key: version, value: tamano) in _tabla.entries) {
      final modulos = 17 + 4 * version;

      test('versión $version ($modulos módulos) a 203 ppp → ${tamano.m203} '
          'puntos, ${tamano.mm203} mm', () {
        for (final ancho in _anchos) {
          final m = elegirModulo(modulos, dpi: 203, anchoMaximoPuntos: ancho);
          expect(m, tamano.m203, reason: '$ancho puntos');
          final mm = modulos * m / _ppmm(203);
          // La tabla da los mm con una décima (truncada en algún caso).
          expect(mm, closeTo(tamano.mm203, 0.1), reason: '$ancho puntos');
          expect(mm, inInclusiveRange(30, 40));
        }
      });

      test('versión $version ($modulos módulos) a 180 ppp → ${tamano.m180} '
          'puntos, ${tamano.mm180} mm', () {
        for (final ancho in _anchos) {
          final m = elegirModulo(modulos, dpi: 180, anchoMaximoPuntos: ancho);
          expect(m, tamano.m180, reason: '$ancho puntos');
          final mm = modulos * m / _ppmm(180);
          expect(mm, closeTo(tamano.mm180, 0.1), reason: '$ancho puntos');
          expect(mm, inInclusiveRange(30, 40));
        }
      });
    }

    test('el objetivo decide entre los candidatos', () {
      // Versión 6 a 203 ppp: 6 puntos → 30,8 mm; 7 puntos → 35,9 mm.
      expect(
        elegirModulo(41, dpi: 203, anchoMaximoPuntos: 576, objetivoMm: 31),
        6,
      );
      expect(
        elegirModulo(41, dpi: 203, anchoMaximoPuntos: 576, objetivoMm: 39),
        7,
      );
    });

    test('la anchura del papel descarta tamaños que no dejan 2 mm', () {
      // Versión 11 a 203 ppp: 5 puntos → 305 + 2 × 16 = 337 > 320;
      // 4 puntos → 244 + 32 = 276 y 30,5 mm.
      expect(elegirModulo(61, dpi: 203, anchoMaximoPuntos: 320), 4);
      expect(elegirModulo(61, dpi: 203, anchoMaximoPuntos: 384), 5);
    });

    test('sin candidato → ValidationException con la versión', () {
      // Versión 40 (177 módulos) a 203 ppp: 1 punto → 22 mm; 2 → 44 mm.
      expect(
        () => elegirModulo(177, dpi: 203, anchoMaximoPuntos: 576),
        _validacion('versión 40'),
      );
      // Versión 6 en un papel de 64 puntos: ningún tamaño cabe.
      expect(
        () => elegirModulo(41, dpi: 203, anchoMaximoPuntos: 64),
        _validacion('no cabe'),
      );
    });

    test('parámetros sin sentido → ValidationException', () {
      final lanza = throwsA(isA<ValidationException>());
      // 20 no es 17 + 4 · versión.
      expect(() => elegirModulo(20, dpi: 203, anchoMaximoPuntos: 576), lanza);
      expect(() => elegirModulo(181, dpi: 203, anchoMaximoPuntos: 576), lanza);
      expect(() => elegirModulo(41, dpi: 0, anchoMaximoPuntos: 576), lanza);
      // 100 no es múltiplo de 8.
      expect(() => elegirModulo(41, dpi: 203, anchoMaximoPuntos: 100), lanza);
      expect(() => elegirModulo(41, dpi: 203, anchoMaximoPuntos: 0), lanza);
      expect(
        () => elegirModulo(
          41,
          dpi: 203,
          anchoMaximoPuntos: 576,
          minMm: 40,
          maxMm: 30,
        ),
        lanza,
      );
      expect(
        () => elegirModulo(
          41,
          dpi: 203,
          anchoMaximoPuntos: 576,
          margenMinimoMm: -1,
        ),
        lanza,
      );
    });
  });

  group('rasterizarQr', () {
    test('las URL de §6.3 dan las versiones esperadas', () {
      // Caso → (URL, longitud, versión).
      final casos = <String, (String, int, int)>{
        'producción VERI*FACTU': (_url(), 125, 8),
        'producción NO VERI*FACTU': (_url(verifactu: false), 136, 8),
        'pruebas VERI*FACTU': (_url(pruebas: true), 111, 7),
        'pruebas NO VERI*FACTU': (
          _url(verifactu: false, pruebas: true),
          122,
          7,
        ),
        'producción NO VERI*FACTU, serie de 20 (máximo de facturascli.codigo)':
            (_url(verifactu: false, numSerie: 'F' * 20), 148, 8),
        'producción NO VERI*FACTU, serie de 60 (máximo de la AEAT)': (
          _url(verifactu: false, numSerie: 'S' * 60),
          188,
          10,
        ),
        'producción VERI*FACTU, serie de 60 e importe máximo': (
          _url(numSerie: 'S' * 60, importeCents: importeQrMaximoCents),
          187,
          10,
        ),
        'producción NO VERI*FACTU, serie de 60 e importe máximo': (
          _url(
            verifactu: false,
            numSerie: 'S' * 60,
            importeCents: importeQrMaximoCents,
          ),
          198,
          10,
        ),
      };
      for (final MapEntry(key: caso, value: (url, longitud, version))
          in casos.entries) {
        expect(url.length, longitud, reason: caso);
        final r = rasterizarQr(url, dpi: 203, anchoMaximoPuntos: 576);
        expect(r.version, version, reason: caso);
        expect(r.modulos, 17 + 4 * version, reason: caso);
      }
    });

    test('anchura múltiplo de 8 y ≤ papel; 6 mm en vertical y ≥ 2 mm a los '
        'lados', () {
      final url = _url();
      for (final dpi in [203, 180]) {
        for (final ancho in _anchos) {
          final r = rasterizarQr(url, dpi: dpi, anchoMaximoPuntos: ancho);
          final ppmm = _ppmm(dpi);
          final motivo = '$dpi ppp, $ancho puntos';
          expect(r.imagen.width % 8, 0, reason: motivo);
          expect(r.imagen.width, lessThanOrEqualTo(ancho), reason: motivo);
          expect(r.ladoMm, inInclusiveRange(30, 40), reason: motivo);
          expect(r.ladoMm, closeTo(r.ladoPuntos / ppmm, 1e-9), reason: motivo);
          // 6 mm arriba y abajo: 48 filas a 203 ppp, 43 a 180.
          final vertical = (6 * ppmm).round();
          expect(vertical, dpi == 203 ? 48 : 43);
          expect(r.margenSuperior, vertical, reason: motivo);
          expect(r.imagen.height, r.ladoPuntos + 2 * vertical, reason: motivo);
          // Al menos 2 mm a cada lado (16 puntos a 203 ppp, 15 a 180) y el
          // relleno a múltiplo de 8 repartido entre ambos.
          final minimo = (2 * ppmm).ceil();
          final derecha = r.imagen.width - r.ladoPuntos - r.margenIzquierdo;
          expect(
            r.margenIzquierdo,
            greaterThanOrEqualTo(minimo),
            reason: motivo,
          );
          expect(derecha, greaterThanOrEqualTo(minimo), reason: motivo);
          expect(
            derecha - r.margenIzquierdo,
            inInclusiveRange(0, 1),
            reason: motivo,
          );
        }
      }
    });

    test('ejemplo de §6.3: versión 8 a 6 puntos y 203 ppp', () {
      final url = _url();
      final en80 = rasterizarQr(url, dpi: 203, anchoMaximoPuntos: 576);
      expect(en80.version, 8);
      expect(en80.modulos, 49);
      expect(en80.puntosPorModulo, 6);
      expect(en80.ladoPuntos, 294);
      expect(en80.ladoMm, closeTo(36.8, 0.05));
      // W = 294 + 96 = 390 → 392 (49 bytes por fila); H = 390.
      expect(en80.imagen.width, 392);
      expect(en80.imagen.height, 390);
      expect(en80.imagen.bytesPerRow, 49);
      expect(en80.imagen.bits.length, 49 * 390);
      expect(en80.margenSuperior, 48);
      expect(en80.margenIzquierdo, 49);

      // En 58 mm el margen lateral baja a 45 y la anchura es justo 384.
      final en58 = rasterizarQr(url, dpi: 203, anchoMaximoPuntos: 384);
      expect(en58.imagen.width, 384);
      expect(en58.imagen.height, 390);
      expect(en58.margenIzquierdo, 45);
      expect(en58.puntosPorModulo, 6);

      // A 180 ppp: 5 puntos por módulo y 43 filas de margen.
      final a180 = rasterizarQr(url, dpi: 180, anchoMaximoPuntos: 512);
      expect(a180.puntosPorModulo, 5);
      expect(a180.ladoPuntos, 245);
      expect(a180.margenSuperior, 43);
      expect(a180.imagen.height, 245 + 2 * 43);
      expect(a180.imagen.width, 336);
    });

    test('fidelidad: cada módulo oscuro es un bloque de m × m puntos y el '
        'margen es blanco', () {
      final url = _url();
      for (final (dpi, ancho) in [
        (203, 576),
        (203, 384),
        (180, 512),
        (180, 384),
      ]) {
        final r = rasterizarQr(url, dpi: dpi, anchoMaximoPuntos: ancho);
        expect(
          _discrepancias(url, r),
          isEmpty,
          reason: '$dpi ppp, $ancho puntos',
        );
      }
      // Y con una URL de otra versión (10).
      final larga = _url(verifactu: false, numSerie: 'S' * 60);
      final r = rasterizarQr(larga, dpi: 203, anchoMaximoPuntos: 576);
      expect(r.version, 10);
      expect(_discrepancias(larga, r), isEmpty);
    });

    test('el patrón de posición superior izquierdo está donde toca', () {
      final r = rasterizarQr(_url(), dpi: 203, anchoMaximoPuntos: 576);
      final m = r.puntosPorModulo;
      final x0 = r.margenIzquierdo;
      final y0 = r.margenSuperior;
      // Módulo (0, 0): negro entero.
      for (var dy = 0; dy < m; dy++) {
        for (var dx = 0; dx < m; dx++) {
          expect(r.imagen.isBlack(x0 + dx, y0 + dy), isTrue);
        }
      }
      // Módulo (1, 1): blanco (interior del patrón).
      expect(r.imagen.isBlack(x0 + m + m ~/ 2, y0 + m + m ~/ 2), isFalse);
      // Módulo (3, 3): negro (centro del patrón).
      expect(
        r.imagen.isBlack(x0 + 3 * m + m ~/ 2, y0 + 3 * m + m ~/ 2),
        isTrue,
      );
      // Justo fuera del símbolo: margen blanco.
      expect(r.imagen.isBlack(x0 - 1, y0), isFalse);
      expect(r.imagen.isBlack(x0, y0 - 1), isFalse);
      expect(r.imagen.isBlack(x0 + r.ladoPuntos, y0), isFalse);
      expect(r.imagen.isBlack(x0, y0 + r.ladoPuntos), isFalse);
    });

    test('determinismo: los mismos datos dan los mismos bytes', () {
      final url = _url();
      final a = rasterizarQr(url, dpi: 203, anchoMaximoPuntos: 576);
      final b = rasterizarQr(url, dpi: 203, anchoMaximoPuntos: 576);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a.imagen.bits, b.imagen.bits);
      final otro = rasterizarQr(
        _url(importeCents: 6701),
        dpi: 203,
        anchoMaximoPuntos: 576,
      );
      expect(a, isNot(otro));
    });

    test('entrada demasiado larga → ValidationException', () {
      // No cabe ni en la versión 40 (2.331 bytes con corrección M).
      expect(
        () => rasterizarQr('x' * 3000, dpi: 203, anchoMaximoPuntos: 576),
        _validacion('capacidad'),
      );
      // Cabe en la versión 40 (177 módulos) pero no entre 30 y 40 mm.
      expect(
        () => rasterizarQr('x' * 2300, dpi: 203, anchoMaximoPuntos: 576),
        _validacion('versión 40'),
      );
    });

    test(
      'entrada vacía o margen menor que el mínimo → ValidationException',
      () {
        expect(
          () => rasterizarQr('', dpi: 203, anchoMaximoPuntos: 576),
          throwsA(isA<ValidationException>()),
        );
        expect(
          () => rasterizarQr(
            _url(),
            dpi: 203,
            anchoMaximoPuntos: 576,
            margenMm: 1,
          ),
          _validacion('margen'),
        );
        expect(
          () => rasterizarQr(_url(), dpi: 203, anchoMaximoPuntos: 100),
          _validacion('múltiplo de 8'),
        );
      },
    );

    test('los parámetros de tamaño llegan a elegirModulo', () {
      // Con un intervalo de 20-25 mm la versión 8 a 203 ppp usa 4 puntos
      // (196 puntos → 24,5 mm).
      final r = rasterizarQr(
        _url(),
        dpi: 203,
        anchoMaximoPuntos: 576,
        minMm: 20,
        maxMm: 25,
        objetivoMm: 22,
      );
      expect(r.puntosPorModulo, 4);
      expect(r.ladoMm, closeTo(24.5, 0.05));
    });
  });
}
