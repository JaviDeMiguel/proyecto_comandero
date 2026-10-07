import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proyecto_comandero/features/settings/data/in_memory_settings_repository.dart';
import 'package:proyecto_comandero/features/settings/domain/app_settings.dart';
import 'package:proyecto_comandero/features/settings/presentation/settings_providers.dart';

void main() {
  test('carga los valores por defecto, actualiza y notifica', () async {
    final repository = InMemorySettingsRepository();
    final container = ProviderContainer(
      overrides: [settingsRepositoryProvider.overrideWith((ref) => repository)],
    );
    addTearDown(container.dispose);
    final subscription = container.listen(appSettingsProvider, (_, _) {});
    addTearDown(subscription.close);

    final inicial = await container.read(appSettingsProvider.future);
    expect(inicial.deviceId, isNotEmpty);
    expect(inicial.rol, isNull);
    expect(await repository.load(), inicial);

    final actualizado = await container
        .read(appSettingsProvider.notifier)
        .actualizar((s) => s.copyWith(rol: DeviceRole.comandero));
    expect(actualizado.rol, DeviceRole.comandero);
    await pumpEventQueue();
    expect(container.read(appSettingsProvider).value, actualizado);
    expect(await repository.load(), actualizado);

    await container.read(appSettingsProvider.notifier).restablecer();
    await pumpEventQueue();
    final restablecido = container.read(appSettingsProvider).value!;
    expect(restablecido.rol, isNull);
    expect(restablecido.deviceId, inicial.deviceId);
  });

  test('respeta los ajustes ya guardados', () async {
    final guardados = AppSettings.defaults(
      deviceId: 'dev-1',
      deviceName: 'Tablet barra',
    ).copyWith(rol: DeviceRole.host);
    final container = ProviderContainer(
      overrides: [
        settingsRepositoryProvider.overrideWith(
          (ref) => InMemorySettingsRepository(initial: guardados),
        ),
      ],
    );
    addTearDown(container.dispose);

    final ajustes = await container.read(appSettingsProvider.future);
    expect(ajustes, guardados);
  });
}
