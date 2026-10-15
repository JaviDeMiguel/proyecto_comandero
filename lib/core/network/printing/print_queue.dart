import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:uuid/uuid.dart';

import '../../errors/app_exception.dart';
import '../../logging/app_logger.dart';
import 'raw_printer_transport.dart';

final Logger _log = appLogger('network.printing');
const Uuid _uuid = Uuid();

/// Estado de un trabajo de impresión.
enum PrintJobStatus {
  /// En cola: esperando turno o esperando para reintentar tras un fallo
  /// (en ese caso `attempts > 0` y `lastError != null`).
  queued,

  /// Enviándose ahora mismo a la impresora.
  printing,

  /// Entregado a la impresora.
  done,

  /// Agotó los intentos. Puede reimprimirse con `PrintQueue.retry`.
  failed,

  /// Retirado de la cola antes de enviarse.
  cancelled;

  /// Estado terminal: el trabajo ya no cambiará salvo `retry` de un [failed].
  bool get isFinished => switch (this) {
    done || failed || cancelled => true,
    queued || printing => false,
  };
}

/// Foto inmutable de un trabajo de impresión. Cada cambio de estado produce
/// una instancia nueva, de modo que la UI puede conservar y comparar fotos sin
/// que cambien bajo sus pies.
@immutable
final class PrintJob {
  const PrintJob({
    required this.id,
    required this.endpoint,
    required this.description,
    required this.byteCount,
    required this.status,
    required this.createdAt,
    this.attempts = 0,
    this.lastError,
    this.finishedAt,
    this.nothingSent = true,
  });

  final String id;
  final PrinterEndpoint endpoint;

  /// Texto para la interfaz (p. ej. "Comanda mesa 4 · cocina").
  final String description;
  final int byteCount;
  final PrintJobStatus status;

  /// Envíos intentados en total, incluidos los de reimpresiones con `retry`.
  final int attempts;

  /// Motivo del último intento fallido; `null` si el último salió bien.
  final String? lastError;
  final DateTime createdAt;

  /// Momento en que alcanzó un estado terminal.
  final DateTime? finishedAt;

  /// `true` mientras ningún intento (tampoco los de las reimpresiones con
  /// `retry`) haya pasado de la conexión: aún no hubo ninguno o todos
  /// fallaron al conectar ([PrinterConnectException]), así que no salió
  /// ningún byte. Pasa a `false` en cuanto un intento conecta (salga bien o
  /// falle al escribir o al cerrar: pudo salir parte del documento) o falla
  /// con un error no tipado, y ya no vuelve a `true`. Una factura fallida
  /// con `nothingSent` puede reencolarse con sus mismos bytes sin duplicar
  /// nada.
  final bool nothingSent;

  bool get isFinished => status.isFinished;

  PrintJob _next({
    required PrintJobStatus status,
    required String? lastError,
    required DateTime? finishedAt,
    int? attempts,
    bool? nothingSent,
  }) => PrintJob(
    id: id,
    endpoint: endpoint,
    description: description,
    byteCount: byteCount,
    status: status,
    createdAt: createdAt,
    attempts: attempts ?? this.attempts,
    lastError: lastError,
    finishedAt: finishedAt,
    nothingSent: nothingSent ?? this.nothingSent,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PrintJob &&
          other.id == id &&
          other.endpoint == endpoint &&
          other.description == description &&
          other.byteCount == byteCount &&
          other.status == status &&
          other.attempts == attempts &&
          other.lastError == lastError &&
          other.createdAt == createdAt &&
          other.finishedAt == finishedAt &&
          other.nothingSent == nothingSent;

  @override
  int get hashCode => Object.hash(
    id,
    endpoint,
    description,
    byteCount,
    status,
    attempts,
    lastError,
    createdAt,
    finishedAt,
    nothingSent,
  );

  @override
  String toString() =>
      'PrintJob($id, "$description" → $endpoint, ${status.name}, '
      'intentos: $attempts${lastError == null ? '' : ', error: $lastError'})';
}

/// Política de reintento de un trabajo: qué fallos del transporte se repiten
/// con los mismos bytes.
enum PrintRetryPolicy {
  /// Cualquier fallo se reintenta (entrega «al menos una vez»). Un envío que
  /// falla a mitad puede haber impreso parte del ticket y el reintento lo
  /// imprime entero otra vez: para una comanda, una repetida es preferible a
  /// una perdida.
  always,

  /// Solo se reintenta si el intento falló al conectar
  /// ([PrinterConnectException]): no salió ningún byte, así que repetir no
  /// duplica nada. Un fallo de escritura o de cierre termina el trabajo como
  /// fallido en ese mismo intento. Es la política de las facturas: el
  /// ORIGINAL no puede salir dos veces.
  connectOnly;

  /// Si un intento que falló con [error] debe repetirse bajo esta política.
  /// Un error no tipado (de un transporte ajeno) no garantiza que no saliera
  /// nada, así que [connectOnly] tampoco lo reintenta.
  bool allowsRetry(Object error) => switch (this) {
    PrintRetryPolicy.always => true,
    PrintRetryPolicy.connectOnly => error is PrinterConnectException,
  };
}

/// Límites de intentos, esperas y memoria de [PrintQueue].
@immutable
final class PrintQueueOptions {
  const PrintQueueOptions({
    this.maxAttempts = 3,
    this.retryDelay = const Duration(seconds: 1),
    this.maxRetryDelay = const Duration(seconds: 30),
    this.maxHistory = 100,
    this.maxPending = 200,
  }) : assert(maxAttempts >= 1, 'maxAttempts debe ser al menos 1'),
       assert(maxHistory >= 0, 'maxHistory no puede ser negativo'),
       assert(maxPending >= 1, 'maxPending debe ser al menos 1');

  /// Envíos que se intentan antes de dar el trabajo por fallido.
  final int maxAttempts;

  /// Espera antes del primer reintento; se duplica en cada reintento
  /// posterior (1 s, 2 s, 4 s...) hasta [maxRetryDelay].
  final Duration retryDelay;

  /// Tope de la espera creciente, para que un [maxAttempts] alto no deje una
  /// impresora parada minutos entre intentos.
  final Duration maxRetryDelay;

  /// Trabajos terminados que se conservan para consulta y reimpresión.
  final int maxHistory;

  /// Trabajos sin terminar admitidos por impresora. Una impresora apagada
  /// durante un servicio acumularía comandas (y sus bytes) sin límite.
  final int maxPending;
}

/// Cola de impresión: serializa los trabajos de cada impresora y reintenta
/// los fallos.
///
/// * **FIFO estricto por impresora.** Nunca hay dos envíos simultáneos al
///   mismo [PrinterEndpoint] ni se adelanta un trabajo a otro: el orden en que
///   salen las comandas de cocina es el orden en que se encolaron. Mientras un
///   trabajo espera para reintentar sigue ocupando la cabeza de su cola.
/// * **Impresoras distintas, en paralelo.** Una impresora apagada no retrasa a
///   las demás.
/// * **Entrega "al menos una vez" por defecto.** Un envío que falla a mitad
///   puede haber impreso parte del ticket, y el reintento lo imprime entero
///   otra vez. Se prefiere una comanda repetida a una perdida. Cada trabajo
///   puede pedir otra política ([PrintRetryPolicy.connectOnly]): una factura
///   solo se reintenta si no se llegó a conectar, porque su ORIGINAL no puede
///   salir dos veces.
///
/// La garantía de orden solo vale dentro de una instancia: usa una única
/// [PrintQueue] por proceso y no envíes por el transporte al margen de ella.
final class PrintQueue {
  /// [now] permite fijar el reloj en tests.
  PrintQueue({
    required this.transport,
    this.options = const PrintQueueOptions(),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final RawPrinterTransport transport;
  final PrintQueueOptions options;
  final DateTime Function() _now;

  /// Todos los trabajos conocidos, en orden de creación.
  final Map<String, _Entry> _entries = <String, _Entry>{};

  /// Una cola por impresora; solo existe mientras tiene trabajos sin terminar.
  final Map<PrinterEndpoint, _Lane> _lanes = <PrinterEndpoint, _Lane>{};

  /// Trabajos terminados, del que terminó antes al más reciente.
  final ListQueue<_Entry> _finished = ListQueue<_Entry>();

  final StreamController<PrintJob> _updates =
      StreamController<PrintJob>.broadcast();

  bool _disposed = false;
  Future<void>? _disposal;

  /// Cada cambio de estado de cada trabajo, como foto nueva de [PrintJob].
  ///
  /// Es *broadcast* y no repite eventos pasados: quien se suscriba tarde debe
  /// leer primero [jobs]. Se cierra con [dispose].
  Stream<PrintJob> get updates => _updates.stream;

  /// Trabajos pendientes e historial reciente, del más antiguo al más nuevo
  /// por fecha de creación (un `retry` no cambia la posición en la lista).
  List<PrintJob> get jobs =>
      List<PrintJob>.unmodifiable(_entries.values.map((entry) => entry.job));

  /// Foto actual de un trabajo, o `null` si no existe o ya salió del historial.
  PrintJob? find(String jobId) => _entries[jobId]?.job;

  /// Trabajos sin terminar (en cola o imprimiéndose) de una impresora.
  int pendingFor(PrinterEndpoint endpoint) =>
      _lanes[endpoint]?.pending.length ?? 0;

  /// Bytes de trabajos que la cola mantiene en memoria: los pendientes y los
  /// fallidos del historial (se conservan para poder reimprimirlos). Los
  /// terminados bien y los cancelados no retienen nada.
  int get retainedBytes => _entries.values.fold(
    0,
    (total, entry) => total + (entry.bytes?.length ?? 0),
  );

  /// Encola [bytes] para [endpoint] y devuelve el trabajo en estado
  /// [PrintJobStatus.queued]. El envío no empieza hasta que termina el código
  /// síncrono del llamante, así que encolar y cancelar a continuación es
  /// determinista.
  ///
  /// [bytes] no se copia (puede ser un logo rasterizado de cientos de KB): no
  /// lo modifiques después de encolarlo.
  ///
  /// [retry] fija qué fallos se reintentan (por defecto, cualquiera); una
  /// reimpresión posterior con [PrintQueue.retry] conserva esa política.
  ///
  /// Lanza [ValidationException] si [bytes] está vacío (un trabajo "impreso"
  /// del que no sale papel engañaría al camarero) y [PrinterException] si la
  /// cola está cerrada o esa impresora ya acumula `maxPending` trabajos.
  PrintJob enqueue(
    PrinterEndpoint endpoint,
    Uint8List bytes, {
    required String description,
    PrintRetryPolicy retry = PrintRetryPolicy.always,
  }) {
    _ensureOpen();
    if (bytes.isEmpty) {
      throw ValidationException(
        "El trabajo de impresión '$description' no contiene datos",
      );
    }
    _ensureCapacity(endpoint);

    final job = PrintJob(
      id: _uuid.v4(),
      endpoint: endpoint,
      description: description,
      byteCount: bytes.length,
      status: PrintJobStatus.queued,
      createdAt: _now(),
    );
    final entry = _Entry(job, bytes, retry: retry);
    _entries[job.id] = entry;
    _schedule(entry);
    _emit(job);
    return job;
  }

  /// Completa con el trabajo cuando alcanza `done`, `failed` o `cancelled`
  /// (de inmediato si ya lo está). Tras un [retry], una nueva llamada espera
  /// al resultado de la reimpresión.
  ///
  /// Falla con [PrinterException] si el trabajo no existe o ya salió del
  /// historial.
  Future<PrintJob> whenFinished(String jobId) {
    final entry = _entries[jobId];
    if (entry == null) {
      return Future<PrintJob>.error(_unknownJob(jobId), StackTrace.current);
    }
    if (entry.job.isFinished) return Future<PrintJob>.value(entry.job);
    return (entry.waiter ??= Completer<PrintJob>()).future;
  }

  /// Retira de la cola un trabajo que aún no se está enviando (incluido uno
  /// que espera para reintentar). Devuelve `false` si no existe, ya terminó o
  /// está en pleno envío: un envío en curso no se interrumpe porque dejaría un
  /// ticket a medias sin corte de papel.
  bool cancel(String jobId) {
    final entry = _entries[jobId];
    if (entry == null || entry.job.status != PrintJobStatus.queued) {
      return false;
    }
    _cancelQueued(entry);
    return true;
  }

  /// Reencola un trabajo [PrintJobStatus.failed] al final de la cola de su
  /// impresora, con un nuevo ciclo completo de intentos. Conserva el `id` (la
  /// UI sigue la misma fila) y acumula `attempts` y `nothingSent`.
  ///
  /// Lanza [PrinterException] si el trabajo no existe, no está fallido, la
  /// cola está cerrada o la impresora ya acumula `maxPending` trabajos.
  PrintJob retry(String jobId) {
    _ensureOpen();
    final entry = _entries[jobId];
    if (entry == null) throw _unknownJob(jobId);
    if (entry.job.status != PrintJobStatus.failed || entry.bytes == null) {
      throw PrinterException(
        "Solo se puede reimprimir un trabajo fallido; '"
        "${entry.job.description}' está en estado ${entry.job.status.name}",
      );
    }
    _ensureCapacity(entry.job.endpoint);

    _finished.remove(entry);
    entry.job = entry.job._next(
      status: PrintJobStatus.queued,
      lastError: entry.job.lastError,
      finishedAt: null,
    );
    _schedule(entry);
    _emit(entry.job);
    return entry.job;
  }

  /// Cierra la cola: cancela lo que aún no se está enviando, espera a que
  /// terminen los envíos en curso (sin más reintentos) y cierra [updates].
  /// Es idempotente; después [enqueue] y [retry] lanzan [PrinterException].
  Future<void> dispose() => _disposal ??= _dispose();

  Future<void> _dispose() async {
    _disposed = true;
    final workers = <Future<void>>[];
    for (final lane in _lanes.values.toList()) {
      for (final entry in lane.pending.toList()) {
        if (entry.job.status == PrintJobStatus.queued) _cancelQueued(entry);
      }
      final worker = lane.worker;
      if (worker != null) workers.add(worker);
    }
    await Future.wait(workers);
    // Sin `await`: el cierre de un stream broadcast no completa mientras
    // quede un oyente en pausa, y eso no debe bloquear el apagado.
    unawaited(_updates.close());
  }

  void _ensureOpen() {
    if (_disposed) {
      throw const PrinterException('La cola de impresión está cerrada');
    }
  }

  void _ensureCapacity(PrinterEndpoint endpoint) {
    final limit = math.max(1, options.maxPending);
    if (pendingFor(endpoint) >= limit) {
      throw PrinterException(
        'La cola de la impresora $endpoint está llena ($limit trabajos '
        'pendientes). Compruebe la impresora',
      );
    }
  }

  PrinterException _unknownJob(String jobId) => PrinterException(
    'No existe el trabajo de impresión $jobId (puede haber salido del '
    'historial)',
  );

  void _schedule(_Entry entry) {
    final endpoint = entry.job.endpoint;
    final lane = _lanes.putIfAbsent(endpoint, _Lane.new);
    lane.pending.add(entry);
    lane.worker ??= Future<void>.microtask(() => _drain(endpoint, lane));
  }

  /// Único consumidor de la cola de una impresora: procesa la cabeza hasta que
  /// termina y solo entonces pasa al siguiente. Que haya un solo `_drain` por
  /// impresora es lo que garantiza el FIFO y que no se intercalen bytes.
  Future<void> _drain(PrinterEndpoint endpoint, _Lane lane) async {
    while (lane.pending.isNotEmpty) {
      final entry = lane.pending.first;
      await _process(lane, entry);
      // `_process` siempre deja el trabajo fuera de la cola; esto solo
      // asegura que un fallo de esa invariante no se convierta en bucle.
      if (lane.pending.isNotEmpty && identical(lane.pending.first, entry)) {
        lane.pending.removeFirst();
      }
    }
    lane.worker = null;
    if (identical(_lanes[endpoint], lane)) _lanes.remove(endpoint);
  }

  Future<void> _process(_Lane lane, _Entry entry) async {
    final maxAttempts = math.max(1, options.maxAttempts);
    var round = 0;
    while (true) {
      round++;
      final bytes = entry.bytes;
      if (bytes == null) return;
      _transition(
        entry,
        status: PrintJobStatus.printing,
        attempts: entry.job.attempts + 1,
        lastError: entry.job.lastError,
      );

      final error = await _attempt(entry, bytes, round, maxAttempts);
      // Solo un fallo al conectar garantiza que el intento no envió nada.
      final nothingSent =
          entry.job.nothingSent && error is PrinterConnectException;
      if (error == null) {
        _finish(
          lane,
          entry,
          PrintJobStatus.done,
          lastError: null,
          nothingSent: false,
        );
        return;
      }
      final failure = error is AppException ? error.message : error.toString();
      // Sin intentos restantes, con la cola cerrándose o con un fallo que la
      // política del trabajo no permite repetir (una factura que pudo enviar
      // bytes), el trabajo queda fallido en este mismo intento.
      if (round >= maxAttempts ||
          _disposed ||
          !entry.retry.allowsRetry(error)) {
        _finish(
          lane,
          entry,
          PrintJobStatus.failed,
          lastError: failure,
          nothingSent: nothingSent,
        );
        return;
      }

      // Vuelve a `queued` sin soltar la cabeza de la cola: así puede
      // cancelarse durante la espera, pero el siguiente no se le adelanta.
      _transition(
        entry,
        status: PrintJobStatus.queued,
        lastError: failure,
        nothingSent: nothingSent,
      );
      await _backoff(lane, round);
      if (entry.job.status != PrintJobStatus.queued) return;
    }
  }

  /// Un envío de [bytes]. Devuelve `null` si se entregó, o el error del
  /// intento: cualquiera (también uno no tipado de un transporte ajeno) se
  /// registra como fallo del intento, porque la cola no puede morir por ello.
  Future<Object?> _attempt(
    _Entry entry,
    Uint8List bytes,
    int round,
    int maxAttempts,
  ) async {
    try {
      await transport.send(entry.job.endpoint, bytes);
      return null;
    } on Object catch (error, stackTrace) {
      final retryable = entry.retry.allowsRetry(error);
      _log.warning(
        "Fallo al imprimir '${entry.job.description}' en "
        '${entry.job.endpoint} (intento $round de $maxAttempts'
        '${retryable ? '' : ', sin reintento: ${entry.retry.name}'})',
        error,
        error is AppException ? null : stackTrace,
      );
      return error;
    }
  }

  /// Espera antes del reintento; `cancel` y `dispose` la interrumpen.
  Future<void> _backoff(_Lane lane, int failedAttempts) async {
    final wake = Completer<void>();
    final timer = Timer(_retryDelayAfter(failedAttempts), () {
      if (!wake.isCompleted) wake.complete();
    });
    lane.backoff = wake;
    await wake.future;
    timer.cancel();
    lane.backoff = null;
  }

  Duration _retryDelayAfter(int failedAttempts) {
    final base = options.retryDelay.inMicroseconds;
    final cap = options.maxRetryDelay.inMicroseconds;
    if (base <= 0) return Duration.zero;
    // Desplazamiento acotado para no desbordar con un maxAttempts absurdo.
    final doubled = base << math.min(failedAttempts - 1, 30);
    return Duration(microseconds: math.min(doubled, math.max(cap, base)));
  }

  void _cancelQueued(_Entry entry) {
    final lane = _lanes[entry.job.endpoint];
    if (lane != null) {
      final wasHead =
          lane.pending.isNotEmpty && identical(lane.pending.first, entry);
      lane.pending.remove(entry);
      // Si estaba esperando para reintentar, despierta a su `_process`.
      final backoff = lane.backoff;
      if (wasHead && backoff != null && !backoff.isCompleted) {
        backoff.complete();
      }
    }
    _finalize(entry, PrintJobStatus.cancelled, lastError: entry.job.lastError);
  }

  void _finish(
    _Lane lane,
    _Entry entry,
    PrintJobStatus status, {
    required String? lastError,
    required bool nothingSent,
  }) {
    lane.pending.remove(entry);
    if (status == PrintJobStatus.failed) {
      _log.severe(
        "Trabajo '${entry.job.description}' fallido en ${entry.job.endpoint} "
        'tras ${entry.job.attempts} intentos: $lastError',
      );
    }
    _finalize(entry, status, lastError: lastError, nothingSent: nothingSent);
  }

  void _finalize(
    _Entry entry,
    PrintJobStatus status, {
    required String? lastError,
    bool? nothingSent,
  }) {
    // Solo los fallidos conservan los bytes (para `retry`): el historial no
    // debe retener megas de tickets ya impresos.
    if (status != PrintJobStatus.failed) entry.bytes = null;
    entry.job = entry.job._next(
      status: status,
      lastError: lastError,
      finishedAt: _now(),
      nothingSent: nothingSent,
    );

    _finished.add(entry);
    final keep = math.max(0, options.maxHistory);
    while (_finished.length > keep) {
      final evicted = _finished.removeFirst();
      evicted.bytes = null;
      _entries.remove(evicted.job.id);
    }

    _emit(entry.job);
    final waiter = entry.waiter;
    entry.waiter = null;
    waiter?.complete(entry.job);
  }

  void _transition(
    _Entry entry, {
    required PrintJobStatus status,
    required String? lastError,
    int? attempts,
    bool? nothingSent,
  }) {
    entry.job = entry.job._next(
      status: status,
      attempts: attempts,
      lastError: lastError,
      finishedAt: null,
      nothingSent: nothingSent,
    );
    _emit(entry.job);
  }

  void _emit(PrintJob job) {
    if (!_updates.isClosed) _updates.add(job);
  }
}

/// Estado mutable interno de un trabajo: la foto pública vigente, los bytes y
/// la política de reintento.
final class _Entry {
  _Entry(this.job, this.bytes, {required this.retry});

  PrintJob job;

  /// `null` en cuanto dejan de hacer falta (ver `PrintQueue._finalize`).
  Uint8List? bytes;

  /// Fijada al encolar; una reimpresión con `PrintQueue.retry` la conserva.
  final PrintRetryPolicy retry;
  Completer<PrintJob>? waiter;
}

/// Cola de una impresora. La cabeza de [pending] es el trabajo que se está
/// enviando o que espera para reintentar.
final class _Lane {
  final ListQueue<_Entry> pending = ListQueue<_Entry>();
  Future<void>? worker;

  /// Espera de reintento en curso del trabajo en cabeza, si la hay.
  Completer<void>? backoff;
}
