import 'package:proyecto_comandero/core/isolates/escpos/cp858.dart';
import 'package:test/test.dart';

void main() {
  group('encodeCp858', () {
    test('ASCII imprimible se copia tal cual', () {
      const text = 'Cafe con leche 1,20 (x2) [ok] #42 @';
      expect(encodeCp858(text), text.codeUnits);
    });

    test('vocales acentuadas minúsculas y mayúsculas', () {
      expect(encodeCp858('áéíóú'), [0xA0, 0x82, 0xA1, 0xA2, 0xA3]);
      expect(encodeCp858('ÁÉÍÓÚ'), [0xB5, 0x90, 0xD6, 0xE0, 0xE9]);
      expect(encodeCp858('àèìòù'), [0x85, 0x8A, 0x8D, 0x95, 0x97]);
      expect(encodeCp858('ÀÈÌÒÙ'), [0xB7, 0xD4, 0xDE, 0xE3, 0xEB]);
    });

    test('eñe, diéresis, cedilla, ordinales y signos invertidos', () {
      expect(encodeCp858('ñÑ'), [0xA4, 0xA5]);
      expect(encodeCp858('üÜ'), [0x81, 0x9A]);
      expect(encodeCp858('çÇ'), [0x87, 0x80]);
      expect(encodeCp858('ªº'), [0xA6, 0xA7]);
      expect(encodeCp858('¿¡'), [0xA8, 0xAD]);
    });

    test('el euro es 0xD5', () {
      expect(encodeCp858('€'), [cp858Euro]);
      expect(cp858Euro, 0xD5);
      expect(encodeCp858('12,50 €'), [...'12,50 '.codeUnits, 0xD5]);
    });

    test('frase española completa → bytes esperados', () {
      expect(encodeCp858('Jamón ibérico 3,50 €/ud ¡Niño!'), [
        ...'Jam'.codeUnits,
        0xA2,
        ...'n ib'.codeUnits,
        0x82,
        ...'rico 3,50 '.codeUnits,
        0xD5,
        ...'/ud '.codeUnits,
        0xAD,
        ...'Ni'.codeUnits,
        0xA4,
        ...'o!'.codeUnits,
      ]);
    });

    test(
      'un carácter produce exactamente un byte, también los desconocidos',
      () {
        const text = 'a€ñ😀中';
        final bytes = encodeCp858(text);
        expect(bytes.length, text.runes.length);
        expect(bytes.length, 5);
        expect(bytes[3], cp858Unknown);
        expect(bytes[4], cp858Unknown);
      },
    );

    test('emoji y caracteres fuera de tabla → "?"', () {
      expect(encodeCp858('😀'), [0x3F]);
      expect(encodeCp858('Ж'), [0x3F]);
      expect(encodeCp858('→'), [0x3F]);
    });

    test('tipografía habitual se aproxima a ASCII', () {
      expect(encodeCp858('“hola” – ‘x’'), [
        0x22,
        ...'hola'.codeUnits,
        0x22,
        0x20,
        0x2D,
        0x20,
        0x27,
        0x78,
        0x27,
      ]);
      expect(encodeCp858(' '), [0x20]);
    });

    test('LF y HT se conservan; el resto de controles se neutralizan', () {
      expect(encodeCp858('a\nb\tc'), [0x61, 0x0A, 0x62, 0x09, 0x63]);
      expect(encodeCp858('\x1B@'), [0x3F, 0x40]);
      expect(encodeCp858('\x1DV'), [0x3F, 0x56]);
      expect(encodeCp858('\x00\x07\x7F'), [0x3F, 0x3F, 0x3F]);
    });

    test('nunca emite ESC ni GS para ningún punto de código', () {
      // Recorre el BMP completo: ninguna runa puede convertirse en 0x1B/0x1D.
      for (var rune = 0; rune < 0x10000; rune++) {
        if (rune >= 0xD800 && rune <= 0xDFFF) continue;
        final byte = cp858ByteFor(rune);
        expect(byte, isNot(0x1B), reason: 'runa $rune');
        expect(byte, isNot(0x1D), reason: 'runa $rune');
        expect(byte, inInclusiveRange(0, 255), reason: 'runa $rune');
      }
    });

    test('cadena vacía → sin bytes', () {
      expect(encodeCp858(''), isEmpty);
    });
  });

  group('decodeCp858', () {
    test('es la inversa de encodeCp858 para texto representable', () {
      const text = 'Año nuevo: 10 € ¿Qué? ¡Sí! ü ç ª º Ñ';
      expect(decodeCp858(encodeCp858(text)), text);
    });

    test('bytes sin entrada en la tabla → "?"', () {
      expect(decodeCp858([0xB0, 0x41]), '?A');
    });
  });
}
