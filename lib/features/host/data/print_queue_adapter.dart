import 'dart:typed_data';

import '../../../core/errors/app_exception.dart';
import '../../../core/network/printing/print_queue.dart';
import '../../../core/network/printing/raw_printer_transport.dart';
import '../application/ports.dart';

/// [PrinterPort] sobre la cola de impresión real (`PrintQueue`), que
/// serializa por impresora, reintenta con backoff y reimprime los trabajos
/// fallidos ([RetryablePrinterPort]).
final class PrintQueueAdapter implements RetryablePrinterPort {
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
    PrintRetryPolicy reintento = PrintRetryPolicy.always,
  }) => queue
      .enqueue(endpoint, bytes, description: description, retry: reintento)
      .id;

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
      PrintJobStatus.cancelled => trabajoCancelado,
      PrintJobStatus.queued || PrintJobStatus.printing => null,
    };
  }

  /// `PrintQueue.retry`: mismos bytes, misma política y mismo id.
  @override
  String reintentar(String jobId) => queue.retry(jobId).id;

  @override
  bool nadaEnviado(String jobId) {
    final job = queue.find(jobId);
    if (job == null) {
      throw PrinterException(
        'No existe el trabajo de impresión $jobId (puede haber salido del '
        'historial)',
      );
    }
    return job.nothingSent;
  }

  Future<void> dispose() => queue.dispose();
}
