/// ERP simulado para la prueba de flujo del host: el doble en memoria de la
/// API REST v3 de FacturaScripts de los tests ([FakeFsApi], que reproduce
/// `crearFacturaCliente` con numeración, totales, asiento y recibo) con lo
/// que la puesta a punto del host necesita además: `settings/default`, la
/// empresa con NIF, familias con su destino del plugin Hosteleria
/// (`tpv_destino`) y platos y bebidas de la carta.
library;

import 'package:proyecto_comandero/core/facturascripts/fs_api.dart';
import 'package:proyecto_comandero/core/facturascripts/fs_resources.dart';

import '../../test/core/facturascripts/fake_fs_api.dart';

export '../../test/core/facturascripts/fake_fs_api.dart' show FakeFsApi;

/// NIF de la empresa emisora simulada (necesario para imprimir facturas).
const String kNifEmisorSimulado = 'B12345678';

/// Artículo de la carta simulada: referencia, descripción, precio neto
/// (IVA 10 %) y familia.
typedef ArticuloSimulado = ({
  String referencia,
  String descripcion,
  double precioNeto,
  String codfamilia,
});

/// Platos de cocina (familia `COC`) y una bebida de barra (familia `BEB`).
/// PVP: 8,00 €, 18,00 € y 2,50 €.
const List<ArticuloSimulado> kCartaSimulada = [
  (
    referencia: 'ENSALADA',
    descripcion: 'Ensalada mixta',
    precioNeto: 7.27273,
    codfamilia: 'COC',
  ),
  (
    referencia: 'ENTRECOT',
    descripcion: 'Entrecot',
    precioNeto: 16.36364,
    codfamilia: 'COC',
  ),
  (
    referencia: 'REFRESCO',
    descripcion: 'Refresco',
    precioNeto: 2.27273,
    codfamilia: 'BEB',
  ),
];

/// Familias con el destino que fija el plugin Hosteleria.
const List<FsRecord> _familias = [
  {
    'codfamilia': 'BEB',
    'descripcion': 'Bebidas',
    'madre': null,
    'tpv_destino': 'barra',
  },
  {
    'codfamilia': 'COC',
    'descripcion': 'Cocina',
    'madre': null,
    'tpv_destino': 'cocina',
  },
];

/// [FakeFsApi] con los datos maestros del sandbox ([FakeFsApi.conDatosBasicos]:
/// cliente `TPVVARIOS`, almacén `ALG`, serie `S`, formas de pago `TPVEFE` y
/// `TPVTAR`...) más la carta, las familias, la empresa y los ajustes.
final class ErpSimulado extends FakeFsApiDelegate {
  ErpSimulado._(super.inner);

  factory ErpSimulado.crear() {
    final api = FakeFsApi.conDatosBasicos();
    api.seed('empresas', {
      'idempresa': 1,
      'nombre': 'Hostelería de Pruebas SL',
      'nombrecorto': 'Bar de Pruebas',
      'cifnif': kNifEmisorSimulado,
      'direccion': 'Calle Mayor 1',
      'ciudad': 'Toledo',
    });
    for (final articulo in kCartaSimulada) {
      final producto = api.seed('productos', {
        'referencia': articulo.referencia,
        'descripcion': articulo.descripcion,
        'codfamilia': articulo.codfamilia,
        'codimpuesto': 'IVA10',
        'nostock': true,
        'sevende': true,
        'secompra': false,
        'bloqueado': false,
        'precio': articulo.precioNeto,
      });
      api.seed('variantes', {
        'idproducto': producto['idproducto'],
        'referencia': articulo.referencia,
        'precio': articulo.precioNeto,
        'coste': 0.0,
      });
    }
    api.calls.clear();
    return ErpSimulado._(api);
  }

  /// Facturas creadas en el ERP simulado.
  List<FsRecord> get facturas => inner.table(FsResources.facturaClientes);

  @override
  Future<List<String>> resources() async => [
    ...FsResources.requeridosPorElTpv,
    FsResources.familias,
    FsResources.settings,
  ];

  @override
  Future<List<FsRecord>> listAll(
    String resource, {
    Map<String, Object?> filters = const {},
    required String sortBy,
    int pageSize = 200,
  }) {
    if (resource == FsResources.familias) {
      return Future.value([for (final f in _familias) Map.of(f)]);
    }
    return super.listAll(
      resource,
      filters: filters,
      sortBy: sortBy,
      pageSize: pageSize,
    );
  }

  @override
  Future<FsRecord?> get(String resource, Object id) {
    if (resource == FsResources.settings && id == 'default') {
      return Future.value({
        'name': 'default',
        'properties': {
          'idempresa': 1,
          'codalmacen': 'ALG',
          'codserie': 'S',
          'codpago': 'TPVEFE',
          'codimpuesto': 'IVA10',
        },
      });
    }
    return super.get(resource, id);
  }
}
