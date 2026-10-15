import 'dart:typed_data';

import 'package:proyecto_comandero/core/errors/app_exception.dart';
import 'package:proyecto_comandero/core/network/printing/print_queue.dart';
import 'package:proyecto_comandero/core/network/printing/raw_printer_transport.dart';
import 'package:proyecto_comandero/features/host/data/print_queue_adapter.dart';
import 'package:test/test.dart';

import '../../core/network/printing/fake_transport.dart';

const Duration _timeout = Duration(seconds: 5);

/// Reintentos rápidos para que la suite no espere segundos entre intentos.
const PrintQueueOptions _fastOptions = PrintQueueOptions(
  retryDelay: Duration(milliseconds: 5),
);

const PrinterException _writeFailure = PrinterException(
  'La impresora cortó la conexión al terminar el envío',
);
const PrinterConnectException _connectFailure = PrinterConnectException(
  'No se pudo conectar con la impresora',
);

final PrinterEndpoint _tickets = PrinterEndpoint('192.168.1.40');
final Uint8List _bytes = Uint8List.fromList([0x1B, 0x40, 0x46, 0x31, 0x0A]);

void main() {
  late FakeTransport transport;
  late PrintQueueAdapter adapter;

  setUp(() {
    transport = FakeTransport();
    adapter = PrintQueueAdapter.forTransport(transport, options: _fastOptions);
  });

  tearDown(() => adapter.dispose());

  test('imprimir encola el trabajo y terminado devuelve null al '
      'imprimirse', () async {
    final id = adapter.imprimir(_tickets, _bytes, description: 'Ticket 1');

    expect(adapter.queue.find(id)?.description, 'Ticket 1');
    expect(await adapter.terminado(id).timeout(_timeout), isNull);
    expect(transport.sent.single.bytes, _bytes);
    expect(adapter.queue.find(id)?.status, PrintJobStatus.done);
  });

  group('política de reintento', () {
    test('por defecto es always: un fallo de escritura se reintenta', () async {
      transport.failNext(_writeFailure, times: 2);

      final id = adapter.imprimir(_tickets, _bytes, description: 'Comanda');

      expect(await adapter.terminado(id).timeout(_timeout), isNull);
      expect(transport.attempts, hasLength(3));
      expect(adapter.queue.find(id)?.attempts, 3);
    });

    test('connectOnly llega a la cola: un fallo de escritura termina el '
        'trabajo en el primer intento con su mensaje', () async {
      transport.failNext(_writeFailure);

      final id = adapter.imprimir(
        _tickets,
        _bytes,
        description: 'Factura F1',
        reintento: PrintRetryPolicy.connectOnly,
      );

      expect(
        await adapter.terminado(id).timeout(_timeout),
        _writeFailure.message,
      );
      expect(transport.attempts, hasLength(1), reason: 'sin reintento');
      expect(transport.sent, isEmpty);
      final job = adapter.queue.find(id);
      expect(job?.status, PrintJobStatus.failed);
      expect(job?.attempts, 1);
    });

    test('connectOnly: un fallo de conexión sí se reintenta', () async {
      transport.failNext(_connectFailure);

      final id = adapter.imprimir(
        _tickets,
        _bytes,
        description: 'Factura F1',
        reintento: PrintRetryPolicy.connectOnly,
      );

      expect(await adapter.terminado(id).timeout(_timeout), isNull);
      expect(transport.attempts, hasLength(2));
      expect(transport.sent, hasLength(1));
    });

    test('always explícito reintenta igual que el valor por defecto', () async {
      transport.failNext(_writeFailure);

      final id = adapter.imprimir(
        _tickets,
        _bytes,
        description: 'Comanda',
        reintento: PrintRetryPolicy.always,
      );

      expect(await adapter.terminado(id).timeout(_timeout), isNull);
      expect(transport.attempts, hasLength(2));
    });
  });

  group('terminado', () {
    test('devuelve el motivo del último fallo si agota los intentos', () async {
      transport.failNext(const PrinterException('sin papel'), times: 3);

      final id = adapter.imprimir(_tickets, _bytes, description: 'Comanda');

      expect(await adapter.terminado(id).timeout(_timeout), 'sin papel');
      expect(transport.attempts, hasLength(3));
    });

    test('devuelve "cancelado" para un trabajo retirado de la cola', () async {
      transport.holdSends = true;
      adapter.imprimir(_tickets, _bytes, description: 'en curso');
      final id = adapter.imprimir(_tickets, _bytes, description: 'en cola');
      await transport.whenHeld(1);

      expect(adapter.queue.cancel(id), isTrue);
      expect(await adapter.terminado(id).timeout(_timeout), 'cancelado');

      transport.releaseAll();
    });

    test('devuelve el error de la cola para un trabajo desconocido', () async {
      expect(
        await adapter.terminado('no-existe').timeout(_timeout),
        contains('no-existe'),
      );
    });
  });

  group('reintentar', () {
    test('llama a queue.retry, conserva el id y terminado espera a la '
        'reimpresión', () async {
      transport.failNext(_writeFailure, times: 3);
      final id = adapter.imprimir(_tickets, _bytes, description: 'Comanda');
      expect(
        await adapter.terminado(id).timeout(_timeout),
        _writeFailure.message,
      );

      final otra = adapter.reintentar(id);

      expect(otra, id);
      expect(adapter.queue.find(id)?.status, PrintJobStatus.queued);
      expect(await adapter.terminado(id).timeout(_timeout), isNull);
      expect(transport.sent.single.bytes, _bytes);
      expect(adapter.queue.find(id)?.attempts, 4);
    });

    test('conserva la política del trabajo (connectOnly)', () async {
      transport.failNext(_writeFailure);
      final id = adapter.imprimir(
        _tickets,
        _bytes,
        description: 'Factura F1',
        reintento: PrintRetryPolicy.connectOnly,
      );
      await adapter.terminado(id).timeout(_timeout);

      transport.failNext(_writeFailure);
      adapter.reintentar(id);

      expect(
        await adapter.terminado(id).timeout(_timeout),
        _writeFailure.message,
      );
      expect(transport.attempts, hasLength(2), reason: 'sin reintento');
    });

    test('lanza con un trabajo que no está fallido', () async {
      final id = adapter.imprimir(_tickets, _bytes, description: 'Comanda');
      await adapter.terminado(id).timeout(_timeout);

      expect(() => adapter.reintentar(id), throwsA(isA<PrinterException>()));
    });

    test('lanza con un trabajo desconocido', () {
      expect(
        () => adapter.reintentar('no-existe'),
        throwsA(isA<PrinterException>()),
      );
    });
  });

  group('nadaEnviado', () {
    test('es verdadero si todos los intentos fallaron al conectar', () async {
      transport.failNext(_connectFailure, times: 3);
      final id = adapter.imprimir(
        _tickets,
        _bytes,
        description: 'Factura F1',
        reintento: PrintRetryPolicy.connectOnly,
      );
      await adapter.terminado(id).timeout(_timeout);

      expect(adapter.nadaEnviado(id), isTrue);
    });

    test('es falso si algún intento llegó a escribir', () async {
      transport.failNext(_writeFailure);
      final id = adapter.imprimir(
        _tickets,
        _bytes,
        description: 'Factura F1',
        reintento: PrintRetryPolicy.connectOnly,
      );
      await adapter.terminado(id).timeout(_timeout);

      expect(adapter.nadaEnviado(id), isFalse);
    });

    test('lanza con un trabajo desconocido', () {
      expect(
        () => adapter.nadaEnviado('no-existe'),
        throwsA(
          isA<PrinterException>().having(
            (e) => e.message,
            'message',
            contains('no-existe'),
          ),
        ),
      );
    });
  });
}
