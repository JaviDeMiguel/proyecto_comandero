import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../core/logging/app_logger.dart';
import 'multicast_lock.dart';

/// Recursos de plataforma que el modo host necesita mientras su runtime está
/// en marcha: pantalla siempre encendida (la tablet-servidor no debe
/// suspenderse) y el lock de multidifusión Wi-Fi (Android descarta los
/// broadcast UDP de descubrimiento sin él).
///
/// Ninguna operación lanza: un fallo de plataforma deja el host funcionando
/// en modo degradado y se registra en el log.
abstract interface class HostPlatformHooks {
  /// Activa los recursos. Idempotente.
  Future<void> activar();

  /// Libera los recursos adquiridos. Idempotente.
  Future<void> liberar();
}

/// Implementación real: `wakelock_plus` + [MulticastLock].
final class DefaultHostPlatformHooks implements HostPlatformHooks {
  DefaultHostPlatformHooks({this._multicastLock = const MulticastLock()});

  static final Logger _log = appLogger('platform.host_hooks');

  final MulticastLock _multicastLock;
  bool _activo = false;

  @override
  Future<void> activar() async {
    if (_activo) return;
    _activo = true;
    try {
      await WakelockPlus.enable();
    } on Object catch (error, stackTrace) {
      _log.warning(
        'No se pudo mantener la pantalla encendida',
        error,
        stackTrace,
      );
    }
    final adquirido = await _multicastLock.acquire();
    _log.fine('MulticastLock adquirido: $adquirido');
  }

  @override
  Future<void> liberar() async {
    if (!_activo) return;
    _activo = false;
    try {
      await WakelockPlus.disable();
    } on Object catch (error, stackTrace) {
      _log.warning('No se pudo liberar el wakelock', error, stackTrace);
    }
    await _multicastLock.release();
  }
}

/// Recursos de plataforma del modo host (en tests, un doble).
final hostPlatformHooksProvider = Provider<HostPlatformHooks>(
  (ref) => DefaultHostPlatformHooks(),
);
