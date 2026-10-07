import 'dart:convert';

import 'package:proyecto_comandero/core/facturascripts/catalog/catalog_models.dart';
import 'package:proyecto_comandero/core/utils/json_map.dart';
import 'package:proyecto_comandero/features/sala/domain/comanda.dart';
import 'package:proyecto_comandero/features/sala/domain/enrutamiento_comandas.dart';
import 'package:proyecto_comandero/features/sala/domain/linea_comanda.dart';
import 'package:proyecto_comandero/features/sala/domain/mesa.dart';
import 'package:proyecto_comandero/features/sala/protocol/sala_messages.dart';
import 'package:test/test.dart';

const DestinoPreparacion cocina = DestinoPreparacion.cocina;
const DestinoPreparacion barra = DestinoPreparacion.barra;

/// Bebidas ⊃ Cervezas ⊃ Artesanas; Comidas ⊃ Postres.
const List<FamiliaCatalogo> familias = [
  FamiliaCatalogo(codfamilia: 'BEB', descripcion: 'Bebidas'),
  FamiliaCatalogo(codfamilia: 'CER', descripcion: 'Cervezas', madre: 'BEB'),
  FamiliaCatalogo(codfamilia: 'ART', descripcion: 'Artesanas', madre: 'CER'),
  FamiliaCatalogo(codfamilia: 'COM', descripcion: 'Comidas'),
  FamiliaCatalogo(codfamilia: 'POS', descripcion: 'Postres', madre: 'COM'),
];

Map<String, Object?> ida(Map<String, Object?> json) =>
    (jsonDecode(jsonEncode(json)) as Map).cast<String, Object?>();

void main() {
  final madreDe = EnrutamientoComandas.jerarquia(familias);

  group('destinoDe', () {
    test('sin reglas todo va a cocina', () {
      const e = EnrutamientoComandas();
      expect(e.destinoDe('BEB', madreDe: madreDe), cocina);
      expect(e.destinoDe(null), cocina);
      expect(e.todoACocina, isTrue);
    });

    test('regla propia, herencia por madre y abuela, y por defecto', () {
      const e = EnrutamientoComandas(porFamilia: {'BEB': barra});
      expect(e.destinoDe('BEB', madreDe: madreDe), barra);
      expect(e.destinoDe('CER', madreDe: madreDe), barra);
      expect(e.destinoDe('ART', madreDe: madreDe), barra, reason: 'abuela');
      expect(e.destinoDe('POS', madreDe: madreDe), cocina);
      expect(e.destinoDe(null, madreDe: madreDe), cocina);
      expect(e.destinoDe('', madreDe: madreDe), cocina);
      expect(e.destinoDe('DESCONOCIDA', madreDe: madreDe), cocina);
      // Sin jerarquía no hay herencia.
      expect(e.destinoDe('CER'), cocina);
      expect(e.todoACocina, isFalse);
    });

    test('la regla más cercana gana a la de la antecesora', () {
      const e = EnrutamientoComandas(
        porFamilia: {'BEB': barra, 'CER': cocina},
        porDefecto: barra,
      );
      expect(e.destinoDe('ART', madreDe: madreDe), cocina);
      expect(e.origenDe('ART', madreDe: madreDe), (
        destino: cocina,
        familia: 'CER',
      ));
      expect(e.destinoDe('POS', madreDe: madreDe), barra);
      expect(e.origenDe('POS', madreDe: madreDe), (
        destino: barra,
        familia: null,
      ));
    });

    test('un ciclo en la jerarquía no cuelga: usa el destino por defecto', () {
      const ciclo = {'A': 'B', 'B': 'C', 'C': 'A', 'D': 'D'};
      const e = EnrutamientoComandas(porDefecto: barra);
      expect(e.destinoDe('A', madreDe: ciclo), barra);
      expect(e.destinoDe('D', madreDe: ciclo), barra);
      const conRegla = EnrutamientoComandas(porFamilia: {'C': cocina});
      expect(conRegla.destinoDe('A', madreDe: ciclo), cocina);
    });

    test('jerarquia trata madres vacías como raíz', () {
      final j = EnrutamientoComandas.jerarquia(const [
        FamiliaCatalogo(codfamilia: 'X', descripcion: 'X', madre: ''),
        FamiliaCatalogo(codfamilia: 'Y', descripcion: 'Y', madre: 'X'),
      ]);
      const e = EnrutamientoComandas(porFamilia: {'X': barra});
      expect(e.destinoDe('Y', madreDe: j), barra);
      expect(
        const EnrutamientoComandas(porFamilia: {'': barra})
            .destinoDe('X', madreDe: j),
        cocina,
      );
    });
  });

  group('edición', () {
    test('conRegla añade, cambia y quita (heredar) sin mutar el original', () {
      const base = EnrutamientoComandas();
      final conBarra = base.conRegla('BEB', barra);
      expect(conBarra.reglaDe('BEB'), barra);
      expect(base.porFamilia, isEmpty);
      final heredando = conBarra.conRegla('BEB', null);
      expect(heredando.reglaDe('BEB'), isNull);
      expect(heredando, base);
      expect(() => conBarra.porFamilia['X'] = cocina, throwsUnsupportedError);
    });

    test('conPorDefecto y usa', () {
      final e = const EnrutamientoComandas().conPorDefecto(barra);
      expect(e.porDefecto, barra);
      expect(e.usa(barra), isTrue);
      expect(e.usa(cocina), isFalse);
      expect(e.conRegla('COM', cocina).usa(cocina), isTrue);
    });
  });

  group('JSON', () {
    test('ida y vuelta', () {
      const e = EnrutamientoComandas(
        porFamilia: {'BEB': barra, 'POS': cocina},
        porDefecto: barra,
      );
      final json = ida(e.toJson());
      expect(json, {
        'porDefecto': 'barra',
        'porFamilia': {'BEB': 'barra', 'POS': 'cocina'},
      });
      expect(EnrutamientoComandas.fromJson(json), e);
    });

    test('tolerante con lo que falta', () {
      expect(
        EnrutamientoComandas.fromJson(const {}),
        const EnrutamientoComandas(),
      );
      expect(
        EnrutamientoComandas.fromJson(const {
          'porFamilia': {'BEB': 'barra'},
        }),
        const EnrutamientoComandas(porFamilia: {'BEB': barra}),
      );
      expect(
        EnrutamientoComandas.fromJson(const {'porDefecto': 'barra'}),
        const EnrutamientoComandas(porDefecto: barra),
      );
    });

    test('valores inválidos → FormatException', () {
      for (final json in <Map<String, Object?>>[
        {'porDefecto': 'terraza'},
        {'porDefecto': 3},
        {
          'porFamilia': {'BEB': 'terraza'},
        },
        {
          'porFamilia': {'BEB': 1},
        },
        {'porFamilia': 'BEB'},
        {
          'porFamilia': {' ': 'barra'},
        },
      ]) {
        expect(
          () => EnrutamientoComandas.fromJson(json),
          throwsFormatException,
          reason: '$json',
        );
      }
    });

    test('el mapa leído no se puede modificar', () {
      final e = EnrutamientoComandas.fromJson(const {
        'porFamilia': {'BEB': 'barra'},
      });
      expect(() => e.porFamilia['X'] = cocina, throwsUnsupportedError);
    });
  });

  group('SalaSnapshot.enrutamiento', () {
    final generado = DateTime(2026, 10, 7, 12);
    SalaSnapshot snapshot(EnrutamientoComandas? enrutamiento) => SalaSnapshot(
      mesas: const [Mesa(id: 'm1', nombre: 'Mesa 1')],
      comandas: const [],
      generadoEn: generado,
      enrutamiento: enrutamiento,
    );

    test('viaja en el JSON del snapshot', () {
      final s = snapshot(
        const EnrutamientoComandas(porFamilia: {'BEB': barra}),
      );
      final json = ida(s.toJson());
      expect(json.optionalMap('enrutamiento'), isNotNull);
      expect(SalaSnapshot.fromJson(json), s);
    });

    test('un host antiguo (sin el campo) da null', () {
      final json = ida(snapshot(null).toJson());
      expect(json.containsKey('enrutamiento'), isFalse);
      expect(SalaSnapshot.fromJson(json).enrutamiento, isNull);
    });

    test('un enrutamiento que no se entiende se ignora sin invalidar el '
        'snapshot', () {
      final json = ida(snapshot(null).toJson())
        ..['enrutamiento'] = {'porDefecto': 'terraza'};
      final leido = SalaSnapshot.fromJson(json);
      expect(leido.enrutamiento, isNull);
      expect(leido.mesas.single.id, 'm1');
      json['enrutamiento'] = 'barra';
      expect(SalaSnapshot.fromJson(json).enrutamiento, isNull);
    });

    test('conComanda conserva el enrutamiento', () {
      const e = EnrutamientoComandas(porFamilia: {'BEB': barra});
      final comanda = Comanda(id: 'c1', mesaId: 'm1', abiertaEn: generado);
      final con = snapshot(e).conComanda('m1', comanda, generadoEn: generado);
      expect(con.enrutamiento, e);
      expect(con.comandaDeMesa('m1'), comanda);
      final sin = con.conComanda('m1', null, generadoEn: generado);
      expect(sin.comandas, isEmpty);
      expect(sin.enrutamiento, e);
    });
  });

  test('LineaComanda.copyWith cambia el destino', () {
    final linea = LineaComanda(
      id: 'l1',
      referencia: 'CANA',
      descripcion: 'Caña',
      cantidad: 1,
      pvpUnitarioCents: 95,
      pvpUnitarioNeto: 0.86364,
      ivaBp: 1000,
      creadaEn: DateTime(2026, 10, 7),
    );
    expect(linea.copyWith(destino: barra).destino, barra);
    expect(linea.copyWith().destino, cocina);
  });
}
