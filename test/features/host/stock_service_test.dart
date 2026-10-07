import 'package:proyecto_comandero/core/errors/app_exception.dart';
import 'package:proyecto_comandero/core/inventory/inventory_models.dart';
import 'package:proyecto_comandero/core/isolates/isolate_runner.dart';
import 'package:proyecto_comandero/features/host/application/stock_service.dart';
import 'package:proyecto_comandero/features/host/application/sync_outbox.dart';
import 'package:proyecto_comandero/features/host/domain/sync_job.dart';
import 'package:proyecto_comandero/features/sala/domain/ticket.dart';
import 'package:test/test.dart';

import 'fakes/fake_ports.dart';
import 'support/host_test_support.dart';

const recetasPaella = [
  RecetaLinea(refPlato: 'PAELLA', refIngrediente: 'ARROZ', cantidadNeta: 0.1),
  RecetaLinea(
    refPlato: 'PAELLA',
    refIngrediente: 'POLLO',
    cantidadNeta: 0.2,
    mermaPct: 20,
  ),
];

void main() {
  late SalaFixture f;
  late SyncOutbox outbox;
  late FakeStockPort stock;
  late FakeRecetasPort recetas;
  late StockService service;
  late List<List<NivelStock>> descuentos;

  setUp(() async {
    f = await SalaFixture.create();
    outbox = SyncOutbox(store: f.store, alerts: f.alerts, now: f.clock.call);
    stock = FakeStockPort()
      ..niveles = const [
        NivelStock(
          referencia: 'ARROZ',
          codalmacen: 'ALG',
          cantidad: 4,
          reservada: 0,
          disponible: 4,
          pterecibir: 0,
          stockmin: 5,
          stockmax: 20,
        ),
      ];
    recetas = FakeRecetasPort(recetasPaella);
    service = StockService(
      store: f.store,
      alerts: f.alerts,
      outbox: outbox,
      runner: const InlineIsolateRunner(),
      codalmacen: 'ALG',
      stock: stock,
      recetas: recetas,
      now: f.clock.call,
    );
    f.sala.addEffects(service);
    descuentos = [];
    service.descuentos.listen(descuentos.add);
    await outbox.start();
  });

  tearDown(() async {
    await service.dispose();
    await outbox.dispose();
    await f.dispose();
  });

  Future<void> settle() async {
    await f.sala.idle();
    await outbox.idle();
    await Future<void>.delayed(Duration.zero);
  }

  test(
    'aceptar un plato con receta encola un job por línea y lo aplica',
    () async {
      await f.sala.aceptarLineas(
        submit('m1', [linea('p1', 'PAELLA', 2), linea('c1', 'CANA', 1)]),
      );
      await settle();

      final job = f.store.snapshot.jobPorId('stock:p1')!;
      expect(job.tipo, SyncJobTipo.descuentoStock);
      expect(job.estado, SyncJobEstado.hecho);
      expect(job.payload['operacion'], 'p1');
      expect(job.payload['referencia'], 'PAELLA');
      expect(job.payload['cantidad'], 2);
      expect(job.payload['codalmacen'], 'ALG');
      expect(job.payload['motivo'], 'comanda');
      expect(job.payload['origen'], 'Mesa Mesa 1 · Paella');
      // Sin caché de recetas aún, la caña también se encola; al ejecutarse
      // no tiene receta y no toca el stock.
      expect(
        f.store.snapshot.jobPorId('stock:c1')!.estado,
        SyncJobEstado.hecho,
      );
      expect(stock.aplicadas.keys, ['p1']);
      // Con la caché vigente, un plato sin receta ya no genera trabajo.
      await f.sala.aceptarLineas(submit('m1', [linea('c2', 'CANA', 1)]));
      await settle();
      expect(f.store.snapshot.jobPorId('stock:c2'), isNull);

      // Consumos: 2 × 0.1 arroz; 2 × 0.2 / 0.8 pollo = 0.5.
      final aplicados = stock.aplicadas['p1']!;
      expect(aplicados, const [
        ConsumoStock(referencia: 'ARROZ', cantidad: 0.2),
        ConsumoStock(referencia: 'POLLO', cantidad: 0.5),
      ]);
      expect(descuentos.single.single.referencia, 'ARROZ');
      // Recetas cacheadas en el diario.
      expect(f.store.snapshot.recetas!.lineas, recetasPaella);
      expect(recetas.calls, 1);
    },
  );

  test(
    'anular la línea encola el job inverso con operación :anulacion',
    () async {
      await f.sala.aceptarLineas(submit('m1', [linea('p1', 'PAELLA', 1)]));
      await settle();
      await f.sala.anularLinea('m1', 'p1');
      await settle();

      final inverso = f.store.snapshot.jobPorId('stock:p1:anulacion')!;
      expect(inverso.estado, SyncJobEstado.hecho);
      expect(stock.ordenOperaciones, ['p1', 'p1:anulacion']);
      expect(stock.aplicadas['p1:anulacion'], const [
        ConsumoStock(referencia: 'ARROZ', cantidad: -0.1),
        ConsumoStock(referencia: 'POLLO', cantidad: -0.25),
      ]);
      // Anular dos veces no encola otro.
      await f.sala.anularLinea('m1', 'p1');
      await settle();
      expect(f.store.snapshot.cola, hasLength(2));
    },
  );

  test('vaciar la mesa revierte cada línea activa', () async {
    await f.sala.aceptarLineas(
      submit('m1', [linea('p1', 'PAELLA', 1), linea('p2', 'PAELLA', 3)]),
    );
    await settle();
    await f.sala.vaciarMesa('m1');
    await settle();
    expect(
      stock.ordenOperaciones,
      containsAll(['p1', 'p2', 'p1:anulacion', 'p2:anulacion']),
    );
  });

  test('cobrar no toca el stock (ya se descontó al enviar a cocina)', () async {
    await f.sala.aceptarLineas(submit('m1', [linea('p1', 'PAELLA', 1)]));
    await settle();
    await f.sala.cobrar('m1', MetodoPago.tarjeta);
    await settle();
    expect(stock.ordenOperaciones, ['p1']);
  });

  test('la caché de recetas respeta el TTL', () async {
    await f.sala.aceptarLineas(submit('m1', [linea('p1', 'PAELLA', 1)]));
    await settle();
    f.clock.advance(const Duration(minutes: 5));
    await f.sala.aceptarLineas(submit('m1', [linea('p2', 'PAELLA', 1)]));
    await settle();
    expect(recetas.calls, 1);
    f.clock.advance(const Duration(minutes: 6));
    await f.sala.aceptarLineas(submit('m1', [linea('p3', 'PAELLA', 1)]));
    await settle();
    expect(recetas.calls, 2);
  });

  test('h2: si MySQL falla sin caché el descuento se reintenta (no se '
      'pierde); con caché caducada se usa y se avisa', () async {
    recetas.failNext(const NetworkException('mysql caído'));
    await f.sala.aceptarLineas(submit('m1', [linea('p1', 'PAELLA', 1)]));
    await settle();
    final pendiente = f.store.snapshot.jobPorId('stock:p1')!;
    expect(pendiente.estado, SyncJobEstado.pendiente);
    expect(pendiente.proximoIntentoEn, isNotNull);
    expect(pendiente.ultimoError, contains('recetas'));
    expect(stock.aplicadas, isEmpty);

    await outbox.reintentar('stock:p1');
    await settle();
    expect(f.store.snapshot.jobPorId('stock:p1')!.estado, SyncJobEstado.hecho);
    expect(stock.aplicadas.keys, ['p1']);

    await f.sala.aceptarLineas(submit('m1', [linea('p2', 'PAELLA', 1)]));
    await settle();
    expect(f.store.snapshot.jobPorId('stock:p2'), isNotNull);
    f.clock.advance(const Duration(minutes: 11));
    recetas.failNext(const NetworkException('mysql caído'));
    await f.sala.aceptarLineas(submit('m1', [linea('p3', 'PAELLA', 1)]));
    await settle();
    expect(f.store.snapshot.jobPorId('stock:p3'), isNotNull);
    expect(
      f.alerts.recientes.map((a) => a.titulo),
      contains(contains('se usa la caché')),
    );
  });

  test('un escandallo cíclico avisa y no bloquea la comanda', () async {
    recetas.recetas = const [
      RecetaLinea(refPlato: 'PAELLA', refIngrediente: 'ARROZ', cantidadNeta: 1),
      RecetaLinea(refPlato: 'ARROZ', refIngrediente: 'PAELLA', cantidadNeta: 1),
    ];
    final result = await f.sala.aceptarLineas(
      submit('m1', [linea('p1', 'PAELLA', 1)]),
    );
    await settle();
    expect(result.lineasNuevas, 1);
    final job = f.store.snapshot.jobPorId('stock:p1')!;
    expect(job.estado, SyncJobEstado.error);
    expect(job.ultimoError, contains('inválido'));
    expect(stock.aplicadas, isEmpty);
    expect(
      f.alerts.recientes.map((a) => a.detalle ?? ''),
      contains(contains('inválido')),
    );
  });

  test(
    'deadlock de MySQL se reintenta; referencia desconocida es definitivo',
    () async {
      stock.failNext(const DatabaseException('deadlock', errorCode: 1213));
      await f.sala.aceptarLineas(submit('m1', [linea('p1', 'PAELLA', 1)]));
      await settle();
      var job = f.store.snapshot.jobPorId('stock:p1')!;
      expect(job.estado, SyncJobEstado.pendiente);
      expect(job.intentos, 1);
      expect(job.proximoIntentoEn, isNotNull);

      stock.failNext(const ValidationException('referencia desconocida'));
      await f.sala.aceptarLineas(submit('m1', [linea('p2', 'PAELLA', 1)]));
      await settle();
      job = f.store.snapshot.jobPorId('stock:p2')!;
      expect(job.estado, SyncJobEstado.error);
      expect(job.ultimoError, 'referencia desconocida');
    },
  );

  test(
    'sin MySQL configurado no se encola nada y se informa una vez',
    () async {
      service.configurar();
      expect(service.disponible, isFalse);
      await f.sala.aceptarLineas(submit('m1', [linea('p1', 'PAELLA', 1)]));
      await f.sala.aceptarLineas(submit('m1', [linea('p2', 'PAELLA', 1)]));
      await settle();
      expect(f.store.snapshot.cola, isEmpty);
      expect(f.alerts.recientes, hasLength(1));
    },
  );

  test('h2: el trabajo de stock se guarda en la misma escritura que la línea '
      '(sin leer recetas antes)', () async {
    await outbox.stop();
    await f.sala.aceptarLineas(submit('m1', [linea('p1', 'PAELLA', 2)]));
    await f.sala.idle();
    await f.store.flush();
    final guardado = (await f.repo.load())!;
    expect(guardado.comandaDeMesa('m1')!.lineaPorId('p1'), isNotNull);
    final job = guardado.jobPorId('stock:p1')!;
    expect(job.estado, SyncJobEstado.pendiente);
    expect(job.payload['lineaId'], 'p1');
    expect(job.payload['referencia'], 'PAELLA');
    expect(job.payload['cantidad'], 2);
    expect(recetas.calls, 0, reason: 'el escandallo se resuelve al ejecutar');
    expect(stock.aplicadas, isEmpty);

    await outbox.start();
    await settle();
    expect(stock.aplicadas['p1'], const [
      ConsumoStock(referencia: 'ARROZ', cantidad: 0.2),
      ConsumoStock(referencia: 'POLLO', cantidad: 0.5),
    ]);
  });

  group('h4: la anulación revierte solo lo aplicado', () {
    test(
      'si no hubo descuento (sin MySQL al aceptar) no devuelve nada',
      () async {
        service.configurar();
        await f.sala.aceptarLineas(submit('m1', [linea('p1', 'PAELLA', 1)]));
        await settle();
        expect(f.store.snapshot.cola, isEmpty);

        service.configurar(stock: stock, recetas: recetas, codalmacen: 'ALG');
        await f.sala.anularLinea('m1', 'p1');
        await settle();
        final inverso = f.store.snapshot.jobPorId('stock:p1:anulacion')!;
        expect(inverso.estado, SyncJobEstado.hecho);
        expect(stock.aplicadas, isEmpty);
      },
    );

    test('devuelve lo descontado aunque la receta haya cambiado', () async {
      await f.sala.aceptarLineas(submit('m1', [linea('p1', 'PAELLA', 1)]));
      await settle();
      recetas.recetas = const [
        RecetaLinea(
          refPlato: 'PAELLA',
          refIngrediente: 'ARROZ',
          cantidadNeta: 0.5,
        ),
      ];
      f.clock.advance(const Duration(minutes: 11));
      await f.sala.anularLinea('m1', 'p1');
      await settle();
      expect(stock.aplicadas['p1:anulacion'], const [
        ConsumoStock(referencia: 'ARROZ', cantidad: -0.1),
        ConsumoStock(referencia: 'POLLO', cantidad: -0.25),
      ]);
    });

    test(
      'si el original quedó en error no se devuelve nada y se retira',
      () async {
        stock.failNext(const ValidationException('referencia desconocida'));
        await f.sala.aceptarLineas(submit('m1', [linea('p1', 'PAELLA', 1)]));
        await settle();
        expect(
          f.store.snapshot.jobPorId('stock:p1')!.estado,
          SyncJobEstado.error,
        );
        await f.sala.anularLinea('m1', 'p1');
        await settle();
        expect(f.store.snapshot.jobPorId('stock:p1'), isNull);
        expect(
          f.store.snapshot.jobPorId('stock:p1:anulacion')!.estado,
          SyncJobEstado.hecho,
        );
        expect(stock.aplicadas, isEmpty);
      },
    );

    test('si el original sigue sin ejecutar se cancela y ninguno toca el '
        'stock', () async {
      await outbox.stop();
      await f.sala.aceptarLineas(submit('m1', [linea('p1', 'PAELLA', 1)]));
      await f.sala.anularLinea('m1', 'p1');
      await f.sala.idle();
      expect(f.store.snapshot.cola, isEmpty);
      await outbox.start();
      await settle();
      expect(stock.aplicadas, isEmpty);
    });

    test('si el original está en backoff, la anulación lo cancela y no '
        'devuelve lo que no se aplicó', () async {
      stock.failNext(const DatabaseException('deadlock', errorCode: 1213));
      await f.sala.aceptarLineas(submit('m1', [linea('p1', 'PAELLA', 1)]));
      await settle();
      expect(f.store.snapshot.jobPorId('stock:p1')!.intentos, 1);
      await f.sala.anularLinea('m1', 'p1');
      await settle();
      expect(f.store.snapshot.jobPorId('stock:p1'), isNull);
      expect(
        f.store.snapshot.jobPorId('stock:p1:anulacion')!.estado,
        SyncJobEstado.hecho,
      );
      expect(stock.aplicadas, isEmpty);
    });
  });
}
