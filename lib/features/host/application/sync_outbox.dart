import 'dart:async';
import 'dart:math' as math;

import 'package:equatable/equatable.dart';
import 'package:uuid/uuid.dart';

import '../../../core/database/mysql_database.dart' show TransactionException;
import '../../../core/errors/app_exception.dart';
import '../../../core/logging/app_logger.dart';
import '../domain/host_snapshot.dart';
import '../domain/sync_job.dart';
import 'alert_bus.dart';
import 'host_state_store.dart';

const Uuid _uuid = Uuid();

/// Ejecuta un trabajo. Devuelve avisos no bloqueantes; lanza si falló (la
/// cola decide por el tipo de excepción si reintenta, para o lo da por
/// definitivo). Debe ser idempotente: tras un corte puede volver a llamarse
/// con el mismo trabajo.
typedef SyncJobHandler = Future<List<String>> Function(SyncJob job);

/// Foto del estado de la cola para la interfaz.
final class SyncOutboxStatus extends Equatable {
  const SyncOutboxStatus({
    required this.pendientes,
    required this.enError,
    required this.bloqueados,
    required this.enCurso,
    required this.pausada,
    this.motivoPausa,
    this.ultimoExito,
    this.proximoIntentoEn,
    this.tiposEnPausa = const {},
  });

  final int pendientes;
  final int enError;
  final int bloqueados;
  final bool enCurso;

  /// Hay algo en pausa: la cola entera (credenciales, API desactivada) o
  /// algún tipo de trabajo concreto ([tiposEnPausa]). Se levanta con
  /// `SyncOutbox.reanudar`.
  final bool pausada;
  final String? motivoPausa;
  final DateTime? ultimoExito;

  /// Cuándo vence el backoff más cercano, si hay trabajos esperando.
  final DateTime? proximoIntentoEn;

  /// Tipos de trabajo en pausa por falta de configuración (p. ej. stock sin
  /// MySQL) mientras el resto de la cola sigue funcionando.
  final Set<SyncJobTipo> tiposEnPausa;

  bool get todoSincronizado =>
      pendientes == 0 && enError == 0 && bloqueados == 0 && !enCurso;

  @override
  List<Object?> get props => [
    pendientes,
    enError,
    bloqueados,
    enCurso,
    pausada,
    motivoPausa,
    ultimoExito,
    proximoIntentoEn,
    tiposEnPausa,
  ];
}

/// Qué hacer con un trabajo tras un fallo.
enum _Veredicto {
  transitorio,
  definitivo,

  /// Toda la cola en pausa (credenciales, API desactivada).
  pausa,

  /// Solo los trabajos del mismo tipo en pausa (falta configuración).
  pausaTipo,
}

/// Cola persistente y secuencial de trabajos idempotentes hacia el ERP.
///
/// * **Un trabajo en vuelo.** Los trabajos se ejecutan de uno en uno en
///   orden de creación. Las facturas son además FIFO estricto entre sí: una
///   factura pendiente, en backoff o en error bloquea a las posteriores (la
///   serie de FacturaScripts exige fechas no decrecientes). Los demás tipos
///   adelantan a los que esperan.
/// * **Backoff exponencial** (1 s, 2 s, 4 s... hasta 5 min) para los errores
///   transitorios: red, 5xx, IP baneada, deadlock de MySQL, resultado
///   desconocido de una transacción.
/// * **Error definitivo** (validación, 404, SQL inválido, datos corruptos):
///   el trabajo queda en `error` con el mensaje y no se reintenta solo; la
///   interfaz ofrece [reintentar] o [descartar].
/// * **Pausa** (credenciales rechazadas, API desactivada): toda la cola pasa
///   a `bloqueado` hasta [reanudar]. Así nunca se acumulan los cinco fallos
///   de token que banean la IP.
/// * **Pausa por tipo** (`ConfigException`: ERP o MySQL sin configurar para
///   ese trabajo): solo los trabajos de ese tipo pasan a `bloqueado`; el
///   resto de la cola sigue (las facturas no esperan a un stock sin MySQL).
/// * **Reanudación tras reinicio.** Los trabajos viven en el diario local;
///   al arrancar, los que quedaron `enCurso` vuelven a `pendiente` (el
///   servicio del ERP comprueba por clave si ya se hizo) y los tipos con
///   trabajos `bloqueado` arrancan en pausa.
/// * **Encolado atómico.** [encolarEn] añade el trabajo al snapshot que otro
///   servicio está guardando, de modo que la mutación y su trabajo se
///   persisten en la misma escritura; la cola lo detecta al cambiar el
///   diario.
final class SyncOutbox {
  SyncOutbox({
    required this._store,
    required this._alerts,
    DateTime Function()? now,
    this.backoffBase = const Duration(seconds: 1),
    this.backoffMax = const Duration(minutes: 5),
    this.maxHechos = 200,
  }) : _now = now ?? DateTime.now;

  static final Logger _log = appLogger('host.outbox');

  final HostStateStore _store;
  final AlertBus _alerts;
  final DateTime Function() _now;
  final Duration backoffBase;
  final Duration backoffMax;

  /// Trabajos terminados que se conservan en el diario para consulta.
  final int maxHechos;

  final Map<SyncJobTipo, SyncJobHandler> _handlers = {};
  final StreamController<SyncOutboxStatus> _status =
      StreamController<SyncOutboxStatus>.broadcast();
  final StreamController<SyncJob> _terminados =
      StreamController<SyncJob>.broadcast();

  bool _running = false;
  bool _disposed = false;
  bool _pausada = false;
  String? _motivoPausa;
  final Map<SyncJobTipo, String> _tiposEnPausa = {};
  StreamSubscription<HostSnapshot>? _cambiosDiario;
  DateTime? _ultimoExito;
  Future<void>? _inFlight;
  Timer? _timer;

  List<SyncJob> get jobs => _store.snapshot.cola;
  bool get isRunning => _running;

  /// La cola entera o algún tipo de trabajo está en pausa.
  bool get pausada => _pausada || _tiposEnPausa.isNotEmpty;

  /// Tipos de trabajo en pausa por falta de configuración.
  Set<SyncJobTipo> get tiposEnPausa => Set.unmodifiable(_tiposEnPausa.keys);

  /// Cambios de estado de la cola.
  Stream<SyncOutboxStatus> get status => _status.stream;

  /// Cada trabajo que alcanza `hecho` o `error`.
  Stream<SyncJob> get terminados => _terminados.stream;

  SyncOutboxStatus get estado {
    var pendientes = 0;
    var enError = 0;
    var bloqueados = 0;
    DateTime? proximo;
    for (final job in jobs) {
      switch (job.estado) {
        case SyncJobEstado.pendiente || SyncJobEstado.enCurso:
          pendientes++;
          final cuando = job.proximoIntentoEn;
          if (cuando != null && (proximo == null || cuando.isBefore(proximo))) {
            proximo = cuando;
          }
        case SyncJobEstado.error:
          enError++;
        case SyncJobEstado.bloqueado:
          bloqueados++;
        case SyncJobEstado.hecho:
          break;
      }
    }
    return SyncOutboxStatus(
      pendientes: pendientes,
      enError: enError,
      bloqueados: bloqueados,
      enCurso: _inFlight != null,
      pausada: pausada,
      motivoPausa: _motivoPausa ?? _tiposEnPausa.values.firstOrNull,
      ultimoExito: _ultimoExito,
      proximoIntentoEn: proximo,
      tiposEnPausa: Set.unmodifiable(_tiposEnPausa.keys),
    );
  }

  /// Registra el ejecutor de un tipo de trabajo (sustituye al anterior).
  void registerHandler(SyncJobTipo tipo, SyncJobHandler handler) {
    _handlers[tipo] = handler;
    _kick();
  }

  void unregisterHandler(SyncJobTipo tipo) => _handlers.remove(tipo);

  /// Encola un trabajo. Con [id] explícito la operación es idempotente: si ya
  /// existe un trabajo con ese id se devuelve sin crear otro.
  Future<SyncJob> enqueue(
    SyncJobTipo tipo,
    Map<String, Object?> payload, {
    String? id,
  }) async {
    final existente = id == null ? null : _store.snapshot.jobPorId(id);
    if (existente != null) {
      _kick();
      return existente;
    }
    final job = _nuevo(tipo, payload, id ?? _uuid.v4());
    await _store.update((s) => s.conJob(job));
    _log.fine('Encolado ${job.descripcion} (${job.id})');
    _emitStatus();
    _kick();
    return job;
  }

  /// Añade a [snapshot] un trabajo nuevo (idempotente por [id]) sin
  /// persistir nada: el llamador lo usa dentro de su propio
  /// `HostStateStore.update` para que la mutación y el trabajo se guarden en
  /// la misma escritura. Si ya existe un trabajo con ese id devuelve
  /// [snapshot] sin cambios. La cola lo recoge al cambiar el diario.
  HostSnapshot encolarEn(
    HostSnapshot snapshot,
    SyncJobTipo tipo,
    Map<String, Object?> payload, {
    required String id,
  }) {
    if (snapshot.jobPorId(id) != null) return snapshot;
    return snapshot.conJob(_nuevo(tipo, payload, id));
  }

  SyncJob _nuevo(SyncJobTipo tipo, Map<String, Object?> payload, String id) =>
      SyncJob(
        id: id,
        tipo: tipo,
        payload: payload,
        creadoEn: _now(),
        estado: _pausada || _tiposEnPausa.containsKey(tipo)
            ? SyncJobEstado.bloqueado
            : SyncJobEstado.pendiente,
      );

  /// Arranca el procesador. Los trabajos que quedaron `enCurso` en una
  /// sesión anterior vuelven a `pendiente`; si quedaron `bloqueado`, su tipo
  /// arranca en pausa hasta que el usuario (o un cambio de ajustes) la
  /// reanude.
  Future<void> start() async {
    if (_disposed) throw StateError('SyncOutbox cerrado');
    if (_running) return;
    _running = true;
    final tiposBloqueados = <SyncJobTipo>{};
    await _store.update((s) {
      final interrumpidos = s.cola.any(
        (j) => j.estado == SyncJobEstado.enCurso,
      );
      tiposBloqueados.addAll([
        for (final j in s.cola)
          if (j.estado == SyncJobEstado.bloqueado) j.tipo,
      ]);
      if (!interrumpidos) return s;
      return s.copyWith(
        cola: [
          for (final job in s.cola)
            if (job.estado == SyncJobEstado.enCurso)
              job.copyWith(estado: SyncJobEstado.pendiente)
            else
              job,
        ],
      );
    });
    for (final tipo in tiposBloqueados) {
      _tiposEnPausa.putIfAbsent(
        tipo,
        () => 'Sincronización en pausa desde la sesión anterior',
      );
    }
    // Trabajos añadidos con [encolarEn] dentro de la escritura de otro
    // servicio: la cola se entera por el cambio del diario.
    _cambiosDiario ??= _store.changes.listen((_) {
      _emitStatus();
      _kick();
    });
    _emitStatus();
    _kick();
  }

  /// Para el procesador esperando al trabajo en vuelo. No vacía la cola.
  Future<void> stop() async {
    _running = false;
    _timer?.cancel();
    _timer = null;
    final cambios = _cambiosDiario;
    _cambiosDiario = null;
    await cambios?.cancel();
    await _inFlight;
  }

  /// Vuelve a intentar ahora un trabajo en `error` (o adelanta uno en
  /// backoff).
  Future<void> reintentar(String jobId) async {
    final job = _store.snapshot.jobPorId(jobId);
    if (job == null || job.estado == SyncJobEstado.hecho) return;
    if (job.estado == SyncJobEstado.enCurso) return;
    await _store.update(
      (s) => s.conJob(
        job.copyWith(
          estado: SyncJobEstado.pendiente,
          limpiarProximoIntento: true,
        ),
      ),
    );
    _emitStatus();
    _kick();
  }

  /// Retira un trabajo que no se está ejecutando.
  Future<bool> descartar(String jobId) async {
    final job = _store.snapshot.jobPorId(jobId);
    if (job == null || job.estado == SyncJobEstado.enCurso) return false;
    await _store.update(
      (s) => s.copyWith(
        cola: [
          for (final j in s.cola)
            if (j.id != jobId) j,
        ],
      ),
    );
    _log.info('Descartado ${job.descripcion} (${job.id})');
    _emitStatus();
    _kick();
    return true;
  }

  /// Levanta la pausa (global y por tipo): los trabajos `bloqueado` vuelven
  /// a `pendiente`.
  ///
  /// Tras un fallo de credenciales el cliente HTTP del ERP mantiene su
  /// propio bloqueo: usa `HostRuntime.reanudarSincronizacion`, que lo
  /// rearma antes de llamar aquí.
  Future<void> reanudar() async {
    _pausada = false;
    _motivoPausa = null;
    _tiposEnPausa.clear();
    await _store.update(
      (s) => s.copyWith(
        cola: [
          for (final j in s.cola)
            if (j.estado == SyncJobEstado.bloqueado)
              j.copyWith(
                estado: SyncJobEstado.pendiente,
                limpiarProximoIntento: true,
              )
            else
              j,
        ],
      ),
    );
    _emitStatus();
    _kick();
  }

  /// Completa cuando no hay trabajo en vuelo ni ninguno ejecutable ahora.
  Future<void> idle() async {
    while (true) {
      final inFlight = _inFlight;
      if (inFlight != null) {
        await inFlight;
        continue;
      }
      if (_running && !_pausada && _siguiente(_now()) != null) {
        await Future<void>.delayed(Duration.zero);
        continue;
      }
      return;
    }
  }

  Future<void> dispose() async {
    await stop();
    _disposed = true;
    await _status.close();
    await _terminados.close();
  }

  // ---------------------------------------------------------------------------
  // Procesador

  void _kick() {
    if (!_running || _disposed || _pausada || _inFlight != null) return;
    scheduleMicrotask(_tick);
  }

  Future<void> _tick() async {
    if (!_running || _disposed || _pausada || _inFlight != null) return;
    final job = _siguiente(_now());
    if (job == null) {
      _armTimer();
      return;
    }
    final running = _run(job);
    _inFlight = running;
    _emitStatus();
    try {
      await running;
    } finally {
      _inFlight = null;
    }
    _emitStatus();
    _kick();
  }

  /// Primer trabajo ejecutable ahora, respetando el FIFO de facturas.
  SyncJob? _siguiente(DateTime now) {
    var facturasBloqueadas = false;
    for (final job in jobs) {
      if (job.tipo == SyncJobTipo.factura && facturasBloqueadas) continue;
      switch (job.estado) {
        case SyncJobEstado.hecho:
          continue;
        case SyncJobEstado.error ||
            SyncJobEstado.bloqueado ||
            SyncJobEstado.enCurso:
          if (job.tipo == SyncJobTipo.factura) facturasBloqueadas = true;
          continue;
        case SyncJobEstado.pendiente:
          final cuando = job.proximoIntentoEn;
          final vencido = cuando == null || !cuando.isAfter(now);
          if (vencido) return job;
          if (job.tipo == SyncJobTipo.factura) facturasBloqueadas = true;
      }
    }
    return null;
  }

  void _armTimer() {
    _timer?.cancel();
    _timer = null;
    final proximo = estado.proximoIntentoEn;
    if (proximo == null || !_running) return;
    var espera = proximo.difference(_now());
    if (espera.isNegative) espera = Duration.zero;
    _timer = Timer(espera, _kick);
  }

  Future<void> _run(SyncJob job) async {
    final handler = _handlers[job.tipo];
    final enCurso = job.copyWith(
      estado: SyncJobEstado.enCurso,
      intentos: job.intentos + 1,
    );
    await _store.update((s) => s.conJob(enCurso));
    _log.fine('Ejecutando ${job.descripcion} (intento ${enCurso.intentos})');

    try {
      if (handler == null) {
        throw ConfigException(
          'No hay servicio configurado para ${job.tipo.name}',
        );
      }
      final avisos = await handler(enCurso);
      final hecho = enCurso.copyWith(
        estado: SyncJobEstado.hecho,
        terminadoEn: _now(),
        avisos: avisos,
        limpiarError: true,
        limpiarProximoIntento: true,
      );
      _ultimoExito = hecho.terminadoEn;
      await _store.update((s) => _podar(s.conJob(hecho)));
      for (final aviso in avisos) {
        _alerts.aviso('${job.descripcion}: $aviso', origen: 'outbox');
      }
      _terminado(hecho);
    } on Object catch (error, stackTrace) {
      final mensaje = error is AppException ? error.message : error.toString();
      switch (_clasificar(error)) {
        case _Veredicto.transitorio:
          final espera = _backoff(enCurso.intentos);
          final reintento = enCurso.copyWith(
            estado: SyncJobEstado.pendiente,
            ultimoError: mensaje,
            proximoIntentoEn: _now().add(espera),
          );
          _log.warning(
            '${job.descripcion}: fallo transitorio, reintento en $espera',
            error,
          );
          await _store.update((s) => s.conJob(reintento));
        case _Veredicto.definitivo:
          final fallido = enCurso.copyWith(
            estado: SyncJobEstado.error,
            ultimoError: mensaje,
            limpiarProximoIntento: true,
          );
          _log.severe(
            '${job.descripcion}: error definitivo',
            error,
            stackTrace,
          );
          await _store.update((s) => s.conJob(fallido));
          _alerts.error(
            '${job.descripcion} rechazado',
            detalle: mensaje,
            origen: 'outbox',
          );
          _terminado(fallido);
        case _Veredicto.pausaTipo:
          _tiposEnPausa[job.tipo] = mensaje;
          _log.severe('${job.tipo.name} en pausa: $mensaje', error);
          await _store.update(
            (s) => s.copyWith(
              cola: [
                for (final j in s.cola)
                  if (j.id == enCurso.id)
                    enCurso.copyWith(
                      estado: SyncJobEstado.bloqueado,
                      ultimoError: mensaje,
                      limpiarProximoIntento: true,
                    )
                  else if (j.tipo == job.tipo &&
                      j.estado == SyncJobEstado.pendiente)
                    j.copyWith(estado: SyncJobEstado.bloqueado)
                  else
                    j,
              ],
            ),
          );
          _alerts.error(
            'Sincronización de ${_nombreTipo(job.tipo)} en pausa',
            detalle: mensaje,
            origen: 'outbox',
          );
        case _Veredicto.pausa:
          _pausada = true;
          _motivoPausa = mensaje;
          _timer?.cancel();
          _timer = null;
          _log.severe('Cola en pausa: $mensaje', error);
          await _store.update(
            (s) => s.copyWith(
              cola: [
                for (final j in s.cola)
                  if (j.id == enCurso.id)
                    enCurso.copyWith(
                      estado: SyncJobEstado.bloqueado,
                      ultimoError: mensaje,
                      limpiarProximoIntento: true,
                    )
                  else if (j.estado == SyncJobEstado.pendiente)
                    j.copyWith(estado: SyncJobEstado.bloqueado)
                  else
                    j,
              ],
            ),
          );
          _alerts.error(
            'Sincronización con el ERP en pausa',
            detalle: mensaje,
            origen: 'outbox',
          );
      }
    }
  }

  /// `backoffBase · 2^(intentos-1)` acotado a [backoffMax]. El exponente se
  /// limita antes de la potencia: con enteros, `2^63` desborda a negativo y
  /// `2^64` a cero, y el trabajo reintentaría sin espera.
  Duration _backoff(int intentos) {
    final exponente = math.min(math.max(0, intentos - 1), 30);
    final ms = backoffBase.inMilliseconds * math.pow(2.0, exponente);
    final limite = backoffMax.inMilliseconds.toDouble();
    final acotado = math.max(0.0, math.min(ms.toDouble(), limite));
    return Duration(milliseconds: acotado.round());
  }

  static String _nombreTipo(SyncJobTipo tipo) => switch (tipo) {
    SyncJobTipo.descuentoStock => 'stock',
    SyncJobTipo.factura => 'facturas',
    SyncJobTipo.pedidoProveedor => 'pedidos a proveedor',
    SyncJobTipo.asientoZ => 'asientos del Cierre Z',
  };

  static _Veredicto _clasificar(Object error) => switch (error) {
    ErpApiException(isAuthFailure: true) => _Veredicto.pausa,
    ErpApiException(kind: ErpApiErrorKind.disabled) => _Veredicto.pausa,
    ErpApiException(isTransient: true) => _Veredicto.transitorio,
    ErpApiException() => _Veredicto.definitivo,
    TransactionException(outcomeUnknown: true) => _Veredicto.transitorio,
    DatabaseException(isRetryable: true) => _Veredicto.transitorio,
    DatabaseException() => _Veredicto.definitivo,
    NetworkException() => _Veredicto.transitorio,
    ConfigException() => _Veredicto.pausaTipo,
    _ => _Veredicto.definitivo,
  };

  /// Conserva solo los últimos [maxHechos] trabajos terminados.
  HostSnapshot _podar(HostSnapshot s) {
    var hechos = s.cola.where((j) => j.estado == SyncJobEstado.hecho).length;
    if (hechos <= maxHechos) return s;
    final cola = <SyncJob>[];
    for (final job in s.cola) {
      if (job.estado == SyncJobEstado.hecho && hechos > maxHechos) {
        hechos--;
        continue;
      }
      cola.add(job);
    }
    return s.copyWith(cola: cola);
  }

  void _terminado(SyncJob job) {
    if (!_terminados.isClosed) _terminados.add(job);
  }

  void _emitStatus() {
    if (!_status.isClosed) _status.add(estado);
  }
}
