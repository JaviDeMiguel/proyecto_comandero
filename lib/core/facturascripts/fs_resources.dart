/// Nombres reales de los recursos de la API v3 de FacturaScripts 2026.5.
///
/// El nombre de un recurso NO es el de la tabla ni el plural castellano: lo
/// genera `APIModel::pluralize()` a partir del nombre del modelo PHP
/// (`FormaPago` → `formapagos`, `EstadoDocumento` → `estadodocumentos`). Un
/// nombre mal escrito con una clave restringida no da 404 sino 403 **y cuenta
/// como incidencia** (5 incidencias en 10 minutos banean la IP), así que todos
/// los nombres viven aquí y en ningún otro sitio.
library;

/// Recursos de modelo y endpoints personalizados de la API.
abstract final class FsResources {
  // --- Documentos de venta y compra ---------------------------------------
  static const String facturaClientes = 'facturaclientes';
  static const String lineaFacturaClientes = 'lineafacturaclientes';
  static const String pedidoProveedores = 'pedidoproveedores';
  static const String lineaPedidoProveedores = 'lineapedidoproveedores';
  static const String reciboClientes = 'reciboclientes';

  /// Cobros de los recibos de cliente (tabla `pagoscli`). Los crea el recibo
  /// al quedar pagado; el TPV solo los lee para verificar el cobro mixto.
  static const String pagoClientes = 'pagoclientes';

  // --- Contabilidad --------------------------------------------------------
  static const String asientos = 'asientos';
  static const String partidas = 'partidas';
  static const String subcuentas = 'subcuentas';
  static const String cuentas = 'cuentas';
  static const String ejercicios = 'ejercicios';

  // --- Catálogo y stock ----------------------------------------------------
  static const String productos = 'productos';
  static const String variantes = 'variantes';
  static const String stocks = 'stocks';
  static const String familias = 'familias';
  static const String impuestos = 'impuestos';

  // --- Datos maestros ------------------------------------------------------
  static const String series = 'series';
  static const String formaPagos = 'formapagos';
  static const String almacenes = 'almacenes';
  static const String clientes = 'clientes';
  static const String proveedores = 'proveedores';
  static const String productoProveedores = 'productoproveedores';
  static const String empresas = 'empresas';
  static const String settings = 'settings';
  static const String estadoDocumentos = 'estadodocumentos';

  // --- Endpoints personalizados (no son modelos) --------------------------
  /// `POST /api/3/crearFacturaCliente`: cabecera + líneas en una transacción.
  static const String crearFacturaCliente = 'crearFacturaCliente';

  /// `POST /api/3/crearPedidoProveedor`: pedido a proveedor transaccional.
  static const String crearPedidoProveedor = 'crearPedidoProveedor';

  /// `POST /api/3/pagarFacturaCliente/{idfactura}`: marca cobrada la factura.
  static const String pagarFacturaCliente = 'pagarFacturaCliente';

  /// Recursos que el TPV necesita. Se comparan con la lista que devuelve
  /// `GET /api/3` en la pantalla de configuración para detectar una clave
  /// restringida o una versión distinta ANTES de llamarlos (y de acumular
  /// incidencias).
  static const Set<String> requeridosPorElTpv = {
    facturaClientes,
    lineaFacturaClientes,
    pedidoProveedores,
    lineaPedidoProveedores,
    reciboClientes,
    pagoClientes,
    asientos,
    partidas,
    subcuentas,
    cuentas,
    ejercicios,
    productos,
    variantes,
    stocks,
    familias,
    impuestos,
    series,
    formaPagos,
    almacenes,
    clientes,
    proveedores,
    productoProveedores,
    empresas,
    settings,
    estadoDocumentos,
    crearFacturaCliente,
    crearPedidoProveedor,
    pagarFacturaCliente,
  };
}
