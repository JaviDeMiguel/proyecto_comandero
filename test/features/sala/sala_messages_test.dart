import 'dart:convert';
import 'dart:io';

import 'package:proyecto_comandero/features/sala/domain/comanda.dart';
import 'package:proyecto_comandero/features/sala/domain/enrutamiento_comandas.dart';
import 'package:proyecto_comandero/features/sala/domain/linea_comanda.dart';
import 'package:proyecto_comandero/features/sala/domain/mesa.dart';
import 'package:proyecto_comandero/features/sala/domain/pases.dart';
import 'package:proyecto_comandero/features/sala/protocol/sala_messages.dart';
import 'package:test/test.dart';

/// Lee una fixture de compatibilidad y devuelve su texto normalizado (los
/// finales de línea dependen de `core.autocrlf` al clonar).
String fixture(String nombre) =>
    File('test/fixtures/compat/$nombre')
        .readAsStringSync()
        .replaceAll('\r\n', '\n')
        .trimRight();

const JsonEncoder encoder = JsonEncoder.withIndent('  ');

/// Serializa y vuelve a leer pasando por texto JSON, como en el cable.
Map<String, Object?> ida(Map<String, Object?> json) =>
    jsonDecode(jsonEncode(json)) as Map<String, Object?>;

final DateTime generado = DateTime(2026, 10, 9, 13, 30);

LineaComanda linea(String id) => LineaComanda(
  id: id,
  referencia: 'CANA',
  descripcion: 'Caña',
  cantidad: 1,
  pvpUnitarioCents: 95,
  pvpUnitarioNeto: 0.86364,
  ivaBp: 1000,
  codimpuesto: 'IVA10',
  creadaEn: generado,
);

SalaSnapshot snapshot({
  PasesConfig? pases,
  List<Comanda> comandas = const [],
}) => SalaSnapshot(
  mesas: const [Mesa(id: 'm1', nombre: 'Mesa 1')],
  comandas: comandas,
  catalogoVersion: 'v1',
  generadoEn: generado,
  enrutamiento: const EnrutamientoComandas(
    porFamilia: {'BEB': DestinoPreparacion.barra},
  ),
  pases: pases,
);

void main() {
  group('tipos de mensaje y códigos de error', () {
    test('la petición de marchar y sus códigos de error nuevos', () {
      expect(SalaMessageTypes.paseMarchar, 'comanda.pase.marchar');
      expect(SalaErrorCodes.paseNoValido, 'pase_no_valido');
      expect(SalaErrorCodes.paseSinLineas, 'pase_sin_lineas');
    });

    test('los tipos y códigos existentes no cambian', () {
      expect(SalaMessageTypes.comandaSubmit, 'comanda.submit');
      expect(SalaMessageTypes.enrutamientoChanged, 'enrutamiento.changed');
      expect(SalaErrorCodes.mesaDesconocida, 'mesa_desconocida');
      expect(SalaErrorCodes.mesaSinComanda, 'mesa_sin_comanda');
    });
  });

  group('SalaSnapshot.pases', () {
    test('viaja en el JSON del snapshot, con activos true o false', () {
      for (final pases in [
        const PasesConfig(),
        const PasesConfig(
          activos: false,
          nombres: ['Único'],
          marcharAlEnviar: false,
        ),
      ]) {
        final s = snapshot(pases: pases);
        final json = ida(s.toJson());
        expect(json['pases'], pases.toJson());
        final leido = SalaSnapshot.fromJson(json);
        expect(leido, s);
        expect(leido.pases, pases);
      }
    });

    test('sin pases no se escribe la clave y un JSON antiguo da null', () {
      final json = ida(snapshot().toJson());
      expect(json.containsKey('pases'), isFalse);
      expect(SalaSnapshot.fromJson(json).pases, isNull);
      final antiguo = SalaSnapshot.fromJson({
        'mesas': <Object?>[],
        'comandas': <Object?>[],
        'generadoEn': generado.toIso8601String(),
      });
      expect(antiguo.pases, isNull);
      expect(antiguo.enrutamiento, isNull);
    });

    test('un pases raro se ignora sin invalidar el snapshot', () {
      for (final raro in <Object?>[
        'x',
        7,
        <Object?>[],
        {'nombres': <Object?>[]},
        {'activos': 'sí'},
      ]) {
        final json = ida(snapshot().toJson())..['pases'] = raro;
        final leido = SalaSnapshot.fromJson(json);
        expect(leido.pases, isNull, reason: '$raro');
        expect(leido.mesas.single.id, 'm1');
        expect(leido.enrutamiento, isNotNull);
      }
    });

    test('conComanda conserva pases', () {
      const pases = PasesConfig(activos: false);
      final comanda = Comanda(
        id: 'c1',
        mesaId: 'm1',
        abiertaEn: generado,
        lineas: [linea('l1')],
      );
      final con = snapshot(pases: pases)
          .conComanda('m1', comanda, generadoEn: generado);
      expect(con.pases, pases);
      expect(con.comandaDeMesa('m1'), comanda);
      expect(con.enrutamiento, isNotNull);
      final sin = con.conComanda('m1', null, generadoEn: generado);
      expect(sin.comandas, isEmpty);
      expect(sin.pases, pases);
    });

    test('props distingue pases', () {
      expect(snapshot(pases: const PasesConfig()), isNot(snapshot()));
      expect(
        snapshot(pases: const PasesConfig()),
        snapshot(pases: const PasesConfig()),
      );
    });
  });

  group('MarcharPasePayload', () {
    test(
      'ida y vuelta completa y mínima (comandaId y camarero opcionales)',
      () {
        const completo = MarcharPasePayload(
          mesaId: 'mesa-7',
          pase: 2,
          marchaId: '5b1f2c7a',
          comandaId: 'c-7f3a',
          camarero: 'Ana',
        );
        final json = ida(completo.toJson());
        expect(json, {
          'mesaId': 'mesa-7',
          'pase': 2,
          'marchaId': '5b1f2c7a',
          'comandaId': 'c-7f3a',
          'camarero': 'Ana',
        });
        expect(MarcharPasePayload.fromJson(json), completo);

        const minimo = MarcharPasePayload(
          mesaId: 'mesa-7',
          pase: 1,
          marchaId: 'm',
        );
        final jsonMinimo = ida(minimo.toJson());
        expect(jsonMinimo, {'mesaId': 'mesa-7', 'pase': 1, 'marchaId': 'm'});
        final leido = MarcharPasePayload.fromJson(jsonMinimo);
        expect(leido, minimo);
        expect(leido.comandaId, isNull);
        expect(leido.camarero, isNull);
        expect(minimo, isNot(completo));
      },
    );

    test('validaciones: campos obligatorios, pase < 1 y marchaId vacío o de '
        'más de 64 caracteres', () {
      const valido = <String, Object?>{
        'mesaId': 'mesa-7',
        'pase': 2,
        'marchaId': 'abc',
      };
      expect(MarcharPasePayload.fromJson(valido).pase, 2);
      for (final json in <Map<String, Object?>>[
        {...valido}..remove('mesaId'),
        {...valido}..remove('pase'),
        {...valido}..remove('marchaId'),
        {...valido, 'pase': 0},
        {...valido, 'pase': -2},
        {...valido, 'pase': '2'},
        {...valido, 'pase': 2.0},
        {...valido, 'marchaId': ''},
        {...valido, 'marchaId': 'a' * 65},
        {...valido, 'marchaId': 7},
        {...valido, 'mesaId': 3},
        {...valido, 'comandaId': 1},
        {...valido, 'camarero': true},
      ]) {
        expect(
          () => MarcharPasePayload.fromJson(json),
          throwsFormatException,
          reason: '$json',
        );
      }
      expect(MarcharPasePayload.maxLongitudMarchaId, 64);
      expect(
        MarcharPasePayload.fromJson({...valido, 'marchaId': 'a' * 64}).marchaId,
        'a' * 64,
      );
      expect(MarcharPasePayload.fromJson({...valido, 'pase': 1}).pase, 1);
    });

    test('un pase fuera de la configuración es válido en el payload', () {
      final leido = MarcharPasePayload.fromJson(const {
        'mesaId': 'm',
        'pase': 7,
        'marchaId': 'x',
      });
      expect(leido.pase, 7);
    });
  });

  group('ComandaSubmitPayload', () {
    test('comandaId solo se escribe si no es nulo', () {
      final sin = ComandaSubmitPayload(
        mesaId: 'm1',
        lineas: [linea('l1')],
        camarero: 'Ana',
        comensales: 2,
      );
      final jsonSin = ida(sin.toJson());
      expect(jsonSin.containsKey('comandaId'), isFalse);
      final leidoSin = ComandaSubmitPayload.fromJson(jsonSin);
      expect(leidoSin, sin);
      expect(leidoSin.comandaId, isNull);

      // Envío de solo comensales: sin líneas y con la comanda que se ve.
      final con = ComandaSubmitPayload(
        mesaId: 'm1',
        lineas: const [],
        comensales: 4,
        comandaId: 'c-7f3a',
      );
      final jsonCon = ida(con.toJson());
      expect(jsonCon, {
        'mesaId': 'm1',
        'lineas': <Object?>[],
        'comensales': 4,
        'comandaId': 'c-7f3a',
      });
      final leidoCon = ComandaSubmitPayload.fromJson(jsonCon);
      expect(leidoCon, con);
      expect(leidoCon.comandaId, 'c-7f3a');
      expect(
        con,
        isNot(
          ComandaSubmitPayload(mesaId: 'm1', lineas: const [], comensales: 4),
        ),
      );
    });

    test('un comandaId con tipo inválido es un error de validación', () {
      expect(
        () => ComandaSubmitPayload.fromJson({
          'mesaId': 'm1',
          'lineas': <Object?>[],
          'comandaId': 5,
        }),
        throwsFormatException,
      );
    });

    test('copyWith cambia camarero o comensales y conserva el resto', () {
      final base = ComandaSubmitPayload(
        mesaId: 'm1',
        lineas: [linea('l1'), linea('l2')],
        comensales: 2,
        comandaId: 'c1',
      );
      final conCamarero = base.copyWith(camarero: 'Tablet 2');
      expect(conCamarero.camarero, 'Tablet 2');
      expect(conCamarero.mesaId, 'm1');
      expect(conCamarero.lineas, base.lineas);
      expect(conCamarero.comensales, 2);
      expect(conCamarero.comandaId, 'c1');
      expect(base.camarero, isNull, reason: 'no se muta');
      expect(base.copyWith(comensales: 5).comensales, 5);
      expect(base.copyWith(comensales: 5).camarero, isNull);
      expect(base.copyWith(), base);
      final conAmbos = base.copyWith(camarero: 'Ana', comensales: 3);
      expect(
        conAmbos,
        ComandaSubmitPayload(
          mesaId: 'm1',
          lineas: base.lineas,
          camarero: 'Ana',
          comensales: 3,
          comandaId: 'c1',
        ),
      );
      // Un camarero ya puesto no se pisa con null.
      expect(conAmbos.copyWith(comensales: 4).camarero, 'Ana');
    });
  });

  group('compatibilidad', () {
    test('sala_snapshot_v1.json se lee y se reescribe byte a byte igual', () {
      final texto = fixture('sala_snapshot_v1.json');
      final json = jsonDecode(texto) as Map<String, Object?>;
      final snapshot = SalaSnapshot.fromJson(json);
      expect(snapshot.mesas, hasLength(4));
      expect(snapshot.comandas, hasLength(2));
      expect(snapshot.enrutamiento, isNotNull);
      // Un host antiguo no publica pases: el campo queda nulo y no se escribe.
      expect(snapshot.pases, isNull);
      expect(texto, isNot(contains('"pases"')));
      expect(encoder.convert(snapshot.toJson()), texto);
    });
  });
}
