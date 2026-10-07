import 'dart:async';

import 'package:proyecto_comandero/core/errors/app_exception.dart';
import 'package:proyecto_comandero/core/facturascripts/accounting/accounting_models.dart';
import 'package:proyecto_comandero/core/isolates/cierre_z/cierre_z_models.dart'
    show ModoAsientoZ;
import 'package:proyecto_comandero/core/isolates/isolate_runner.dart';
import 'package:proyecto_comandero/core/network/printing/raw_printer_transport.dart';
import 'package:proyecto_comandero/features/host/application/cierre_z_service.dart';
import 'package:proyecto_comandero/features/host/application/printing_service.dart';
import 'package:proyecto_comandero/features/host/application/sync_outbox.dart';
import 'package:proyecto_comandero/features/host/domain/host_settings.dart';
import 'package:proyecto_comandero/features/host/domain/host_snapshot.dart';
import 'package:proyecto_comandero/features/host/domain/sync_job.dart';
import 'package:proyecto_comandero/features/sala/domain/ticket.dart';
import 'package:test/test.dart';

import 'fakes/fake_ports.dart';
import 'support/host_test_support.dart';

const fiscal = FiscalSettings(
  codcliente: 'TPVVARIOS',
  codpagoEfectivo: 'TPVEFE',
  codpagoTarjeta: 'TPVTAR',
  codalmacen: 'ALG',
);

/// Runner que, con [retener] puesto, deja la ejecución en espera hasta que
/// se complete (para abrir la ventana entre calcular y guardar el cierre).
final class RetenedorRunner implements IsolateRunner {
  Completer<void>? retener;
  Completer<void> llamado = Completer<void>();

  @override
  Future<R> run<M, R>(
    IsolateEntryPoint<M, R> entryPoint,
    M message, {
    String? debugName,
  }) async {
    final gate = retener;
    if (gate != null) {
      if (!llamado.isCompleted) llamado.complete();
      await gate.future;
    }
    return entryPoint(message);
  }
}

void main() {
  late SalaFixture f;
  late SyncOutbox outbox;
  late FakePrinterPort printer;
  late PrintingService printing;
  late FakeAccountingPort accounting;
  late CierreZService service;
  late List<ResumenCierre> cierres;

  Future<void> setUpWith({
    ModoAsientoZ modo = ModoAsientoZ.soloDescuadre,
    bool conErp = true,
    IsolateRunner runner = const InlineIsolateRunner(),
  }) async {
    f = await SalaFixture.create();
    outbox = SyncOutbox(store: f.store, alerts: f.alerts, now: f.clock.call);
    printer = FakePrinterPort();
    printing = PrintingService(
      alerts: f.alerts,
      runner: const InlineIsolateRunner(),
      settings: ImpresionSettings(
        tickets: PrinterEndpoint('10.0.0.12'),
        imprimirTicketAlCobrar: false,
      ),
      nombreTpv: 'Barra',
      printer: printer,
      now: f.clock.call,
    );
    accounting = FakeAccountingPort();
    var ids = 0;
    service = CierreZService(
      store: f.store,
      alerts: f.alerts,
      outbox: outbox,
      printing: printing,
      runner: runner,
      cierre: CierreSettings(modoAsientoZ: modo),
      fiscal: fiscal,
      nombreTpv: 'Barra',
      accounting: conErp ? accounting : null,
      now: f.clock.call,
      newId: () => 'cierre-${++ids}',
    );
    cierres = [];
    service.cierres.listen(cierres.add);
    await outbox.start();
  }

  tearDown(() async {
    await service.dispose();
    await outbox.dispose();
    await f.dispose();
  });

  /// Dos tickets: 6,65 en efectivo y 1,00 (AGUA al 21 %) con tarjeta.
  Future<void> vender() async {
    await f.sala.aceptarLineas(submit('m1', [linea('l1', 'CANA', 7)]));
    await f.sala.cobrar('m1', MetodoPago.efectivo, entregadoCents: 1000);
    await f.sala.aceptarLineas(submit('m2', [linea('l2', 'AGUA', 1)]));
    await f.sala.cobrar('m2', MetodoPago.tarjeta);
    await f.sala.idle();
  }

  Future<void> settle() async {
    await outbox.idle();
    await printing.idle();
    await Future<void>.delayed(Duration.zero);
  }

  /// Marca como sincronizadas las facturas de los tickets del turno.
  Future<void> marcarFacturadas() => f.store.update(
    (s) => s.copyWith(
      ticketsTurno: [
        for (final t in s.ticketsTurno)
          t.conFactura(
            FacturaSincronizada(
              estado: EstadoSincronizacion.sincronizado,
              idfactura: t.numeroLocal,
              codigo: 'F${t.numeroLocal}',
            ),
          ),
      ],
    ),
  );

  group('turno', () {
    setUp(() => setUpWith());

    test('iniciar, retiradas y validaciones', () async {
      expect(service.turno, isNull);
      final turno = await service.iniciarTurno(10000);
      expect(turno.fondoCajaCents, 10000);
      expect(turno.abiertoEn, f.clock.now);
      expect(
        () => service.iniciarTurno(1),
        throwsA(isA<ValidationException>()),
      );
      expect(
        () => service.registrarRetirada(0),
        throwsA(isA<ValidationException>()),
      );
      await service.registrarRetirada(2000);
      final actualizado = await service.registrarRetirada(500);
      expect(actualizado.retiradasCents, 2500);
      expect((await f.repo.load())!.cierreAbierto, actualizado);
    });
  });

  group('previsualizar y cerrar (solo descuadre)', () {
    setUp(() => setUpWith());

    test(
      'sin descuadre: informe correcto, asiento vacío, nada que encolar',
      () async {
        await service.iniciarTurno(10000);
        await vender();
        final preview = await service.previsualizar(
          efectivoContadoCents: 10665,
        );
        expect(preview.informe.numTickets, 2);
        expect(preview.informe.ventasTotalCents, 765);
        expect(preview.informe.ventasEfectivoCents, 665);
        expect(preview.informe.ventasTarjetaCents, 100);
        expect(preview.informe.efectivoEsperadoCents, 10665);
        expect(preview.informe.descuadreCents, 0);
        expect(preview.informe.porIva.map((v) => v.codimpuesto), [
          'IVA10',
          'IVA21',
        ]);
        expect(preview.asiento.vacio, isTrue);
        expect(preview.asientoContabilizable, isFalse);
        expect(preview.motivoNoContabilizable, contains('vacío'));
        expect(accounting.calls, 1, reason: 'resolverSubcuentas');

        final resumen = await service.cerrar(efectivoContadoCents: 10665);
        await settle();
        expect(resumen.id, 'cierre-1');
        expect(resumen.numTickets, 2);
        expect(resumen.descuadreCents, 0);
        expect(resumen.documentoAsiento, isNull);
        expect(resumen.asientoEncolado, isFalse);
        expect(service.turno, isNull);
        expect(service.ticketsTurno, isEmpty);
        expect(service.historial, [resumen]);
        expect(f.store.snapshot.cola, isEmpty);
        expect(cierres, [resumen]);
        expect(printer.jobs.single.description, contains('Informe Z'));
        expect(
          f.alerts.recientes.last.titulo,
          contains('nada que contabilizar'),
        );
        // Un nuevo turno vuelve a numerar tickets de forma correlativa.
        await f.sala.aceptarLineas(submit('m1', [linea('l3', 'CANA', 1)]));
        final siguiente = await f.sala.cobrar('m1', MetodoPago.tarjeta);
        expect(siguiente.numeroLocal, 3);
      },
    );

    test('u6: sin turno ni tickets (tras un cierre) rechaza un segundo cierre '
        'vacío', () async {
      expect(service.hayAlgoQueCerrar, isFalse);
      await expectLater(
        service.cerrar(efectivoContadoCents: 10000),
        throwsA(isA<ValidationException>()),
      );
      expect(service.historial, isEmpty);

      await service.iniciarTurno(10000);
      await vender();
      expect(service.hayAlgoQueCerrar, isTrue);
      await service.cerrar(efectivoContadoCents: 10665);
      await settle();
      expect(service.hayAlgoQueCerrar, isFalse);

      // El cajero cuenta los 100 € de cambio que deja en el cajón y repite.
      await expectLater(
        service.cerrar(efectivoContadoCents: 10000),
        throwsA(
          isA<ValidationException>().having(
            (e) => e.message,
            'message',
            contains('No hay turno ni tickets'),
          ),
        ),
      );
      await settle();
      expect(service.historial, hasLength(1));
      expect(f.store.snapshot.cola, isEmpty, reason: 'ningún asiento 759');
    });

    test('con descuadre: asiento 659/570 encolado y contabilizado', () async {
      await service.iniciarTurno(10000);
      await service.registrarRetirada(1000);
      await vender();
      // Esperado: 10000 + 665 - 1000 = 9665; contado 9600 → faltan 0,65.
      final resumen = await service.cerrar(efectivoContadoCents: 9600);
      await settle();

      expect(resumen.efectivoEsperadoCents, 9665);
      expect(resumen.descuadreCents, -65);
      expect(resumen.asientoEncolado, isTrue);
      expect(resumen.documentoAsiento, startsWith('Z-20261007-'));

      final job = f.store.snapshot.jobPorId(
        'asientoZ:${resumen.documentoAsiento}',
      )!;
      expect(job.tipo, SyncJobTipo.asientoZ);
      expect(job.estado, SyncJobEstado.hecho);
      final asiento = accounting.contabilizados.single;
      expect(asiento.clave, resumen.documentoAsiento);
      expect(asiento.cuadrado, isTrue);
      expect(asiento.debeTotalCents, 65);
      expect(
        asiento.lineas.map((l) => (l.codsubcuenta, l.debeCents, l.haberCents)),
        containsAll([('6590000000', 65, 0), ('5700000000', 0, 65)]),
      );
    });

    test('sobrante: 570 al debe y 759 al haber', () async {
      await vender(); // Sin turno abierto: fondo implícito 0.
      final preview = await service.previsualizar(efectivoContadoCents: 700);
      expect(preview.informe.fondoCajaCents, 0);
      expect(preview.informe.descuadreCents, 35);
      expect(
        preview.asiento.partidas.map(
          (p) => (p.codsubcuenta, p.debeCents, p.haberCents),
        ),
        containsAll([('5700000000', 35, 0), ('7590000000', 0, 35)]),
      );
      expect(preview.asientoContabilizable, isTrue);
    });

    test(
      'si no se resuelven las subcuentas se informa pero no se contabiliza',
      () async {
        accounting.subcuentasDisponibles = false;
        await vender();
        final preview = await service.previsualizar(efectivoContadoCents: 600);
        expect(preview.informe.descuadreCents, -65);
        expect(preview.asiento.vacio, isFalse);
        expect(preview.asientoContabilizable, isFalse);
        expect(preview.motivoNoContabilizable, contains('ejercicio'));

        final resumen = await service.cerrar(efectivoContadoCents: 600);
        await settle();
        expect(resumen.asientoEncolado, isFalse);
        expect(resumen.documentoAsiento, isNotNull);
        expect(f.store.snapshot.cola, isEmpty);
        expect(
          f.alerts.recientes.map((a) => a.titulo),
          contains(contains('no se contabiliza')),
        );
      },
    );

    test('cobro mixto: solo la parte en efectivo entra en caja y cada parte '
        'suma a las ventas de su forma de pago', () async {
      await service.iniciarTurno(10000);
      await vender();
      // 6,65 € = 4,00 en efectivo (entrega 5,00) + 2,65 con tarjeta.
      await f.sala.aceptarLineas(submit('m1', [linea('l3', 'CANA', 7)]));
      await f.sala.cobrarMixto('m1', efectivoCents: 400, entregadoCents: 500);
      await f.sala.idle();

      final preview = await service.previsualizar(efectivoContadoCents: 11065);
      final i = preview.informe;
      expect(i.numTickets, 3);
      expect(i.numTicketsMixtos, 1);
      expect(i.ventasTotalCents, 1430);
      expect(i.ventasEfectivoCents, 665 + 400);
      expect(i.ventasTarjetaCents, 100 + 265);
      // Fondo + efectivo de los tickets (el cambio no cuenta: sale y entra).
      expect(i.efectivoEsperadoCents, 10000 + 1065);
      expect(i.descuadreCents, 0);
      expect(preview.asiento.vacio, isTrue);

      final resumen = await service.cerrar(efectivoContadoCents: 11000);
      await settle();
      expect(resumen.numTicketsMixtos, 1);
      expect(resumen.ventasEfectivoCents, 1065);
      expect(resumen.ventasTarjetaCents, 365);
      expect(resumen.efectivoEsperadoCents, 11065);
      expect(resumen.descuadreCents, -65);
      expect(
        accounting.contabilizados.single.lineas.map(
          (l) => (l.codsubcuenta, l.debeCents, l.haberCents),
        ),
        containsAll([('6590000000', 65, 0), ('5700000000', 0, 65)]),
      );
      // El resumen archivado conserva el recuento al releer el diario.
      final releido = (await f.repo.load())!.historialCierres.single;
      expect(releido, resumen);
      expect(ResumenCierre.fromJson(resumen.toJson()), resumen);
    });

    test('un resumen archivado sin cobros mixtos (diario antiguo) lee 0', () {
      final antiguo = ResumenCierre(
        id: 'z',
        abiertoEn: DateTime(2026, 10, 6, 9),
        cerradoEn: DateTime(2026, 10, 6, 23),
        numTickets: 2,
        numAnulados: 0,
        ventasTotalCents: 765,
        ventasEfectivoCents: 665,
        ventasTarjetaCents: 100,
        fondoCajaCents: 0,
        retiradasCents: 0,
        efectivoEsperadoCents: 665,
        descuadreCents: 0,
      );
      final json = antiguo.toJson();
      expect(json.containsKey('numTicketsMixtos'), isFalse);
      expect(ResumenCierre.fromJson(json).numTicketsMixtos, 0);
    });

    test('un asiento encolado sin ERP configurado espera en pausa', () async {
      await vender();
      service.configurar(accounting: null);
      final resumen = await service.cerrar(efectivoContadoCents: 600);
      await settle();
      // Sin ERP el asiento no se encola (no se pueden resolver subcuentas).
      expect(resumen.asientoEncolado, isFalse);
      expect(resumen.documentoAsiento, isNotNull);
    });
  });

  group('resumen completo', () {
    setUp(() => setUpWith(modo: ModoAsientoZ.resumenCompleto));

    test('se bloquea si las facturas del día ya tienen asiento', () async {
      accounting.facturasConAsiento = true;
      await vender();
      final resumen = await service.cerrar(efectivoContadoCents: 665);
      await settle();
      expect(resumen.asientoEncolado, isFalse);
      expect(f.store.snapshot.cola, isEmpty);
      expect(
        f.alerts.recientes.map((a) => a.detalle ?? ''),
        contains(contains('duplicaría')),
      );
    });

    test(
      'sin facturas con asiento se contabiliza el resumen cuadrado',
      () async {
        await vender();
        await marcarFacturadas();
        final resumen = await service.cerrar(efectivoContadoCents: 665);
        await settle();
        expect(resumen.asientoEncolado, isTrue);
        final asiento = accounting.contabilizados.single;
        expect(asiento.cuadrado, isTrue);
        expect(asiento.debeTotalCents, 765);
        expect(
          asiento.lineas.map((l) => l.codsubcuenta),
          containsAll([
            '5700000000',
            '5720000000',
            '7000000000',
            '4770000010',
            '4770000021',
          ]),
        );
      },
    );

    test('cobro mixto: 570 y 572 al debe por las partes de cada forma de '
        'pago', () async {
      await vender();
      await f.sala.aceptarLineas(submit('m1', [linea('l3', 'CANA', 7)]));
      await f.sala.cobrarMixto('m1', efectivoCents: 400);
      await f.sala.idle();
      await marcarFacturadas();
      final resumen = await service.cerrar(efectivoContadoCents: 1065);
      await settle();
      expect(resumen.asientoEncolado, isTrue);
      final asiento = accounting.contabilizados.single;
      expect(asiento.cuadrado, isTrue);
      expect(asiento.debeTotalCents, 1430);
      final debe = {
        for (final l in asiento.lineas)
          if (l.debeCents > 0) l.codsubcuenta: l.debeCents,
      };
      expect(debe, {'5700000000': 1065, '5720000000': 365});
    });

    test('h8: un turno que cruza la medianoche consulta también el día de '
        'los tickets', () async {
      f.clock.now = DateTime(2026, 10, 7, 22);
      await vender();
      await marcarFacturadas();
      accounting.diasConAsiento.add(DateTime(2026, 10, 7));
      f.clock.now = DateTime(2026, 10, 8, 1, 30);
      final resumen = await service.cerrar(efectivoContadoCents: 665);
      await settle();
      expect(resumen.asientoEncolado, isFalse);
      expect(accounting.contabilizados, isEmpty);
      // Antes solo se consultaba el día del cierre (el 8).
      expect(accounting.consultados.map((d) => d.day), contains(7));
      expect(
        f.alerts.recientes.map((a) => a.detalle ?? ''),
        contains(contains('07/10/2026')),
      );
    });

    test('h8: con facturas del turno aún sin sincronizar no se contabiliza '
        'el resumen', () async {
      await vender(); // Sin BillingService: facturas pendientes.
      final resumen = await service.cerrar(efectivoContadoCents: 665);
      await settle();
      expect(resumen.asientoEncolado, isFalse);
      expect(accounting.contabilizados, isEmpty);
      expect(
        f.alerts.recientes.map((a) => a.detalle ?? ''),
        contains(contains('pendientes de sincronizar')),
      );
    });

    test('h8: el ejecutor repite la comprobación antes de contabilizar y '
        'pasa a error si ya hay asientos', () async {
      await vender();
      await marcarFacturadas();
      await outbox.stop();
      final resumen = await service.cerrar(efectivoContadoCents: 665);
      expect(resumen.asientoEncolado, isTrue);
      final job = f.store.snapshot.jobPorId(
        'asientoZ:${resumen.documentoAsiento}',
      )!;
      expect(job.payload['modo'], 'resumenCompleto');
      expect(job.payload['fechasTickets'], isNotEmpty);

      // Entre el cierre y la ejecución las facturas generaron su asiento.
      accounting.facturasConAsiento = true;
      await outbox.start();
      await settle();
      final ejecutado = f.store.snapshot.jobPorId(job.id)!;
      expect(ejecutado.estado, SyncJobEstado.error);
      expect(ejecutado.ultimoError, contains('no contabilizado'));
      expect(accounting.contabilizados, isEmpty);
    });
  });

  test('h7: los tickets cobrados y las retiradas anotadas mientras se '
      'calcula el cierre quedan para el siguiente turno; doble toque = un '
      'cierre', () async {
    final runner = RetenedorRunner();
    await setUpWith(runner: runner);
    await service.iniciarTurno(10000);
    await vender();
    runner.retener = Completer<void>();

    final cerrando = service.cerrar(efectivoContadoCents: 10665);
    await runner.llamado.future;
    // Ventana: se cobra otra mesa y se retira efectivo.
    await f.sala.aceptarLineas(submit('m1', [linea('l3', 'CANA', 1)]));
    final tardio = await f.sala.cobrar('m1', MetodoPago.tarjeta);
    await service.registrarRetirada(500);
    final dobleToque = service.cerrar(efectivoContadoCents: 10665);
    runner.retener!.complete();
    runner.retener = null;

    final resumen = await cerrando;
    expect(await dobleToque, same(resumen));
    await settle();
    expect(resumen.numTickets, 2);
    expect(service.ticketsTurno.map((t) => t.id), [tardio.id]);
    expect(service.historial, [resumen]);
    expect(service.turno, isNotNull);
    expect(service.turno!.retiradasCents, 500);
    expect(service.turno!.fondoCajaCents, 0);
    expect(
      printer.jobs.where((j) => j.description.contains('Informe Z')),
      hasLength(1),
    );
  });

  test(
    'el ejecutor del asiento es idempotente y traduce payloads corruptos',
    () async {
      await setUpWith();
      await outbox.enqueue(SyncJobTipo.asientoZ, {'clave': 'x'}, id: 'roto');
      await settle();
      expect(f.store.snapshot.jobPorId('roto')!.estado, SyncJobEstado.error);
      expect(
        f.store.snapshot.jobPorId('roto')!.ultimoError,
        contains('corrupto'),
      );
    },
  );

  test('overrides de subcuentas se pasan al ERP', () async {
    await setUpWith();
    service.configurar(
      cierre: const CierreSettings(
        overridesSubcuentas: {CuentaZ.caja570: '5700000001'},
      ),
      accounting: accounting,
    );
    await vender();
    final preview = await service.previsualizar(efectivoContadoCents: 600);
    expect(
      preview.asiento.partidas.map((p) => p.codsubcuenta),
      contains('5700000001'),
    );
  });
}
