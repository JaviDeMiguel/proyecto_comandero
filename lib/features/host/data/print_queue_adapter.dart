import 'dart:typed_data';

import '../../../core/errors/app_exception.dart';
import '../../../core/network/printing/print_queue.dart';
import '../../../core/network/printing/raw_printer_transport.dart';
import '../application/ports.dart';

/// [PrinterPort] sobre la cola de impresión real (`PrintQueue`), que
/// serializa por impresora y reintenta con backoff.
final class PrintQueueAdapter implements PrinterPort {
  PrintQueueAdapter(this.queue);

  /// Cola sobre un `RawPrinterTransport` (normalmente `EscPosSocketPrinter`).
  factory PrintQueueAdapter.forTransport(
    RawPrinterTransport transport, {
    PrintQueueOptions options = const PrintQueueOptions(),
    DateTime Function()? now,
  }) => PrintQueueAdapter(
    PrintQueue(transport: transport, options: options, now: now),
  );

  final PrintQueue queue;

  @override
  String imprimir(
    PrinterEndpoint endpoint,
    Uint8List bytes, {
    required String description,
  }) => queue.enqueue(endpoint, bytes, description: description).id;

  @override
  Future<String?> terminado(String jobId) async {
    final PrintJob job;
    try {
      job = await queue.whenFinished(jobId);
    } on PrinterException catch (error) {
      return error.message;
    }
    return switch (job.status) {
      PrintJobStatus.done => null,
      PrintJobStatus.failed => job.lastError ?? 'agotó los reintentos',
      PrintJobStatus.cancelled => 'cancelado',
      PrintJobStatus.queued || PrintJobStatus.printing => null,
    };
  }

  Future<void> dispose() => queue.dispose();
}
