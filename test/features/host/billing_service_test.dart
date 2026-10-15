import 'dart:convert';
import 'dart:io';

import 'package:proyecto_comandero/core/errors/app_exception.dart';
import 'package:proyecto_comandero/core/facturascripts/documents/invoice_models.dart';
import 'package:proyecto_comandero/core/facturascripts/master_data/fs_master_models.dart';
import 'package:proyecto_comandero/core/isolates/escpos/ticket_documents.dart'
    show EmpresaTicket;
import 'package:proyecto_comandero/core/isolates/isolate_runner.dart';
import 'package:proyecto_comandero/core/logging/app_logger.dart';
import 'package:proyecto_comandero/core/money/money.dart';
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
import 'package:proyecto_comandero/features/host/data/in_memory_host_state_repository.dart';
import 'package:proyecto_comandero/features/host/domain/host_settings.dart';
import 'package:proyecto_comandero/features/host/domain/host_snapshot.dart';
import 'package:proyecto_comandero/features/host/domain/sync_job.dart';
import 'package:proyecto_comandero/features/sala/domain/linea_comanda.dart';
import 'package:proyecto_comandero/features/sala/domain/precuenta_emitida.dart';
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

  /// [repo] y [clock] permiten arrancar sobre un diario ya guardado (p. ej.
  /// una fixture de compatibilidad) con el reloj que haga falta.
  Future<void> setUpWith(
    InvoicePort invoice, {
    bool emitir = true,
    bool conCatalogo = true,
    String? codimpuestoPorDefecto = 'IVA21',
    InMemoryHostStateRepository? repo,
    FakeClock? clock,
  }) async {
    f = await SalaFixture.create(
      repo: repo,
      clock: clock,
      conCatalogo: conCatalogo,
    );
    outbox = SyncOutbox(store: f.store, alerts: f.alerts, now: f.clock.call);
    printer = FakePrinterPort();
    printing = PrintingService(
      alerts: f.alerts,
      runner: const InlineIsolateRunner(),
      settings: const ImpresionSettings(imprimirTicketAlCobrar: false),
      nombreTpv: 'Barra',
      store: f.store,
      printer: printer,
      // Con NIF: sin él, reimprimir daría una copia del provisional.
      empresa: const EmpresaTicket(
        nombre: 'Bar de pruebas',
        cifnif: 'B12345678',
      ),
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

  /// Siembra [ticket] en el diario y encola su trabajo de factura como hace
  /// `alCobrar`, sin pasar por `SalaService.cobrar` (su enlace con las
  /// precuentas es de WP-07a); espera a que la cola lo procese.
  Future<void> facturarDirecto(Ticket ticket) async {
    await f.store.update((s) => s.conTicket(ticket));
    await outbox.enqueue(SyncJobTipo.factura, {
      'ticket': ticket.toJson(),
    }, id: BillingService.jobIdDe(ticket.id));
    await settle();
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
      // Sincronizada con su fecha y su total de FS y con NIF del emisor: la
      // factura, ORIGINAL la primera vez y DUPLICADO después.
      await billing.reimprimir(ticket.id);
      await printing.idle();
      final codigo = f.store.snapshot.ticketPorId(ticket.id)!.factura!.codigo;
      expect(printer.jobs.single.description, contains('original'));
      expect(printer.jobs.single.description, 'Factura $codigo (original)');
      await billing.reimprimir(ticket.id);
      await printing.idle();
      expect(printer.jobs.last.description, contains('duplicado'));
      expect(printer.jobs.last.description, 'Factura $codigo (duplicado 1)');
      expect(
        () => billing.reimprimir('nope'),
        throwsA(isA<ValidationException>()),
      );
    });

    test('el ticket sincronizado guarda la fecha y el total de FS', () async {
      invoice.fecha = DateTime(2026, 10, 7, 13, 45, 10);
      await f.sala.aceptarLineas(submit('m1', [linea('l1', 'CANA', 7)]));
      final ticket = await f.sala.cobrar(
        'm1',
        MetodoPago.efectivo,
        entregadoCents: 1000,
      );
      await settle();

      final factura = f.store.snapshot.ticketPorId(ticket.id)!.factura!;
      expect(factura.estado, EstadoSincronizacion.sincronizado);
      expect(factura.fecha, DateTime(2026, 10, 7, 13, 45, 10));
      expect(factura.fecha, isNot(ticket.fechaHora), reason: 'la de FS');
      expect(factura.totalFsCents, 665);
      // Persistidos en el diario.
      final guardada = (await f.repo.load())!.ticketPorId(ticket.id)!.factura!;
      expect(guardada.fecha, DateTime(2026, 10, 7, 13, 45, 10));
      expect(guardada.totalFsCents, 665);
    });

    test('sin fecha ni total de FS quedan nulos: el total nunca se rellena '
        'con el del ticket', () async {
      invoice.fecha = null;
      invoice.devuelveTotal = false;
      await f.sala.aceptarLineas(submit('m1', [linea('l1', 'CANA', 7)]));
      final ticket = await f.sala.cobrar('m1', MetodoPago.tarjeta);
      await settle();

      final factura = f.store.snapshot.ticketPorId(ticket.id)!.factura!;
      expect(factura.estado, EstadoSincronizacion.sincronizado);
      expect(factura.codigo, 'F2026S1');
      expect(factura.fecha, isNull);
      expect(factura.totalFsCents, isNull);
      final guardada = (await f.repo.load())!.ticketPorId(ticket.id)!.factura!;
      expect(guardada.totalFsCents, isNull);
    });

    test('las observaciones llevan el número, la hora y el total de cada '
        'precuenta solo si las hay', () async {
      await facturarDirecto(
        ticketDirecto(
          id: 't-pre',
          precuentas: [
            precuenta(1, DateTime(2026, 10, 7, 14, 10), 6700),
            precuenta(2, DateTime(2026, 10, 7, 14, 25), 7050),
          ],
        ),
      );
      expect(
        invoice.recibidos.single.observaciones,
        'TPV ticket 15 · Mesa Mesa 1 · Camarero Ana · '
        'Precuentas nº 1 14:10 67,00 €, nº 2 14:25 70,50 €',
      );

      // Sin camarero y con una sola precuenta (hora con cero a la izquierda
      // y total con miles).
      await facturarDirecto(
        ticketDirecto(
          id: 't-pre-sola',
          camarero: null,
          precuentas: [precuenta(1, DateTime(2026, 10, 7, 9, 5), 1234567)],
        ),
      );
      expect(
        invoice.recibidos.last.observaciones,
        'TPV ticket 15 · Mesa Mesa 1 · Precuentas nº 1 09:05 12.345,67 €',
      );

      // Sin precuentas, el texto es idéntico al de hoy (contrato con el
      // plugin Hosteleria: se amplía, no se cambia).
      await facturarDirecto(ticketDirecto(id: 't-sin'));
      expect(
        invoice.recibidos.last.observaciones,
        'TPV ticket 15 · Mesa Mesa 1 · Camarero Ana',
      );
      await facturarDirecto(
        ticketDirecto(id: 't-sin-camarero', camarero: null),
      );
      expect(
        invoice.recibidos.last.observaciones,
        'TPV ticket 15 · Mesa Mesa 1',
      );
    });

    test('una marca de impresión escrita mientras se factura se conserva, '
        'igual que las precuentas', () async {
      final ticket = ticketDirecto(
        id: 't-marca',
        precuentas: [precuenta(1, DateTime(2026, 10, 7, 14, 10), 6700)],
      );
      final marca = ImpresionTicket(
        provisionalEn: DateTime(2026, 10, 7, 14, 31),
      );
      // Mientras el ERP trabaja, la impresión anota el provisional en el
      // diario (misma carrera que T4: factura e impresion sobre el ticket).
      invoice.antesDeResponder = (_) => f.store.update(
        (s) =>
            s.conTicket(s.ticketPorId('t-marca')!.copyWith(impresion: marca)),
      );
      await facturarDirecto(ticket);

      final actualizado = f.store.snapshot.ticketPorId('t-marca')!;
      expect(actualizado.factura!.estado, EstadoSincronizacion.sincronizado);
      expect(actualizado.factura!.totalFsCents, 665);
      expect(actualizado.impresion, marca);
      expect(actualizado.precuentas, ticket.precuentas);
      expect((await f.repo.load())!.ticketPorId('t-marca'), actualizado);
    });

    test('la rama de error del trabajo también conserva la marca de '
        'impresión y las precuentas', () async {
      final ticket = ticketDirecto(
        id: 't-error',
        precuentas: [precuenta(1, DateTime(2026, 10, 7, 14, 10), 6700)],
      );
      final marca = ImpresionTicket(
        provisionalEn: DateTime(2026, 10, 7, 14, 31),
        copiasProvisional: 1,
      );
      invoice.antesDeResponder = (_) => f.store.update(
        (s) =>
            s.conTicket(s.ticketPorId('t-error')!.copyWith(impresion: marca)),
      );
      invoice.failNext(
        const ErpApiException('fecha no válida', statusCode: 422),
      );
      await facturarDirecto(ticket);
      await Future<void>.delayed(Duration.zero);

      final actualizado = f.store.snapshot.ticketPorId('t-error')!;
      expect(actualizado.factura!.estado, EstadoSincronizacion.error);
      expect(actualizado.factura!.error, 'fecha no válida');
      expect(actualizado.impresion, marca);
      expect(actualizado.precuentas, ticket.precuentas);
      expect((await f.repo.load())!.ticketPorId('t-error'), actualizado);
    });

    group('si el ticket sale del turno con la factura en vuelo', () {
      late List<LogRecord> registros;

      setUp(() {
        registros = [];
        configureLogging(level: Level.ALL, onRecord: registros.add);
        addTearDown(configureLogging);
      });

      /// Lo que hace el Cierre Z: archiva el ticket (lo saca de
      /// `ticketsTurno`) aunque su factura siga pendiente.
      Future<void> archivar(String ticketId) => f.store.update(
        (s) => s.copyWith(
          ticketsTurno: [
            for (final t in s.ticketsTurno)
              if (t.id != ticketId) t,
          ],
        ),
      );

      /// El ticket sigue fuera del diario, en memoria y en disco, y
      /// `_actualizarTicket` pasó por la rama que no lo escribe (`conTicket`
      /// lo añadiría si falta).
      Future<void> comprobarFuera(String ticketId) async {
        expect(f.store.snapshot.ticketPorId(ticketId), isNull);
        expect((await f.repo.load())!.ticketPorId(ticketId), isNull);
        expect(
          registros.map((r) => r.message),
          contains(startsWith('Ticket $ticketId ya no está en el turno')),
        );
      }

      test('el trabajo termina y el ticket no reaparece', () async {
        invoice.antesDeResponder = (_) => archivar('t-fuera');
        await facturarDirecto(ticketDirecto(id: 't-fuera'));

        expect(invoice.recibidos, hasLength(1));
        final job = f.store.snapshot.jobPorId(
          BillingService.jobIdDe('t-fuera'),
        );
        expect(job!.estado, SyncJobEstado.hecho);
        await comprobarFuera('t-fuera');
      });

      test(
        'si el ERP la rechaza, la marca de error tampoco lo resucita',
        () async {
          invoice.antesDeResponder = (_) => archivar('t-fuera-error');
          invoice.failNext(
            const ErpApiException('fecha no válida', statusCode: 422),
          );
          await facturarDirecto(ticketDirecto(id: 't-fuera-error'));
          await Future<void>.delayed(Duration.zero);

          final job = f.store.snapshot.jobPorId(
            BillingService.jobIdDe('t-fuera-error'),
          );
          expect(job!.estado, SyncJobEstado.error);
          await comprobarFuera('t-fuera-error');
        },
      );
    });
  });

  group('compatibilidad', () {
    test('el trabajo de factura de host_snapshot_v1.json se ejecuta igual '
        'que hoy', () async {
      final json = jsonDecode(
        fixtureCompat('host_snapshot_v1.json'),
      ) as Map<String, Object?>;
      final invoice = FakeInvoicePort()
        ..fecha = DateTime(2026, 10, 9, 13, 10, 2);
      await setUpWith(
        invoice,
        repo: InMemoryHostStateRepository(HostSnapshot.fromJson(json)),
        // Pasado el `proximoIntentoEn` del trabajo (09/10 13:05).
        clock: FakeClock(DateTime(2026, 10, 9, 13, 10)),
      );
      await settle();

      // La misma factura que hoy: cobro mixto de la Barra, sin camarero.
      final enviado = invoice.recibidos.single;
      expect(enviado.claveIdempotente, 'TPV-t-0002');
      expect(enviado.codcliente, 'TPVVARIOS');
      expect(enviado.codserie, 'S');
      expect(enviado.codalmacen, 'ALG');
      expect(enviado.fechaHora, DateTime(2026, 10, 9, 12, 55));
      expect(enviado.observaciones, 'TPV ticket 13 · Mesa Barra');
      expect(enviado.lineas.map((l) => (l.referencia, l.codimpuesto)), [
        ('AGUA', 'IVA21'),
        ('CAFE', 'IVA10'),
      ]);
      expect(enviado.totalEsperadoCents, 230);
      expect(enviado.codpago, 'TPVTAR', reason: 'el efectivo nace pagado');
      expect(enviado.modoPago, ModoPago.pagarTrasCrear);
      expect(enviado.pagos, [
        PagoFactura(
          codpago: 'TPVEFE',
          importeCents: 100,
          modoPago: ModoPago.nacePagada,
          efectivo: true,
        ),
        PagoFactura(codpago: 'TPVTAR', importeCents: 130),
      ]);
      expect(enviado.emitir, isTrue);
      expect(enviado.idEstadoEmitida, 11);

      final job = f.store.snapshot.jobPorId('factura:t-0002')!;
      expect(job.estado, SyncJobEstado.hecho);
      expect(job.intentos, 3, reason: 'la fixture ya llevaba dos');
      final ticket = f.store.snapshot.ticketPorId('t-0002')!;
      final factura = ticket.factura!;
      expect(factura.estado, EstadoSincronizacion.sincronizado);
      expect(factura.codigo, 'F2026S1');
      expect(factura.fecha, DateTime(2026, 10, 9, 13, 10, 2));
      expect(factura.totalFsCents, 230);
      // Un ticket de la versión anterior no tiene precuentas ni impresión.
      expect(ticket.precuentas, isEmpty);
      expect(ticket.impresion.estaVacia, isTrue);
      // El resto del diario no cambia.
      final snapshot = f.store.snapshot;
      expect(snapshot.ticketPorId('t-0001')!.factura!.codigo, 'F2026S318');
      expect(snapshot.jobPorId('stock:t-0001')!.estado, SyncJobEstado.hecho);
      expect(snapshot.comandas, hasLength(2));
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
        // Fecha (con hora) y total tal como los devolvió el ERP.
        expect(factura.fecha, ticket.fechaHora);
        expect(factura.totalFsCents, 665);

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

/// Lee una fixture de compatibilidad (los finales de línea dependen de
/// `core.autocrlf` al clonar).
String fixtureCompat(String nombre) =>
    File('test/fixtures/compat/$nombre')
        .readAsStringSync()
        .replaceAll('\r\n', '\n');

/// Totales al 10 % de un importe con IVA incluido.
TotalesTicket totalesIva10(int totalCents) {
  final (:baseCents, :taxCents) = splitTaxIncluded(totalCents, 1000);
  return TotalesTicket(
    netoCents: baseCents,
    ivaCents: taxCents,
    totalCents: totalCents,
    desglose: [
      DesgloseIva(
        codimpuesto: 'IVA10',
        ivaBp: 1000,
        baseCents: baseCents,
        cuotaCents: taxCents,
      ),
    ],
  );
}

/// Precuenta nº [numero] de la Mesa 1 emitida en [emitidaEn] por
/// [totalCents].
PrecuentaEmitida precuenta(int numero, DateTime emitidaEn, int totalCents) =>
    PrecuentaEmitida(
      numero: numero,
      emitidaEn: emitidaEn,
      comandaId: 'c-directo',
      nombreMesa: 'Mesa 1',
      lineas: [LineaPrecuenta.desde(linea('l1', 'CANA', 7))],
      totales: totalesIva10(totalCents),
      comensales: 2,
      emitidaPor: 'Barra',
    );

/// Ticket nº 15 de la Mesa 1 (7 cañas, 6,65 € en efectivo) construido
/// directamente, sin pasar por `SalaService.cobrar`.
Ticket ticketDirecto({
  required String id,
  String? camarero = 'Ana',
  List<PrecuentaEmitida> precuentas = const [],
}) => Ticket(
  id: id,
  numeroLocal: 15,
  mesaId: 'm1',
  nombreMesa: 'Mesa 1',
  comandaId: 'c-directo',
  fechaHora: DateTime(2026, 10, 7, 14, 30),
  lineas: [linea('l1', 'CANA', 7)],
  totales: totalesIva10(665),
  metodoPago: MetodoPago.efectivo,
  entregadoCents: 1000,
  camarero: camarero,
  precuentas: precuentas,
);

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
    store: store,
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
