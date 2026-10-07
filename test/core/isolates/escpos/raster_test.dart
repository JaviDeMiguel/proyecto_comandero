import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:proyecto_comandero/core/errors/app_exception.dart';
import 'package:proyecto_comandero/core/isolates/escpos/raster.dart';
import 'package:test/test.dart';

/// PNG de [width]×[height] blanco con un rectángulo negro en la mitad
/// izquierda (blanco y negro puros, sin grises).
Uint8List halfBlackPng(int width, int height, {bool alpha = false}) {
  final image = img.Image(
    width: width,
    height: height,
    numChannels: alpha ? 4 : 3,
  )..clear(img.ColorRgba8(255, 255, 255, 255));
  img.fillRect(
    image,
    x1: 0,
    y1: 0,
    x2: width ~/ 2 - 1,
    y2: height - 1,
    color: img.ColorRgba8(0, 0, 0, 255),
  );
  return img.encodePng(image);
}

/// PNG con un degradado horizontal de negro (izquierda) a blanco (derecha).
Uint8List gradientPng(int width, int height) {
  final image = img.Image(width: width, height: height);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final v = (x * 255 / (width - 1)).round();
      image.setPixelRgb(x, y, v, v, v);
    }
  }
  return img.encodePng(image);
}

/// PNG gris uniforme (valor [gray]).
Uint8List flatGrayPng(int width, int height, int gray) {
  final image = img.Image(width: width, height: height)
    ..clear(img.ColorRgb8(gray, gray, gray));
  return img.encodePng(image);
}

int countBlack(RasterImage r) {
  var n = 0;
  for (var y = 0; y < r.height; y++) {
    for (var x = 0; x < r.width; x++) {
      if (r.isBlack(x, y)) n++;
    }
  }
  return n;
}

void main() {
  group('RasterImage', () {
    test('valida anchura múltiplo de 8 y tamaño de datos', () {
      expect(
        () => RasterImage(width: 12, height: 1, bits: Uint8List(2)),
        throwsA(isA<ValidationException>()),
      );
      expect(
        () => RasterImage(width: 0, height: 1, bits: Uint8List(0)),
        throwsA(isA<ValidationException>()),
      );
      expect(
        () => RasterImage(width: 8, height: 0, bits: Uint8List(0)),
        throwsA(isA<ValidationException>()),
      );
      expect(
        () => RasterImage(width: 16, height: 2, bits: Uint8List(3)),
        throwsA(
          isA<ValidationException>().having(
            (e) => e.message,
            'message',
            allOf(contains('3 bytes'), contains('4')),
          ),
        ),
      );
    });

    test('isBlack lee el bit MSB primero', () {
      final r = RasterImage(
        width: 16,
        height: 1,
        bits: Uint8List.fromList([0x80, 0x01]),
      );
      expect(r.isBlack(0, 0), isTrue);
      expect(r.isBlack(1, 0), isFalse);
      expect(r.isBlack(15, 0), isTrue);
      expect(r.bytesPerRow, 2);
    });

    test('igualdad por valor incluyendo los bits', () {
      final a = RasterImage(width: 8, height: 1, bits: Uint8List.fromList([1]));
      final b = RasterImage(width: 8, height: 1, bits: Uint8List.fromList([1]));
      final c = RasterImage(width: 8, height: 1, bits: Uint8List.fromList([2]));
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(c));
    });
  });

  group('rasterizarLogo', () {
    test('blanco y negro puros sin dithering: bits exactos', () {
      final png = halfBlackPng(16, 2);
      final r = rasterizarLogo(png, maxWidthDots: 384, dithering: false);
      expect(r.width, 16);
      expect(r.height, 2);
      // Mitad izquierda negra: 0xFF 0x00 por fila.
      expect(r.bits, [0xFF, 0x00, 0xFF, 0x00]);
    });

    test('blanco y negro puros con dithering: mismo resultado', () {
      final png = halfBlackPng(16, 2);
      final sin = rasterizarLogo(png, maxWidthDots: 384, dithering: false);
      final con = rasterizarLogo(png, maxWidthDots: 384);
      expect(con, sin);
    });

    test('anchura no múltiplo de 8 se rellena con blanco a la derecha', () {
      final png = halfBlackPng(10, 1); // 5 negros + 5 blancos
      final r = rasterizarLogo(png, maxWidthDots: 384, dithering: false);
      expect(r.width, 16);
      expect(r.bits, [0xF8, 0x00]);
    });

    test(
      'imagen más ancha que el papel se reescala conservando proporción',
      () {
        final png = halfBlackPng(800, 200);
        final r = rasterizarLogo(png, maxWidthDots: 384, dithering: false);
        expect(r.width, 384);
        expect(r.height, 96); // 200 × 384 / 800
        expect(r.width % 8, 0);
        // La mitad izquierda sigue siendo negra y la derecha blanca.
        expect(r.isBlack(10, 50), isTrue);
        expect(r.isBlack(380, 50), isFalse);
        final black = countBlack(r);
        expect(black, closeTo(384 * 96 / 2, 384 * 2));
      },
    );

    test('reescalado a anchura máxima no múltiplo de 8 se rechaza', () {
      expect(
        () => rasterizarLogo(halfBlackPng(8, 1), maxWidthDots: 100),
        throwsA(isA<ValidationException>()),
      );
      expect(
        () => rasterizarLogo(halfBlackPng(8, 1), maxWidthDots: 0),
        throwsA(isA<ValidationException>()),
      );
    });

    test('imagen más estrecha que el papel no se amplía', () {
      final r = rasterizarLogo(halfBlackPng(64, 8), maxWidthDots: 576);
      expect(r.width, 64);
      expect(r.height, 8);
    });

    test(
      'gris medio: umbral da todo blanco/negro, dithering reparte ~50 %',
      () {
        final png = flatGrayPng(64, 64, 128);
        final threshold = rasterizarLogo(
          png,
          maxWidthDots: 576,
          dithering: false,
        );
        expect(countBlack(threshold), 0, reason: '128 no es < 128');
        final dark = rasterizarLogo(
          flatGrayPng(64, 64, 127),
          maxWidthDots: 576,
          dithering: false,
        );
        expect(countBlack(dark), 64 * 64);

        final dithered = rasterizarLogo(png, maxWidthDots: 576);
        final ratio = countBlack(dithered) / (64 * 64);
        expect(ratio, closeTo(0.5, 0.05));
      },
    );

    test(
      'degradado con dithering: más negro a la izquierda que a la derecha',
      () {
        final r = rasterizarLogo(gradientPng(256, 32), maxWidthDots: 576);
        var left = 0;
        var right = 0;
        for (var y = 0; y < r.height; y++) {
          for (var x = 0; x < 64; x++) {
            if (r.isBlack(x, y)) left++;
            if (r.isBlack(192 + x, y)) right++;
          }
        }
        expect(left, greaterThan(64 * 32 * 0.7));
        expect(right, lessThan(64 * 32 * 0.3));
      },
    );

    test('es determinista', () {
      final png = gradientPng(200, 40);
      final a = rasterizarLogo(png, maxWidthDots: 384);
      final b = rasterizarLogo(png, maxWidthDots: 384);
      expect(a, b);
    });

    test('la transparencia se compone sobre blanco', () {
      final image = img.Image(width: 8, height: 1, numChannels: 4)
        ..clear(img.ColorRgba8(0, 0, 0, 0)); // negro totalmente transparente
      final png = img.encodePng(image);
      final r = rasterizarLogo(png, maxWidthDots: 384, dithering: false);
      expect(r.bits, [0x00]);
    });

    test('JPEG también se acepta', () {
      final image = img.Image(width: 16, height: 4)
        ..clear(img.ColorRgb8(0, 0, 0));
      final jpg = img.encodeJpg(image);
      final r = rasterizarLogo(jpg, maxWidthDots: 384, dithering: false);
      expect(r.width, 16);
      expect(countBlack(r), 64);
    });

    test('PNG corrupto → ValidationException', () {
      final png = halfBlackPng(16, 16);
      final corrupt = Uint8List.fromList(png.sublist(0, 20));
      expect(
        () => rasterizarLogo(corrupt, maxWidthDots: 384),
        throwsA(isA<ValidationException>()),
      );
      final garbage = Uint8List.fromList(List.generate(100, (i) => i));
      expect(
        () => rasterizarLogo(garbage, maxWidthDots: 384),
        throwsA(
          isA<ValidationException>().having(
            (e) => e.message,
            'message',
            contains('logo'),
          ),
        ),
      );
      expect(
        () => rasterizarLogo(Uint8List(0), maxWidthDots: 384),
        throwsA(isA<ValidationException>()),
      );
    });

    test('imagen demasiado alta → ValidationException', () {
      final png = flatGrayPng(8, rasterMaxHeight + 1, 0);
      expect(
        () => rasterizarLogo(png, maxWidthDots: 384),
        throwsA(
          isA<ValidationException>().having(
            (e) => e.message,
            'message',
            contains('$rasterMaxHeight'),
          ),
        ),
      );
    });
  });
}
