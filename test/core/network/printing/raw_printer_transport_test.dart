import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:proyecto_comandero/core/errors/app_exception.dart';
import 'package:proyecto_comandero/core/network/printing/raw_printer_transport.dart';
import 'package:test/test.dart';

import 'fake_printer.dart';

const ListEquality<int> _bytesEqual = ListEquality<int>();

/// Patrón verificable: no es constante ni periódico en 256, de modo que un
/// trozo perdido, duplicado o desordenado rompe la igualdad.
Uint8List _pattern(int length, {int seed = 7}) {
  final bytes = Uint8List(length);
  for (var i = 0; i < length; i++) {
    bytes[i] = (i * 31 + seed) & 0xFF;
  }
  return bytes;
}

/// Opciones cortas para que los fallos de los tests no tarden segundos.
const PrinterTransportOptions _fastOptions = PrinterTransportOptions(
  connectTimeout: Duration(seconds: 2),
  writeTimeout: Duration(seconds: 2),
  closeTimeout: Duration(seconds: 1),
);

/// Socket que acepta escrituras pero nunca confirma el `flush`: simula una
/// impresora cuya ventana TCP se ha cerrado (sin papel, colgada).
final class _StuckSocket implements Socket {
  bool destroyed = false;
  final StreamController<Uint8List> _incoming = StreamController<Uint8List>();
  final Completer<void> _never = Completer<void>();

  @override
  void add(List<int> data) {}

  @override
  Future<void> flush() => _never.future;

  @override
  Future<void> get done => _never.future;

  @override
  Future<void> close() => _never.future;

  @override
  bool setOption(SocketOption option, bool enabled) => true;

  @override
  void destroy() {
    destroyed = true;
    unawaited(_incoming.close());
  }

  @override
  StreamSubscription<Uint8List> listen(
    void Function(Uint8List event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => _incoming.stream.listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('PrinterEndpoint', () {
    test('toString es host:port y el puerto por defecto es 9100', () {
      expect(kRawPrintPort, 9100);
      expect(PrinterEndpoint('192.168.1.50').toString(), '192.168.1.50:9100');
      expect(PrinterEndpoint('cocina.local', port: 9101).port, 9101);
    });

    test('igualdad por host (sin distinguir mayúsculas) y puerto', () {
      final a = PrinterEndpoint('Cocina.local');
      final b = PrinterEndpoint(' cocina.local ');
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(equals(PrinterEndpoint('cocina.local', port: 9101))));
      expect(a, isNot(equals(PrinterEndpoint('barra.local'))));
    });

    test('rechaza hosts vacíos o con espacios y puertos fuera de rango', () {
      expect(() => PrinterEndpoint('   '), throwsA(isA<ValidationException>()));
      expect(
        () => PrinterEndpoint('192.168.1 50'),
        throwsA(isA<ValidationException>()),
      );
      expect(
        () => PrinterEndpoint('x', port: 0),
        throwsA(isA<ValidationException>()),
      );
      expect(
        () => PrinterEndpoint('x', port: 65536),
        throwsA(isA<ValidationException>()),
      );
    });
  });

  group('PrinterTransportOptions', () {
    test('valores por defecto', () {
      const options = PrinterTransportOptions();
      expect(options.connectTimeout, const Duration(seconds: 5));
      expect(options.writeTimeout, const Duration(seconds: 10));
      expect(options.closeTimeout, const Duration(seconds: 3));
      expect(options.chunkBytes, 4096);
      expect(options.awaitPeerClose, isTrue);
    });
  });

  group('EscPosSocketPrinter', () {
    late FakePrinter printer;

    setUp(() async {
      printer = await FakePrinter.start();
    });

    tearDown(() => printer.close());

    test('los bytes llegan exactos', () async {
      final bytes = Uint8List.fromList([0x1B, 0x40, 0x48, 0x6F, 0x6C, 0x61]);
      final transport = EscPosSocketPrinter(options: _fastOptions);

      await transport.send(printer.endpoint, bytes);
      await printer.waitForJobs(1);

      expect(printer.jobs.single, bytes);
    });

    test('una carga de 1 MiB llega íntegra', () async {
      final bytes = _pattern(1 << 20);
      final transport = EscPosSocketPrinter(options: _fastOptions);

      await transport.send(printer.endpoint, bytes);
      await printer.waitForJobs(1);

      expect(printer.jobs.single.length, bytes.length);
      expect(_bytesEqual.equals(printer.jobs.single, bytes), isTrue);
    });

    test('un trabajo que no es múltiplo del trozo llega íntegro', () async {
      final bytes = _pattern(1001, seed: 3);
      final transport = EscPosSocketPrinter(
        options: const PrinterTransportOptions(
          connectTimeout: Duration(seconds: 2),
          writeTimeout: Duration(seconds: 2),
          closeTimeout: Duration(seconds: 1),
          chunkBytes: 7,
        ),
      );

      await transport.send(printer.endpoint, bytes);
      await printer.waitForJobs(1);

      expect(_bytesEqual.equals(printer.jobs.single, bytes), isTrue);
    });

    test('abre una conexión por trabajo y la cierra tras enviar', () async {
      final transport = EscPosSocketPrinter(options: _fastOptions);

      await transport.send(printer.endpoint, _pattern(100, seed: 1));
      await printer.waitForJobs(1);
      expect(printer.connectionsAccepted, 1);
      expect(printer.openConnections, 0);

      await transport.send(printer.endpoint, _pattern(100, seed: 2));
      await printer.waitForJobs(2);
      expect(printer.connectionsAccepted, 2);
      expect(printer.openConnections, 0);
      expect(printer.maxConcurrentConnections, 1);
      expect(
        _bytesEqual.equals(printer.jobs[0], _pattern(100, seed: 1)),
        isTrue,
      );
      expect(
        _bytesEqual.equals(printer.jobs[1], _pattern(100, seed: 2)),
        isTrue,
      );
    });

    test('con bytes vacíos no abre conexión y completa sin error', () async {
      var connectorCalls = 0;
      final transport = EscPosSocketPrinter(
        options: _fastOptions,
        connector: (host, port, {timeout}) {
          connectorCalls++;
          return Socket.connect(host, port, timeout: timeout);
        },
      );

      await transport.send(printer.endpoint, Uint8List(0));

      expect(connectorCalls, 0);
      expect(printer.connectionsAccepted, 0);
    });

    test('si la impresora no cierra su lado, el trabajo se da por entregado '
        'al agotar closeTimeout', () async {
      final silent = await FakePrinter.start(closeOnEof: false);
      addTearDown(silent.close);
      final transport = EscPosSocketPrinter(
        options: const PrinterTransportOptions(
          connectTimeout: Duration(seconds: 2),
          writeTimeout: Duration(seconds: 2),
          closeTimeout: Duration(milliseconds: 100),
        ),
      );
      final bytes = _pattern(300);

      await transport.send(silent.endpoint, bytes);
      await silent.waitForJobs(1);

      expect(_bytesEqual.equals(silent.jobs.single, bytes), isTrue);
    });
  });

  group('EscPosSocketPrinter: fallos', () {
    test('conexión rechazada -> PrinterException con host:port', () async {
      // Reservar un puerto efímero y liberarlo garantiza que está cerrado.
      final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final endpoint = PrinterEndpoint('127.0.0.1', port: probe.port);
      await probe.close();
      // Windows reintenta el SYN tras el RST y tarda unos 2 s en informar del
      // rechazo: el timeout debe ser holgado para que la causa sea el rechazo
      // y no nuestro propio temporizador.
      final transport = EscPosSocketPrinter(
        options: const PrinterTransportOptions(
          connectTimeout: Duration(seconds: 15),
          writeTimeout: Duration(seconds: 2),
          closeTimeout: Duration(seconds: 1),
        ),
      );

      await expectLater(
        transport.send(endpoint, _pattern(10)),
        throwsA(
          isA<PrinterException>()
              .having((e) => e.message, 'message', contains('$endpoint'))
              .having((e) => e.cause, 'cause', isA<SocketException>()),
        ),
      );
    });

    test('timeout de conexión con un conector que nunca responde', () async {
      final endpoint = PrinterEndpoint('10.255.255.1');
      final transport = EscPosSocketPrinter(
        options: const PrinterTransportOptions(
          connectTimeout: Duration(milliseconds: 100),
        ),
        connector: (host, port, {timeout}) => Completer<Socket>().future,
      );

      await expectLater(
        transport.send(endpoint, _pattern(10)),
        throwsA(
          isA<PrinterException>()
              .having((e) => e.message, 'message', contains('$endpoint'))
              .having((e) => e.message, 'message', contains('no responde'))
              .having((e) => e.cause, 'cause', isA<TimeoutException>()),
        ),
      );
    });

    test('host inalcanzable (SocketException del conector)', () async {
      final endpoint = PrinterEndpoint('impresora-inexistente.local');
      final transport = EscPosSocketPrinter(
        options: _fastOptions,
        connector: (host, port, {timeout}) async {
          throw const SocketException('Host no encontrado');
        },
      );

      await expectLater(
        transport.send(endpoint, _pattern(10)),
        throwsA(
          isA<PrinterException>()
              .having((e) => e.message, 'message', contains('$endpoint'))
              .having((e) => e.cause, 'cause', isA<SocketException>()),
        ),
      );
    });

    test(
      'timeout de escritura cuando la impresora deja de aceptar datos',
      () async {
        final endpoint = PrinterEndpoint('192.168.1.77');
        final stuck = _StuckSocket();
        final transport = EscPosSocketPrinter(
          options: const PrinterTransportOptions(
            connectTimeout: Duration(seconds: 1),
            writeTimeout: Duration(milliseconds: 100),
            closeTimeout: Duration(milliseconds: 100),
          ),
          connector: (host, port, {timeout}) async => stuck,
        );

        await expectLater(
          transport.send(endpoint, _pattern(10)),
          throwsA(
            isA<PrinterException>()
                .having((e) => e.message, 'message', contains('$endpoint'))
                .having(
                  (e) => e.message,
                  'message',
                  contains('dejó de aceptar datos'),
                )
                .having((e) => e.cause, 'cause', isA<TimeoutException>()),
          ),
        );
        expect(stuck.destroyed, isTrue, reason: 'destroy() siempre en finally');
      },
    );

    test('la impresora corta a mitad de trabajo -> PrinterException', () async {
      // Con un trabajo mucho mayor que los búferes TCP de loopback el cliente
      // aún está escribiendo cuando llega el RST.
      final printer = await FakePrinter.start(cutAfterBytes: 1);
      addTearDown(printer.close);
      final transport = EscPosSocketPrinter(options: _fastOptions);

      await expectLater(
        transport.send(printer.endpoint, _pattern(8 << 20)),
        throwsA(
          isA<PrinterException>().having(
            (e) => e.message,
            'message',
            contains('${printer.endpoint}'),
          ),
        ),
      );
    });

    test('la impresora cierra ordenadamente antes de tiempo', () async {
      // Un servidor que cierra sin leer: el cliente ve EOF (o RST) y debe
      // fallar de forma controlada, nunca con un error asíncrono suelto.
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      server.listen((client) {
        unawaited(client.done.then<void>((_) {}, onError: (Object _) {}));
        client.listen((_) {}, onError: (Object _) {}, cancelOnError: true);
        unawaited(client.close().then<void>((_) {}, onError: (Object _) {}));
      });
      final endpoint = PrinterEndpoint('127.0.0.1', port: server.port);
      final transport = EscPosSocketPrinter(
        options: const PrinterTransportOptions(
          connectTimeout: Duration(seconds: 2),
          writeTimeout: Duration(seconds: 2),
          closeTimeout: Duration(seconds: 1),
          chunkBytes: 1024,
        ),
      );

      await expectLater(
        transport.send(endpoint, _pattern(4 << 20)),
        throwsA(isA<PrinterException>()),
      );
    });
  });
}
