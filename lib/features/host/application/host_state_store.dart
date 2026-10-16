import 'dart:async';

import '../../../core/logging/app_logger.dart';
import '../../../core/utils/streams.dart';
import '../domain/host_snapshot.dart';
import 'alert_bus.dart';
import 'host_state_repository.dart';

/// Estado vivo del host: un [HostSnapshot] en memoria que todos los servicios
/// mutan de forma atómica y que se persiste tras cada cambio.
///
/// * La mutación es síncrona ([update] aplica la función de inmediato), así
///   que dos peticiones concurrentes sobre la misma mesa nunca se pisan.
/// * Las escrituras en disco se serializan en orden y nunca propagan su
///   error al llamador: un disco lleno no debe impedir tomar comandas. El
///   fallo se avisa por [AlertBus] y queda en [ultimoErrorPersistencia].
final class HostStateStore {
  HostStateStore(this._repository, HostSnapshot initial, [this._alerts])
    : _snapshot = initial;

  static final Logger _log = appLogger('host.state');

  /// Carga el snapshot guardado (o [initial] si no hay ninguno legible).
  static Future<HostStateStore> load(
    HostStateRepository repository, {
    required HostSnapshot Function() initial,
    AlertBus? alerts,
  }) async {
    HostSnapshot? saved;
    try {
      saved = await repository.load();
    } on Object catch (error, stackTrace) {
      _log.severe('No se pudo leer el diario local', error, stackTrace);
      alerts?.error(
        'No se pudo leer el diario local; se empieza de cero',
        detalle: error.toString(),
        origen: 'estado',
      );
    }
    return HostStateStore(repository, saved ?? initial(), alerts);
  }

  final HostStateRepository _repository;
  final AlertBus? _alerts;
  final StreamController<HostSnapshot> _changes =
      StreamController<HostSnapshot>.broadcast();

  HostSnapshot _snapshot;
  Future<void> _saving = Future<void>.value();
  Object? _ultimoErrorPersistencia;
  bool _disposed = false;

  HostSnapshot get snapshot => _snapshot;

  /// Cada snapshot nuevo tras [update] (broadcast).
  Stream<HostSnapshot> get changes => _changes.stream;

  /// Error de la última escritura, o `null` si salió bien.
  Object? get ultimoErrorPersistencia => _ultimoErrorPersistencia;

  /// Aplica [mutate] al snapshot actual y programa su persistencia.
  /// Devuelve el snapshot resultante; el `Future` completa cuando la
  /// escritura (correcta o no) ha terminado.
  Future<HostSnapshot> update(HostSnapshot Function(HostSnapshot) mutate) {
    if (_disposed) throw StateError('HostStateStore cerrado');
    final next = mutate(_snapshot);
    if (identical(next, _snapshot)) return Future.value(next);
    _snapshot = next;
    if (!_changes.isClosed) _changes.add(next);
    final saving = _saving.then((_) => _persist(next));
    _saving = saving;
    return saving.then((_) => next);
  }

  /// Espera a que todas las escrituras pendientes terminen.
  Future<void> flush() => _saving;

  Future<void> _persist(HostSnapshot snapshot) async {
    try {
      await _repository.save(snapshot);
      if (_ultimoErrorPersistencia != null) {
        _ultimoErrorPersistencia = null;
        _alerts?.info('Diario local recuperado', origen: 'estado');
      }
    } on Object catch (error, stackTrace) {
      _log.severe('No se pudo guardar el diario local', error, stackTrace);
      if (_ultimoErrorPersistencia == null) {
        _alerts?.error(
          'No se pudo guardar el diario local',
          detalle: error.toString(),
          origen: 'estado',
        );
      }
      _ultimoErrorPersistencia = error;
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    await _saving;
    cerrarSinEsperar(_changes);
  }
}
