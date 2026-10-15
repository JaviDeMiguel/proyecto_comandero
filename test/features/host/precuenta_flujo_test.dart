/// Una precuenta de principio a fin en el host, con la sala, la cola y la
/// facturación reales contra el ERP falso: la sala la emite, el cobro la
/// enlaza al ticket y la factura la lleva en sus observaciones con su
/// número, su hora y su total (§5.8, §5.16). Si la mesa se vacía sin cobrar,
/// no llega a ninguna factura y queda para el Cierre Z (§5.15).
library;

import 'package:proyecto_comandero/core/isolates/isolate_runner.dart';
import 'package:proyecto_comandero/features/host/application/billing_service.dart';
import 'package:proyecto_comandero/features/host/application/printing_service.dart';
import 'package:proyecto_comandero/features/host/application/sync_outbox.dart';
import 'package:proyecto_comandero/features/host/data/in_memory_host_state_repository.dart';
import 'package:proyecto_comandero/features/host/domain/host_settings.dart';
import 'package:proyecto_comandero/features/sala/domain/ticket.dart';
import 'package:test/test.dart';

import 'fakes/fake_ports.dart';
import 'support/host_test_support.dart';

const FiscalSettings _fiscal = FiscalSettings(
  codcliente: 'TPVVARIOS',
  codpagoEfectivo: 'TPVEFE',
  codpagoTarjeta: 'TPVTAR',
  codalmacen: 'ALG',
);

/// Ids únicos durante toda la ejecución, también entre arranques del host
/// sobre el mismo diario.
var _ids = 0;
String _nuevoId() => 'id-${++_ids}';

/// Host con sala, cola de sincronización y facturación sobre un diario.
final class _Host {
  _Host._(this.f, this.outbox, this.billing);

  static Future<_Host> arrancar(
    FakeInvoicePort invoice, {
    required FakeClock clock,
    InMemoryHostStateRepository? repo,
  }) async {
    final f = await SalaFixture.create(
      repo: repo,
      clock: clock,
      newId: _nuevoId,
    );
    final outbox = SyncOutbox(
      store: f.store,
      alerts: f.alerts,
      now: f.clock.call,
    );
    final billing = BillingService(
      store: f.store,
      alerts: f.alerts,
      outbox: outbox,
      printing: PrintingService(
        alerts: f.alerts,
        runner: const InlineIsolateRunner(),
        settings: const ImpresionSettings(imprimirTicketAlCobrar: false),
        nombreTpv: 'Barra',
        store: f.store,
        printer: FakePrinterPort(),
        now: f.clock.call,
      ),
      fiscal: _fiscal,
      invoice: invoice,
      masterData: FakeMasterDataPort(),
      now: f.clock.call,
    );
    f.sala.addEffects(billing);
    await outbox.start();
    return _Host._(f, outbox, billing);
  }

  final SalaFixture f;
  final SyncOutbox outbox;
  final BillingService billing;

  /// Espera a que terminen los efectos de la sala y los trabajos de la cola.
  Future<void> settle() async {
    await f.sala.idle();
    await outbox.idle();
    await Future<void>.delayed(Duration.zero);
  }

  Future<void> parar() async {
    await billing.dispose();
    await outbox.dispose();
    await f.dispose();
  }
}

void main() {
  late FakeClock reloj;
  late FakeInvoicePort invoice;
  late _Host host;

  setUp(() async {
    reloj = FakeClock(DateTime(2026, 10, 7, 14));
    invoice = FakeInvoicePort();
    host = await _Host.arrancar(invoice, clock: reloj);
  });

  tearDown(() => host.parar());

  test('emitirPrecuenta y cobrar: las observaciones de la factura llevan '
      '«Precuentas nº 1 hh:mm 6,65 €»', () async {
    final sala = host.f.sala;
    await sala.aceptarLineas(
      submit('m1', [linea('l1', 'CANA', 7)], camarero: 'Ana'),
    );
    reloj.now = DateTime(2026, 10, 7, 14, 10);
    final precuenta = await sala.emitirPrecuenta('m1', emitidaPor: 'Barra');
    expect(precuenta.numero, 1);
    expect(precuenta.totalCents, 665);
    expect(precuenta.emitidaEn, DateTime(2026, 10, 7, 14, 10));

    reloj.now = DateTime(2026, 10, 7, 14, 31);
    final ticket = await sala.cobrar(
      'm1',
      MetodoPago.efectivo,
      entregadoCents: 1000,
    );
    await host.settle();

    expect(ticket.precuentas, [precuenta]);
    expect(
      invoice.recibidos.single.observaciones,
      'TPV ticket 1 · Mesa Mesa 1 · Camarero Ana · '
      'Precuentas nº 1 14:10 6,65 €',
    );
    final guardado = host.f.store.snapshot.ticketPorId(ticket.id)!;
    expect(guardado.factura!.estado, EstadoSincronizacion.sincronizado);
    expect(guardado.precuentas, [precuenta]);
    expect(host.f.store.snapshot.precuentasSinCobro, isEmpty);
  });

  test('varias precuentas, aunque el host se reinicie entre medias, salen '
      'en orden con su hora y su total', () async {
    await host.f.sala.aceptarLineas(
      submit('m1', [linea('l1', 'CANA', 7)], camarero: 'Ana'),
    );
    reloj.now = DateTime(2026, 10, 7, 14, 10);
    await host.f.sala.emitirPrecuenta('m1');
    await host.f.sala.aceptarLineas(submit('m1', [linea('l2', 'CANA', 1)]));
    reloj.now = DateTime(2026, 10, 7, 14, 25);
    final segunda = await host.f.sala.emitirPrecuenta('m1');
    expect(segunda.numero, 2);
    expect(segunda.totalCents, 760);

    // Las precuentas viven en el diario: sobreviven al reinicio.
    final repo = host.f.repo;
    await host.parar();
    host = await _Host.arrancar(invoice, clock: reloj, repo: repo);
    reloj.now = DateTime(2026, 10, 7, 14, 40);
    final ticket = await host.f.sala.cobrar('m1', MetodoPago.tarjeta);
    await host.settle();

    expect(ticket.precuentas.map((p) => p.numero), [1, 2]);
    expect(
      invoice.recibidos.single.observaciones,
      'TPV ticket 1 · Mesa Mesa 1 · Camarero Ana · '
      'Precuentas nº 1 14:10 6,65 €, nº 2 14:25 7,60 €',
    );
  });

  test('la precuenta de una mesa vaciada no llega a ninguna factura: queda '
      'para el Cierre Z', () async {
    final sala = host.f.sala;
    await sala.aceptarLineas(submit('m1', [linea('l1', 'CANA', 7)]));
    final precuenta = await sala.emitirPrecuenta('m1');
    await sala.vaciarMesa('m1', motivo: 'Se marcharon sin pagar');

    // Otros clientes ocupan la mesa y pagan: su ticket no hereda nada.
    await sala.aceptarLineas(
      submit('m1', [linea('l2', 'CAFE', 2)], camarero: 'Luis'),
    );
    final ticket = await sala.cobrar('m1', MetodoPago.tarjeta);
    await host.settle();

    expect(ticket.precuentas, isEmpty);
    expect(
      invoice.recibidos.single.observaciones,
      'TPV ticket 1 · Mesa Mesa 1 · Camarero Luis',
    );
    final sinCobro = host.f.store.snapshot.precuentasSinCobro.single;
    expect(sinCobro.precuenta, precuenta);
    expect(sinCobro.motivo, 'Se marcharon sin pagar');
  });
}
