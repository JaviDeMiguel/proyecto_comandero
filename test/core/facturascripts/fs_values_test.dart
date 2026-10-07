import 'dart:convert';

import 'package:proyecto_comandero/core/facturascripts/fs_api.dart';
import 'package:proyecto_comandero/core/facturascripts/fs_values.dart';
import 'package:test/test.dart';

void main() {
  group('fsEncodeValue', () {
    test('null viaja como el literal "null"', () {
      expect(fsEncodeValue(null), 'null');
    });

    test('los booleanos viajan como 1 / 0', () {
      expect(fsEncodeValue(true), '1');
      expect(fsEncodeValue(false), '0');
    });

    test('los números usan punto decimal y nunca exponente', () {
      expect(fsEncodeValue(7), '7');
      expect(fsEncodeValue(12.5), '12.5');
      expect(fsEncodeValue(3.0), '3');
      expect(fsEncodeValue(0.86364), '0.86364');
      expect(fsEncodeValue(0.0000001), '0');
      expect(fsEncodeValue(123456789012.5), '123456789012.5');
      expect(() => fsEncodeValue(1e21), throwsArgumentError);
      expect(fsEncodeValue(-0.0), '0');
      expect(fsEncodeValue(-2.50), '-2.5');
    });

    test('las cadenas viajan tal cual', () {
      expect(fsEncodeValue('TPV-0001'), 'TPV-0001');
      expect(fsEncodeValue(''), '');
    });

    test('listas y mapas viajan como JSON (campo lineas)', () {
      final encoded = fsEncodeValue([
        {'referencia': 'CANA', 'cantidad': 7, 'pvpunitario': 0.86364},
      ]);
      expect(jsonDecode(encoded), [
        {'referencia': 'CANA', 'cantidad': 7, 'pvpunitario': 0.86364},
      ]);
      expect(fsEncodeValue(<String, Object?>{'a': 1}), '{"a":1}');
    });

    test('rechaza tipos no admitidos y números no finitos', () {
      expect(() => fsEncodeValue(DateTime(2026)), throwsArgumentError);
      expect(() => fsEncodeValue(double.nan), throwsArgumentError);
      expect(() => fsEncodeValue(double.infinity), throwsArgumentError);
    });

    test('fsEncodeFields codifica todos los campos', () {
      expect(fsEncodeFields({'pagada': true, 'canal': null, 'total': 6.65}), {
        'pagada': '1',
        'canal': 'null',
        'total': '6.65',
      });
    });
  });

  group('formato de fechas', () {
    final date = DateTime(2026, 10, 6, 9, 5, 3);

    test('formatos de escritura', () {
      expect(fsFormatDate(date), '06-10-2026');
      expect(fsFormatTime(date), '09:05:03');
      expect(fsFormatDateTime(date), '06-10-2026 09:05:03');
      expect(fsFormatIsoDate(date), '2026-10-06');
    });

    test('fsParseDate acepta d-m-Y e Y-m-d, con y sin hora', () {
      expect(fsParseDate('06-10-2026'), DateTime(2026, 10, 6));
      expect(fsParseDate('6-1-2026'), DateTime(2026, 1, 6));
      expect(fsParseDate('2026-10-06'), DateTime(2026, 10, 6));
      expect(
        fsParseDate('06-10-2026 14:05:09'),
        DateTime(2026, 10, 6, 14, 5, 9),
      );
      expect(fsParseDate('2026-10-06 14:05'), DateTime(2026, 10, 6, 14, 5));
      expect(
        fsParseDate('2026-10-06T14:05:09'),
        DateTime(2026, 10, 6, 14, 5, 9),
      );
      expect(fsParseDate('  06-10-2026 '), DateTime(2026, 10, 6));
    });

    test('fsParseDate devuelve null ante vacíos o basura', () {
      expect(fsParseDate(null), isNull);
      expect(fsParseDate(''), isNull);
      expect(fsParseDate('   '), isNull);
      expect(fsParseDate('06/10/2026'), isNull);
      expect(fsParseDate('TPV-0001'), isNull);
      expect(fsParseDate('31-02-2026'), isNull);
      expect(fsParseDate('2026-13-01'), isNull);
      expect(fsParseDate('01-01-2026 25:00:00'), isNull);
    });

    test('ida y vuelta', () {
      expect(fsParseDate(fsFormatDateTime(date)), date);
      expect(fsParseDate(fsFormatDate(date)), DateTime(2026, 10, 6));
    });
  });

  group('FsRecordReader', () {
    // Mezcla de tipos tal como los devuelve la API: números en un GET y
    // cadenas en la respuesta de un POST.
    final FsRecord record = {
      'idasiento': '57',
      'numero': 57,
      'importe': '3.20',
      'total': 6.65,
      'entero_float': 12.0,
      'editable': true,
      'pagada': '1',
      'vencida': 0,
      'texto_bool': 'false',
      'codigo': 'F2026S12',
      'fecha': '06-10-2026',
      'fecha_iso': '2026-10-06',
      'vacio': '',
      'nulo': null,
      'lista': <Object?>[1],
    };

    test('fsInt tolera números, textos y decimales enteros', () {
      expect(record.fsInt('idasiento'), 57);
      expect(record.fsInt('numero'), 57);
      expect(record.fsInt('entero_float'), 12);
      expect(record.fsInt('vacio'), isNull);
      expect(record.fsInt('nulo'), isNull);
      expect(record.fsInt('ausente'), isNull);
      expect(() => record.fsInt('total'), throwsFormatException);
      expect(() => record.fsInt('codigo'), throwsFormatException);
    });

    test('fsDouble tolera números y textos', () {
      expect(record.fsDouble('importe'), 3.2);
      expect(record.fsDouble('total'), 6.65);
      expect(record.fsDouble('numero'), 57.0);
      expect(record.fsDouble('vacio'), isNull);
      expect(() => record.fsDouble('codigo'), throwsFormatException);
      expect(() => record.fsDouble('editable'), throwsFormatException);
    });

    test('fsBool tolera todas las formas', () {
      expect(record.fsBool('editable'), isTrue);
      expect(record.fsBool('pagada'), isTrue);
      expect(record.fsBool('vencida'), isFalse);
      expect(record.fsBool('texto_bool'), isFalse);
      expect(record.fsBool('nulo'), isFalse);
      expect(record.fsBool('ausente', orElse: true), isTrue);
      expect(record.fsBool('vacio', orElse: true), isTrue);
      expect(() => record.fsBool('codigo'), throwsFormatException);
    });

    test('fsString convierte números a texto', () {
      expect(record.fsString('codigo'), 'F2026S12');
      expect(record.fsString('numero'), '57');
      expect(record.fsString('total'), '6.65');
      expect(record.fsString('vacio'), '');
      expect(record.fsNonEmptyString('vacio'), isNull);
      expect(record.fsString('nulo'), isNull);
      expect(() => record.fsString('lista'), throwsFormatException);
    });

    test('fsDate acepta ambos formatos', () {
      expect(record.fsDate('fecha'), DateTime(2026, 10, 6));
      expect(record.fsDate('fecha_iso'), DateTime(2026, 10, 6));
      expect(record.fsDate('vacio'), isNull);
      expect(() => record.fsDate('codigo'), throwsFormatException);
    });

    test('los fsRequire* lanzan cuando el campo falta', () {
      expect(record.fsRequireInt('idasiento'), 57);
      expect(record.fsRequireDouble('importe'), 3.2);
      expect(record.fsRequireString('codigo'), 'F2026S12');
      expect(() => record.fsRequireInt('ausente'), throwsFormatException);
      expect(() => record.fsRequireDouble('nulo'), throwsFormatException);
      expect(() => record.fsRequireString('nulo'), throwsFormatException);
    });
  });
}
