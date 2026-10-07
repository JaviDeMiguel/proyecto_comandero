import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proyecto_comandero/app/app.dart';
import 'package:proyecto_comandero/app/role_selection_page.dart';
import 'package:proyecto_comandero/features/settings/application/settings_service.dart';
import 'package:proyecto_comandero/features/settings/data/in_memory_settings_repository.dart';
import 'package:proyecto_comandero/features/settings/domain/app_settings.dart';
import 'package:proyecto_comandero/features/settings/presentation/settings_providers.dart';

/// Almacenamiento que nunca responde (plugin de plataforma colgado).
final class _AlmacenamientoMudo implements SettingsRepository {
  @override
  Future<AppSettings?> load() => Completer<AppSettings?>().future;

  @override
  Future<void> save(AppSettings settings) async {}

  @override
  Future<void> clear() async {}
}

void main() {
  testWidgets('la aplicación arranca y, sin rol, ofrece elegirlo', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsRepositoryProvider.overrideWith(
            (ref) => InMemorySettingsRepository(),
          ),
        ],
        child: const TpvComanderoApp(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(RoleSelectionPage), findsOneWidget);
    expect(find.text('Servidor TPV (tablet)'), findsOneWidget);
    expect(find.text('Comandero (móvil)'), findsOneWidget);
  });

  testWidgets(
    'si el almacenamiento de ajustes no responde, muestra el error con salida',
    (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            settingsRepositoryProvider.overrideWith(
              (ref) => _AlmacenamientoMudo(),
            ),
          ],
          child: const TpvComanderoApp(),
        ),
      );
      await tester.pump(
        kTimeoutAlmacenamientoAjustes + const Duration(seconds: 1),
      );
      await tester.pumpAndSettle();

      expect(find.text('Reintentar'), findsOneWidget);
      expect(find.text('Restablecer ajustes'), findsOneWidget);
    },
  );
}
