import 'dart:convert';

import 'package:proyecto_comandero/core/logging/app_logger.dart';
import 'package:proyecto_comandero/core/utils/json_tolerante.dart';
import 'package:test/test.dart';

void main() {
  group('lectores escalares', () {
    test('enteroTolerante: ausente u otro tipo → null; entero → su valor', () {
      expect(enteroTolerante(null), isNull);
      expect(enteroTolerante('7'), isNull);
      expect(enteroTolerante(7.0), isNull);
      expect(enteroTolerante(true), isNull);
      expect(enteroTolerante([7]), isNull);
      expect(enteroTolerante(7), 7);
      expect(enteroTolerante(0), 0);
      expect(enteroTolerante(-3), -3);
    });

    test('enteroPositivoTolerante: solo enteros mayores que cero', () {
      expect(enteroPositivoTolerante(null), isNull);
      expect(enteroPositivoTolerante('2'), isNull);
      expect(enteroPositivoTolerante(2.0), isNull);
      expect(enteroPositivoTolerante(0), isNull);
      expect(enteroPositivoTolerante(-1), isNull);
      expect(enteroPositivoTolerante(1), 1);
      expect(enteroPositivoTolerante(12), 12);
    });

    test('booleanoTolerante: bool → su valor; otro → porDefecto', () {
      expect(booleanoTolerante(null), isFalse);
      expect(booleanoTolerante(null, porDefecto: true), isTrue);
      expect(booleanoTolerante('true'), isFalse);
      expect(booleanoTolerante(1, porDefecto: true), isTrue);
      expect(booleanoTolerante(true), isTrue);
      expect(booleanoTolerante(false, porDefecto: true), isFalse);
    });

    test('textoTolerante: texto no vacío → su valor; vacío u otro → null', () {
      expect(textoTolerante(null), isNull);
      expect(textoTolerante(''), isNull);
      expect(textoTolerante('   \n'), isNull);
      expect(textoTolerante(5), isNull);
      expect(textoTolerante('Ana'), 'Ana');
      // No recorta: solo comprueba que haya algo.
      expect(textoTolerante(' Ana '), ' Ana ');
    });

    test('fechaTolerante: ISO-8601 → fecha; otro texto u otro tipo → null', () {
      expect(fechaTolerante(null), isNull);
      expect(fechaTolerante('ayer'), isNull);
      expect(fechaTolerante(20261009), isNull);
      expect(
        fechaTolerante('2026-10-09T21:52:40.000'),
        DateTime(2026, 10, 9, 21, 52, 40),
      );
    });
  });

  group('listaTolerante', () {
    int leerX(Map<String, Object?> json) {
      final x = json['x'];
      if (x is! int) throw const FormatException('x no es entero');
      return x;
    }

    test('ausente o de otro tipo → lista vacía', () {
      expect(listaTolerante(null, leerX), isEmpty);
      expect(listaTolerante('x', leerX), isEmpty);
      expect(listaTolerante({'x': 1}, leerX), isEmpty);
    });

    test('lee los elementos válidos tras pasar por texto JSON', () {
      final Object? valor = jsonDecode('[{"x": 1}, {"x": 2}]');
      expect(listaTolerante(valor, leerX), [1, 2]);
    });

    test('descarta los no mapas y los que el lector rechaza, con registro', () {
      final registros = <LogRecord>[];
      configureLogging(level: Level.ALL, onRecord: registros.add);
      addTearDown(configureLogging);

      final Object? valor = jsonDecode(
        '[{"x": 1}, 3, "x", null, [1], {"x": "no"}, {"x": 2}]',
      );
      expect(listaTolerante(valor, leerX), [1, 2]);

      final mensajes = [
        for (final registro in registros)
          if (registro.level == Level.FINE) registro.message,
      ];
      expect(mensajes, hasLength(5));
      expect(
        mensajes.where((mensaje) => mensaje.contains('no es un objeto')),
        hasLength(4),
      );
      expect(
        mensajes.where((mensaje) => mensaje.contains('x no es entero')),
        hasLength(1),
      );
    });

    test('descarta el elemento cuyo lector lanza TypeError', () {
      int leerConCast(Map<String, Object?> json) => json['x'] as int;
      final Object? valor = jsonDecode('[{"x": 1}, {"x": "2"}, {"x": 3}]');
      expect(listaTolerante(valor, leerConCast), [1, 3]);
    });

    test('no atrapa otras excepciones del lector', () {
      int lanza(Map<String, Object?> json) => throw StateError('otra');
      expect(
        () => listaTolerante([<String, Object?>{}], lanza),
        throwsStateError,
      );
    });
  });
}
