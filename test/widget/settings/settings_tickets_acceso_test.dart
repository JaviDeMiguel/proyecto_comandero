import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proyecto_comandero/app/theme.dart';
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

final Finder acceso = find.byKey(const Key('ajustes-tickets-comandas'));

const String subtitulo =
    'Papel, copias y avisos por impresora, formato del ticket, emisión, '
    'QR VeriFactu y pases';

const String avisoSinGuardar =
    'Guarda antes los cambios de esta pantalla: «Tickets y comandas» usa las '
    'impresoras guardadas';

void main() {
  Future<void> montar(
    WidgetTester tester,
    AppSettings ajustes, {
    void Function(BuildContext context)? onAbrirTicketsYComandas,
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
          home: SettingsPage(
            onAbrirEnrutamiento: onAbrirEnrutamiento,
            onAbrirTicketsYComandas: onAbrirTicketsYComandas,
          ),
        ),
      ),
    );
    await asentar(tester);
  }

  Future<void> pulsarAcceso(WidgetTester tester) async {
    await tester.ensureVisible(acceso);
    await tester.pump();
    await tester.tap(acceso);
    await asentar(tester);
  }

  testWidgets('en el host, Ajustes > Impresoras abre «Tickets y comandas»', (
    tester,
  ) async {
    final abiertas = <BuildContext>[];
    await montar(
      tester,
      ajustes(DeviceRole.host),
      onAbrirTicketsYComandas: abiertas.add,
    );

    await tester.ensureVisible(acceso);
    await tester.pump();
    expect(find.text('Tickets y comandas'), findsOneWidget);
    expect(find.text(subtitulo), findsOneWidget);
    await pulsarAcceso(tester);

    expect(abiertas, hasLength(1));
    expect(abiertas.single.mounted, isTrue);
    // Sin cambios pendientes no hay aviso.
    expect(find.text(avisoSinGuardar), findsNothing);
  });

  testWidgets('va debajo del acceso al enrutamiento', (tester) async {
    await montar(
      tester,
      ajustes(DeviceRole.host),
      onAbrirEnrutamiento: (_) {},
      onAbrirTicketsYComandas: (_) {},
    );
    final enrutamiento = find.byKey(const Key('ajustes-enrutamiento'));

    await tester.ensureVisible(acceso);
    await tester.pump();
    expect(enrutamiento, findsOneWidget);
    expect(
      tester.getTopLeft(acceso).dy,
      greaterThanOrEqualTo(tester.getBottomLeft(enrutamiento).dy),
    );
  });

  testWidgets('con cambios sin guardar avisa antes de abrir', (tester) async {
    var abiertas = 0;
    await montar(
      tester,
      ajustes(DeviceRole.host),
      onAbrirTicketsYComandas: (_) => abiertas++,
    );
    final cocina = find.byKey(const Key('ajustes-impresora-cocina'));
    await tester.ensureVisible(cocina);
    await tester.pump();
    await tester.enterText(cocina, '10.0.0.5');
    await tester.pump();

    await pulsarAcceso(tester);

    expect(find.text(avisoSinGuardar), findsOneWidget);
    expect(abiertas, 1);
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
      onAbrirTicketsYComandas: (_) {},
    );
    expect(find.text('Dispositivo'), findsWidgets);
    expect(acceso, findsNothing);
  });
}
