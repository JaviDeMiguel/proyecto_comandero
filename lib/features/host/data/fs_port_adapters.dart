/// Adaptadores de los servicios de FacturaScripts (`lib/core/facturascripts`)
/// a los puertos del host.
library;

import '../../../core/facturascripts/accounting/accounting_models.dart';
import '../../../core/facturascripts/accounting/fs_accounting_service.dart';
import '../../../core/facturascripts/catalog/fs_catalog_service.dart';
import '../../../core/facturascripts/documents/fs_invoice_service.dart';
import '../../../core/facturascripts/documents/fs_supplier_order_service.dart';
import '../../../core/facturascripts/documents/invoice_models.dart';
import '../../../core/facturascripts/documents/supplier_order_models.dart';
import '../../../core/facturascripts/fs_api.dart';
import '../../../core/facturascripts/master_data/fs_master_data_service.dart';
import '../application/ports.dart';

/// Todos los puertos del ERP construidos sobre una misma [FsApi].
final class FsPorts {
  FsPorts(FsApi api, {DateTime Function()? now})
    : invoice = FsInvoiceAdapter(FsInvoiceService(api)),
      supplierOrder = FsSupplierOrderAdapter(FsSupplierOrderService(api)),
      accounting = FsAccountingAdapter(FsAccountingService(api, now: now)),
      masterData = FsMasterDataAdapter(FsMasterDataService(api)),
      catalog = FsCatalogAdapter(FsCatalogService(api));

  final FsInvoiceAdapter invoice;
  final FsSupplierOrderAdapter supplierOrder;
  final FsAccountingAdapter accounting;
  final FsMasterDataAdapter masterData;
  final FsCatalogAdapter catalog;
}

final class FsInvoiceAdapter implements InvoicePort {
  FsInvoiceAdapter(this._service);

  final FsInvoiceService _service;

  @override
  Future<ResultadoFactura> crearOReanudar(TicketFactura ticket) =>
      _service.crearOReanudar(ticket);
}

final class FsSupplierOrderAdapter implements SupplierOrderPort {
  FsSupplierOrderAdapter(this._service);

  final FsSupplierOrderService _service;

  @override
  Future<ResultadoPedido> crearOReanudar(PedidoProveedorDraft draft) =>
      _service.crearOReanudar(draft);
}

final class FsAccountingAdapter implements AccountingPort {
  FsAccountingAdapter(this._service);

  final FsAccountingService _service;

  @override
  Future<SubcuentasCierre> resolverSubcuentas(
    DateTime fecha, {
    required int idempresa,
    Map<CuentaZ, String> overrides = const {},
  }) => _service.resolverSubcuentas(
    fecha,
    idempresa: idempresa,
    overrides: overrides,
  );

  @override
  Future<ResultadoAsiento> contabilizarOReanudar(AsientoZ asiento) =>
      _service.contabilizarOReanudar(asiento);

  @override
  Future<bool> hayFacturasConAsiento({
    required DateTime fecha,
    required String codserie,
  }) => _service.hayFacturasConAsiento(fecha: fecha, codserie: codserie);
}

final class FsMasterDataAdapter implements MasterDataPort {
  FsMasterDataAdapter(this._service);

  final FsMasterDataService _service;

  @override
  Future<FsDefaultSettings> settingsDefault() => _service.settingsDefault();

  @override
  Future<FsEmpresa> empresa(int idempresa) => _service.empresa(idempresa);

  @override
  Future<List<FsFormaPago>> formasPago() => _service.formasPago();

  @override
  Future<List<FsEstadoDocumento>> estadosFactura() => _service.estadosFactura();

  @override
  Future<List<DiagnosticoItem>> diagnosticar(DiagnosticoConfig config) =>
      _service.diagnosticar(config);
}

final class FsCatalogAdapter implements CatalogPort {
  FsCatalogAdapter(this._service);

  final FsCatalogService _service;

  @override
  Future<CatalogSnapshot> cargar({
    DateTime Function()? now,
    String? codimpuestoPorDefecto,
  }) => _service.cargar(now: now, codimpuestoPorDefecto: codimpuestoPorDefecto);
}
