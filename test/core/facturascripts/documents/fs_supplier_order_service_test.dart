import 'package:proyecto_comandero/core/errors/app_exception.dart';
import 'package:proyecto_comandero/core/facturascripts/documents/fs_supplier_order_service.dart';
import 'package:proyecto_comandero/core/facturascripts/documents/supplier_order_models.dart';
import 'package:test/test.dart';

import '../fake_fs_api.dart';

PedidoProveedorDraft draft({
  String clave = 'TPV-REPO-L1-PROV1',
  List<LineaPedido>? lineas,
}) => PedidoProveedorDraft(
  clave: clave,
  codproveedor: 'PROV1',
  codalmacen: 'ALG',
  fechaHora: DateTime(2026, 10, 6, 23, 59, 1),
  observaciones: 'Reposición automática',
  lineas:
      lineas ??
      [
        LineaPedido(referencia: 'ARROZ', cantidad: 25),
        LineaPedido(referencia: 'POLLO', cantidad: 10, descripcion: 'Pollo'),
      ],
);

void main() {
  late FakeFsApi api;
  late FsSupplierOrderService service;

  setUp(() {
    api = FakeFsApi.conDatosBasicos();
    service = FsSupplierOrderService(api);
  });

  test('camino feliz: consulta, crea y suma pterecibir', () async {
    final result = await service.crearOReanudar(draft());

    expect(result.yaExistia, isFalse);
    expect(result.idpedido, 1);
    expect(result.codigo, 'PED2026A1');
    expect(result.totalCents, 25 * 120 + 10 * 550);
    expect(result.referenciasSinProducto, isEmpty);

    expect(api.calls.map((c) => '${c.method} ${c.resource}'), [
      'LIST pedidoproveedores',
      'CALL crearPedidoProveedor',
    ]);
    expect(api.calls.first.filters, {'numproveedor': 'TPV-REPO-L1-PROV1'});

    final fields = api.calls.last.fields;
    expect(fields.keys.toSet(), {
      'codproveedor',
      'codalmacen',
      'fecha',
      'hora',
      'numproveedor',
      'observaciones',
      'lineas',
    });
    expect(fields['fecha'], '06-10-2026');
    expect(fields['hora'], '23:59:01');
    expect(fields['lineas'], [
      {'referencia': 'ARROZ', 'cantidad': 25.0},
      {'referencia': 'POLLO', 'cantidad': 10.0, 'descripcion': 'Pollo'},
    ]);
    for (final linea in fields['lineas']! as List<Object?>) {
      expect(linea, isNot(contains('pvpunitario')));
    }

    final arroz = api
        .table('stocks')
        .firstWhere((s) => s['referencia'] == 'ARROZ');
    expect(arroz['pterecibir'], 25.0);
    expect(arroz['cantidad'], 10.0);
  });

  test('reanudación: respuesta perdida no crea un segundo pedido', () async {
    api.loseResponseOn('crearPedidoProveedor', nth: 1);
    await expectLater(
      service.crearOReanudar(draft()),
      throwsA(
        isA<ErpApiException>().having(
          (e) => e.kind,
          'kind',
          ErpApiErrorKind.network,
        ),
      ),
    );
    expect(api.table('pedidoproveedores'), hasLength(1));

    final result = await service.crearOReanudar(draft());

    expect(result.yaExistia, isTrue);
    expect(result.idpedido, 1);
    expect(result.codigo, 'PED2026A1');
    expect(result.totalCents, 25 * 120 + 10 * 550);
    expect(result.referenciasSinProducto, isEmpty);
    expect(api.callsTo('crearPedidoProveedor'), hasLength(1));
    expect(api.callsTo('lineapedidoproveedores', method: 'LIST'), isNotEmpty);
    final arroz = api
        .table('stocks')
        .firstWhere((s) => s['referencia'] == 'ARROZ');
    expect(arroz['pterecibir'], 25.0, reason: 'no se sumó dos veces');
  });

  test(
    'referencias desconocidas se devuelven en referenciasSinProducto',
    () async {
      final result = await service.crearOReanudar(
        draft(
          lineas: [
            LineaPedido(referencia: 'ARROZ', cantidad: 5),
            LineaPedido(referencia: 'NOEXISTE', cantidad: 2),
          ],
        ),
      );
      expect(result.referenciasSinProducto, ['NOEXISTE']);
      expect(
        api.table('stocks').where((s) => s['referencia'] == 'NOEXISTE'),
        isEmpty,
      );
    },
  );

  test('referencias sin producto también al reanudar', () async {
    await service.crearOReanudar(
      draft(lineas: [LineaPedido(referencia: 'NOEXISTE', cantidad: 2)]),
    );
    final result = await service.crearOReanudar(
      draft(lineas: [LineaPedido(referencia: 'NOEXISTE', cantidad: 2)]),
    );
    expect(result.yaExistia, isTrue);
    expect(result.referenciasSinProducto, ['NOEXISTE']);
  });

  test('clave duplicada en FS: ValidationException', () async {
    await service.crearOReanudar(draft());
    api.seed('pedidoproveedores', {
      'numproveedor': 'TPV-REPO-L1-PROV1',
      'codigo': 'PED2026A99',
    });
    await expectLater(
      service.crearOReanudar(draft()),
      throwsA(isA<ValidationException>()),
    );
  });

  test('404 de proveedor se propaga como ErpApiException notFound', () async {
    final malo = PedidoProveedorDraft(
      clave: 'TPV-REPO-L2-NADIE',
      codproveedor: 'NADIE',
      codalmacen: 'ALG',
      fechaHora: DateTime(2026, 10, 6),
      lineas: [LineaPedido(referencia: 'ARROZ', cantidad: 1)],
    );
    await expectLater(
      service.crearOReanudar(malo),
      throwsA(
        isA<ErpApiException>().having(
          (e) => e.kind,
          'kind',
          ErpApiErrorKind.notFound,
        ),
      ),
    );
  });

  group('validación del borrador', () {
    test('clave con forma de fecha o demasiado larga', () {
      expect(
        () => draft(clave: '06-10-2026'),
        throwsA(isA<ValidationException>()),
      );
      expect(() => draft(clave: 'R' * 51), throwsA(isA<ValidationException>()));
    });

    test('sin líneas, cantidad no positiva', () {
      expect(() => draft(lineas: []), throwsA(isA<ValidationException>()));
      expect(
        () => LineaPedido(referencia: 'ARROZ', cantidad: 0),
        throwsA(isA<ValidationException>()),
      );
      expect(
        () => LineaPedido(referencia: '', cantidad: 1),
        throwsA(isA<ValidationException>()),
      );
    });
  });
}
