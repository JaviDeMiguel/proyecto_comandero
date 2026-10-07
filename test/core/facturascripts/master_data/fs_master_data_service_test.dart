import 'package:proyecto_comandero/core/errors/app_exception.dart';
import 'package:proyecto_comandero/core/facturascripts/fs_api.dart';
import 'package:proyecto_comandero/core/facturascripts/fs_resources.dart';
import 'package:proyecto_comandero/core/facturascripts/master_data/fs_master_data_service.dart';
import 'package:test/test.dart';

import '../fs_fake_api.dart';

// Fixtures copiados de las respuestas reales del sandbox (GET: tipos nativos,
// fechas d-m-Y, `properties` de settings como texto JSON).
const _settingsProperties =
    '{"codpais":"ESP","currency_position":"right","item_limit":50,'
    '"decimals":2,"decimal_separator":",","thousands_separator":" ",'
    '"idempresa":1,"coddivisa":"EUR","codimpuesto":"IVA21","codpago":"CONT",'
    '"codserie":"A","codserierec":"R","tipoidfiscal":"NIF",'
    '"updatesupplierprices":true,"validate_iban":true,"regimeniva":"General",'
    '"homepage":"Root","codalmacen":"ALG","ventasinstock":true,'
    '"site_url":"http:\\/\\/127.0.0.1:8765","codretencion":null,'
    '"finofertadays":null,"codrole":"employee"}';

final Map<String, List<FsRecord>> _sandbox = {
  'settings': [
    {'name': 'default', 'properties': _settingsProperties},
  ],
  'empresas': [
    {
      'administrador': '',
      'apartado': '',
      'cifnif': 'B12345674',
      'ciudad': 'Madrid',
      'codpais': 'ESP',
      'codpostal': '28001',
      'direccion': 'Calle de Pruebas 1',
      'email': 'sandbox@example.invalid',
      'fax': null,
      'fechaalta': null,
      'idempresa': 1,
      'idlogo': null,
      'nombre': 'Bar Sandbox TPV S.L.',
      'nombrecorto': 'Bar Sandbox TPV S.L.',
      'observaciones': null,
      'personafisica': false,
      'provincia': 'Madrid',
      'regimeniva': 'General',
      'telefono1': '910000000',
      'telefono2': '',
      'tipoidfiscal': 'CIF',
      'web': '',
    },
  ],
  'series': [
    {
      'canal': null,
      'codserie': 'S',
      'descripcion': 'Simplificadas',
      'iddiario': null,
      'siniva': false,
      'tipo': 'S',
    },
    {
      'canal': null,
      'codserie': 'A',
      'descripcion': 'General',
      'iddiario': null,
      'siniva': false,
      'tipo': '',
    },
    {
      'canal': null,
      'codserie': 'R',
      'descripcion': 'Rectificativas',
      'iddiario': null,
      'siniva': false,
      'tipo': 'R',
    },
  ],
  'formapagos': [
    {
      'activa': true,
      'codcuentabanco': null,
      'codpago': 'CONT',
      'descripcion': 'Al contado',
      'domiciliado': false,
      'idempresa': 1,
      'imprimir': true,
      'pagado': false,
      'plazovencimiento': 0,
      'tipovencimiento': 'days',
    },
    {
      'activa': true,
      'codcuentabanco': '9001',
      'codpago': 'TPVEFE',
      'descripcion': 'Efectivo (TPV)',
      'domiciliado': false,
      'idempresa': 1,
      'imprimir': true,
      'pagado': true,
      'plazovencimiento': 0,
      'tipovencimiento': 'days',
    },
    {
      'activa': true,
      'codcuentabanco': '9002',
      'codpago': 'TPVTAR',
      'descripcion': 'Tarjeta (TPV)',
      'domiciliado': false,
      'idempresa': 1,
      'imprimir': true,
      'pagado': false,
      'plazovencimiento': 0,
      'tipovencimiento': 'days',
    },
    {
      'activa': false,
      'codcuentabanco': null,
      'codpago': 'VIEJA',
      'descripcion': 'Desactivada',
      'domiciliado': false,
      'idempresa': 1,
      'imprimir': true,
      'pagado': true,
      'plazovencimiento': 0,
      'tipovencimiento': 'days',
    },
  ],
  'almacenes': [
    {
      'activo': true,
      'apartado': null,
      'ciudad': 'Madrid',
      'codalmacen': 'ALG',
      'codpais': 'ESP',
      'codpostal': '28001',
      'direccion': 'Calle de Pruebas 1',
      'idempresa': 1,
      'nombre': 'Bar Sandbox TPV S.L.',
      'provincia': 'Madrid',
      'telefono': '',
    },
  ],
  'estadodocumentos': [
    {
      'activo': true,
      'actualizastock': -1,
      'bloquear': true,
      'color': null,
      'editable': false,
      'generadoc': '',
      'icon': '',
      'idestado': 11,
      'nombre': 'Emitida',
      'predeterminado': false,
      'tipodoc': 'FacturaCliente',
    },
    {
      'activo': true,
      'actualizastock': -1,
      'bloquear': true,
      'color': null,
      'editable': true,
      'generadoc': '',
      'icon': '',
      'idestado': 10,
      'nombre': 'Boceto',
      'predeterminado': true,
      'tipodoc': 'FacturaCliente',
    },
    {
      'activo': true,
      'actualizastock': 0,
      'bloquear': false,
      'color': null,
      'editable': true,
      'generadoc': '',
      'icon': '',
      'idestado': 1,
      'nombre': 'Pendiente',
      'predeterminado': true,
      'tipodoc': 'PresupuestoCliente',
    },
  ],
  'clientes': [
    {
      'cifnif': '',
      'codagente': null,
      'codcliente': 'TPVVARIOS',
      'codpago': 'TPVEFE',
      'codserie': 'S',
      'debaja': false,
      'fechaalta': '06-10-2026',
      'nombre': 'CLIENTES VARIOS (TPV)',
      'personafisica': true,
      'razonsocial': 'CLIENTES VARIOS (TPV)',
      'riesgoalcanzado': 18.48,
      'riesgomax': null,
    },
  ],
};

const _config = DiagnosticoConfig(
  codserie: 'S',
  codpagoEfectivo: 'TPVEFE',
  codpagoTarjeta: 'TPVTAR',
  codalmacen: 'ALG',
  codcliente: 'TPVVARIOS',
);

void main() {
  late FakeFsApi api;
  late FsMasterDataService service;

  setUp(() {
    api = FakeFsApi(
      resources: FsResources.requeridosPorElTpv.toList(),
      records: _sandbox,
    );
    service = FsMasterDataService(api);
  });

  group('settingsDefault', () {
    test('interpreta properties como texto JSON', () async {
      final settings = await service.settingsDefault();
      expect(settings.codalmacen, 'ALG');
      expect(settings.codpago, 'CONT');
      expect(settings.codserie, 'A');
      expect(settings.coddivisa, 'EUR');
      expect(settings.codimpuesto, 'IVA21');
      expect(settings.idempresa, 1);
      expect(settings.decimals, 2);
      expect(settings.taxCalculationMethod, 'classic');
      expect(settings.ventasinstock, isTrue);
      expect(settings.properties['site_url'], 'http://127.0.0.1:8765');
      expect(api.calls, ['get settings/default']);
    });

    test('tolera claves ausentes y properties como objeto o texto', () async {
      api.records['settings'] = [
        {
          'name': 'default',
          'properties': {
            'codalmacen': 'ALG',
            'decimals': '3',
            'taxcalculationmethod': 'price-adjusted',
          },
        },
      ];
      final settings = await service.settingsDefault();
      expect(settings.codalmacen, 'ALG');
      expect(settings.codpago, isNull);
      expect(settings.idempresa, isNull);
      expect(settings.decimals, 3);
      expect(settings.taxCalculationMethod, 'price-adjusted');
      expect(settings.ventasinstock, isNull);

      api.records['settings'] = [
        {'name': 'default', 'properties': ''},
      ];
      expect((await service.settingsDefault()).decimals, 2);
    });

    test('properties no JSON lanza ErpApiException unexpected', () async {
      api.records['settings'] = [
        {'name': 'default', 'properties': '{no json'},
      ];
      await expectLater(
        service.settingsDefault(),
        throwsA(
          isA<ErpApiException>()
              .having((e) => e.kind, 'kind', ErpApiErrorKind.unexpected)
              .having((e) => e.cause, 'cause', isA<FormatException>()),
        ),
      );
    });

    test('sin registro default lanza', () async {
      api.records['settings'] = [];
      await expectLater(
        service.settingsDefault(),
        throwsA(isA<ErpApiException>()),
      );
    });
  });

  group('empresa', () {
    test('lee la cabecera del ticket; cadenas vacías pasan a null', () async {
      final empresa = await service.empresa(1);
      expect(empresa.idempresa, 1);
      expect(empresa.nombre, 'Bar Sandbox TPV S.L.');
      expect(empresa.cifnif, 'B12345674');
      expect(empresa.direccion, 'Calle de Pruebas 1');
      expect(empresa.codpostal, '28001');
      expect(empresa.ciudad, 'Madrid');
      expect(empresa.provincia, 'Madrid');
      expect(empresa.telefono1, '910000000');
      expect(empresa.email, 'sandbox@example.invalid');
      expect(empresa.web, isNull);
    });

    test('empresa inexistente lanza', () async {
      await expectLater(service.empresa(99), throwsA(isA<ErpApiException>()));
    });
  });

  group('listados', () {
    test('series ordenadas por codserie con tipo', () async {
      final series = await service.series();
      expect(series.map((s) => s.codserie), ['A', 'R', 'S']);
      expect(series.last.esSimplificada, isTrue);
      expect(series.first.tipo, isNull);
      expect(api.calls.single, startsWith('list series'));
    });

    test('formas de pago con pagado, activa y codcuentabanco', () async {
      final formas = await service.formasPago();
      final efectivo = formas.singleWhere((f) => f.codpago == 'TPVEFE');
      expect(efectivo.pagado, isTrue);
      expect(efectivo.codcuentabanco, '9001');
      expect(efectivo.activa, isTrue);
      final contado = formas.singleWhere((f) => f.codpago == 'CONT');
      expect(contado.pagado, isFalse);
      expect(contado.codcuentabanco, isNull);
      expect(formas.singleWhere((f) => f.codpago == 'VIEJA').activa, isFalse);
    });

    test('almacenes', () async {
      final almacenes = await service.almacenes();
      expect(
        almacenes.single,
        const FsAlmacen(
          codalmacen: 'ALG',
          nombre: 'Bar Sandbox TPV S.L.',
          activo: true,
          idempresa: 1,
        ),
      );
    });

    test('estadosFactura filtra por tipodoc=FacturaCliente', () async {
      final estados = await service.estadosFactura();
      expect(estados.map((e) => e.idestado), [10, 11]);
      final boceto = estados.first;
      expect(boceto.nombre, 'Boceto');
      expect(boceto.predeterminado, isTrue);
      expect(boceto.editable, isTrue);
      expect(boceto.actualizastock, -1);
      final emitida = estados.last;
      expect(emitida.editable, isFalse);
      expect(emitida.predeterminado, isFalse);
    });

    test('un registro ininterpretable se traduce a ErpApiException', () async {
      api.records['series']!.add({'codserie': null, 'descripcion': 'rota'});
      await expectLater(
        service.series(),
        throwsA(
          isA<ErpApiException>()
              .having((e) => e.statusCode, 'statusCode', 200)
              .having((e) => e.message, 'message', contains('series')),
        ),
      );
    });
  });

  group('cliente', () {
    test('cliente existente y ausente', () async {
      final cliente = await service.cliente('TPVVARIOS');
      expect(cliente!.nombre, 'CLIENTES VARIOS (TPV)');
      expect(cliente.cifnif, '');
      expect(cliente.riesgomax, isNull);
      expect(cliente.codserie, 'S');
      expect(await service.cliente('NADIE'), isNull);
    });

    test(
      'crearClienteGenerico crea con cifnif vacío y sin riesgomax',
      () async {
        final creado = await service.crearClienteGenerico();
        expect(creado.codcliente, 'TPV');
        expect(creado.nombre, 'CLIENTES VARIOS (TPV)');
        expect(creado.cifnif, '');
        expect(creado.riesgomax, isNull);
        expect(api.calls, [
          'get clientes/TPV',
          'create clientes',
          'get clientes/TPV',
        ]);
        final stored = api.records['clientes']!.last;
        expect(stored, {
          'codcliente': 'TPV',
          'nombre': 'CLIENTES VARIOS (TPV)',
          'cifnif': '',
        });
        expect(stored.containsKey('riesgomax'), isFalse);
      },
    );

    test('crearClienteGenerico es idempotente', () async {
      final existente = await service.crearClienteGenerico(
        codcliente: 'TPVVARIOS',
      );
      expect(existente.nombre, 'CLIENTES VARIOS (TPV)');
      expect(api.calls, ['get clientes/TPVVARIOS']);
    });

    test('crearClienteGenerico tolera la carrera "Registro duplicado"', () async {
      // El GET previo no lo ve, el POST falla por duplicado y el GET final sí.
      var reads = 0;
      final racing = _RacingApi(api, onGet: () => reads++ == 0);
      final service = FsMasterDataService(racing);
      final cliente = await service.crearClienteGenerico(
        codcliente: 'TPVVARIOS',
      );
      expect(cliente.codcliente, 'TPVVARIOS');
    });

    test('crearClienteGenerico propaga otros errores', () async {
      api.failures['clientes'] = const ErpApiException(
        'caído',
        statusCode: 500,
      );
      await expectLater(
        service.crearClienteGenerico(),
        throwsA(
          isA<ErpApiException>().having(
            (e) => e.kind,
            'kind',
            ErpApiErrorKind.server,
          ),
        ),
      );
    });
  });

  group('diagnosticar', () {
    Map<String, DiagnosticoItem> byCode(List<DiagnosticoItem> items) => {
      for (final i in items) i.codigo: i,
    };

    test('configuración correcta: todo ok salvo avisos justificados', () async {
      final items = byCode(await service.diagnosticar(_config));
      expect(items['api']!.nivel, DiagnosticoNivel.ok);
      expect(items['serie']!.nivel, DiagnosticoNivel.ok);
      expect(items['pago_efectivo']!.nivel, DiagnosticoNivel.ok);
      expect(items.containsKey('pago_efectivo_pagado'), isFalse);
      expect(items.containsKey('pago_efectivo_cuenta'), isFalse);
      expect(items['pago_tarjeta']!.nivel, DiagnosticoNivel.ok);
      expect(items['pago_tarjeta_pagado']!.nivel, DiagnosticoNivel.aviso);
      expect(
        items['pago_tarjeta_pagado']!.detalle,
        contains(
          'la factura nacerá pendiente de cobro; se usará pagarFacturaCliente',
        ),
      );
      expect(items['almacen']!.nivel, DiagnosticoNivel.ok);
      expect(items['cliente']!.nivel, DiagnosticoNivel.ok);
      expect(
        items.values.every((i) => i.titulo.isNotEmpty && i.detalle.isNotEmpty),
        isTrue,
      );
    });

    test('almacén sin configurar: error que explica qué hacer', () async {
      final items = byCode(
        await service.diagnosticar(
          const DiagnosticoConfig(
            codserie: 'S',
            codpagoEfectivo: 'TPVEFE',
            codpagoTarjeta: 'TPVTAR',
            codalmacen: ' ',
            codcliente: 'TPVVARIOS',
          ),
        ),
      );
      final almacen = items['almacen']!;
      expect(almacen.nivel, DiagnosticoNivel.error);
      expect(almacen.detalle, contains('No hay almacén configurado'));
      expect(almacen.detalle, contains('Ajustes → Fiscal'));
      expect(almacen.detalle, contains("'ALG'"));
      expect(almacen.detalle, isNot(contains("''")));
    });

    test('forma de pago sin cuenta bancaria avisa de la 572', () async {
      final items = byCode(
        await service.diagnosticar(
          const DiagnosticoConfig(
            codserie: 'S',
            codpagoEfectivo: 'CONT',
            codpagoTarjeta: 'VIEJA',
            codalmacen: 'ALG',
            codcliente: 'TPVVARIOS',
          ),
        ),
      );
      expect(items['pago_efectivo']!.nivel, DiagnosticoNivel.ok);
      expect(items['pago_efectivo_pagado']!.nivel, DiagnosticoNivel.aviso);
      expect(items['pago_efectivo_cuenta']!.nivel, DiagnosticoNivel.aviso);
      expect(
        items['pago_efectivo_cuenta']!.detalle,
        contains('el cobro se contabilizará en 572 y no en 570'),
      );
      expect(items['pago_tarjeta']!.nivel, DiagnosticoNivel.error);
      expect(items['pago_tarjeta']!.detalle, contains('desactivada'));
    });

    test(
      'serie, almacén y cliente inexistentes son errores; serie no S avisa',
      () async {
        final items = byCode(
          await service.diagnosticar(
            const DiagnosticoConfig(
              codserie: 'A',
              codpagoEfectivo: 'NOEXISTE',
              codpagoTarjeta: 'TPVTAR',
              codalmacen: 'XXX',
              codcliente: 'NADIE',
            ),
          ),
        );
        expect(items['serie']!.nivel, DiagnosticoNivel.aviso);
        expect(items['pago_efectivo']!.nivel, DiagnosticoNivel.error);
        expect(items['almacen']!.nivel, DiagnosticoNivel.error);
        expect(items['cliente']!.nivel, DiagnosticoNivel.error);
        expect(items['cliente']!.detalle, contains('no existe'));

        api.records['series'] = [];
        final sinSerie = byCode(await service.diagnosticar(_config));
        expect(sinSerie['serie']!.nivel, DiagnosticoNivel.error);
      },
    );

    test('faltan recursos en la API: error con la lista', () async {
      api = FakeFsApi(
        resources: const ['productos', 'clientes'],
        records: _sandbox,
      );
      service = FsMasterDataService(api);
      final items = byCode(await service.diagnosticar(_config));
      expect(items['api']!.nivel, DiagnosticoNivel.error);
      expect(items['api']!.detalle, contains('crearFacturaCliente'));
      expect(items['api']!.detalle, isNot(contains('productos')));
      // Sigue comprobando el resto.
      expect(items['serie']!.nivel, DiagnosticoNivel.ok);
    });

    test(
      'API inaccesible: un único item de error y no se llama a nada más',
      () async {
        api.resourcesFailure = const ErpApiException('sin red');
        final items = await service.diagnosticar(_config);
        expect(items.single.codigo, 'api');
        expect(items.single.nivel, DiagnosticoNivel.error);
        expect(items.single.detalle, 'sin red');
        expect(api.calls, ['resources']);
      },
    );

    test('un fallo en un listado no impide el resto', () async {
      api.failures['formapagos'] = const ErpApiException(
        'boom',
        statusCode: 500,
      );
      final items = byCode(await service.diagnosticar(_config));
      expect(items['pago']!.nivel, DiagnosticoNivel.error);
      expect(items['almacen']!.nivel, DiagnosticoNivel.ok);
      expect(items['cliente']!.nivel, DiagnosticoNivel.ok);
    });

    test('toJson del item', () {
      const item = DiagnosticoItem(
        codigo: 'x',
        nivel: DiagnosticoNivel.aviso,
        titulo: 't',
        detalle: 'd',
      );
      expect(item.toJson(), {
        'codigo': 'x',
        'nivel': 'aviso',
        'titulo': 't',
        'detalle': 'd',
      });
    });
  });
}

/// Envuelve el doble para simular que el GET previo no ve el registro.
final class _RacingApi implements FsApi {
  _RacingApi(this._inner, {required this.onGet});

  final FakeFsApi _inner;
  final bool Function() onGet;

  @override
  Future<FsRecord?> get(String resource, Object id) async =>
      onGet() ? null : _inner.get(resource, id);

  @override
  Future<FsRecord> create(String resource, Map<String, Object?> fields) =>
      _inner.create(resource, fields);

  @override
  Future<FsRecord> call(
    String endpoint, {
    List<Object> path = const [],
    Map<String, Object?> fields = const {},
  }) => _inner.call(endpoint, path: path, fields: fields);

  @override
  Future<bool> delete(String resource, Object id) =>
      _inner.delete(resource, id);

  @override
  Future<FsPage> list(
    String resource, {
    Map<String, Object?> filters = const {},
    Map<String, FsSortOrder> sort = const {},
    int limit = 50,
    int offset = 0,
  }) => _inner.list(
    resource,
    filters: filters,
    sort: sort,
    limit: limit,
    offset: offset,
  );

  @override
  Future<List<FsRecord>> listAll(
    String resource, {
    Map<String, Object?> filters = const {},
    required String sortBy,
    int pageSize = 200,
  }) => _inner.listAll(
    resource,
    filters: filters,
    sortBy: sortBy,
    pageSize: pageSize,
  );

  @override
  Future<List<String>> resources() => _inner.resources();

  @override
  Future<FsRecord> update(
    String resource,
    Object id,
    Map<String, Object?> fields,
  ) => _inner.update(resource, id, fields);
}
