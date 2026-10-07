import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proyecto_comandero/app/theme.dart';
import 'package:proyecto_comandero/features/sala/domain/enrutamiento_comandas.dart';
import 'package:proyecto_comandero/features/sala/domain/linea_comanda.dart';
import 'package:proyecto_comandero/features/settings/data/in_memory_settings_repository.dart';
import 'package:proyecto_comandero/features/settings/domain/app_settings.dart';
import 'package:proyecto_comandero/features/settings/presentation/settings_diagnostics.dart';
import 'package:proyecto_comandero/features/settings/presentation/settings_page.dart';
import 'package:proyecto_comandero/features/settings/presentation/settings_providers.dart';

import '../app/app_fakes.dart';

AppSettings ajustes(DeviceRole rol) => AppSettings.defaults(
  deviceId: 'd-1',
  deviceName: 'Tablet',
).copyWith(rol: rol);

Future<void> asentar(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

final Finder acceso = find.byKey(const Key('ajustes-enrutamiento'));

void main() {
  Future<void> montar(
    WidgetTester tester,
    AppSettings ajustes, {
    void Function(BuildContext context)? onAbrirEnrutamiento,
  }) async {
    tester.view
      ..physicalSize = const Size(1000, 1400)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsRepositoryProvider.overrideWith(
            (ref) => InMemorySettingsRepository(initial: ajustes),
          ),
          settingsDiagnosticsProvider.overrideWithValue(
            FakeSettingsDiagnostics(),
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: SettingsPage(onAbrirEnrutamiento: onAbrirEnrutamiento),
        ),
      ),
    );
    await asentar(tester);
  }

  testWidgets('en el host, Ajustes > Impresoras abre el enrutamiento', (
    tester,
  ) async {
    var abiertas = 0;
    await montar(
      tester,
      ajustes(DeviceRole.host).copyWith(
        impresion: const PrintingSettings(
          enrutamiento: EnrutamientoComandas(
            porFamilia: {
              'BEB': DestinoPreparacion.barra,
              'CAF': DestinoPreparacion.barra,
            },
          ),
        ),
      ),
      onAbrirEnrutamiento: (_) => abiertas++,
    );

    await tester.ensureVisible(acceso);
    await tester.pump();
    expect(find.text('Enrutamiento por familias'), findsOneWidget);
    expect(
      find.textContaining('2 familias con destino propio'),
      findsOneWidget,
    );
    await tester.tap(acceso);
    await asentar(tester);
    expect(abiertas, 1);
  });

  testWidgets('sin reglas lo indica', (tester) async {
    await montar(tester, ajustes(DeviceRole.host), onAbrirEnrutamiento: (_) {});
    await tester.ensureVisible(acceso);
    await tester.pump();
    expect(
      find.textContaining('Todas las familias van al destino por defecto'),
      findsOneWidget,
    );
  });

  testWidgets('sin callback no hay acceso', (tester) async {
    await montar(tester, ajustes(DeviceRole.host));
    expect(find.text('Impresoras'), findsWidgets);
    expect(acceso, findsNothing);
  });

  testWidgets('en el comandero no hay acceso', (tester) async {
    await montar(
      tester,
      ajustes(DeviceRole.comandero),
      onAbrirEnrutamiento: (_) {},
    );
    expect(acceso, findsNothing);
  });
}
