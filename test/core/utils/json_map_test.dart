import 'dart:convert';

import 'package:proyecto_comandero/core/utils/json_map.dart';
import 'package:test/test.dart';

void main() {
  final json = jsonDecode(
    '{"s":"hola","i":7,"d":2.5,"b":true,"n":null,'
    '"m":{"k":"v"},"l":[1,"a"],"ml":[{"x":1},{"x":2}],"bad":[{"x":1},3]}',
  ) as Map<String, Object?>;

  test('lee los campos presentes con su tipo', () {
    expect(json.requireString('s'), 'hola');
    expect(json.requireInt('i'), 7);
    expect(json.requireDouble('d'), 2.5);
    expect(json.requireDouble('i'), 7.0);
    expect(json.requireBool('b'), isTrue);
    expect(json.requireMap('m'), {'k': 'v'});
    expect(json.requireList('l'), [1, 'a']);
    expect(json.requireMapList('ml').map((item) => item['x']), [1, 2]);
  });

  test('los opcionales devuelven null si faltan o son null', () {
    expect(json.optionalString('nope'), isNull);
    expect(json.optionalString('n'), isNull);
    expect(json.optionalInt('n'), isNull);
    expect(json.optionalDouble('n'), isNull);
    expect(json.optionalBool('n'), isNull);
    expect(json.optionalMap('n'), isNull);
    expect(json.optionalList('n'), isNull);
    expect(json.optionalInt('i'), 7);
  });

  test('un campo obligatorio ausente o nulo lanza FormatException', () {
    expect(() => json.requireString('nope'), throwsFormatException);
    expect(() => json.requireInt('n'), throwsFormatException);
  });

  test('un tipo incorrecto lanza FormatException con el nombre del campo', () {
    expect(
      () => json.requireInt('s'),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          allOf(contains("'s'"), contains('int'), contains('String')),
        ),
      ),
    );
    expect(() => json.requireInt('d'), throwsFormatException);
    expect(() => json.optionalString('i'), throwsFormatException);
    expect(() => json.requireMap('l'), throwsFormatException);
    expect(() => json.requireList('m'), throwsFormatException);
    expect(() => json.requireMapList('bad'), throwsFormatException);
  });
}
