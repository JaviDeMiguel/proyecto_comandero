import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:proyecto_comandero/core/errors/app_exception.dart';
import 'package:proyecto_comandero/core/network/printing/raw_printer_transport.dart';

/// Un envío registrado por [FakeTransport].
final class SentJob {
  SentJob(this.endpoint, this.bytes);

  final PrinterEndpoint endpoint;

  /// Copia de los bytes en el momento del envío.
  final Uint8List bytes;
}

/// Transporte en memoria para probar `PrintQueue` sin sockets.
///
/// Permite simular fallos transitorios ([failuresBeforeSuccess]), fallos
/// concretos en orden ([failNext]), retener los envíos hasta que el test los
/// libere ([holdSends] + [held]) y comprobar cuántos envíos hubo a la vez.
final class FakeTransport implements RawPrinterTransport {
  FakeTransport({this.failuresBeforeSuccess = 0, this.holdSends = false});

  /// Envíos que fallarán con [PrinterException] antes de empezar a funcionar.
  int failuresBeforeSuccess;

  /// Fallos programados: cada envío consume y lanza el primero, antes de
  /// contar [failuresBeforeSuccess]. Permite distinguir un fallo de conexión
  /// ([PrinterConnectException]) de uno de escritura o cierre
  /// ([PrinterException]) o de una excepción ajena al transporte.
  final List<Exception> faults = <Exception>[];

  /// Programa [error] para los próximos [times] envíos.
  void failNext(Exception error, {int times = 1}) {
    for (var i = 0; i < times; i++) {
      faults.add(error);
    }
  }

  /// Si es `true`, cada envío se queda esperando a que el test complete el
  /// `Completer` correspondiente de [held].
  bool holdSends;

  /// Envíos retenidos, en orden de llegada. Completar uno lo deja continuar.
  final List<Completer<void>> held = <Completer<void>>[];

  /// Todos los intentos (fallidos o no), en orden.
  final List<PrinterEndpoint> attempts = <PrinterEndpoint>[];

  /// Envíos que terminaron bien, en orden.
  final List<SentJob> sent = <SentJob>[];

  final Map<PrinterEndpoint, int> _active = <PrinterEndpoint, int>{};
  final List<_HoldWaiter> _holdWaiters = <_HoldWaiter>[];

  int maxConcurrentTotal = 0;
  int maxConcurrentSameEndpoint = 0;

  /// Completa cuando hay al menos [count] envíos retenidos en [held].
  Future<void> whenHeld(
    int count, {
    Duration timeout = const Duration(seconds: 5),
  }) {
    if (held.length >= count) return Future<void>.value();
    final waiter = _HoldWaiter(count);
    _holdWaiters.add(waiter);
    return waiter.completer.future.timeout(
      timeout,
      onTimeout: () {
        _holdWaiters.remove(waiter);
        throw TimeoutException(
          'Solo hay ${held.length} de $count envíos retenidos',
          timeout,
        );
      },
    );
  }

  /// Libera todos los envíos retenidos hasta ahora.
  void releaseAll() {
    for (final completer in held) {
      if (!completer.isCompleted) completer.complete();
    }
  }

  @override
  Future<void> send(PrinterEndpoint endpoint, Uint8List bytes) async {
    attempts.add(endpoint);
    _enter(endpoint);
    try {
      if (holdSends) {
        final gate = Completer<void>();
        held.add(gate);
        for (final waiter in _holdWaiters.toList()) {
          if (held.length >= waiter.count) {
            _holdWaiters.remove(waiter);
            waiter.completer.complete();
          }
        }
        await gate.future;
      }
      if (faults.isNotEmpty) throw faults.removeAt(0);
      if (failuresBeforeSuccess > 0) {
        failuresBeforeSuccess--;
        throw PrinterException('Fallo simulado al imprimir en $endpoint');
      }
      sent.add(SentJob(endpoint, Uint8List.fromList(bytes)));
    } finally {
      _leave(endpoint);
    }
  }

  void _enter(PrinterEndpoint endpoint) {
    final active = (_active[endpoint] ?? 0) + 1;
    _active[endpoint] = active;
    maxConcurrentSameEndpoint = math.max(maxConcurrentSameEndpoint, active);
    final total = _active.values.fold(0, (sum, value) => sum + value);
    maxConcurrentTotal = math.max(maxConcurrentTotal, total);
  }

  void _leave(PrinterEndpoint endpoint) {
    final active = (_active[endpoint] ?? 1) - 1;
    if (active <= 0) {
      _active.remove(endpoint);
    } else {
      _active[endpoint] = active;
    }
  }
}

final class _HoldWaiter {
  _HoldWaiter(this.count);

  final int count;
  final Completer<void> completer = Completer<void>();
}
