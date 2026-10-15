import 'dart:convert';

import 'package:proyecto_comandero/features/sala/domain/pases.dart';
import 'package:test/test.dart';

/// Serializa y vuelve a leer pasando por texto JSON, como en el cable.
Map<String, Object?> ida(Map<String, Object?> json) =>
    jsonDecode(jsonEncode(json)) as Map<String, Object?>;

void main() {
  group('PasesConfig', () {
    test('valores por defecto', () {
      const config = PasesConfig();
      expect(config.activos, isTrue);
      expect(config.nombres, ['Primeros', 'Segundos', 'Postres']);
      expect(config.nombres, PasesConfig.porDefecto);
      expect(config.marcharAlEnviar, isTrue);
      expect(config.numPases, 3);
      expect(PasesConfig.maxPases, 5);
      expect(PasesConfig.maxLongitudNombre, 16);
    });

    test(
      'existe, nombreDe y etiqueta: fuera de la configuración, «Pase N»',
      () {
        const config = PasesConfig();
        expect(config.existe(-1), isFalse);
        expect(config.existe(0), isFalse);
        expect(config.existe(1), isTrue);
        expect(config.existe(3), isTrue);
        expect(config.existe(4), isFalse);
        expect(config.nombreDe(1), 'Primeros');
        expect(config.nombreDe(2), 'Segundos');
        expect(config.nombreDe(3), 'Postres');
        expect(config.nombreDe(4), 'Pase 4');
        expect(config.nombreDe(7), 'Pase 7');
        expect(config.nombreDe(0), 'Pase 0');
        expect(config.etiqueta(null), 'Directo');
        expect(config.etiqueta(1), '1. Primeros');
        expect(config.etiqueta(2), '2. Segundos');
        expect(config.etiqueta(7), '7. Pase 7');
      },
    );

    test('con un solo pase', () {
      const config = PasesConfig(nombres: ['Único']);
      expect(config.numPases, 1);
      expect(config.existe(1), isTrue);
      expect(config.existe(2), isFalse);
      expect(config.etiqueta(1), '1. Único');
      expect(config.etiqueta(2), '2. Pase 2');
    });

    test('toJson siempre completo e ida y vuelta', () {
      const config = PasesConfig(
        activos: false,
        nombres: ['Entrantes', 'Principales'],
        marcharAlEnviar: false,
      );
      final json = ida(config.toJson());
      expect(json, {
        'activos': false,
        'nombres': ['Entrantes', 'Principales'],
        'marcharAlEnviar': false,
      });
      expect(PasesConfig.fromJson(json), config);
      // También con los valores por defecto: nunca se omite nada.
      final porDefecto = ida(const PasesConfig().toJson());
      expect(porDefecto, {
        'activos': true,
        'nombres': ['Primeros', 'Segundos', 'Postres'],
        'marcharAlEnviar': true,
      });
      expect(PasesConfig.fromJson(porDefecto), const PasesConfig());
    });

    test('fromJson: lo que falta toma su valor por defecto', () {
      expect(PasesConfig.fromJson(const {}), const PasesConfig());
      expect(
        PasesConfig.fromJson(const {'activos': false}),
        const PasesConfig(activos: false),
      );
      expect(
        PasesConfig.fromJson(const {
          'nombres': ['A', 'B'],
        }),
        const PasesConfig(nombres: ['A', 'B']),
      );
      expect(
        PasesConfig.fromJson(const {'marcharAlEnviar': false}),
        const PasesConfig(marcharAlEnviar: false),
      );
    });

    test('fromJson estricto: 0 o 6 nombres, nombre vacío, 17 caracteres o '
        'tipos inválidos lanzan FormatException', () {
      final seis = [for (var i = 1; i <= 6; i++) 'Pase $i'];
      for (final json in <Map<String, Object?>>[
        {'nombres': <Object?>[]},
        {'nombres': seis},
        {
          'nombres': ['Primeros', ''],
        },
        {
          'nombres': ['Primeros', '   '],
        },
        {
          'nombres': ['A' * 17],
        },
        {
          'nombres': ['Primeros', 2],
        },
        {'nombres': 'Primeros'},
        {'activos': 'sí'},
        {'marcharAlEnviar': 1},
      ]) {
        expect(
          () => PasesConfig.fromJson(json),
          throwsFormatException,
          reason: '$json',
        );
      }
      // Los límites se admiten.
      final cinco = [for (var i = 1; i <= 5; i++) 'Pase $i'];
      expect(PasesConfig.fromJson({'nombres': cinco}).numPases, 5);
      expect(
        PasesConfig.fromJson({
          'nombres': ['A' * 16],
        }).nombreDe(1),
        'A' * 16,
      );
      expect(
        PasesConfig.fromJson(const {
          'nombres': ['Solo'],
        }).numPases,
        1,
      );
    });

    test('tolerante devuelve null con tipos o valores raros y nunca lanza', () {
      for (final raw in <Object?>[
        null,
        'x',
        3,
        true,
        <Object?>[],
        {'nombres': <Object?>[]},
        {'activos': 'x'},
        {
          'nombres': ['A' * 17],
        },
        <Object?, Object?>{1: 2},
      ]) {
        expect(PasesConfig.tolerante(raw), isNull, reason: '$raw');
      }
      expect(
        PasesConfig.tolerante(const <String, Object?>{}),
        const PasesConfig(),
      );
      expect(
        PasesConfig.tolerante(ida(const PasesConfig(activos: false).toJson())),
        const PasesConfig(activos: false),
      );
    });

    test('copyWith conserva lo que no cambia', () {
      const base = PasesConfig();
      final copia = base.copyWith(activos: false, nombres: ['Uno', 'Dos']);
      expect(copia.activos, isFalse);
      expect(copia.nombres, ['Uno', 'Dos']);
      expect(copia.marcharAlEnviar, isTrue);
      expect(base.copyWith(), base);
      expect(copia.copyWith(marcharAlEnviar: false).nombres, ['Uno', 'Dos']);
      expect(copia.copyWith(marcharAlEnviar: false).activos, isFalse);
      expect(base, isNot(copia));
      expect(base.nombres, PasesConfig.porDefecto, reason: 'no se muta');
    });

    test('las listas leídas o copiadas no se pueden modificar', () {
      final leida = PasesConfig.fromJson(const {
        'nombres': ['A', 'B'],
      });
      expect(() => leida.nombres.add('C'), throwsUnsupportedError);
      final copiada = const PasesConfig().copyWith(nombres: ['X']);
      expect(() => copiada.nombres.add('Y'), throwsUnsupportedError);
    });
  });
}
