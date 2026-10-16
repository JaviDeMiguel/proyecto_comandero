/// `SharedPrefsSettingsRepository.dispose` termina aunque un oyente tenga en
/// pausa su suscripción a [SharedPrefsSettingsRepository.avisos].
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:proyecto_comandero/features/settings/data/secret_store.dart';
import 'package:proyecto_comandero/features/settings/data/shared_prefs_settings_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('dispose no espera a un oyente de avisos en pausa', () async {
    SharedPreferences.setMockInitialValues({});
    final repo = SharedPrefsSettingsRepository(
      prefs: await SharedPreferences.getInstance(),
      secrets: InMemorySecretStore(),
    );
    final suscripcion = repo.avisos.listen((_) {})..pause();
    addTearDown(suscripcion.cancel);

    await expectLater(
      repo.dispose().timeout(const Duration(seconds: 2)),
      completes,
    );
  });
}
