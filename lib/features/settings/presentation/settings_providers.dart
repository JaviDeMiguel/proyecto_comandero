/// Proveedores Riverpod de los ajustes, compartidos por el host, el comandero
/// y el shell de la aplicación.
///
/// En tests se sustituye el almacenamiento:
/// ```dart
/// ProviderScope(
///   overrides: [
///     settingsRepositoryProvider.overrideWith(
///       (ref) => InMemorySettingsRepository(initial: ajustes),
///     ),
///   ],
///   child: ...,
/// )
/// ```
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/errors/app_exception.dart';
import '../application/settings_service.dart';
import '../data/shared_prefs_settings_repository.dart';
import '../domain/app_settings.dart';

/// Sin reintentos automáticos: un fallo al abrir o leer los ajustes (datos
/// corruptos, plugin ausente) lo resuelve el usuario desde la UI.
Duration? _sinReintentos(int retryCount, Object error) => null;

/// Tiempo máximo para abrir y leer el almacenamiento de ajustes. Un plugin
/// de plataforma que no responde dejaría la aplicación en la pantalla de
/// carga para siempre; así se muestra el error con "Reintentar".
const Duration kTimeoutAlmacenamientoAjustes = Duration(seconds: 15);

Future<T> _conTimeout<T>(Future<T> future) => future.timeout(
  kTimeoutAlmacenamientoAjustes,
  onTimeout: () => throw const ConfigException(
    'El almacenamiento de ajustes del dispositivo no responde',
  ),
);

/// Almacenamiento de los ajustes: `shared_preferences` + almacenamiento seguro.
final settingsRepositoryProvider = FutureProvider<SettingsRepository>((
  ref,
) async {
  final repository = await _conTimeout(SharedPrefsSettingsRepository.open());
  ref.onDispose(() => unawaited(repository.dispose()));
  return repository;
}, retry: _sinReintentos);

/// Servicio de ajustes ya cargado (la primera vez crea los valores por
/// defecto con un `deviceId` nuevo).
final settingsServiceProvider = FutureProvider<SettingsService>((ref) async {
  final repository = await ref.watch(settingsRepositoryProvider.future);
  final service = SettingsService(repository);
  ref.onDispose(() => unawaited(service.dispose()));
  await _conTimeout(service.load());
  return service;
}, retry: _sinReintentos);

/// Ajustes vigentes; se actualiza con cada cambio guardado.
///
/// Para modificarlos: `ref.read(appSettingsProvider.notifier).actualizar(...)`.
final appSettingsProvider =
    AsyncNotifierProvider<AppSettingsNotifier, AppSettings>(
      AppSettingsNotifier.new,
      retry: _sinReintentos,
    );

final class AppSettingsNotifier extends AsyncNotifier<AppSettings> {
  @override
  Future<AppSettings> build() async {
    final service = await ref.watch(settingsServiceProvider.future);
    // Suscripción antes de leer `current`: no se pierde ningún cambio.
    final subscription = service.changes.listen(
      (settings) => state = AsyncData(settings),
    );
    ref.onDispose(() => unawaited(subscription.cancel()));
    return service.current;
  }

  /// Aplica [mutate] sobre los ajustes vigentes, los guarda y los devuelve.
  Future<AppSettings> actualizar(
    AppSettings Function(AppSettings actuales) mutate,
  ) async {
    final service = await ref.read(settingsServiceProvider.future);
    return service.update(mutate);
  }

  /// Vuelve a los valores por defecto conservando la identidad del
  /// dispositivo.
  Future<void> restablecer() async {
    final service = await ref.read(settingsServiceProvider.future);
    await service.reset();
  }
}
