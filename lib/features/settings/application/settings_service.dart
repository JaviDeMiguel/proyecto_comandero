import 'dart:async';

import 'package:uuid/uuid.dart';

import '../../../core/errors/app_exception.dart';
import '../../../core/logging/app_logger.dart';
import '../domain/app_settings.dart';

/// Persistencia de los ajustes (Shared Preferences + almacenamiento seguro,
/// fichero, memoria...). La implementación decide dónde van los secretos.
abstract interface class SettingsRepository {
  /// Ajustes guardados o `null` si el dispositivo no tiene ninguno. Lanza
  /// [ConfigException] si los datos guardados están corruptos.
  Future<AppSettings?> load();

  /// Guarda [settings] completos (incluidos los secretos).
  Future<void> save(AppSettings settings);

  /// Borra todo lo guardado (ajustes y secretos).
  Future<void> clear();
}

/// Capacidad opcional de un [SettingsRepository] que distingue "secreto no
/// leído" de "secreto borrado" (p. ej. cuando el almacenamiento seguro falló
/// al leer): en [SettingsRepository.save] un secreto nulo no leído se
/// conserva, y este método lo borra porque el usuario lo pidió.
abstract interface class BorradoExplicitoDeSecretos {
  /// Guarda [settings] y elimina los secretos que no contenga. Si el guardado
  /// de los ajustes falla, no borra nada.
  Future<void> saveBorrandoSecretos(AppSettings settings);
}

/// Identidad del dispositivo: lo que permite al host reconocer al comandero
/// tras reconectar y lo que el usuario ve en la red local.
final class IdentidadDispositivo {
  const IdentidadDispositivo({
    required this.deviceId,
    required this.deviceName,
  });

  final String deviceId;
  final String deviceName;

  /// Lectura tolerante de la identidad desde el JSON en crudo de unos
  /// ajustes (aunque otras secciones estén corruptas). `null` si no hay un
  /// `deviceId` legible; sin `deviceName` legible se usa 'Dispositivo'.
  static IdentidadDispositivo? desdeJson(Object? json) {
    if (json is! Map<String, Object?>) return null;
    final id = json['deviceId'];
    if (id is! String || id.trim().isEmpty) return null;
    final nombre = json['deviceName'];
    return IdentidadDispositivo(
      deviceId: id,
      deviceName: nombre is String && nombre.trim().isNotEmpty
          ? nombre
          : 'Dispositivo',
    );
  }

  @override
  bool operator ==(Object other) =>
      other is IdentidadDispositivo &&
      other.deviceId == deviceId &&
      other.deviceName == deviceName;

  @override
  int get hashCode => Object.hash(deviceId, deviceName);

  @override
  String toString() => 'IdentidadDispositivo($deviceId, $deviceName)';
}

/// Capacidad opcional de un [SettingsRepository]: rescatar la identidad del
/// dispositivo de unos ajustes guardados que no se pueden cargar enteros.
abstract interface class IdentidadRescatable {
  /// Identidad guardada, leída de forma tolerante, o `null` si no hay o no
  /// se puede leer. No lanza.
  Future<IdentidadDispositivo?> leerIdentidad();
}

/// Restablece unos ajustes guardados que no se pueden cargar (corruptos),
/// sin pasar por [SettingsService]. Si [repositorio] permite rescatar la
/// identidad ([IdentidadRescatable]), guarda los valores por defecto con el
/// mismo `deviceId` y `deviceName` (y sin secretos); si no, lo borra todo y
/// la próxima carga generará una identidad nueva.
///
/// Devuelve la identidad conservada, o `null` si no se pudo conservar.
Future<IdentidadDispositivo?> restablecerAjustesIlegibles(
  SettingsRepository repositorio,
) async {
  IdentidadDispositivo? identidad;
  if (repositorio case final IdentidadRescatable rescatable) {
    try {
      identidad = await rescatable.leerIdentidad();
    } on Object catch (error, stackTrace) {
      appLogger('settings')
          .warning('No se pudo rescatar la identidad', error, stackTrace);
    }
  }
  if (identidad == null) {
    await repositorio.clear();
    return null;
  }
  final settings = AppSettings.defaults(
    deviceId: identidad.deviceId,
    deviceName: identidad.deviceName,
  );
  if (repositorio case final BorradoExplicitoDeSecretos borrable) {
    await borrable.saveBorrandoSecretos(settings);
  } else {
    await repositorio.clear();
    await repositorio.save(settings);
  }
  return identidad;
}

/// Fuente única de los ajustes en memoria: carga, expone el valor actual,
/// serializa las modificaciones y notifica los cambios.
///
/// Uso: `await service.load()` en el arranque; después `current` es síncrono
/// y `changes` emite cada versión guardada (sin repetir la actual).
final class SettingsService {
  /// [newDeviceId] permite fijar el generador de identificadores (tests);
  /// por defecto UUID v4.
  SettingsService(this._repository, {String Function()? newDeviceId})
    : _newDeviceId = newDeviceId ?? const Uuid().v4;

  final SettingsRepository _repository;
  final String Function() _newDeviceId;
  final Logger _log = appLogger('settings');

  final StreamController<AppSettings> _changes =
      StreamController<AppSettings>.broadcast();

  AppSettings? _current;

  /// Cola de escrituras: las modificaciones se aplican una detrás de otra
  /// para que dos `update` concurrentes no se pisen.
  Future<void> _queue = Future<void>.value();

  bool _disposed = false;

  /// `true` tras [load].
  bool get isLoaded => _current != null;

  /// Ajustes vigentes. Lanza [StateError] si aún no se ha llamado a [load].
  AppSettings get current {
    final settings = _current;
    if (settings == null) {
      throw StateError('SettingsService.load() no se ha completado todavía');
    }
    return settings;
  }

  /// Cada versión guardada de los ajustes (tras `update`, `reset` o `load`).
  Stream<AppSettings> get changes => _changes.stream;

  /// Carga los ajustes guardados. Si no existen, crea los valores por defecto
  /// con un `deviceId` nuevo y un nombre `Dispositivo-xxxx`, y los guarda.
  ///
  /// Lanza [ConfigException] si lo guardado está corrupto: no se sobrescribe
  /// para que el usuario pueda decidir (reintentar o `reset`).
  Future<AppSettings> load() async {
    _checkNotDisposed();
    final completer = Completer<AppSettings>();
    _enqueue(() async {
      try {
        var settings = await _repository.load();
        if (settings == null) {
          settings = _nuevosDefaults();
          _log.info('Sin ajustes guardados: creando ${settings.deviceName}');
          await _repository.save(settings);
        }
        _publish(settings);
        completer.complete(settings);
      } catch (error, stackTrace) {
        completer.completeError(_translate(error, stackTrace), stackTrace);
      }
    });
    return completer.future;
  }

  /// Aplica [mutate] sobre los ajustes vigentes, guarda el resultado y lo
  /// emite en [changes]. Si [mutate] devuelve un valor igual al actual no se
  /// guarda ni se notifica nada. Devuelve los ajustes resultantes.
  Future<AppSettings> update(AppSettings Function(AppSettings) mutate) async {
    _checkNotDisposed();
    if (!isLoaded) {
      throw StateError('SettingsService.load() no se ha completado todavía');
    }
    final completer = Completer<AppSettings>();
    _enqueue(() async {
      try {
        final before = current;
        final after = mutate(before);
        if (after.deviceId != before.deviceId) {
          throw const ConfigException(
            'El deviceId no se puede cambiar desde los ajustes',
          );
        }
        if (after == before) {
          completer.complete(before);
          return;
        }
        await _repository.save(after);
        _publish(after);
        completer.complete(after);
      } catch (error, stackTrace) {
        completer.completeError(_translate(error, stackTrace), stackTrace);
      }
    });
    return completer.future;
  }

  /// Vuelve a los valores por defecto conservando la identidad del dispositivo
  /// (`deviceId` y `deviceName`), que no es una preferencia sino lo que
  /// permite al host reconocer al comandero tras reconectar.
  Future<void> reset() async {
    _checkNotDisposed();
    final completer = Completer<void>();
    _enqueue(() async {
      try {
        final previous = _current;
        final settings = previous == null
            ? _nuevosDefaults()
            : AppSettings.defaults(
                deviceId: previous.deviceId,
                deviceName: previous.deviceName,
              );
        // Nada se borra antes de guardar: si el guardado falla, lo anterior
        // (y la identidad del dispositivo) sigue intacto. `save` sobrescribe
        // los ajustes; los secretos se eliminan de forma explícita porque el
        // usuario pidió restablecer.
        if (_repository case final BorradoExplicitoDeSecretos borrable) {
          await borrable.saveBorrandoSecretos(settings);
        } else {
          await _repository.save(settings);
        }
        _log.info('Ajustes restablecidos (${settings.deviceName})');
        _publish(settings);
        completer.complete();
      } catch (error, stackTrace) {
        completer.completeError(_translate(error, stackTrace), stackTrace);
      }
    });
    return completer.future;
  }

  /// Cierra el flujo de cambios. Las operaciones posteriores fallan con
  /// [StateError].
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _queue;
    await _changes.close();
  }

  AppSettings _nuevosDefaults() {
    final deviceId = _newDeviceId();
    if (deviceId.isEmpty) {
      throw const ConfigException('El generador de deviceId devolvió vacío');
    }
    return AppSettings.defaults(
      deviceId: deviceId,
      deviceName: nombrePorDefecto(deviceId),
    );
  }

  /// `Dispositivo-xxxx` con los cuatro últimos caracteres alfanuméricos del
  /// identificador, en mayúsculas.
  static String nombrePorDefecto(String deviceId) {
    final alnum = deviceId.replaceAll(RegExp('[^0-9A-Za-z]'), '');
    final sufijo = alnum.length <= 4
        ? alnum
        : alnum.substring(alnum.length - 4);
    return 'Dispositivo-${sufijo.toUpperCase()}';
  }

  void _publish(AppSettings settings) {
    _current = settings;
    if (!_changes.isClosed) _changes.add(settings);
  }

  void _enqueue(Future<void> Function() task) {
    _queue = _queue.then((_) => task());
  }

  void _checkNotDisposed() {
    if (_disposed) throw StateError('SettingsService ya está cerrado');
  }

  /// Los errores de persistencia llegan tipados del repositorio; cualquier
  /// otro se envuelve en [ConfigException] para que la UI no vea excepciones
  /// crudas de plataforma.
  Object _translate(Object error, StackTrace stackTrace) {
    if (error is AppException) return error;
    _log.severe('Error inesperado en los ajustes', error, stackTrace);
    return ConfigException(
      'No se pudieron guardar o leer los ajustes: $error',
      cause: error,
    );
  }
}
