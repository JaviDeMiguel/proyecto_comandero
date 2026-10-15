/// Dobles en memoria de los puertos del host (`application/ports.dart`).
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:proyecto_comandero/core/database/repositories/stock_repository.dart'
    show StockApplyResult;
import 'package:proyecto_comandero/core/errors/app_exception.dart';
import 'package:proyecto_comandero/core/facturascripts/accounting/accounting_models.dart';
import 'package:proyecto_comandero/core/facturascripts/catalog/catalog_models.dart';
import 'package:proyecto_comandero/core/facturascripts/documents/invoice_models.dart';
import 'package:proyecto_comandero/core/facturascripts/documents/supplier_order_models.dart';
import 'package:proyecto_comandero/core/facturascripts/master_data/fs_master_models.dart';
import 'package:proyecto_comandero/core/inventory/inventory_models.dart';
import 'package:proyecto_comandero/core/network/printing/print_queue.dart'
    show PrintRetryPolicy;
import 'package:proyecto_comandero/core/network/printing/raw_printer_transport.dart';
import 'package:proyecto_comandero/features/host/application/ports.dart';

/// Reloj controlable.
final class FakeClock {
  FakeClock([DateTime? start]) : now = start ?? DateTime(2026, 10, 7, 13, 30);

  DateTime now;

  DateTime call() => now;

  void advance(Duration d) => now = now.add(d);
}

/// Cola de errores programados: cada llamada consume el primero; con la cola
/// vacía la operación tiene éxito.
mixin _Faults {
  final List<Exception> faults = [];
  int calls = 0;

  void failNext(Exception error, {int times = 1}) {
    for (var i = 0; i < times; i++) {
      faults.add(error);
    }
  }

  void _consume() {
    calls++;
    if (faults.isNotEmpty) throw faults.removeAt(0);
  }
}

final class FakeCatalogPort with _Faults implements CatalogPort {
  FakeCatalogPort(this.snapshot);

  CatalogSnapshot snapshot;

  @override
  Future<CatalogSnapshot> cargar({
    DateTime Function()? now,
    String? codimpuestoPorDefecto,
  }) async {
    _consume();
    return snapshot;
  }
}

final class FakeInvoicePort with _Faults implements InvoicePort {
  final List<TicketFactura> recibidos = [];
  int siguienteId = 1;

  /// Fecha y hora de expedición que «FS» devuelve con cada factura (distinta
  /// de la del ticket a propósito: el ERP puede cambiarla). A `null`, el
  /// resultado sale sin fecha, como si FS no la devolviera ni al releer.
  DateTime? fecha = DateTime(2026, 10, 7, 13, 31);

  /// Si «FS» devuelve el total de la factura. A `false`, `totalFsCents` queda
  /// nulo y `totalCents` sigue siendo el del ticket, como hace
  /// `FsInvoiceService`.
  bool devuelveTotal = true;

  /// Si no es nulo, se espera con la petición en vuelo, antes de responder o
  /// de fallar: simula lo que pasa en el host mientras el ERP trabaja (p. ej.
  /// una escritura en el diario).
  Future<void> Function(TicketFactura ticket)? antesDeResponder;

  /// Si no es nula, cada petición espera a que se complete antes de
  /// responder o de fallar (después de [antesDeResponder]): retiene la
  /// factura para probar la espera del cobro y la emisión pendiente. Una
  /// puerta ya completada no retiene nada; para volver a retener, otra nueva.
  Completer<void>? puerta;

  /// Peticiones retenidas ahora mismo en la [puerta].
  int retenidas = 0;

  /// Completa la [puerta] (si la hay y no estaba completada) y deja pasar
  /// las peticiones retenidas. Útil en el `tearDown`, para que nada se quede
  /// esperando.
  void abrirPuerta() {
    final abierta = puerta;
    if (abierta != null && !abierta.isCompleted) abierta.complete();
  }

  @override
  Future<ResultadoFactura> crearOReanudar(TicketFactura ticket) async {
    await antesDeResponder?.call(ticket);
    final retenida = puerta;
    if (retenida != null) {
      retenidas++;
      try {
        await retenida.future;
      } finally {
        retenidas--;
      }
    }
    _consume();
    recibidos.add(ticket);
    final id = siguienteId++;
    final totalFsCents = devuelveTotal ? ticket.totalEsperadoCents : null;
    return ResultadoFactura(
      idfactura: id,
      codigo: 'F2026S$id',
      numero: '$id',
      fecha: fecha,
      totalCents: totalFsCents ?? ticket.totalEsperadoCents,
      totalFsCents: totalFsCents,
      pagada: ticket.modoPago == ModoPago.nacePagada,
      idasiento: 100 + id,
      emitida: ticket.emitir,
      yaExistia: false,
      avisos: const [],
    );
  }
}

final class FakeSupplierOrderPort with _Faults implements SupplierOrderPort {
  final List<PedidoProveedorDraft> recibidos = [];

  @override
  Future<ResultadoPedido> crearOReanudar(PedidoProveedorDraft draft) async {
    _consume();
    recibidos.add(draft);
    return ResultadoPedido(
      idpedido: recibidos.length,
      codigo: 'PED${recibidos.length}',
      totalCents: 0,
      referenciasSinProducto: const [],
      yaExistia: false,
    );
  }
}

final class FakeAccountingPort with _Faults implements AccountingPort {
  final List<AsientoZ> contabilizados = [];
  bool facturasConAsiento = false;
  bool subcuentasDisponibles = true;

  /// Días (a medianoche) cuyas facturas ya tienen asiento.
  final Set<DateTime> diasConAsiento = {};

  /// Fechas consultadas con [hayFacturasConAsiento].
  final List<DateTime> consultados = [];

  @override
  Future<SubcuentasCierre> resolverSubcuentas(
    DateTime fecha, {
    required int idempresa,
    Map<CuentaZ, String> overrides = const {},
  }) async {
    _consume();
    if (!subcuentasDisponibles) {
      throw const ConfigException('No hay ejercicio abierto para la fecha');
    }
    return SubcuentasCierre(
      codejercicio: '2026',
      porCuenta: {
        CuentaZ.caja570: '5700000000',
        CuentaZ.banco572: '5720000000',
        CuentaZ.ventas700: '7000000000',
        CuentaZ.ivaRepercutido477: '4770000000',
        CuentaZ.perdidas659: '6590000000',
        CuentaZ.ingresos759: '7590000000',
        ...overrides,
      },
      ivaPorCodimpuesto: const {'IVA10': '4770000010', 'IVA21': '4770000021'},
    );
  }

  @override
  Future<ResultadoAsiento> contabilizarOReanudar(AsientoZ asiento) async {
    _consume();
    contabilizados.add(asiento);
    return ResultadoAsiento(
      idasiento: contabilizados.length,
      numero: contabilizados.length,
      yaExistia: false,
      partidasCreadas: asiento.lineas.length,
      verificado: true,
    );
  }

  @override
  Future<bool> hayFacturasConAsiento({
    required DateTime fecha,
    required String codserie,
  }) async {
    _consume();
    consultados.add(fecha);
    final dia = DateTime(fecha.year, fecha.month, fecha.day);
    return facturasConAsiento || diasConAsiento.contains(dia);
  }
}

final class FakeMasterDataPort with _Faults implements MasterDataPort {
  FakeMasterDataPort({
    this.formas = const [
      FsFormaPago(codpago: 'TPVEFE', descripcion: 'Efectivo', pagado: true),
      FsFormaPago(codpago: 'TPVTAR', descripcion: 'Tarjeta'),
    ],
    this.estados = const [
      FsEstadoDocumento(
        idestado: 10,
        nombre: 'Boceto',
        tipodoc: 'FacturaCliente',
        predeterminado: true,
      ),
      FsEstadoDocumento(
        idestado: 11,
        nombre: 'Emitida',
        tipodoc: 'FacturaCliente',
        editable: false,
      ),
    ],
    FsEmpresa? empresa,
  }) : empresaFs = empresa;

  /// Empresa que devuelve [empresa] (`cifnif`, dirección…). Nula, una «Bar
  /// de pruebas» sin NIF con el id pedido.
  FsEmpresa? empresaFs;

  /// Ids que se han pedido a [empresa], en orden.
  final List<int> empresasPedidas = [];

  List<FsFormaPago> formas;
  List<FsEstadoDocumento> estados;
  List<DiagnosticoItem> diagnostico = const [];
  FsDefaultSettings ajustes = const FsDefaultSettings(
    codalmacen: 'ALG',
    codserie: 'S',
    codimpuesto: 'IVA21',
    idempresa: 1,
  );

  @override
  Future<FsDefaultSettings> settingsDefault() async {
    _consume();
    return ajustes;
  }

  @override
  Future<FsEmpresa> empresa(int idempresa) async {
    _consume();
    empresasPedidas.add(idempresa);
    return empresaFs ??
        FsEmpresa(idempresa: idempresa, nombre: 'Bar de pruebas');
  }

  @override
  Future<List<FsFormaPago>> formasPago() async {
    _consume();
    return formas;
  }

  @override
  Future<List<FsEstadoDocumento>> estadosFactura() async {
    _consume();
    return estados;
  }

  @override
  Future<List<DiagnosticoItem>> diagnosticar(DiagnosticoConfig config) async {
    _consume();
    return diagnostico;
  }
}

final class FakeStockPort with _Faults implements StockPort {
  /// Operaciones aplicadas: `operacion` → consumos.
  final Map<String, List<ConsumoStock>> aplicadas = {};

  /// Almacén de cada operación aplicada.
  final Map<String, String> almacenes = {};
  final List<String> ordenOperaciones = [];
  List<NivelStock> niveles = const [];
  List<OfertaProveedor> ofertas = const [];

  @override
  Future<StockApplyResult> aplicarConsumos({
    required String operacion,
    required List<ConsumoStock> consumos,
    required String codalmacen,
    required String motivo,
    String? origen,
  }) async {
    _consume();
    if (aplicadas.containsKey(operacion)) {
      return StockApplyResult(
        yaAplicada: true,
        niveles: niveles,
        avisos: const [],
      );
    }
    aplicadas[operacion] = consumos;
    almacenes[operacion] = codalmacen;
    ordenOperaciones.add(operacion);
    return StockApplyResult(
      yaAplicada: false,
      niveles: niveles,
      avisos: const [],
    );
  }

  @override
  Future<List<NivelStock>> leerNiveles({
    required String codalmacen,
    Set<String>? referencias,
    bool soloConMinimo = false,
  }) async {
    _consume();
    return [
      for (final n in niveles)
        if ((referencias == null || referencias.contains(n.referencia)) &&
            (!soloConMinimo || n.stockmin > 0))
          n,
    ];
  }

  @override
  Future<List<OfertaProveedor>> leerOfertas(Set<String> referencias) async {
    _consume();
    return [
      for (final o in ofertas)
        if (referencias.contains(o.referencia)) o,
    ];
  }

  @override
  Future<Map<String, List<ConsumoStock>>> leerConsumosAplicados(
    String operacion,
  ) async {
    _consume();
    final consumos = aplicadas[operacion];
    if (consumos == null) return const {};
    return {almacenes[operacion]!: consumos};
  }
}

final class FakeRecetasPort with _Faults implements RecetasPort {
  FakeRecetasPort([this.recetas = const []]);

  List<RecetaLinea> recetas;

  @override
  Future<List<RecetaLinea>> listAll() async {
    _consume();
    return recetas;
  }
}

/// Trabajo de impresión registrado por [FakePrinterPort].
typedef PrintedJob = ({
  String id,
  PrinterEndpoint endpoint,
  Uint8List bytes,
  String description,
  PrintRetryPolicy reintento,
});

final class FakePrinterPort implements RetryablePrinterPort {
  final List<PrintedJob> jobs = [];

  /// Si no es nulo, todos los trabajos terminan con este error (también los
  /// reintentados: se lee al seguir cada uno).
  String? error;

  /// Si no es nulo, [imprimir] lo lanza sin encolar nada, como la cola
  /// llena o cerrada.
  PrinterException? errorAlEncolar;

  /// Ids pasados a [reintentar], en orden (los mismos bytes, sin trabajo
  /// nuevo en [jobs]).
  final List<String> reintentados = [];

  /// Trabajos que fallaron sin enviar nada (todos sus intentos fallaron al
  /// conectar): [nadaEnviado] da `true` solo para ellos.
  final Set<String> sinEnviar = {};

  /// Si no es nulo, [reintentar] lo lanza, como la cola cerrada o llena.
  PrinterException? errorAlReintentar;

  @override
  String imprimir(
    PrinterEndpoint endpoint,
    Uint8List bytes, {
    required String description,
    PrintRetryPolicy reintento = PrintRetryPolicy.always,
  }) {
    final fallo = errorAlEncolar;
    if (fallo != null) throw fallo;
    final id = 'print-${jobs.length + 1}';
    jobs.add((
      id: id,
      endpoint: endpoint,
      bytes: bytes,
      description: description,
      reintento: reintento,
    ));
    return id;
  }

  @override
  Future<String?> terminado(String jobId) async => error;

  /// Registra el id en [reintentados] y lo devuelve. Lanza
  /// [errorAlReintentar] o, si el trabajo no existe, [PrinterException].
  @override
  String reintentar(String jobId) {
    _existeOLanza(jobId);
    final fallo = errorAlReintentar;
    if (fallo != null) throw fallo;
    reintentados.add(jobId);
    return jobId;
  }

  @override
  bool nadaEnviado(String jobId) {
    _existeOLanza(jobId);
    return sinEnviar.contains(jobId);
  }

  void _existeOLanza(String jobId) {
    if (!jobs.any((job) => job.id == jobId)) {
      throw PrinterException('No existe el trabajo de impresión $jobId');
    }
  }
}
