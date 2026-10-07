import 'dart:async';
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:fake_async/fake_async.dart';
import 'package:proyecto_comandero/core/errors/app_exception.dart';
import 'package:proyecto_comandero/core/network/printing/print_queue.dart';
import 'package:proyecto_comandero/core/network/printing/raw_printer_transport.dart';
import 'package:test/test.dart';

import 'fake_printer.dart';
import 'fake_transport.dart';

const ListEquality<int> _bytesEqual = ListEquality<int>();
const Duration _timeout = Duration(seconds: 5);

/// Bytes identificables por trabajo: el primer byte es [tag].
Uint8List _ticket(int tag, {int length = 64}) {
  final bytes = Uint8List(length);
  for (var i = 0; i < length; i++) {
    bytes[i] = (tag * 97 + i * 13) & 0xFF;
  }
  bytes[0] = tag & 0xFF;
  return bytes;
}

/// Opciones rápidas para que los reintentos no alarguen la suite.
const PrintQueueOptions _fastOptions = PrintQueueOptions(
  retryDelay: Duration(milliseconds: 5),
);

final PrinterEndpoint _kitchen = PrinterEndpoint('192.168.1.10');
final PrinterEndpoint _bar = PrinterEndpoint('192.168.1.11');

List<PrintJobStatus> _statusesOf(List<PrintJob> events, String jobId) =>
    events.where((job) => job.id == jobId).map((job) => job.status).toList();

Future<PrintJob> _waitFor(
  Stream<PrintJob> updates,
  bool Function(PrintJob job) predicate,
) => updates.firstWhere(predicate).timeout(_timeout);

void main() {
  group('PrintQueueOptions', () {
    test('valores por defecto', () {
      const options = PrintQueueOptions();
      expect(options.maxAttempts, 3);
      expect(options.retryDelay, const Duration(seconds: 1));
      expect(options.maxHistory, 100);
      expect(options.maxPending, 200);
    });
  });

  group('PrintJob', () {
    test('isFinished solo en estados terminales', () {
      expect(PrintJobStatus.queued.isFinished, isFalse);
      expect(PrintJobStatus.printing.isFinished, isFalse);
      expect(PrintJobStatus.done.isFinished, isTrue);
      expect(PrintJobStatus.failed.isFinished, isTrue);
      expect(PrintJobStatus.cancelled.isFinished, isTrue);
    });
  });

  group('PrintQueue con transporte en memoria', () {
    late FakeTransport transport;
    late PrintQueue queue;
    late List<PrintJob> events;

    setUp(() {
      transport = FakeTransport();
      queue = PrintQueue(transport: transport, options: _fastOptions);
      events = <PrintJob>[];
      queue.updates.listen(events.add);
    });

    tearDown(() => queue.dispose());

    test('enqueue devuelve el trabajo en cola y termina en done', () async {
      final job = queue.enqueue(
        _kitchen,
        _ticket(1),
        description: 'Comanda mesa 4',
      );
      expect(job.status, PrintJobStatus.queued);
      expect(job.attempts, 0);
      expect(job.byteCount, 64);
      expect(job.description, 'Comanda mesa 4');
      expect(job.endpoint, _kitchen);
      expect(job.finishedAt, isNull);

      final finished = await queue.whenFinished(job.id).timeout(_timeout);
      expect(finished.id, job.id);
      expect(finished.status, PrintJobStatus.done);
      expect(finished.attempts, 1);
      expect(finished.lastError, isNull);
      expect(finished.finishedAt, isNotNull);
      expect(transport.sent, hasLength(1));
      expect(
        _bytesEqual.equals(transport.sent.single.bytes, _ticket(1)),
        isTrue,
      );
      // La instancia devuelta por enqueue es una foto: no cambia.
      expect(job.status, PrintJobStatus.queued);
    });

    test('updates emite cada transición queued -> printing -> done', () async {
      final job = queue.enqueue(_kitchen, _ticket(1), description: 'a');
      await queue.whenFinished(job.id).timeout(_timeout);
      await pumpEventQueue();

      expect(_statusesOf(events, job.id), [
        PrintJobStatus.queued,
        PrintJobStatus.printing,
        PrintJobStatus.done,
      ]);
    });

    test('rechaza trabajos sin bytes', () {
      expect(
        () => queue.enqueue(_kitchen, Uint8List(0), description: 'vacío'),
        throwsA(isA<ValidationException>()),
      );
      expect(queue.jobs, isEmpty);
    });

    test('dos impresoras imprimen en paralelo', () async {
      transport.holdSends = true;
      final kitchen = queue.enqueue(_kitchen, _ticket(1), description: 'k');
      final bar = queue.enqueue(_bar, _ticket(2), description: 'b');

      await transport.whenHeld(2);
      expect(queue.find(kitchen.id)?.status, PrintJobStatus.printing);
      expect(queue.find(bar.id)?.status, PrintJobStatus.printing);
      expect(transport.maxConcurrentTotal, 2);

      transport.releaseAll();
      await Future.wait([
        queue.whenFinished(kitchen.id),
        queue.whenFinished(bar.id),
      ]).timeout(_timeout);
      expect(transport.maxConcurrentSameEndpoint, 1);
    });

    test('la misma impresora nunca recibe dos envíos a la vez', () async {
      transport.holdSends = true;
      final first = queue.enqueue(_kitchen, _ticket(1), description: '1');
      final second = queue.enqueue(_kitchen, _ticket(2), description: '2');

      await transport.whenHeld(1);
      expect(queue.find(first.id)?.status, PrintJobStatus.printing);
      expect(queue.find(second.id)?.status, PrintJobStatus.queued);
      expect(queue.pendingFor(_kitchen), 2);

      transport.held[0].complete();
      await transport.whenHeld(2);
      expect(queue.find(first.id)?.status, PrintJobStatus.done);
      expect(queue.find(second.id)?.status, PrintJobStatus.printing);

      transport.held[1].complete();
      await queue.whenFinished(second.id).timeout(_timeout);
      expect(transport.maxConcurrentSameEndpoint, 1);
      expect(transport.sent.map((s) => s.bytes[0]), [1, 2]);
      expect(queue.pendingFor(_kitchen), 0);
    });

    test('reintenta tras fallos transitorios y acaba en done', () async {
      transport.failuresBeforeSuccess = 2;
      final job = queue.enqueue(_kitchen, _ticket(1), description: 'a');

      final finished = await queue.whenFinished(job.id).timeout(_timeout);
      await pumpEventQueue();

      expect(finished.status, PrintJobStatus.done);
      expect(finished.attempts, 3);
      expect(finished.lastError, isNull);
      expect(transport.attempts, hasLength(3));
      expect(_statusesOf(events, job.id), [
        PrintJobStatus.queued,
        PrintJobStatus.printing,
        PrintJobStatus.queued,
        PrintJobStatus.printing,
        PrintJobStatus.queued,
        PrintJobStatus.printing,
        PrintJobStatus.done,
      ]);
      // Mientras espera el reintento, el trabajo expone el motivo del fallo
      // y cuántos envíos lleva.
      final waiting = events
          .where((e) => e.id == job.id && e.status == PrintJobStatus.queued)
          .toList();
      expect(waiting.map((e) => e.attempts), [0, 1, 2]);
      expect(waiting.map((e) => e.lastError), [
        isNull,
        contains('Fallo simulado'),
        contains('Fallo simulado'),
      ]);
    });

    test('un fallo definitivo deja el trabajo failed y la cola sigue con el '
        'siguiente de la misma impresora', () async {
      transport.failuresBeforeSuccess = 3;
      final broken = queue.enqueue(_kitchen, _ticket(1), description: 'x');
      final next = queue.enqueue(_kitchen, _ticket(2), description: 'y');

      final failed = await queue.whenFinished(broken.id).timeout(_timeout);
      expect(failed.status, PrintJobStatus.failed);
      expect(failed.attempts, 3);
      expect(failed.lastError, contains('Fallo simulado'));
      expect(failed.finishedAt, isNotNull);

      final done = await queue.whenFinished(next.id).timeout(_timeout);
      expect(done.status, PrintJobStatus.done);
      expect(transport.sent.single.bytes[0], 2);
      // El siguiente no empezó hasta que el anterior agotó sus intentos.
      expect(transport.attempts, hasLength(4));
    });

    test('retry reencola un failed con sus bytes originales', () async {
      transport.failuresBeforeSuccess = 3;
      final job = queue.enqueue(_kitchen, _ticket(7), description: 'a');
      final failed = await queue.whenFinished(job.id).timeout(_timeout);
      expect(failed.status, PrintJobStatus.failed);
      expect(queue.retainedBytes, 64, reason: 'los fallidos conservan bytes');

      final requeued = queue.retry(job.id);
      expect(requeued.id, job.id);
      expect(requeued.status, PrintJobStatus.queued);
      expect(requeued.attempts, 3);
      expect(requeued.finishedAt, isNull);

      final done = await queue.whenFinished(job.id).timeout(_timeout);
      expect(done.status, PrintJobStatus.done);
      expect(done.attempts, 4);
      expect(done.lastError, isNull);
      expect(
        _bytesEqual.equals(transport.sent.single.bytes, _ticket(7)),
        isTrue,
      );
      expect(queue.retainedBytes, 0);
      expect(queue.jobs.map((j) => j.id), [job.id]);
    });

    test('retry solo admite trabajos failed', () async {
      final job = queue.enqueue(_kitchen, _ticket(1), description: 'a');
      await queue.whenFinished(job.id).timeout(_timeout);

      expect(() => queue.retry(job.id), throwsA(isA<PrinterException>()));
      expect(() => queue.retry('no-existe'), throwsA(isA<PrinterException>()));
    });

    test('cancel retira un trabajo en cola', () async {
      transport.holdSends = true;
      final first = queue.enqueue(_kitchen, _ticket(1), description: '1');
      final second = queue.enqueue(_kitchen, _ticket(2), description: '2');
      await transport.whenHeld(1);

      expect(queue.cancel(second.id), isTrue);
      final cancelled = await queue.whenFinished(second.id).timeout(_timeout);
      expect(cancelled.status, PrintJobStatus.cancelled);
      expect(cancelled.finishedAt, isNotNull);
      expect(queue.cancel(second.id), isFalse, reason: 'ya terminado');

      transport.releaseAll();
      await queue.whenFinished(first.id).timeout(_timeout);
      await pumpEventQueue();
      expect(transport.sent.map((s) => s.bytes[0]), [1]);
      expect(_statusesOf(events, second.id), [
        PrintJobStatus.queued,
        PrintJobStatus.cancelled,
      ]);
    });

    test('cancel de un trabajo en curso devuelve false', () async {
      transport.holdSends = true;
      final job = queue.enqueue(_kitchen, _ticket(1), description: '1');
      await transport.whenHeld(1);

      expect(queue.cancel(job.id), isFalse);
      expect(queue.cancel('no-existe'), isFalse);

      transport.releaseAll();
      final done = await queue.whenFinished(job.id).timeout(_timeout);
      expect(done.status, PrintJobStatus.done);
    });

    test('cancel durante la espera de reintento libera la cola', () async {
      final slow = PrintQueue(
        transport: transport,
        options: const PrintQueueOptions(retryDelay: Duration(seconds: 30)),
      );
      addTearDown(slow.dispose);
      transport.failuresBeforeSuccess = 1;
      final broken = slow.enqueue(_kitchen, _ticket(1), description: 'x');
      final next = slow.enqueue(_kitchen, _ticket(2), description: 'y');

      await _waitFor(
        slow.updates,
        (job) =>
            job.id == broken.id &&
            job.status == PrintJobStatus.queued &&
            job.attempts == 1,
      );
      expect(slow.cancel(broken.id), isTrue);

      final done = await slow.whenFinished(next.id).timeout(_timeout);
      expect(done.status, PrintJobStatus.done);
      expect(slow.find(broken.id)?.status, PrintJobStatus.cancelled);
      expect(slow.find(broken.id)?.lastError, contains('Fallo simulado'));
    });

    test('maxPending limita los trabajos pendientes por impresora', () async {
      final limited = PrintQueue(
        transport: transport,
        options: const PrintQueueOptions(maxPending: 2),
      );
      addTearDown(limited.dispose);
      transport.holdSends = true;

      final a = limited.enqueue(_kitchen, _ticket(1), description: 'a');
      limited.enqueue(_kitchen, _ticket(2), description: 'b');
      expect(
        () => limited.enqueue(_kitchen, _ticket(3), description: 'c'),
        throwsA(
          isA<PrinterException>().having(
            (e) => e.message,
            'message',
            contains('$_kitchen'),
          ),
        ),
      );
      // Otra impresora tiene su propio límite.
      final bar = limited.enqueue(_bar, _ticket(4), description: 'd');

      await transport.whenHeld(2); // a y d en curso
      transport.releaseAll();
      await limited.whenFinished(a.id).timeout(_timeout);
      // Al liberarse hueco vuelve a admitir trabajos (b sigue pendiente).
      expect(limited.pendingFor(_kitchen), 1);
      final e = limited.enqueue(_kitchen, _ticket(5), description: 'e');
      await transport.whenHeld(3); // b en curso; e espera detrás
      transport.releaseAll();
      await transport.whenHeld(4); // e en curso
      transport.releaseAll();
      await Future.wait([
        limited.whenFinished(bar.id),
        limited.whenFinished(e.id),
      ]).timeout(_timeout);
      expect(transport.sent, hasLength(4));
      expect(
        transport.sent
            .where((s) => s.endpoint == _kitchen)
            .map((s) => s.bytes[0]),
        [1, 2, 5],
      );
    });

    test('whenFinished falla para trabajos desconocidos', () {
      expect(queue.whenFinished('no-existe'), throwsA(isA<PrinterException>()));
    });

    test('whenFinished completa de inmediato si ya terminó', () async {
      final job = queue.enqueue(_kitchen, _ticket(1), description: 'a');
      await queue.whenFinished(job.id).timeout(_timeout);
      final again = await queue.whenFinished(job.id).timeout(_timeout);
      expect(again.status, PrintJobStatus.done);
    });

    test(
      'jobs lista pendientes e historial del más antiguo al más nuevo',
      () async {
        transport.holdSends = true;
        final ids = [
          for (var i = 1; i <= 3; i++)
            queue.enqueue(_kitchen, _ticket(i), description: '$i').id,
        ];
        await transport.whenHeld(1);
        expect(queue.jobs.map((j) => j.id), ids);
        expect(queue.jobs.map((j) => j.status), [
          PrintJobStatus.printing,
          PrintJobStatus.queued,
          PrintJobStatus.queued,
        ]);
        expect(() => queue.jobs.add(queue.jobs.first), throwsUnsupportedError);

        transport.holdSends = false;
        transport.releaseAll();
        await queue.whenFinished(ids.last).timeout(_timeout);
        expect(queue.jobs.map((j) => j.id), ids);
        expect(
          queue.jobs.every((j) => j.status == PrintJobStatus.done),
          isTrue,
        );
      },
    );

    test(
      'el historial está acotado y no retiene los bytes de los done',
      () async {
        final small = PrintQueue(
          transport: transport,
          options: const PrintQueueOptions(maxHistory: 3),
        );
        addTearDown(small.dispose);
        final ids = [
          for (var i = 1; i <= 6; i++)
            small
                .enqueue(_kitchen, _ticket(i, length: 1024), description: '$i')
                .id,
        ];
        await small.whenFinished(ids.last).timeout(_timeout);

        expect(small.jobs.map((j) => j.id), ids.sublist(3));
        expect(small.retainedBytes, 0);
        expect(small.find(ids.first), isNull);
        expect(small.whenFinished(ids.first), throwsA(isA<PrinterException>()));
      },
    );

    test('dispose cancela lo pendiente, espera al envío en curso y cierra '
        'updates', () async {
      transport.holdSends = true;
      final printing = queue.enqueue(_kitchen, _ticket(1), description: '1');
      final waiting = queue.enqueue(_kitchen, _ticket(2), description: '2');
      final other = queue.enqueue(_bar, _ticket(3), description: '3');
      await transport.whenHeld(2);

      final closed = queue.updates.toList();
      final disposal = queue.dispose();
      expect(queue.find(waiting.id)?.status, PrintJobStatus.cancelled);
      expect(queue.find(printing.id)?.status, PrintJobStatus.printing);
      expect(queue.find(other.id)?.status, PrintJobStatus.printing);
      expect(
        () => queue.enqueue(_kitchen, _ticket(9), description: 'tarde'),
        throwsA(isA<PrinterException>()),
      );

      transport.releaseAll();
      await disposal.timeout(_timeout);
      expect(queue.find(printing.id)?.status, PrintJobStatus.done);
      expect(queue.find(other.id)?.status, PrintJobStatus.done);
      expect(transport.sent.map((s) => s.bytes[0]), unorderedEquals([1, 3]));
      // El stream se ha cerrado: toList completa.
      await closed.timeout(_timeout);
      // Idempotente.
      await queue.dispose().timeout(_timeout);
    });

    test('dispose durante la espera de reintento no reintenta más', () async {
      final slow = PrintQueue(
        transport: transport,
        options: const PrintQueueOptions(retryDelay: Duration(seconds: 30)),
      );
      transport.failuresBeforeSuccess = 1;
      final job = slow.enqueue(_kitchen, _ticket(1), description: 'x');
      await _waitFor(
        slow.updates,
        (j) =>
            j.id == job.id &&
            j.status == PrintJobStatus.queued &&
            j.attempts == 1,
      );

      await slow.dispose().timeout(_timeout);
      expect(slow.find(job.id)?.status, PrintJobStatus.cancelled);
      expect(transport.attempts, hasLength(1));
    });
  });

  group('PrintQueue: espera creciente entre reintentos (fake_async)', () {
    test('duplica retryDelay en cada reintento hasta maxRetryDelay', () {
      fakeAsync((async) {
        final transport = FakeTransport(failuresBeforeSuccess: 1 << 30);
        final queue = PrintQueue(
          transport: transport,
          options: const PrintQueueOptions(
            maxAttempts: 4,
            retryDelay: Duration(seconds: 1),
            maxRetryDelay: Duration(seconds: 3),
          ),
        );
        final job = queue.enqueue(_kitchen, _ticket(1), description: 'x');
        async.flushMicrotasks();
        expect(transport.attempts, hasLength(1));
        expect(queue.find(job.id)?.status, PrintJobStatus.queued);

        // Primer reintento tras 1 s.
        async.elapse(const Duration(milliseconds: 999));
        expect(transport.attempts, hasLength(1));
        async.elapse(const Duration(milliseconds: 1));
        expect(transport.attempts, hasLength(2));

        // Segundo tras 2 s.
        async.elapse(const Duration(milliseconds: 1999));
        expect(transport.attempts, hasLength(2));
        async.elapse(const Duration(milliseconds: 1));
        expect(transport.attempts, hasLength(3));

        // Tercero: 4 s se recorta a maxRetryDelay = 3 s.
        async.elapse(const Duration(milliseconds: 2999));
        expect(transport.attempts, hasLength(3));
        async.elapse(const Duration(milliseconds: 1));
        expect(transport.attempts, hasLength(4));
        expect(queue.find(job.id)?.status, PrintJobStatus.failed);
        expect(queue.find(job.id)?.attempts, 4);

        unawaited(queue.dispose());
        async.flushMicrotasks();
        expect(
          async.pendingTimers,
          isEmpty,
          reason: 'sin temporizadores sueltos',
        );
      });
    });
  });

  group('PrintQueue con impresoras reales (loopback)', () {
    test(
      'FIFO estricto con una impresora lenta y una sola conexión a la vez',
      () async {
        final printer = await FakePrinter.start(
          readDelay: const Duration(milliseconds: 15),
        );
        addTearDown(printer.close);
        final queue = PrintQueue(
          transport: EscPosSocketPrinter(
            options: const PrinterTransportOptions(
              connectTimeout: Duration(seconds: 2),
              writeTimeout: Duration(seconds: 2),
              closeTimeout: Duration(seconds: 1),
              chunkBytes: 64,
            ),
          ),
        );
        addTearDown(queue.dispose);

        final jobs = [
          for (var i = 1; i <= 5; i++)
            queue.enqueue(
              printer.endpoint,
              _ticket(i, length: 200),
              description: 'comanda $i',
            ),
        ];
        final finished = await Future.wait(
          jobs.map((job) => queue.whenFinished(job.id)),
        ).timeout(const Duration(seconds: 20));

        expect(
          finished.map((j) => j.status),
          everyElement(PrintJobStatus.done),
        );
        await printer.waitForJobs(5);
        expect(printer.jobs.map((bytes) => bytes[0]), [1, 2, 3, 4, 5]);
        for (var i = 0; i < 5; i++) {
          expect(
            _bytesEqual.equals(printer.jobs[i], _ticket(i + 1, length: 200)),
            isTrue,
            reason: 'bytes del trabajo ${i + 1}',
          );
        }
        expect(printer.connectionsAccepted, 5);
        expect(printer.maxConcurrentConnections, 1);
      },
    );

    test('dos impresoras reales imprimen en paralelo', () async {
      final kitchen = await FakePrinter.start(
        readDelay: const Duration(milliseconds: 20),
      );
      final bar = await FakePrinter.start(
        readDelay: const Duration(milliseconds: 20),
      );
      addTearDown(kitchen.close);
      addTearDown(bar.close);
      final queue = PrintQueue(
        transport: EscPosSocketPrinter(
          options: const PrinterTransportOptions(
            connectTimeout: Duration(seconds: 2),
            writeTimeout: Duration(seconds: 2),
            closeTimeout: Duration(seconds: 1),
            chunkBytes: 32,
          ),
        ),
      );
      addTearDown(queue.dispose);

      final events = <PrintJob>[];
      final bothPrinting = Completer<void>();
      queue.updates.listen((job) {
        events.add(job);
        final printing = events.where(
          (e) => e.status == PrintJobStatus.printing,
        );
        if (printing.length == 2 && !bothPrinting.isCompleted) {
          bothPrinting.complete();
        }
      });
      final k = queue.enqueue(
        kitchen.endpoint,
        _ticket(1, length: 256),
        description: 'k',
      );
      final b = queue.enqueue(
        bar.endpoint,
        _ticket(2, length: 256),
        description: 'b',
      );

      // Ambos están imprimiendo a la vez antes de que termine ninguno.
      await bothPrinting.future.timeout(_timeout);
      expect(events.where((e) => e.status == PrintJobStatus.done), isEmpty);

      await Future.wait([queue.whenFinished(k.id), queue.whenFinished(b.id)])
          .timeout(const Duration(seconds: 20));
      await kitchen.waitForJobs(1);
      await bar.waitForJobs(1);
      expect(kitchen.jobs.single[0], 1);
      expect(bar.jobs.single[0], 2);
    });

    test('impresora apagada: failed con host:port y la otra sigue', () async {
      final probe = await FakePrinter.start();
      final offline = probe.endpoint;
      await probe.close();
      final online = await FakePrinter.start();
      addTearDown(online.close);
      final queue = PrintQueue(
        transport: EscPosSocketPrinter(
          options: const PrinterTransportOptions(
            connectTimeout: Duration(seconds: 10),
            writeTimeout: Duration(seconds: 2),
            closeTimeout: Duration(seconds: 1),
          ),
        ),
        options: const PrintQueueOptions(
          maxAttempts: 2,
          retryDelay: Duration(milliseconds: 5),
        ),
      );
      addTearDown(queue.dispose);

      final broken = queue.enqueue(offline, _ticket(1), description: 'x');
      final ok = queue.enqueue(online.endpoint, _ticket(2), description: 'y');

      final done = await queue.whenFinished(ok.id).timeout(_timeout);
      expect(done.status, PrintJobStatus.done);
      final failed = await queue
          .whenFinished(broken.id)
          .timeout(const Duration(seconds: 30));
      expect(failed.status, PrintJobStatus.failed);
      expect(failed.attempts, 2);
      expect(failed.lastError, contains('$offline'));
    });
  });
}
