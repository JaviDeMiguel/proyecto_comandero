import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:proyecto_comandero/core/network/printing/raw_printer_transport.dart';

/// Impresora térmica simulada: un `ServerSocket` en 127.0.0.1 con puerto
/// efímero que captura los bytes de cada conexión.
///
/// Imita lo que hace el firmware RAW 9100 de una impresora real: lee todo lo
/// que llega y, cuando el cliente cierra su lado (FIN), cierra el suyo. Los
/// parámetros permiten simular una impresora lenta ([readDelay]), una que
/// corta la conexión a mitad de trabajo ([cutAfterBytes]) o una que nunca
/// cierra su lado ([closeOnEof] = false).
final class FakePrinter {
  FakePrinter._(
    this._server, {
    required this.readDelay,
    required this.cutAfterBytes,
    required this.closeOnEof,
  });

  static Future<FakePrinter> start({
    Duration readDelay = Duration.zero,
    int? cutAfterBytes,
    bool closeOnEof = true,
  }) async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final printer = FakePrinter._(
      server,
      readDelay: readDelay,
      cutAfterBytes: cutAfterBytes,
      closeOnEof: closeOnEof,
    );
    printer._accepting = server.listen(
      printer._accept,
      onError: (Object _) {},
      cancelOnError: true,
    );
    return printer;
  }

  final ServerSocket _server;

  /// Pausa tras cada segmento recibido (impresora lenta).
  final Duration readDelay;

  /// Si no es `null`, destruye la conexión en cuanto ha recibido al menos
  /// estos bytes (RST hacia el cliente).
  final int? cutAfterBytes;

  /// Cerrar el lado del servidor cuando el cliente envía su FIN.
  final bool closeOnEof;

  StreamSubscription<Socket>? _accepting;
  final Set<Socket> _clients = <Socket>{};
  final List<_Waiter> _waiters = <_Waiter>[];

  /// Bytes recibidos en cada conexión ya terminada, en orden de finalización.
  final List<Uint8List> jobs = <Uint8List>[];

  int connectionsAccepted = 0;
  int openConnections = 0;

  /// Máximo de conexiones abiertas a la vez durante toda la vida del servidor.
  int maxConcurrentConnections = 0;

  int get port => _server.port;

  PrinterEndpoint get endpoint => PrinterEndpoint('127.0.0.1', port: port);

  /// Completa cuando hay al menos [count] conexiones terminadas.
  Future<void> waitForJobs(
    int count, {
    Duration timeout = const Duration(seconds: 10),
  }) {
    if (jobs.length >= count) return Future<void>.value();
    final waiter = _Waiter(count);
    _waiters.add(waiter);
    return waiter.completer.future.timeout(
      timeout,
      onTimeout: () {
        _waiters.remove(waiter);
        throw TimeoutException(
          'La impresora falsa solo ha recibido ${jobs.length} de $count '
          'trabajos',
          timeout,
        );
      },
    );
  }

  Future<void> close() async {
    await _accepting?.cancel();
    _accepting = null;
    for (final client in _clients.toList()) {
      client.destroy();
    }
    _clients.clear();
    await _server.close();
  }

  void _accept(Socket client) {
    connectionsAccepted++;
    openConnections++;
    maxConcurrentConnections = math.max(
      maxConcurrentConnections,
      openConnections,
    );
    _clients.add(client);
    // Todo `Future` de socket con manejador: un RST del cliente no puede
    // tumbar la zona del test.
    unawaited(client.done.then<void>((_) {}, onError: (Object _) {}));

    final buffer = BytesBuilder(copy: true);
    var finished = false;
    late final StreamSubscription<Uint8List> subscription;

    void finish() {
      if (finished) return;
      finished = true;
      openConnections--;
      _clients.remove(client);
      jobs.add(buffer.takeBytes());
      for (final waiter in _waiters.toList()) {
        if (jobs.length >= waiter.count) {
          _waiters.remove(waiter);
          waiter.completer.complete();
        }
      }
    }

    subscription = client.listen(
      (chunk) {
        buffer.add(chunk);
        final cut = cutAfterBytes;
        if (cut != null && buffer.length >= cut) {
          client.destroy();
          finish();
          return;
        }
        if (readDelay > Duration.zero) {
          subscription.pause(Future<void>.delayed(readDelay));
        }
      },
      onError: (Object _) => finish(),
      onDone: () {
        finish();
        if (closeOnEof) {
          unawaited(client.close().then<void>((_) {}, onError: (Object _) {}));
        }
      },
      cancelOnError: true,
    );
  }
}

final class _Waiter {
  _Waiter(this.count);

  final int count;
  final Completer<void> completer = Completer<void>();
}
