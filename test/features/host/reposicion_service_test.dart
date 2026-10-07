import 'package:fake_async/fake_async.dart';
import 'package:proyecto_comandero/core/errors/app_exception.dart';
import 'package:proyecto_comandero/core/isolates/isolate_runner.dart';
import 'package:proyecto_comandero/core/isolates/reposicion/reposicion_models.dart';
import 'package:proyecto_comandero/features/host/application/alert_bus.dart';
import 'package:proyecto_comandero/features/host/application/host_state_store.dart';
import 'package:proyecto_comandero/features/host/application/reposicion_service.dart';
import 'package:proyecto_comandero/features/host/application/sync_outbox.dart';
import 'package:proyecto_comandero/features/host/data/in_memory_host_state_repository.dart';
import 'package:proyecto_comandero/features/host/domain/host_settings.dart';
import 'package:proyecto_comandero/features/host/domain/host_snapshot.dart';
import 'package:proyecto_comandero/features/host/domain/sync_job.dart';
import 'package:test/test.dart';

import 'fakes/fake_ports.dart';

NivelStock nivel(
  String ref, {
  required double disponible,
  double stockmin = 5,
  double stockmax = 20,
  double pterecibir = 0,
}) => NivelStock(
  referencia: ref,
  codalmacen: 'ALG',
  cantidad: disponible,
  reservada: 0,
  disponible: disponible,
  pterecibir: pterecibir,
  stockmin: stockmin,
  stockmax: stockmax,
  descripcion: ref.toLowerCase(),
);

final class Harness {
  Harness._(this.store, this.alerts, this.outbox, this.stock, this.orders);

  static Future<Harness> create({
    required DateTime Function() now,
    ReposicionSettings settings = const ReposicionSettings(automatica: true),
    bool conErp = true,
  }) async {
    final alerts = AlertBus(now: now);
    final store = await HostStateStore.load(
      InMemoryHostStateRepository(),
      initial: HostSnapshot.new,
      alerts: alerts,
    );
    final outbox = SyncOutbox(store: store, alerts: alerts, now: now);
    final stock = FakeStockPort()
      ..niveles = [
        nivel('ARROZ', disponible: 2),
        nivel('POLLO', disponible: 1, pterecibir: 10),
        nivel('PATATA', disponible: 0, stockmin: 3, stockmax: 0),
        nivel('SAL', disponible: 100, stockmin: 0),
      ]
      ..ofertas = const [
        OfertaProveedor(
          referencia: 'ARROZ',
          codproveedor: 'PROV1',
          precioNeto: 1.2,
        ),
        OfertaProveedor(
          referencia: 'ARROZ',
          codproveedor: 'PROV2',
          precioNeto: 1.1,
        ),
        OfertaProveedor(
          referencia: 'PATATA',
          codproveedor: 'PROV1',
          precioNeto: 0.9,
        ),
      ];
    final orders = FakeSupplierOrderPort();
    final h = Harness._(store, alerts, outbox, stock, orders);
    h.service = ReposicionService(
      alerts: alerts,
      outbox: outbox,
      runner: const InlineIsolateRunner(),
      settings: settings,
      codalmacen: 'ALG',
      stock: stock,
      supplierOrders: conErp ? orders : null,
      now: now,
    );
    await outbox.start();
    return h;
  }

  final HostStateStore store;
  final AlertBus alerts;
  final SyncOutbox outbox;
  final FakeStockPort stock;
  final FakeSupplierOrderPort orders;
  late final ReposicionService service;

  Future<void> dispose() async {
    await service.dispose();
    await outbox.dispose();
    await store.dispose();
    await alerts.dispose();
  }
}

void main() {
  final base = DateTime(2026, 10, 7, 20);

  test(
    'auditar propone pedidos al proveedor más barato y los encola',
    () async {
      final h = await Harness.create(now: () => base);
      addTearDown(h.dispose);
      final result = (await h.service.auditar())!;
      await h.outbox.idle();

      // ARROZ: 2 → 20 (pide 18 a PROV2); PATATA: sin máximo → 3×2 = 6 a PROV1;
      // POLLO cubierto por pterecibir; SAL sin mínimo.
      expect(result.roturas.map((r) => r.referencia), ['ARROZ', 'PATATA']);
      expect(result.pedidos.map((p) => p.codproveedor), ['PROV1', 'PROV2']);
      expect(result.sinProveedor, isEmpty);
      expect(h.service.ultimaAuditoria, result);
      expect(h.service.ultimaAuditoriaEn, base);

      final jobs = h.store.snapshot.cola;
      expect(jobs.map((j) => j.id), [
        'pedido:TPV-REPO-20261007-PROV1',
        'pedido:TPV-REPO-20261007-PROV2',
      ]);
      expect(jobs.every((j) => j.estado == SyncJobEstado.hecho), isTrue);
      final enviados = h.orders.recibidos;
      expect(enviados.map((d) => d.clave), [
        'TPV-REPO-20261007-PROV1',
        'TPV-REPO-20261007-PROV2',
      ]);
      expect(enviados.every((d) => d.codalmacen == 'ALG'), isTrue);
      final arroz = enviados.last.lineas.single;
      expect(arroz.referencia, 'ARROZ');
      expect(arroz.cantidad, 18);
      expect(enviados.first.lineas.single.cantidad, 6);
    },
  );

  test(
    'sin proveedor para una rotura se avisa; sin automática no se pide',
    () async {
      final h = await Harness.create(
        now: () => base,
        settings: const ReposicionSettings(),
      );
      addTearDown(h.dispose);
      h.stock.ofertas = const [];
      final result = (await h.service.auditar())!;
      await h.outbox.idle();
      expect(result.sinProveedor, hasLength(2));
      expect(h.store.snapshot.cola, isEmpty);
      expect(
        h.alerts.recientes.map((a) => a.titulo),
        contains(contains('sin proveedor')),
      );
      // Forzar el pedido aunque la automática esté apagada.
      h.stock.ofertas = const [
        OfertaProveedor(
          referencia: 'ARROZ',
          codproveedor: 'PROV1',
          precioNeto: 1,
        ),
      ];
      await h.service.auditar(pedir: true);
      await h.outbox.idle();
      expect(h.store.snapshot.cola, hasLength(1));
    },
  );

  test('onStockDescontado agrupa con debounce de 30 s', () {
    fakeAsync((async) {
      late Harness h;
      Harness.create(now: () => base.add(async.elapsed)).then((v) => h = v);
      async.flushMicrotasks();

      h.service.onStockDescontado();
      async.elapse(const Duration(seconds: 20));
      h.service.onStockDescontado(); // reinicia la espera
      async.elapse(const Duration(seconds: 20));
      expect(h.stock.calls, 0, reason: 'aún dentro del debounce');
      expect(h.service.auditoriaProgramada, isTrue);
      async.elapse(const Duration(seconds: 10));
      async.flushMicrotasks();
      expect(h.stock.calls, 2, reason: 'leerNiveles + leerOfertas');
      expect(h.service.auditoriaProgramada, isFalse);
      expect(h.store.snapshot.cola, hasLength(2));

      h.dispose();
      async.flushMicrotasks();
    });
  });

  test('onCierre audita solo si enCierre; sin MySQL no hace nada', () async {
    final h = await Harness.create(
      now: () => base,
      settings: const ReposicionSettings(enCierre: false),
    );
    addTearDown(h.dispose);
    expect(await h.service.onCierre(), isNull);
    h.service.configurar(
      settings: const ReposicionSettings(enCierre: true),
      stock: h.stock,
      supplierOrders: h.orders,
    );
    expect(await h.service.onCierre(), isNotNull);
    expect(h.store.snapshot.cola, isEmpty, reason: 'automatica = false');

    h.service.configurar(stock: null, supplierOrders: null);
    expect(h.service.disponible, isFalse);
    expect(await h.service.auditar(), isNull);
    h.service.onStockDescontado();
    expect(h.service.auditoriaProgramada, isFalse);
  });

  test('sin ERP los pedidos quedan encolados y la cola en pausa', () async {
    final h = await Harness.create(now: () => base, conErp: false);
    addTearDown(h.dispose);
    await h.service.auditar();
    await h.outbox.idle();
    expect(h.outbox.pausada, isTrue);
    expect(h.store.snapshot.cola, hasLength(2));
    h.service.configurar(stock: h.stock, supplierOrders: h.orders);
    await h.outbox.reanudar();
    await h.outbox.idle();
    expect(h.orders.recibidos, hasLength(2));
  });

  test('la política se aplica (múltiplo de pedido)', () async {
    final h = await Harness.create(
      now: () => base,
      settings: const ReposicionSettings(
        automatica: true,
        politica: PoliticaReposicion(multiploPedido: 5),
      ),
    );
    addTearDown(h.dispose);
    final result = (await h.service.auditar())!;
    final arroz = result.pedidos.firstWhere((p) => p.codproveedor == 'PROV2');
    expect(arroz.lineas.single.cantidad, 20);
  });

  test('h5: con los pedidos en backoff, auditorías repetidas no los '
      'duplican; solo se piden referencias nuevas', () async {
    final h = await Harness.create(now: () => base);
    addTearDown(h.dispose);
    h.orders.failNext(const ErpApiException('503', statusCode: 503), times: 10);
    await h.service.auditar();
    await h.outbox.idle();
    await h.service.auditar();
    await h.outbox.idle();
    await h.service.onCierre();
    await h.outbox.idle();

    List<SyncJob> pedidos() => [
      for (final j in h.store.snapshot.cola)
        if (j.tipo == SyncJobTipo.pedidoProveedor) j,
    ];
    expect(pedidos().map((j) => j.id), [
      'pedido:TPV-REPO-20261007-PROV1',
      'pedido:TPV-REPO-20261007-PROV2',
    ]);
    expect(pedidos().every((j) => j.estado == SyncJobEstado.pendiente), isTrue);

    // Una rotura nueva del mismo proveedor va en otro pedido, solo con ella.
    h.stock
      ..niveles = [...h.stock.niveles, nivel('HARINA', disponible: 1)]
      ..ofertas = [
        ...h.stock.ofertas,
        const OfertaProveedor(
          referencia: 'HARINA',
          codproveedor: 'PROV1',
          precioNeto: 0.5,
        ),
      ];
    await h.service.auditar();
    await h.outbox.idle();
    final nuevo = h.store.snapshot.jobPorId(
      'pedido:TPV-REPO-20261007-PROV1-2',
    )!;
    final lineas = nuevo.payload['lineas']! as List<Object?>;
    expect(lineas, hasLength(1));
    expect((lineas.single! as Map<String, Object?>)['referencia'], 'HARINA');
    expect(pedidos(), hasLength(3));
  });
}
