/// Puertos del host hacia el exterior (ERP, MySQL, impresora).
///
/// Los servicios de `application/` dependen solo de estas interfaces; los
/// adaptadores a las implementaciones reales de `lib/core` viven en `data/`
/// y los dobles en memoria en los tests. Los tipos de datos que cruzan los
/// puertos son los DTOs planos de `lib/core`, que ya son Dart puro.
library;

import 'dart:typed_data';

import '../../../core/database/repositories/stock_repository.dart'
    show StockApplyResult;
import '../../../core/facturascripts/accounting/accounting_models.dart';
import '../../../core/facturascripts/catalog/catalog_models.dart';
import '../../../core/facturascripts/documents/invoice_models.dart';
import '../../../core/facturascripts/documents/supplier_order_models.dart';
import '../../../core/facturascripts/master_data/fs_master_models.dart';
import '../../../core/inventory/inventory_models.dart';
import '../../../core/network/printing/print_queue.dart' show PrintRetryPolicy;
import '../../../core/network/printing/raw_printer_transport.dart'
    show PrinterEndpoint;

/// Factura simplificada de un ticket (`FsInvoiceService`).
abstract interface class InvoicePort {
  Future<ResultadoFactura> crearOReanudar(TicketFactura ticket);
}

/// Pedido a proveedor (`FsSupplierOrderService`).
abstract interface class SupplierOrderPort {
  Future<ResultadoPedido> crearOReanudar(PedidoProveedorDraft draft);
}

/// Contabilidad del Cierre Z (`FsAccountingService`).
abstract interface class AccountingPort {
  Future<SubcuentasCierre> resolverSubcuentas(
    DateTime fecha, {
    required int idempresa,
    Map<CuentaZ, String> overrides = const {},
  });

  Future<ResultadoAsiento> contabilizarOReanudar(AsientoZ asiento);

  Future<bool> hayFacturasConAsiento({
    required DateTime fecha,
    required String codserie,
  });
}

/// Datos maestros del ERP (`FsMasterDataService`).
abstract interface class MasterDataPort {
  Future<FsDefaultSettings> settingsDefault();
  Future<FsEmpresa> empresa(int idempresa);
  Future<List<FsFormaPago>> formasPago();
  Future<List<FsEstadoDocumento>> estadosFactura();
  Future<List<DiagnosticoItem>> diagnosticar(DiagnosticoConfig config);
}

/// Catálogo de artículos del ERP (`FsCatalogService`).
abstract interface class CatalogPort {
  Future<CatalogSnapshot> cargar({
    DateTime Function()? now,
    String? codimpuestoPorDefecto,
  });
}

/// Stock por MySQL directo (`StockRepository`).
abstract interface class StockPort {
  Future<StockApplyResult> aplicarConsumos({
    required String operacion,
    required List<ConsumoStock> consumos,
    required String codalmacen,
    required String motivo,
    String? origen,
  });

  Future<List<NivelStock>> leerNiveles({
    required String codalmacen,
    Set<String>? referencias,
    bool soloConMinimo = false,
  });

  Future<List<OfertaProveedor>> leerOfertas(Set<String> referencias);

  /// Consumos que el diario de stock registra para [operacion], por almacén
  /// (cantidad positiva = consumo). Vacío si nunca se aplicó.
  Future<Map<String, List<ConsumoStock>>> leerConsumosAplicados(
    String operacion,
  );
}

/// Recetas (`EscandalloRepository`).
abstract interface class RecetasPort {
  Future<List<RecetaLinea>> listAll();
}

/// Cola de impresión (`PrintQueue` sobre `RawPrinterTransport`).
///
/// [imprimir] encola y devuelve de inmediato el identificador del trabajo;
/// el resultado del envío llega por [terminado] (`null` error = impreso).
abstract interface class PrinterPort {
  /// [reintento] fija qué fallos se repiten con los mismos bytes:
  /// [PrintRetryPolicy.always] (comandas) cualquiera, y
  /// [PrintRetryPolicy.connectOnly] (facturas) solo si no se llegó a
  /// conectar, para que un ORIGINAL no salga dos veces.
  String imprimir(
    PrinterEndpoint endpoint,
    Uint8List bytes, {
    required String description,
    PrintRetryPolicy reintento = PrintRetryPolicy.always,
  });

  /// Completa cuando el trabajo termina: `null` si se imprimió, el mensaje
  /// de error si agotó los reintentos o [trabajoCancelado] si se canceló.
  Future<String?> terminado(String jobId);
}

/// Lo que devuelve `PrinterPort.terminado` de un trabajo cancelado (al
/// cerrar la cola): se avisa, pero no se ofrece reintentarlo.
const String trabajoCancelado = 'cancelado';

/// Cola de impresión que además reimprime sus trabajos fallidos (P2, §3.13 y
/// §5.17 del diseño de impresión).
///
/// Es una interfaz aparte, y no dos métodos más de [PrinterPort], para que
/// los puertos que solo imprimen sigan valiendo: sin ella, el canal no ofrece
/// reintentos.
abstract interface class RetryablePrinterPort implements PrinterPort {
  /// Vuelve a encolar un trabajo fallido (mismos bytes, mismo id) y devuelve
  /// su id; después, [terminado] espera a la reimpresión. Lanza
  /// `PrinterException` si no existe, no está fallido o ya salió del
  /// historial, o si la cola está cerrada o llena.
  String reintentar(String jobId);

  /// `true` si ningún intento del trabajo pasó de la conexión (todos
  /// fallaron al conectar), así que no salió nada por la impresora. Lanza
  /// `PrinterException` si no existe o ya salió del historial.
  bool nadaEnviado(String jobId);
}
