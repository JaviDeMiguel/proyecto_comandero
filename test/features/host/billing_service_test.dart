import 'package:proyecto_comandero/core/errors/app_exception.dart';
import 'package:proyecto_comandero/core/facturascripts/documents/invoice_models.dart';
import 'package:proyecto_comandero/core/facturascripts/master_data/fs_master_models.dart';
import 'package:proyecto_comandero/core/isolates/isolate_runner.dart';
import 'package:proyecto_comandero/core/network/printing/raw_printer_transport.dart';
import 'package:proyecto_comandero/features/host/application/alert_bus.dart';
import 'package:proyecto_comandero/features/host/application/billing_service.dart';
import 'package:proyecto_comandero/features/host/application/catalog_service.dart';
import 'package:proyecto_comandero/features/host/application/host_state_repository.dart';
import 'package:proyecto_comandero/features/host/application/host_state_store.dart';
import 'package:proyecto_comandero/features/host/application/ports.dart';
import 'package:proyecto_comandero/features/host/application/printing_service.dart';
import 'package:proyecto_comandero/features/host/application/sala_service.dart';
import 'package:proyecto_comandero/features/host/application/sync_outbox.dart';
import 'package:proyecto_comandero/features/host/data/fs_port_adapters.dart';
import 'package:proyecto_comandero/features/host/domain/host_settings.dart';
import 'package:proyecto_comandero/features/host/domain/host_snapshot.dart';
import 'package:proyecto_comandero/features/host/domain/sync_job.dart';
import 'package:proyecto_comandero/features/sala/domain/linea_comanda.dart';
import 'package:proyecto_comandero/features/sala/domain/ticket.dart';
import 'package:test/test.dart';

import '../../core/facturascripts/fake_fs_api.dart';
import 'fakes/fake_ports.dart';
import 'support/host_test_support.dart';

const fiscal = FiscalSettings(
  codcliente: 'TPVVARIOS',
  codserie: 'S',
  codpagoEfectivo: 'TPVEFE',
  codpagoTarjeta: 'TPVTAR',
  codalmacen: 'ALG',
  codimpuestoPorDefecto: 'IVA21',
);

/// Repositorio que conserva cada snapshot guardado.
final class RepoQueAnota implements HostStateRepository {
  final List<HostSnapshot> guardados = [];

  @override
  Future<HostSnapshot?> load() async => null;

  @override
  Future<void> save(HostSnapshot snapshot) async => guardados.add(snapshot);
}

void main() {
  late SalaFixture f;
  late SyncOutbox outbox;
  late FakePrinterPort printer;
  late PrintingService printing;
  late FakeMasterDataPort masterData;
  late BillingService billing;

  Future<void> setUpWith(
    InvoicePort invoice, {
    bool emitir = true,
    bool conCatalogo = true,
    String? codimpuestoPorDefecto = 'IVA21',
  }) async {
    f = await SalaFixture.create(conCatalogo: conCatalogo);
    outbox = SyncOutbox(store: f.store, alerts: f.alerts, now: f.clock.call);
    printer = FakePrinterPort();
    printing = PrintingService(
      alerts: f.alerts,
      runner: const InlineIsolateRunner(),
      settings: const ImpresionSettings(imprimirTicketAlCobrar: false),
      nombreTpv: 'Barra',
      printer: printer,
      now: f.clock.call,
    );
    masterData = FakeMasterDataPort();
    billing = BillingService(
      store: f.store,
      alerts: f.alerts,
      outbox: outbox,
      printing: printing,
      fiscal: FiscalSettings(
        codcliente: fiscal.codcliente,
        codserie: fiscal.codserie,
        codpagoEfectivo: fiscal.codpagoEfectivo,
        codpagoTarjeta: fiscal.codpagoTarjeta,
        codalmacen: fiscal.codalmacen,
        emitirFacturas: emitir,
        codimpuestoPorDefecto: codimpuestoPorDefecto,
      ),
      invoice: invoice,
      masterData: masterData,
      now: f.clock.call,
    );
    f.sala.addEffects(billing);
    await outbox.start();
  }

  tearDown(() async {
    await billing.dispose();
    await outbox.dispose();
    await f.dispose();
  });

  Future<void> settle() async {
    await f.sala.idle();
    await outbox.idle();
    await Future<void>.delayed(Duration.zero);
  }

  group('con el puerto falso', () {
    late FakeInvoicePort invoice;

    setUp(() async {
      invoice = FakeInvoicePort();
      await setUpWith(invoice);
    });

    test(
      'cobrar encola un job factura y el ticket queda sincronizado',
      () async {
        await f.sala.aceptarLineas(
          submit('m1', [linea('l1', 'CANA', 7)], camarero: 'Ana'),
        );
        final ticket = await f.sala.cobrar(
          'm1',
          MetodoPago.efectivo,
          entregadoCents: 1000,
        );
        await settle();

        final job = f.store.snapshot.jobPorId('factura:${ticket.id}')!;
        expect(job.tipo, SyncJobTipo.factura);
        expect(job.estado, SyncJobEstado.hecho);
        expect(job.payload['ticket'], ticket.toJson());

        final enviado = invoice.recibidos.single;
        expect(enviado.claveIdempotente, ticket.claveFactura);
        expect(enviado.codcliente, 'TPVVARIOS');
        expect(enviado.codserie, 'S');
        expect(enviado.codpago, 'TPVEFE');
        expect(enviado.codalmacen, 'ALG');
        expect(enviado.modoPago, ModoPago.nacePagada);
        expect(enviado.emitir, isTrue);
        expect(enviado.idEstadoEmitida, 11);
        expect(enviado.totalEsperadoCents, 665);
        expect(enviado.fechaHora, ticket.fechaHora);
        expect(enviado.observaciones, contains('Mesa 1'));
        expect(enviado.observaciones, contains('Ana'));
        final lineaFs = enviado.lineas.single;
        expect(lineaFs.referencia, 'CANA');
        expect(lineaFs.cantidad, 7);
        expect(lineaFs.pvpunitarioNeto, 0.86364);
        expect(lineaFs.codimpuesto, 'IVA10');

        final actualizado = f.store.snapshot.ticketPorId(ticket.id)!;
        final factura = actualizado.factura!;
        expect(factura.estado, EstadoSincronizacion.sincronizado);
        expect(factura.idfactura, 1);
        expect(factura.codigo, 'F2026S1');
        expect(factura.numero, 1);
        expect(factura.idasiento, 101);
        expect(factura.pagada, isTrue);
        expect(factura.emitida, isTrue);
        expect(factura.actualizadoEn, f.clock.now);
        // Persistido.
        expect((await f.repo.load())!.ticketPorId(ticket.id)!.factura, factura);
      },
    );

    test(
      'tarjeta usa su codpago y pagarTrasCrear si la forma no nace pagada',
      () async {
        await f.sala.aceptarLineas(submit('m1', [linea('l1', 'CANA', 1)]));
        await f.sala.cobrar('m1', MetodoPago.tarjeta);
        await settle();
        final enviado = invoice.recibidos.single;
        expect(enviado.codpago, 'TPVTAR');
        expect(enviado.modoPago, ModoPago.pagarTrasCrear);
        // Las formas de pago y los estados se consultan una sola vez.
        await f.sala.aceptarLineas(submit('m2', [linea('l2', 'CANA', 1)]));
        await f.sala.cobrar('m2', MetodoPago.tarjeta);
        await settle();
        expect(masterData.calls, 2);
      },
    );

    test('pago único: la factura no lleva reparto', () async {
      await f.sala.aceptarLineas(submit('m1', [linea('l1', 'CANA', 1)]));
      await f.sala.cobrar('m1', MetodoPago.efectivo);
      await settle();
      final enviado = invoice.recibidos.single;
      expect(enviado.pagos, isEmpty);
      expect(enviado.esCobroMixto, isFalse);
    });

    test('r3: cobro mixto: un pago por forma de pago, cada uno con su modo; '
        'la cabecera es la forma que no nace pagada', () async {
      await f.sala.aceptarLineas(submit('m1', [linea('l1', 'CANA', 7)]));
      final ticket = await f.sala.cobrarMixto(
        'm1',
        efectivoCents: 400,
        entregadoCents: 500,
      );
      await settle();

      final job = f.store.snapshot.jobPorId('factura:${ticket.id}')!;
      expect(job.estado, SyncJobEstado.hecho);
      expect(job.payload['ticket'], ticket.toJson());

      final enviado = invoice.recibidos.single;
      expect(enviado.totalEsperadoCents, 665);
      // Cabecera: el efectivo es la forma principal (4,00 > 2,65) pero nace
      // pagada, así que va la tarjeta (r3: recibo n.º 1 abierto).
      expect(enviado.codpago, 'TPVTAR');
      expect(enviado.modoPago, ModoPago.pagarTrasCrear);
      expect(enviado.pagos, [
        PagoFactura(
          codpago: 'TPVEFE',
          importeCents: 400,
          modoPago: ModoPago.nacePagada,
          efectivo: true,
        ),
        PagoFactura(codpago: 'TPVTAR', importeCents: 265),
      ]);
      expect(enviado.esCobroMixto, isTrue);
      expect(enviado.planCobro, const [
        ParteCobro(numero: 1, codpago: 'TPVTAR', importeCents: 265),
        ParteCobro(
          numero: 2,
          codpago: 'TPVEFE',
          importeCents: 400,
          modoPago: ModoPago.nacePagada,
          efectivo: true,
        ),
      ]);
      expect(
        f.store.snapshot.ticketPorId(ticket.id)!.factura!.estado,
        EstadoSincronizacion.sincronizado,
      );
      // Las formas de pago se consultan una sola vez.
      expect(masterData.calls, 2, reason: 'formas de pago + estados');
    });

    test('cobro mixto con más tarjeta: la cabecera es la tarjeta', () async {
      await f.sala.aceptarLineas(submit('m1', [linea('l1', 'CANA', 7)]));
      await f.sala.cobrarMixto('m1', efectivoCents: 100);
      await settle();
      final enviado = invoice.recibidos.single;
      expect(enviado.codpago, 'TPVTAR');
      expect(enviado.modoPago, ModoPago.pagarTrasCrear);
      expect(enviado.codpagoCabecera, 'TPVTAR');
      expect(enviado.planCobro.map((p) => (p.codpago, p.importeCents)), [
        ('TPVTAR', 565),
        ('TPVEFE', 100),
      ]);
    });

    test('r3: si la principal no nace pagada, la cabecera es la '
        'principal', () async {
      // Las dos formas con pagado=0: manda la principal (efectivo).
      masterData.formas = const [
        FsFormaPago(codpago: 'TPVEFE', descripcion: 'Efectivo'),
        FsFormaPago(codpago: 'TPVTAR', descripcion: 'Tarjeta'),
      ];
      await f.sala.aceptarLineas(submit('m1', [linea('l1', 'CANA', 7)]));
      await f.sala.cobrarMixto('m1', efectivoCents: 400);
      await settle();
      expect(invoice.recibidos.last.codpago, 'TPVEFE');
      expect(invoice.recibidos.last.modoPago, ModoPago.pagarTrasCrear);
    });

    test('r3: si las dos formas nacen pagadas se mantiene la principal '
        '(coste conocido: DELETE + 2 POST)', () async {
      masterData.formas = const [
        FsFormaPago(codpago: 'TPVEFE', descripcion: 'Efectivo', pagado: true),
        FsFormaPago(codpago: 'TPVTAR', descripcion: 'Tarjeta', pagado: true),
      ];
      await f.sala.aceptarLineas(submit('m1', [linea('l1', 'CANA', 7)]));
      await f.sala.cobrarMixto('m1', efectivoCents: 100);
      await settle();
      final enviado = invoice.recibidos.single;
      expect(enviado.codpago, 'TPVTAR', reason: 'principal: 5,65 > 1,00');
      expect(enviado.modoPago, ModoPago.nacePagada);
    });

    test('cobro mixto con una forma de pago que no existe en el ERP avisa '
        'una vez', () async {
      masterData.formas = const [
        FsFormaPago(codpago: 'TPVEFE', descripcion: 'Efectivo', pagado: true),
      ];
      await f.sala.aceptarLineas(submit('m1', [linea('l1', 'CANA', 7)]));
      final ticket = await f.sala.cobrarMixto('m1', efectivoCents: 400);
      await settle();
      final enviado = invoice.recibidos.single;
      expect(enviado.pagos.last.modoPago, ModoPago.pagarTrasCrear);
      final avisos = f.store.snapshot.ticketPorId(ticket.id)!.factura!.avisos;
      expect(avisos.where((a) => a.contains("'TPVTAR'")), hasLength(1));
    });

    test(
      'error definitivo del ERP marca el ticket en error; reintentar',
      () async {
        invoice.failNext(
          const ErpApiException('fecha no válida', statusCode: 422),
        );
        await f.sala.aceptarLineas(submit('m1', [linea('l1', 'CANA', 1)]));
        final ticket = await f.sala.cobrar('m1', MetodoPago.tarjeta);
        await settle();
        await Future<void>.delayed(Duration.zero);

        var actualizado = f.store.snapshot.ticketPorId(ticket.id)!;
        expect(actualizado.factura!.estado, EstadoSincronizacion.error);
        expect(actualizado.factura!.error, 'fecha no válida');
        expect(outbox.estado.enError, 1);

        await billing.reintentarFactura(ticket.id);
        await settle();
        actualizado = f.store.snapshot.ticketPorId(ticket.id)!;
        expect(actualizado.factura!.estado, EstadoSincronizacion.sincronizado);
      },
    );

    test(
      'fallo transitorio deja la factura pendiente y se reintenta después',
      () async {
        invoice.failNext(const ErpApiException('timeout'));
        await f.sala.aceptarLineas(submit('m1', [linea('l1', 'CANA', 1)]));
        final ticket = await f.sala.cobrar('m1', MetodoPago.tarjeta);
        await settle();
        final job = f.store.snapshot.jobPorId('factura:${ticket.id}')!;
        expect(job.estado, SyncJobEstado.pendiente);
        expect(job.proximoIntentoEn, isNotNull);
        expect(
          f.store.snapshot.ticketPorId(ticket.id)!.factura!.estado,
          EstadoSincronizacion.pendiente,
        );
      },
    );

    test('sin estado Emitida se factura sin emitir y se avisa', () async {
      masterData.estados = const [
        FsEstadoDocumento(
          idestado: 10,
          nombre: 'Boceto',
          tipodoc: 'FacturaCliente',
          predeterminado: true,
        ),
      ];
      await f.sala.aceptarLineas(submit('m1', [linea('l1', 'CANA', 1)]));
      final ticket = await f.sala.cobrar('m1', MetodoPago.tarjeta);
      await settle();
      expect(invoice.recibidos.single.emitir, isFalse);
      final factura = f.store.snapshot.ticketPorId(ticket.id)!.factura!;
      expect(factura.avisos.single, contains('Emitida'));
    });

    test(
      'sin ERP configurado la cola se pausa y el ticket sigue pendiente',
      () async {
        billing.configurar(invoice: null);
        expect(billing.disponible, isFalse);
        await f.sala.aceptarLineas(submit('m1', [linea('l1', 'CANA', 1)]));
        final ticket = await f.sala.cobrar('m1', MetodoPago.tarjeta);
        await settle();
        expect(outbox.pausada, isTrue);
        expect(
          f.store.snapshot.jobPorId('factura:${ticket.id}')!.estado,
          SyncJobEstado.bloqueado,
        );
        billing.configurar(invoice: invoice, masterData: masterData);
        await outbox.reanudar();
        await settle();
        expect(
          f.store.snapshot.ticketPorId(ticket.id)!.factura!.estado,
          EstadoSincronizacion.sincronizado,
        );
      },
    );

    test('reimprimir usa el código de factura', () async {
      await f.sala.aceptarLineas(submit('m1', [linea('l1', 'CANA', 1)]));
      final ticket = await f.sala.cobrar('m1', MetodoPago.tarjeta);
      await settle();
      expect(
        () => billing.reimprimir(ticket.id),
        throwsA(isA<PrinterException>()),
        reason: 'sin impresora de tickets',
      );
      printing.configurar(
        settings: ImpresionSettings(tickets: PrinterEndpoint('10.0.0.12')),
      );
      await billing.reimprimir(ticket.id);
      await printing.idle();
      expect(printer.jobs.single.description, contains('copia'));
      expect(
        () => billing.reimprimir('nope'),
        throwsA(isA<ValidationException>()),
      );
    });
  });

  for (final mixto in [false, true]) {
    test('h2: el ticket${mixto ? ' mixto' : ''} y su trabajo de factura se '
        'guardan en la misma escritura', () async {
      await _comprobarMismaEscritura(mixto: mixto);
    });
  }

  group('h2: reconciliación al arrancar', () {
    late FakeInvoicePort invoice;

    setUp(() async {
      invoice = FakeInvoicePort();
      await setUpWith(invoice);
    });

    test('encola la factura de los tickets pendientes sin trabajo', () async {
      await outbox.stop();
      await f.sala.aceptarLineas(submit('m1', [linea('l1', 'CANA', 1)]));
      final ticket = await f.sala.cobrar('m1', MetodoPago.tarjeta);
      await f.sala.idle();
      // Diario de una versión anterior: el ticket quedó sin su trabajo.
      await f.store.update((s) => s.copyWith(cola: const []));

      expect(await billing.reconciliar(), 1);
      expect(await billing.reconciliar(), 0, reason: 'idempotente');
      expect(
        f.alerts.recientes.map((a) => a.titulo),
        contains('Facturas recuperadas'),
      );
      await outbox.start();
      await settle();
      expect(
        f.store.snapshot.ticketPorId(ticket.id)!.factura!.estado,
        EstadoSincronizacion.sincronizado,
      );
      expect(invoice.recibidos, hasLength(1));
    });

    test(
      'no toca los tickets ya facturados ni los que tienen trabajo',
      () async {
        await f.sala.aceptarLineas(submit('m1', [linea('l1', 'CANA', 1)]));
        await f.sala.cobrar('m1', MetodoPago.tarjeta);
        await settle();
        expect(await billing.reconciliar(), 0);
        expect(invoice.recibidos, hasLength(1));
      },
    );
  });

  group('h15: codimpuesto de respaldo', () {
    late FakeInvoicePort invoice;

    LineaComanda sinImpuesto() => LineaComanda(
      id: 'l1',
      referencia: 'TAPA',
      descripcion: 'Tapa',
      cantidad: 1,
      pvpUnitarioCents: 121,
      pvpUnitarioNeto: 1,
      ivaBp: 2100,
      creadaEn: DateTime(2026, 10, 7, 13),
    );

    test('sin codimpuesto en la línea ni ajuste fiscal, usa el por defecto '
        'del ERP', () async {
      invoice = FakeInvoicePort();
      await setUpWith(invoice, conCatalogo: false, codimpuestoPorDefecto: null);
      await f.sala.aceptarLineas(submit('m1', [sinImpuesto()]));
      await f.sala.cobrar('m1', MetodoPago.tarjeta);
      await settle();
      expect(invoice.recibidos.single.lineas.single.codimpuesto, 'IVA21');
    });

    test('si no hay ningún impuesto por defecto no envía "" y pausa las '
        'facturas', () async {
      invoice = FakeInvoicePort();
      await setUpWith(invoice, conCatalogo: false, codimpuestoPorDefecto: null);
      masterData.ajustes = const FsDefaultSettings(codserie: 'S');
      await f.sala.aceptarLineas(submit('m1', [sinImpuesto()]));
      final ticket = await f.sala.cobrar('m1', MetodoPago.tarjeta);
      await settle();
      expect(invoice.recibidos, isEmpty);
      final job = f.store.snapshot.jobPorId('factura:${ticket.id}')!;
      expect(job.estado, SyncJobEstado.bloqueado);
      expect(job.ultimoError, contains('impuesto'));
      expect(outbox.tiposEnPausa, {SyncJobTipo.factura});
    });
  });

  group('con FsInvoiceService real sobre FakeFsApi', () {
    late FakeFsApi api;

    setUp(() async {
      api = FakeFsApi.conDatosBasicos();
      await setUpWith(FsPorts(api).invoice);
    });

    test(
      'crea la factura en el ERP falso y es idempotente al reintentar',
      () async {
        await f.sala.aceptarLineas(submit('m1', [linea('l1', 'CANA', 7)]));
        final ticket = await f.sala.cobrar(
          'm1',
          MetodoPago.efectivo,
          entregadoCents: 700,
        );
        await settle();

        final facturas = api.table('facturaclientes');
        expect(facturas, hasLength(1));
        expect(facturas.single['numero2'], ticket.claveFactura);
        final factura = f.store.snapshot.ticketPorId(ticket.id)!.factura!;
        expect(factura.estado, EstadoSincronizacion.sincronizado);
        expect(factura.codigo, isNotEmpty);
        expect(factura.pagada, isTrue);
        expect(factura.emitida, isTrue);
        expect(factura.avisos, isEmpty, reason: 'total FS == total TPV');

        // Volver a ejecutar el mismo trabajo no crea otra factura.
        await outbox.reintentar('factura:${ticket.id}');
        await settle();
        expect(api.table('facturaclientes'), hasLength(1));
      },
    );

    test('r3: cobro mixto: una factura con un recibo pagado por forma de '
        'pago, sin borrar cobros; reintentar no duplica nada', () async {
      await f.sala.aceptarLineas(submit('m1', [linea('l1', 'CANA', 7)]));
      final ticket = await f.sala.cobrarMixto(
        'm1',
        efectivoCents: 400,
        entregadoCents: 500,
      );
      await settle();

      final facturas = api.table('facturaclientes');
      expect(facturas, hasLength(1));
      // r3: cabecera con la forma que no nace pagada (la tarjeta).
      expect(facturas.single['codpago'], 'TPVTAR');
      final idfactura = facturas.single['idfactura'];
      List<(Object?, Object?, bool)> recibos() => [
        for (final r in api.table('reciboclientes'))
          if (r['idfactura'] == idfactura)
            (r['codpago'], r['importe'], r['pagado'] == true),
      ];
      expect(recibos(), [('TPVTAR', 2.65, true), ('TPVEFE', 4.0, true)]);
      // r3: el recibo automático nace abierto y se ajusta: ningún cobro (ni
      // su asiento) se crea para borrarlo después.
      expect(api.callsTo('reciboclientes', method: 'DELETE'), isEmpty);
      expect(api.callsTo('reciboclientes', method: 'PUT'), hasLength(1));
      expect(api.callsTo('reciboclientes', method: 'POST'), hasLength(1));
      expect(api.table('pagoclientes'), hasLength(2));
      final factura = f.store.snapshot.ticketPorId(ticket.id)!.factura!;
      expect(factura.estado, EstadoSincronizacion.sincronizado);
      expect(factura.pagada, isTrue);
      expect(factura.emitida, isTrue);

      await outbox.reintentar('factura:${ticket.id}');
      await settle();
      expect(api.table('facturaclientes'), hasLength(1));
      expect(recibos(), hasLength(2));
    });
  });
}

/// Comprueba que ningún snapshot persistido tiene el ticket sin su trabajo
/// de factura (el diario se puede cortar entre dos escrituras cualesquiera).
Future<void> _comprobarMismaEscritura({required bool mixto}) async {
  final repo = RepoQueAnota();
  final alerts = AlertBus();
  final store = HostStateStore(
    repo,
    HostSnapshot(
      mesas: mesasPrueba,
      catalogo: catalogoPrueba(),
      catalogoVersion: CatalogService.versionDe(catalogoPrueba()),
    ),
    alerts,
  );
  final catalog = CatalogService(store: store, alerts: alerts);
  final sala = SalaService(store: store, alerts: alerts, catalog: catalog);
  final cola = SyncOutbox(store: store, alerts: alerts);
  final impresion = PrintingService(
    alerts: alerts,
    runner: const InlineIsolateRunner(),
    settings: const ImpresionSettings(imprimirTicketAlCobrar: false),
    nombreTpv: 'Barra',
  );
  final facturacion = BillingService(
    store: store,
    alerts: alerts,
    outbox: cola,
    printing: impresion,
    fiscal: fiscal,
  );
  sala.addEffects(facturacion);
  addTearDown(() async {
    await facturacion.dispose();
    await cola.dispose();
    await sala.dispose();
    await catalog.dispose();
    await store.dispose();
    await alerts.dispose();
  });

  await sala.aceptarLineas(submit('m1', [linea('l1', 'CANA', 2)]));
  final ticket = mixto
      ? await sala.cobrarMixto('m1', efectivoCents: 100)
      : await sala.cobrar('m1', MetodoPago.tarjeta);
  await sala.idle();
  await store.flush();

  final conTicket = [
    for (final s in repo.guardados)
      if (s.ticketPorId(ticket.id) != null) s,
  ];
  expect(conTicket, isNotEmpty);
  for (final s in conTicket) {
    expect(
      s.jobPorId(BillingService.jobIdDe(ticket.id)),
      isNotNull,
      reason: 'ningún snapshot persistido tiene el ticket sin su factura',
    );
  }
  if (mixto) expect(ticket.esMixto, isTrue);
}
