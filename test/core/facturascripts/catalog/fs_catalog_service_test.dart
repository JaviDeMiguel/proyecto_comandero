import 'dart:convert';

import 'package:proyecto_comandero/core/errors/app_exception.dart';
import 'package:proyecto_comandero/core/facturascripts/catalog/fs_catalog_service.dart';
import 'package:proyecto_comandero/core/facturascripts/fs_api.dart';
import 'package:test/test.dart';

import '../fs_fake_api.dart';

FsRecord _producto(
  int id,
  String referencia,
  String descripcion, {
  String? codfamilia,
  String? codimpuesto = 'IVA10',
  bool nostock = true,
  bool ventasinstock = true,
  bool secompra = false,
  bool sevende = true,
  bool bloqueado = false,
  double precio = 0,
}) => {
  'actualizado': '06-10-2026 22:52:12',
  'bloqueado': bloqueado,
  'codfabricante': null,
  'codfamilia': codfamilia,
  'codimpuesto': codimpuesto,
  'descripcion': descripcion,
  'excepcioniva': null,
  'fechaalta': '06-10-2026',
  'idproducto': id,
  'nostock': nostock,
  'observaciones': '',
  'precio': precio,
  'publico': false,
  'referencia': referencia,
  'secompra': secompra,
  'sevende': sevende,
  'stockfis': 0,
  'tipo': null,
  'ventasinstock': ventasinstock,
};

FsRecord _variante(
  int id,
  int idproducto,
  String referencia,
  double precio, {
  double coste = 0,
  String? codbarras,
}) => {
  'codbarras': codbarras,
  'coste': coste,
  'idatributovalor1': null,
  'idproducto': idproducto,
  'idvariante': id,
  'margen': 0,
  'precio': precio,
  'referencia': referencia,
  'stockfis': 0,
};

FsRecord _impuesto(String cod, String desc, num iva, {String? sub}) => {
  'activo': true,
  'codimpuesto': cod,
  'codsubcuentarep': sub ?? '',
  'codsubcuentasop': '',
  'descripcion': desc,
  'operacion': 'ES_01',
  'tipo': 1,
  'iva': iva,
  'recargo': 0,
};

FsRecord _familia(String cod, String desc, {String? madre}) => {
  'codfamilia': cod,
  'codsubcuentacom': null,
  'codsubcuentaven': null,
  'descripcion': desc,
  'madre': madre,
  'numproductos': 0,
};

Map<String, List<FsRecord>> _sandbox() => {
  'familias': [
    _familia('TAPAS', 'Tapas y raciones'),
    _familia('BEBIDAS', 'Bebidas'),
    _familia('PLATOS', 'Platos de cocina'),
    _familia('MATERIAS', 'Materias primas y semielaborados'),
    _familia('CONTA', 'Contabilidad'),
  ],
  'impuestos': [
    _impuesto('IVA21', 'IVA 21%', 21, sub: '4770000021'),
    _impuesto('IVA10', 'IVA 10%', 10, sub: '4770000010'),
    _impuesto('IVA4', 'IVA 4%', 4, sub: '4770000004'),
    _impuesto('IVA0', 'IVA 0%', 0),
    _impuesto('IGIC13.5', 'IGIC 13.5%', 13.5),
  ],
  'productos': [
    _producto(10, 'PAELLA', 'Paella valenciana (racion)', codfamilia: 'PLATOS'),
    _producto(13, 'CANA', 'Caña de cerveza', codfamilia: 'BEBIDAS'),
    _producto(
      15,
      'COCACOLA',
      'Coca-Cola lata',
      codfamilia: 'BEBIDAS',
      nostock: false,
      ventasinstock: false,
      secompra: true,
    ),
    _producto(
      16,
      'ARROZ',
      'Arroz bomba (kg)',
      codfamilia: 'MATERIAS',
      nostock: false,
      secompra: true,
      sevende: false,
    ),
    _producto(
      18,
      'PATATA',
      'Patata (kg)',
      codfamilia: 'MATERIAS',
      codimpuesto: 'IVA4',
      nostock: false,
      secompra: true,
      sevende: false,
    ),
    _producto(30, 'VIEJO', 'Plato retirado', bloqueado: true),
    _producto(31, 'SINIVA', 'Producto sin impuesto', codimpuesto: null),
    _producto(32, 'RARO', 'Impuesto inexistente', codimpuesto: 'IVAXX'),
    _producto(33, 'CANA2', 'Caña grande', codfamilia: 'BEBIDAS'),
  ],
  'variantes': [
    _variante(10, 10, 'PAELLA', 10.90909),
    _variante(13, 13, 'CANA', 0.86364),
    _variante(15, 15, 'COCACOLA', 2, coste: 0.6, codbarras: '5449000000996'),
    _variante(16, 16, 'ARROZ', 0, coste: 1.8),
    _variante(18, 18, 'PATATA', 0, coste: 0.9),
    _variante(30, 30, 'VIEJO', 5),
    _variante(31, 31, 'SINIVA', 1),
    _variante(32, 32, 'RARO', 1),
    _variante(33, 33, 'CANA2', 1.5),
    _variante(99, 999, 'HUERFANA', 1),
  ],
};

void main() {
  late FakeFsApi api;
  late FsCatalogService service;
  final fixedNow = DateTime(2026, 10, 7, 9, 30);

  setUp(() {
    api = FakeFsApi(records: _sandbox());
    service = FsCatalogService(api);
  });

  test('pagina los cuatro listados con el orden exigido', () async {
    await service.cargar(now: () => fixedNow);
    expect(api.calls, [
      'list familias offset=0 limit=200',
      'list impuestos offset=0 limit=200',
      'list productos offset=0 limit=200',
      'list variantes offset=0 limit=200',
    ]);
  });

  test(
    'une variante → producto → impuesto y calcula el PVP en céntimos',
    () async {
      final snapshot = await service.cargar(
        now: () => fixedNow,
        codimpuestoPorDefecto: 'IVA21',
      );
      expect(snapshot.obtenidoEn, fixedNow);

      final paella = snapshot.porReferencia('PAELLA')!;
      expect(paella.idproducto, 10);
      expect(paella.idvariante, 10);
      expect(paella.descripcion, 'Paella valenciana (racion)');
      expect(paella.codfamilia, 'PLATOS');
      expect(paella.codimpuesto, 'IVA10');
      expect(paella.ivaBp, 1000);
      expect(paella.precioNeto, 10.90909);
      expect(paella.pvpCents, 1200);
      expect(paella.nostock, isTrue);
      expect(paella.ventasinstock, isTrue);
      expect(paella.sevende, isTrue);
      expect(paella.secompra, isFalse);
      expect(paella.bloqueado, isFalse);
      expect(paella.vendible, isTrue);
      expect(paella.codbarras, isNull);
      expect(paella.coste, 0);

      expect(snapshot.porReferencia('CANA')!.pvpCents, 95);
      expect(snapshot.porReferencia('CANA2')!.pvpCents, 165);

      final cocacola = snapshot.porReferencia('COCACOLA')!;
      expect(cocacola.pvpCents, 220);
      expect(cocacola.codbarras, '5449000000996');
      expect(cocacola.coste, 0.6);

      final arroz = snapshot.porReferencia('ARROZ')!;
      expect(arroz.vendible, isFalse);
      expect(arroz.secompra, isTrue);
      expect(arroz.nostock, isFalse);
      expect(arroz.coste, 1.8);
      expect(arroz.pvpCents, 0);

      final patata = snapshot.porReferencia('PATATA')!;
      expect(patata.ivaBp, 400);

      expect(snapshot.porReferencia('VIEJO')!.vendible, isFalse);
      expect(snapshot.porReferencia('HUERFANA'), isNull);
      expect(snapshot.articulos, hasLength(9));
      expect(snapshot.vendibles.map((a) => a.referencia), [
        'PAELLA',
        'CANA',
        'COCACOLA',
        'SINIVA',
        'RARO',
        'CANA2',
      ]);
    },
  );

  test('familias e impuestos ordenados y con sus campos', () async {
    final snapshot = await service.cargar(now: () => fixedNow);
    expect(snapshot.familias.map((f) => f.codfamilia), [
      'BEBIDAS',
      'CONTA',
      'MATERIAS',
      'PLATOS',
      'TAPAS',
    ]);
    expect(snapshot.familias.first.descripcion, 'Bebidas');
    expect(snapshot.impuestos.map((i) => i.codimpuesto), [
      'IGIC13.5',
      'IVA0',
      'IVA10',
      'IVA21',
      'IVA4',
    ]);
    final iva10 = snapshot.impuesto('IVA10')!;
    expect(iva10.ivaBp, 1000);
    expect(iva10.recargoBp, 0);
    expect(iva10.codsubcuentarep, '4770000010');
    expect(snapshot.impuesto('IGIC13.5')!.ivaBp, 1350);
    expect(snapshot.impuesto('IVA0')!.codsubcuentarep, isNull);
  });

  test(
    'avisos: huérfana, impuesto desconocido/vacío, nostock=0+ventasinstock=0',
    () async {
      final snapshot = await service.cargar(
        now: () => fixedNow,
        codimpuestoPorDefecto: 'IVA21',
      );
      const huerfana =
          "variante 'HUERFANA' (idvariante 99) sin producto 999; ignorada";
      const sinIva =
          "producto 'SINIVA' con impuesto vacío; se aplica el impuesto por "
          "defecto 'IVA21'";
      const raro =
          "producto 'RARO' con impuesto 'IVAXX' desconocido; se aplica el "
          "impuesto por defecto 'IVA21'";
      const cocacola =
          'producto COCACOLA vendible con nostock=0 y ventasinstock=0 '
          '(FacturaScripts rechazará la factura si se agota)';
      expect(snapshot.avisos, containsAll([huerfana, sinIva, raro, cocacola]));
      expect(snapshot.avisos, hasLength(4));
      expect(snapshot.porReferencia('SINIVA')!.ivaBp, 2100);
      expect(snapshot.porReferencia('SINIVA')!.pvpCents, 121);
      expect(snapshot.porReferencia('RARO')!.codimpuesto, 'IVAXX');
      expect(snapshot.porReferencia('RARO')!.ivaBp, 2100);
    },
  );

  test('sin impuesto por defecto conocido se aplica IVA 0 con aviso', () async {
    final snapshot = await service.cargar(now: () => fixedNow);
    expect(snapshot.porReferencia('SINIVA')!.ivaBp, 0);
    expect(snapshot.porReferencia('SINIVA')!.pvpCents, 100);
    expect(
      snapshot.avisos,
      contains("producto 'SINIVA' con impuesto vacío; se aplica IVA 0"),
    );

    final otro = await service.cargar(
      now: () => fixedNow,
      codimpuestoPorDefecto: 'NOEXISTE',
    );
    expect(
      otro.avisos,
      contains(
        "el impuesto por defecto 'NOEXISTE' de los ajustes no existe en "
        'impuestos',
      ),
    );
    expect(otro.porReferencia('RARO')!.ivaBp, 0);
  });

  test(
    'la materia prima que no se vende no genera el aviso de stock',
    () async {
      final snapshot = await service.cargar(now: () => fixedNow);
      expect(snapshot.avisos.where((a) => a.contains('ARROZ')), isEmpty);
    },
  );

  test('tolera tipos de texto (respuesta de POST) en los registros', () async {
    api.records['productos'] = [
      {
        'idproducto': '10',
        'referencia': 'PAELLA',
        'descripcion': 'Paella',
        'codimpuesto': 'IVA10',
        'nostock': '1',
        'ventasinstock': '1',
        'secompra': '0',
        'sevende': '1',
        'bloqueado': '0',
      },
    ];
    api.records['variantes'] = [
      {
        'idvariante': '10',
        'idproducto': '10',
        'referencia': 'PAELLA',
        'precio': '10.90909',
        'coste': '',
        'codbarras': '',
      },
    ];
    final snapshot = await service.cargar(now: () => fixedNow);
    final paella = snapshot.articulos.single;
    expect(paella.idproducto, 10);
    expect(paella.pvpCents, 1200);
    expect(paella.nostock, isTrue);
    expect(paella.secompra, isFalse);
    expect(paella.coste, 0);
    expect(paella.codbarras, isNull);
  });

  test('un registro ininterpretable se traduce a ErpApiException', () async {
    api.records['variantes']!.add({'idvariante': 'abc', 'idproducto': 10});
    await expectLater(
      service.cargar(now: () => fixedNow),
      throwsA(
        isA<ErpApiException>()
            .having((e) => e.kind, 'kind', ErpApiErrorKind.unexpected)
            .having((e) => e.message, 'message', contains('variantes'))
            .having((e) => e.cause, 'cause', isA<FormatException>()),
      ),
    );
  });

  test('los errores de la API se propagan', () async {
    api.failures['productos'] = const ErpApiException('caído', statusCode: 503);
    await expectLater(
      service.cargar(now: () => fixedNow),
      throwsA(
        isA<ErpApiException>().having(
          (e) => e.kind,
          'kind',
          ErpApiErrorKind.server,
        ),
      ),
    );
  });

  group('CatalogSnapshot JSON', () {
    test('toJson / fromJson es una identidad (vía jsonEncode)', () async {
      final snapshot = await service.cargar(
        now: () => fixedNow,
        codimpuestoPorDefecto: 'IVA21',
      );
      final text = jsonEncode(snapshot.toJson());
      final decoded = jsonDecode(text) as Map<String, Object?>;
      final restored = CatalogSnapshot.fromJson(decoded);
      expect(restored, snapshot);
      expect(restored.obtenidoEn, fixedNow);
      expect(restored.avisos, snapshot.avisos);
    });

    test('fromJson rechaza formas incorrectas con FormatException', () {
      expect(
        () => CatalogSnapshot.fromJson({'familias': <Object?>[]}),
        throwsFormatException,
      );
      expect(
        () => ArticuloCatalogo.fromJson({'referencia': 'X'}),
        throwsFormatException,
      );
    });
  });

  group('ArticuloCatalogo.pvpCentsFrom', () {
    test('redondea como PHP round() con tolerancia binaria', () {
      expect(ArticuloCatalogo.pvpCentsFrom(10.90909, 1000), 1200);
      expect(ArticuloCatalogo.pvpCentsFrom(0.86364, 1000), 95);
      expect(ArticuloCatalogo.pvpCentsFrom(4.09091, 1000), 450);
      expect(ArticuloCatalogo.pvpCentsFrom(1.18182, 1000), 130);
      expect(ArticuloCatalogo.pvpCentsFrom(2, 1000), 220);
      expect(ArticuloCatalogo.pvpCentsFrom(1.005, 0), 101);
      expect(ArticuloCatalogo.pvpCentsFrom(0, 2100), 0);
      expect(ArticuloCatalogo.pvpCentsFrom(12.39669, 2100), 1500);
    });
  });
}
