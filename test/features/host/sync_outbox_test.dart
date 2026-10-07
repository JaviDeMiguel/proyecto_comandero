import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:proyecto_comandero/core/errors/app_exception.dart';
import 'package:proyecto_comandero/features/host/application/alert_bus.dart';
import 'package:proyecto_comandero/features/host/application/host_state_store.dart';
import 'package:proyecto_comandero/features/host/application/sync_outbox.dart';
import 'package:proyecto_comandero/features/host/data/in_memory_host_state_repository.dart';
import 'package:proyecto_comandero/features/host/domain/host_snapshot.dart';
import 'package:proyecto_comandero/features/host/domain/sync_job.dart';
import 'package:test/test.dart';

/// Ejecutor de pruebas: anota los trabajos y falla según una cola de errores.
final class ScriptedHandler {
  final List<String> ejecutados = [];
  final Map<String, List<Exception>> fallos = {};
  final Map<String, Completer<void>> bloqueos = {};

  void failOn(String jobId, Exception error, {int times = 1}) {
    fallos.putIfAbsent(jobId, () => []).addAll(List.filled(times, error));
  }

  Future<List<String>> call(SyncJob job) async {
    final pendientes = fallos[job.id];
    final bloqueo = bloqueos[job.id];
    if (bloqueo != null) await bloqueo.future;
    ejecutados.add(job.id);
    if (pendientes != null && pendientes.isNotEmpty) {
      throw pendientes.removeAt(0);
    }
    return job.payload['aviso'] == null
        ? const []
        : [job.payload['aviso'] as String];
  }
}

final class Harness {
  Harness._(this.repo, this.store, this.alerts, this.outbox, this.handler);

  static Future<Harness> create({
    InMemoryHostStateRepository? repo,
    DateTime Function()? now,
    bool registrarHandlers = true,
  }) async {
    final repository = repo ?? InMemoryHostStateRepository();
    final alerts = AlertBus(now: now);
    final store = await HostStateStore.load(
      repository,
      initial: HostSnapshot.new,
      alerts: alerts,
    );
    final outbox = SyncOutbox(store: store, alerts: alerts, now: now);
    final handler = ScriptedHandler();
    if (registrarHandlers) {
      for (final tipo in SyncJobTipo.values) {
        outbox.registerHandler(tipo, handler.call);
      }
    }
    return Harness._(repository, store, alerts, outbox, handler);
  }

  final InMemoryHostStateRepository repo;
  final HostStateStore store;
  final AlertBus alerts;
  final SyncOutbox outbox;
  final ScriptedHandler handler;

  SyncJob job(String id) => store.snapshot.jobPorId(id)!;

  Future<void> dispose() async {
    await outbox.dispose();
    await store.dispose();
    await alerts.dispose();
  }
}

const transitorio = ErpApiException('503', statusCode: 503);
const red = ErpApiException('sin red');
const definitivo = ErpApiException('422 fecha', statusCode: 422);
const credenciales = ErpApiException('401', statusCode: 401);

void main() {
  group('SyncOutbox', () {
    test('ejecuta en orden FIFO y conserva avisos', () async {
      final h = await Harness.create();
      addTearDown(h.dispose);
      await h.outbox.start();
      await h.outbox.enqueue(SyncJobTipo.descuentoStock, {}, id: 'a');
      await h.outbox.enqueue(SyncJobTipo.factura, {'aviso': 'ojo'}, id: 'b');
      await h.outbox.enqueue(SyncJobTipo.pedidoProveedor, {}, id: 'c');
      await h.outbox.idle();

      expect(h.handler.ejecutados, ['a', 'b', 'c']);
      expect(h.job('b').estado, SyncJobEstado.hecho);
      expect(h.job('b').avisos, ['ojo']);
      expect(h.job('b').intentos, 1);
      expect(h.outbox.estado.todoSincronizado, isTrue);
      expect(h.outbox.estado.ultimoExito, isNotNull);
      expect(h.alerts.recientes.single.titulo, contains('ojo'));
    });

    test('enqueue con id repetido no duplica', () async {
      final h = await Harness.create();
      addTearDown(h.dispose);
      await h.outbox.start();
      await h.outbox.enqueue(SyncJobTipo.factura, {'n': 1}, id: 'x');
      await h.outbox.enqueue(SyncJobTipo.factura, {'n': 2}, id: 'x');
      await h.outbox.idle();
      expect(h.outbox.jobs, hasLength(1));
      expect(h.handler.ejecutados, ['x']);
    });

    test('transitorio: backoff exponencial y reintento hasta el éxito', () {
      fakeAsync((async) {
        final base = DateTime(2026, 10, 7, 12);
        DateTime now() => base.add(async.elapsed);
        late Harness h;
        Harness.create(now: now).then((value) => h = value);
        async.flushMicrotasks();
        h.handler.failOn('f1', transitorio, times: 2);
        h.handler.failOn('f1', red);
        h.outbox.start();
        h.outbox.enqueue(SyncJobTipo.factura, {}, id: 'f1');
        async.flushMicrotasks();

        expect(h.handler.ejecutados, ['f1']);
        var job = h.job('f1');
        expect(job.estado, SyncJobEstado.pendiente);
        expect(job.intentos, 1);
        expect(job.ultimoError, '503');
        expect(job.proximoIntentoEn, base.add(const Duration(seconds: 1)));
        expect(h.outbox.estado.pendientes, 1);

        async.elapse(const Duration(milliseconds: 999));
        expect(h.handler.ejecutados, hasLength(1));
        async.elapse(const Duration(milliseconds: 1));
        expect(h.handler.ejecutados, hasLength(2));
        job = h.job('f1');
        expect(job.proximoIntentoEn, now().add(const Duration(seconds: 2)));

        async.elapse(const Duration(seconds: 2));
        expect(h.handler.ejecutados, hasLength(3));
        job = h.job('f1');
        expect(job.intentos, 3);
        expect(job.proximoIntentoEn, now().add(const Duration(seconds: 4)));

        async.elapse(const Duration(seconds: 4));
        expect(h.handler.ejecutados, hasLength(4));
        expect(h.job('f1').estado, SyncJobEstado.hecho);
        expect(h.job('f1').ultimoError, isNull);
        h.dispose();
        async.flushMicrotasks();
      });
    });

    test('el backoff se limita a 5 minutos', () {
      fakeAsync((async) {
        final base = DateTime(2026, 10, 7, 12);
        late Harness h;
        Harness.create(now: () => base.add(async.elapsed)).then((v) => h = v);
        async.flushMicrotasks();
        h.handler.failOn('s', transitorio, times: 20);
        h.outbox.start();
        h.outbox.enqueue(SyncJobTipo.descuentoStock, {}, id: 's');
        async.flushMicrotasks();
        async.elapse(const Duration(minutes: 30));
        final job = h.job('s');
        expect(job.intentos, greaterThanOrEqualTo(10));
        expect(
          job.proximoIntentoEn!.difference(base.add(async.elapsed)),
          lessThanOrEqualTo(const Duration(minutes: 5)),
        );
        h.dispose();
        async.flushMicrotasks();
      });
    });

    test(
      'error definitivo: queda en error sin reintentos; reintentar/descartar',
      () async {
        final h = await Harness.create();
        addTearDown(h.dispose);
        h.handler.failOn('d', definitivo);
        await h.outbox.start();
        await h.outbox.enqueue(SyncJobTipo.factura, {}, id: 'd');
        await h.outbox.idle();

        expect(h.job('d').estado, SyncJobEstado.error);
        expect(h.job('d').ultimoError, '422 fecha');
        expect(h.job('d').proximoIntentoEn, isNull);
        expect(h.outbox.estado.enError, 1);
        expect(h.alerts.recientes.single.titulo, contains('rechazado'));
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(h.handler.ejecutados, ['d'], reason: 'sin reintento automático');

        await h.outbox.reintentar('d');
        await h.outbox.idle();
        expect(h.handler.ejecutados, ['d', 'd']);
        expect(h.job('d').estado, SyncJobEstado.hecho);

        h.handler.failOn('e', const ValidationException('mal'));
        await h.outbox.enqueue(SyncJobTipo.asientoZ, {}, id: 'e');
        await h.outbox.idle();
        expect(h.job('e').estado, SyncJobEstado.error);
        expect(await h.outbox.descartar('e'), isTrue);
        expect(h.store.snapshot.jobPorId('e'), isNull);
      },
    );

    test('FIFO estricto de facturas: una en error bloquea a las siguientes, '
        'los otros tipos adelantan', () async {
      final h = await Harness.create();
      addTearDown(h.dispose);
      h.handler.failOn('f1', definitivo);
      await h.outbox.start();
      await h.outbox.enqueue(SyncJobTipo.factura, {}, id: 'f1');
      await h.outbox.enqueue(SyncJobTipo.factura, {}, id: 'f2');
      await h.outbox.enqueue(SyncJobTipo.descuentoStock, {}, id: 's1');
      await h.outbox.idle();

      expect(h.handler.ejecutados, ['f1', 's1']);
      expect(h.job('f2').estado, SyncJobEstado.pendiente);

      await h.outbox.descartar('f1');
      await h.outbox.idle();
      expect(h.handler.ejecutados, ['f1', 's1', 'f2']);
      expect(h.job('f2').estado, SyncJobEstado.hecho);
    });

    test('fallo de credenciales pausa toda la cola hasta reanudar', () async {
      final h = await Harness.create();
      addTearDown(h.dispose);
      h.handler.failOn('f1', credenciales);
      await h.outbox.start();
      await h.outbox.enqueue(SyncJobTipo.factura, {}, id: 'f1');
      await h.outbox.enqueue(SyncJobTipo.descuentoStock, {}, id: 's1');
      await h.outbox.idle();

      expect(h.handler.ejecutados, ['f1']);
      expect(h.outbox.pausada, isTrue);
      expect(h.outbox.estado.motivoPausa, '401');
      expect(h.job('f1').estado, SyncJobEstado.bloqueado);
      expect(h.job('s1').estado, SyncJobEstado.bloqueado);
      // Lo que se encola en pausa nace bloqueado.
      final nuevo = await h.outbox.enqueue(SyncJobTipo.asientoZ, {}, id: 'z');
      expect(nuevo.estado, SyncJobEstado.bloqueado);
      expect(h.outbox.estado.bloqueados, 3);

      await h.outbox.reanudar();
      await h.outbox.idle();
      expect(h.outbox.pausada, isFalse);
      expect(h.handler.ejecutados, ['f1', 'f1', 's1', 'z']);
      expect(h.outbox.estado.todoSincronizado, isTrue);
    });

    test(
      'sin manejador registrado la cola se pausa (ERP no configurado)',
      () async {
        final h = await Harness.create(registrarHandlers: false);
        addTearDown(h.dispose);
        await h.outbox.start();
        await h.outbox.enqueue(SyncJobTipo.factura, {}, id: 'f1');
        await h.outbox.idle();
        expect(h.outbox.pausada, isTrue);
        expect(h.outbox.estado.motivoPausa, contains('factura'));
        h.outbox.registerHandler(SyncJobTipo.factura, h.handler.call);
        await h.outbox.reanudar();
        await h.outbox.idle();
        expect(h.job('f1').estado, SyncJobEstado.hecho);
      },
    );

    test('persistencia y reanudación tras reinicio: enCurso vuelve a '
        'pendiente y los hechos no se repiten', () async {
      final repo = InMemoryHostStateRepository();
      final h1 = await Harness.create(repo: repo);
      await h1.outbox.start();
      await h1.outbox.enqueue(SyncJobTipo.factura, {}, id: 'hecho');
      await h1.outbox.idle();
      // Un trabajo se queda a medias (bloqueado dentro del manejador).
      h1.handler.bloqueos['colgado'] = Completer<void>();
      await h1.outbox.enqueue(SyncJobTipo.factura, {}, id: 'colgado');
      await h1.outbox.enqueue(SyncJobTipo.factura, {}, id: 'despues');
      await Future<void>.delayed(Duration.zero);
      expect(h1.job('colgado').estado, SyncJobEstado.enCurso);
      await h1.store.flush();
      // "Apagón": no esperamos a dispose (el manejador nunca termina).
      unawaited(h1.alerts.dispose());

      final h2 = await Harness.create(repo: repo);
      addTearDown(h2.dispose);
      expect(h2.job('colgado').estado, SyncJobEstado.enCurso);
      await h2.outbox.start();
      await h2.outbox.idle();
      expect(h2.handler.ejecutados, ['colgado', 'despues']);
      expect(h2.job('hecho').estado, SyncJobEstado.hecho);
      expect(h2.job('colgado').estado, SyncJobEstado.hecho);
      expect(h2.job('colgado').intentos, 2);
      expect(h2.job('despues').estado, SyncJobEstado.hecho);
    });

    test('tras un reinicio con trabajos bloqueados arranca en pausa', () async {
      final repo = InMemoryHostStateRepository();
      final h1 = await Harness.create(repo: repo);
      h1.handler.failOn('f1', credenciales);
      await h1.outbox.start();
      await h1.outbox.enqueue(SyncJobTipo.factura, {}, id: 'f1');
      await h1.outbox.idle();
      await h1.dispose();

      final h2 = await Harness.create(repo: repo);
      addTearDown(h2.dispose);
      await h2.outbox.start();
      await h2.outbox.idle();
      expect(h2.outbox.pausada, isTrue);
      expect(h2.handler.ejecutados, isEmpty);
      await h2.outbox.reanudar();
      await h2.outbox.idle();
      expect(h2.job('f1').estado, SyncJobEstado.hecho);
    });

    test('poda los trabajos hechos más antiguos', () async {
      final repo = InMemoryHostStateRepository();
      final alerts = AlertBus();
      final store = await HostStateStore.load(repo, initial: HostSnapshot.new);
      final outbox = SyncOutbox(store: store, alerts: alerts, maxHechos: 2);
      addTearDown(() async {
        await outbox.dispose();
        await store.dispose();
        await alerts.dispose();
      });
      outbox.registerHandler(SyncJobTipo.descuentoStock, (_) async => const []);
      await outbox.start();
      for (var i = 0; i < 5; i++) {
        await outbox.enqueue(SyncJobTipo.descuentoStock, {}, id: 'j$i');
      }
      await outbox.idle();
      expect(outbox.jobs.map((j) => j.id), ['j3', 'j4']);
    });

    test('stop espera al trabajo en vuelo y no arranca más', () async {
      final h = await Harness.create();
      addTearDown(h.dispose);
      final gate = Completer<void>();
      h.handler.bloqueos['a'] = gate;
      await h.outbox.start();
      await h.outbox.enqueue(SyncJobTipo.factura, {}, id: 'a');
      await h.outbox.enqueue(SyncJobTipo.factura, {}, id: 'b');
      await Future<void>.delayed(Duration.zero);
      final stopping = h.outbox.stop();
      gate.complete();
      await stopping;
      expect(h.job('a').estado, SyncJobEstado.hecho);
      expect(h.job('b').estado, SyncJobEstado.pendiente);
      expect(h.outbox.isRunning, isFalse);
    });

    test('h1: con intentos >= 64 el backoff sigue acotado (sin reintentos '
        'inmediatos en bucle)', () async {
      final ahora = DateTime(2026, 10, 7, 12);
      final h = await Harness.create(now: () => ahora);
      addTearDown(h.dispose);
      await h.store.update(
        (s) => s.conJob(
          SyncJob(
            id: 's',
            tipo: SyncJobTipo.descuentoStock,
            payload: const {},
            creadoEn: ahora,
            intentos: 63,
          ),
        ),
      );
      h.handler.failOn('s', transitorio, times: 5);
      await h.outbox.start();
      await h.outbox.idle();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(h.handler.ejecutados, ['s'], reason: 'un solo intento');
      final job = h.job('s');
      expect(job.intentos, 64);
      expect(job.estado, SyncJobEstado.pendiente);
      expect(job.proximoIntentoEn, ahora.add(const Duration(minutes: 5)));

      // Con muchos más intentos tampoco se desborda.
      await h.store.update((s) => s.conJob(job.copyWith(intentos: 1000)));
      await h.outbox.reintentar('s');
      await h.outbox.idle();
      expect(h.handler.ejecutados, ['s', 's']);
      expect(
        h.job('s').proximoIntentoEn,
        ahora.add(const Duration(minutes: 5)),
      );
    });

    test('h14: un ConfigException pausa solo los trabajos de su tipo; las '
        'facturas siguen', () async {
      final h = await Harness.create();
      addTearDown(h.dispose);
      const sinMysql = ConfigException('MySQL no configurado');
      h.handler.failOn('s1', sinMysql, times: 2);
      await h.outbox.start();
      await h.outbox.enqueue(SyncJobTipo.descuentoStock, {}, id: 's1');
      await h.outbox.enqueue(SyncJobTipo.descuentoStock, {}, id: 's2');
      await h.outbox.enqueue(SyncJobTipo.factura, {}, id: 'f1');
      await h.outbox.idle();

      expect(h.handler.ejecutados, ['s1', 'f1']);
      expect(h.job('f1').estado, SyncJobEstado.hecho);
      expect(h.job('s1').estado, SyncJobEstado.bloqueado);
      expect(h.job('s2').estado, SyncJobEstado.bloqueado);
      expect(h.outbox.pausada, isTrue);
      expect(h.outbox.tiposEnPausa, {SyncJobTipo.descuentoStock});
      expect(h.outbox.estado.tiposEnPausa, {SyncJobTipo.descuentoStock});
      expect(h.outbox.estado.motivoPausa, 'MySQL no configurado');
      expect(
        h.alerts.recientes.map((a) => a.titulo),
        contains('Sincronización de stock en pausa'),
      );

      // Lo nuevo de ese tipo nace bloqueado; lo de otros tipos se ejecuta.
      final s3 = await h.outbox.enqueue(SyncJobTipo.descuentoStock, {});
      expect(s3.estado, SyncJobEstado.bloqueado);
      await h.outbox.enqueue(SyncJobTipo.factura, {}, id: 'f2');
      await h.outbox.idle();
      expect(h.job('f2').estado, SyncJobEstado.hecho);

      // Reanudar vuelve a intentar el tipo en pausa (y vuelve a pausarlo).
      await h.outbox.reanudar();
      await h.outbox.idle();
      expect(h.outbox.tiposEnPausa, {SyncJobTipo.descuentoStock});
      await h.outbox.enqueue(SyncJobTipo.factura, {}, id: 'f3');
      await h.outbox.idle();
      expect(h.job('f3').estado, SyncJobEstado.hecho);
      await h.outbox.reanudar();
      await h.outbox.idle();
      expect(h.outbox.pausada, isFalse);
      expect(h.outbox.estado.todoSincronizado, isTrue);
    });

    test(
      'h14: tras un reinicio solo arrancan en pausa los tipos bloqueados',
      () async {
        final repo = InMemoryHostStateRepository();
        final h1 = await Harness.create(repo: repo);
        h1.handler.failOn('s1', const ConfigException('sin MySQL'));
        await h1.outbox.start();
        await h1.outbox.enqueue(SyncJobTipo.descuentoStock, {}, id: 's1');
        await h1.outbox.idle();
        await h1.dispose();

        final h2 = await Harness.create(repo: repo);
        addTearDown(h2.dispose);
        await h2.outbox.start();
        await h2.outbox.enqueue(SyncJobTipo.factura, {}, id: 'f1');
        await h2.outbox.idle();
        expect(h2.outbox.tiposEnPausa, {SyncJobTipo.descuentoStock});
        expect(h2.handler.ejecutados, ['f1']);
      },
    );

    test('h2: encolarEn añade el trabajo en la escritura del llamador y la '
        'cola lo ejecuta', () async {
      final h = await Harness.create();
      addTearDown(h.dispose);
      await h.outbox.start();
      final guardadas = h.repo.saves;
      await h.store.update(
        (s) => h.outbox.encolarEn(
          s.copyWith(numeroLocalSiguiente: 7),
          SyncJobTipo.factura,
          {'n': 1},
          id: 'x',
        ),
      );
      expect(h.repo.saves, guardadas + 1, reason: 'una sola escritura');
      expect(h.repo.savedJson, contains('"id":"x"'));
      // Idempotente por id.
      final s = h.store.snapshot;
      expect(
        identical(h.outbox.encolarEn(s, SyncJobTipo.factura, {}, id: 'x'), s),
        isTrue,
      );
      await Future<void>.delayed(Duration.zero);
      await h.outbox.idle();
      expect(h.handler.ejecutados, ['x']);
      expect(h.job('x').estado, SyncJobEstado.hecho);
    });
  });
}
