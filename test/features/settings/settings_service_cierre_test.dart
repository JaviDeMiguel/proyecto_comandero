/// `SettingsService.dispose` termina aunque un oyente tenga en pausa su
/// suscripción a [SettingsService.changes].
library;

import 'package:proyecto_comandero/features/settings/application/settings_service.dart';
import 'package:proyecto_comandero/features/settings/data/in_memory_settings_repository.dart';
import 'package:test/test.dart';

void main() {
  test('dispose no espera a un oyente de changes en pausa', () async {
    final service = SettingsService(InMemorySettingsRepository());
    final suscripcion = service.changes.listen((_) {})..pause();
    addTearDown(suscripcion.cancel);

    await expectLater(
      service.dispose().timeout(const Duration(seconds: 2)),
      completes,
    );
  });
}
