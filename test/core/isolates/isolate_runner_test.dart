import 'dart:isolate';
import 'dart:typed_data';

import 'package:proyecto_comandero/core/errors/app_exception.dart';
import 'package:proyecto_comandero/core/isolates/isolate_runner.dart';
import 'package:test/test.dart';

int _sumOfSquares(List<int> values) =>
    values.fold(0, (total, value) => total + value * value);

String _currentIsolateName(Object? _) => Isolate.current.debugName ?? '';

Never _failWith(String message) => throw ValidationException(message);

Future<int> _asyncDouble(int value) async => value * 2;

Uint8List _filledBytes(int length) =>
    Uint8List(length)..fillRange(0, length, 7);

void main() {
  group('SpawningIsolateRunner', () {
    const runner = SpawningIsolateRunner();

    test('ejecuta una función top-level y devuelve su resultado', () async {
      expect(await runner.run(_sumOfSquares, [1, 2, 3]), 14);
    });

    test('el trabajo corre en un isolate distinto del llamante', () async {
      final name = await runner.run(
        _currentIsolateName,
        null,
        debugName: 'motor-de-prueba',
      );
      expect(name, 'motor-de-prueba');
      expect(Isolate.current.debugName, isNot('motor-de-prueba'));
    });

    test('propaga las excepciones tipadas del motor', () async {
      await expectLater(
        runner.run(_failWith, 'receta cíclica'),
        throwsA(
          isA<ValidationException>().having(
            (error) => error.message,
            'message',
            'receta cíclica',
          ),
        ),
      );
    });

    test('admite puntos de entrada asíncronos', () async {
      expect(await runner.run(_asyncDouble, 21), 42);
    });

    test('devuelve buffers binarios grandes', () async {
      final bytes = await runner.run(_filledBytes, 1 << 20);
      expect(bytes.length, 1 << 20);
      expect(bytes.first, 7);
      expect(bytes.last, 7);
    });
  });

  group('InlineIsolateRunner', () {
    const runner = InlineIsolateRunner();

    test('ejecuta en el isolate actual', () async {
      expect(await runner.run(_sumOfSquares, [2, 2]), 8);
      expect(
        await runner.run(_currentIsolateName, null),
        Isolate.current.debugName ?? '',
      );
    });

    test('convierte los errores síncronos en futuros fallidos', () async {
      await expectLater(
        runner.run(_failWith, 'merma fuera de rango'),
        throwsA(isA<ValidationException>()),
      );
    });
  });
}
