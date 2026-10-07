import 'package:proyecto_comandero/core/facturascripts/fs_resources.dart';
import 'package:test/test.dart';

void main() {
  group('FsResources', () {
    test('usa los nombres reales de pluralize(), no los de las tablas', () {
      expect(FsResources.facturaClientes, 'facturaclientes');
      expect(FsResources.lineaFacturaClientes, 'lineafacturaclientes');
      expect(FsResources.pedidoProveedores, 'pedidoproveedores');
      expect(FsResources.lineaPedidoProveedores, 'lineapedidoproveedores');
      expect(FsResources.formaPagos, 'formapagos');
      expect(FsResources.estadoDocumentos, 'estadodocumentos');
      expect(FsResources.productoProveedores, 'productoproveedores');
      expect(FsResources.reciboClientes, 'reciboclientes');
      expect(FsResources.pagoClientes, 'pagoclientes');
      expect(FsResources.settings, 'settings');
    });

    test('los endpoints personalizados conservan las mayúsculas', () {
      expect(FsResources.crearFacturaCliente, 'crearFacturaCliente');
      expect(FsResources.crearPedidoProveedor, 'crearPedidoProveedor');
      expect(FsResources.pagarFacturaCliente, 'pagarFacturaCliente');
    });

    test('los recursos de modelo van en minúsculas sin espacios', () {
      final modelos = FsResources.requeridosPorElTpv.where(
        (r) => !r.startsWith('crear') && !r.startsWith('pagar'),
      );
      for (final resource in modelos) {
        expect(resource, matches(RegExp(r'^[a-z]+$')), reason: resource);
      }
    });

    test('requeridosPorElTpv incluye todo lo que usa el TPV', () {
      expect(
        FsResources.requeridosPorElTpv,
        containsAll([
          'facturaclientes',
          'lineafacturaclientes',
          'pedidoproveedores',
          'lineapedidoproveedores',
          'asientos',
          'partidas',
          'subcuentas',
          'cuentas',
          'ejercicios',
          'productos',
          'variantes',
          'stocks',
          'familias',
          'impuestos',
          'series',
          'formapagos',
          'almacenes',
          'clientes',
          'proveedores',
          'productoproveedores',
          'empresas',
          'settings',
          'estadodocumentos',
          'reciboclientes',
          'pagoclientes',
          'crearFacturaCliente',
          'crearPedidoProveedor',
          'pagarFacturaCliente',
        ]),
      );
      expect(FsResources.requeridosPorElTpv, hasLength(28));
    });
  });
}
