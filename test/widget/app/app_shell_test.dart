import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:proyecto_comandero/app/app.dart';
import 'package:proyecto_comandero/app/platform/host_platform_hooks.dart';
import 'package:proyecto_comandero/app/role_selection_page.dart';
import 'package:proyecto_comandero/features/comandero/domain/comandero_state.dart';
import 'package:proyecto_comandero/features/comandero/presentation/comandero_home.dart';
import 'package:proyecto_comandero/features/comandero/presentation/conexion_page.dart';
import 'package:proyecto_comandero/features/comandero/presentation/mesas_page.dart';
import 'package:proyecto_comandero/features/comandero/presentation/providers.dart';
import 'package:proyecto_comandero/features/host/presentation/host_home_page.dart';
import 'package:proyecto_comandero/features/settings/application/settings_service.dart';
import 'package:proyecto_comandero/features/settings/data/in_memory_settings_repository.dart';
import 'package:proyecto_comandero/features/settings/domain/app_settings.dart';
import 'package:proyecto_comandero/features/settings/presentation/settings_diagnostics.dart';
import 'package:proyecto_comandero/features/settings/presentation/settings_page.dart';
import 'package:proyecto_comandero/features/settings/presentation/settings_providers.dart';

import '../comandero/fake_comandero_gateway.dart';
import '../host/support/host_harness.dart';
import 'app_fakes.dart';

/// Deja correr microtareas y frames sin esperar animaciones infinitas.
Future<void> asentar(WidgetTester tester, {int frames = 6}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

ProviderContainer contenedor(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(TpvComanderoApp)));

void main() {
  late FakeHostPlatformHooks hooks;
  late FakeComanderoGateway gateway;

  setUp(() {
    hooks = FakeHostPlatformHooks();
    gateway = FakeComanderoGateway();
  });

  tearDown(() async {
    await gateway.dispose();
  });

  Future<void> montar(
    WidgetTester tester, {
    required List<Override> overrides,
    Size size = const Size(1280, 800),
    Override? comandero,
  }) async {
    tester.view
      ..physicalSize = size
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          hostPlatformHooksProvider.overrideWithValue(hooks),
          comandero ??
              comanderoControllerProvider.overrideWith((ref) async => gateway),
          settingsDiagnosticsProvider.overrideWithValue(
            FakeSettingsDiagnostics(),
          ),
          ...overrides,
        ],
        child: const TpvComanderoApp(),
      ),
    );
    await asentar(tester);
  }

  testWidgets('sin rol muestra el selector de modo', (tester) async {
    final repo = InMemorySettingsRepository();
    await montar(
      tester,
      overrides: [settingsRepositoryProvider.overrideWith((ref) => repo)],
    );

    expect(find.byType(RoleSelectionPage), findsOneWidget);
    expect(find.text('Servidor TPV (tablet)'), findsOneWidget);
    expect(find.text('Comandero (móvil)'), findsOneWidget);
    expect((await repo.load())!.rol, isNull);
    expect(hooks.llamadas, isEmpty);
  });

  testWidgets('elegir Comandero persiste el rol y abre el comandero', (
    tester,
  ) async {
    final repo = InMemorySettingsRepository();
    await montar(
      tester,
      size: const Size(420, 900),
      overrides: [settingsRepositoryProvider.overrideWith((ref) => repo)],
    );

    await tester.tap(find.text('Comandero (móvil)'));
    await asentar(tester);

    expect((await repo.load())!.rol, DeviceRole.comandero);
    expect(find.byType(RoleSelectionPage), findsNothing);
    expect(find.byType(ComanderoHome), findsOneWidget);
    expect(find.byType(ConexionPage), findsOneWidget);
    expect(hooks.llamadas, isEmpty, reason: 'el comandero no usa wakelock');
  });

  testWidgets('el comandero abre los ajustes con solo dispositivo y red', (
    tester,
  ) async {
    final repo = InMemorySettingsRepository(
      initial: AppSettings.defaults(
        deviceId: 'dev-1',
        deviceName: 'Móvil 1',
      ).copyWith(rol: DeviceRole.comandero),
    );
    await montar(
      tester,
      size: const Size(420, 900),
      overrides: [settingsRepositoryProvider.overrideWith((ref) => repo)],
    );

    await tester.tap(find.byTooltip('Ajustes').first);
    await asentar(tester);

    expect(find.byType(SettingsPage), findsOneWidget);
    expect(find.text('Dispositivo'), findsOneWidget);
    expect(find.text('Red local'), findsOneWidget);
    expect(find.text('ERP FacturaScripts'), findsNothing);
    expect(find.byKey(const Key('ajustes-host-manual')), findsOneWidget);
  });

  testWidgets('con rol host muestra el salón y mantiene la pantalla '
      'encendida; al pasar a comandero libera el host', (tester) async {
    final harness = HostHarness();
    await montar(tester, overrides: harness.overrides);
    for (var i = 0; i < 20 && !hooks.activo; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    await harness.settle(tester);

    expect(find.byType(HostHomePage), findsOneWidget);
    expect(find.text('TPV Prueba'), findsWidgets);
    expect(hooks.llamadas, ['activar']);
    final runtime = harness.runtime;

    await contenedor(tester)
        .read(appSettingsProvider.notifier)
        .actualizar((s) => s.copyWith(rol: DeviceRole.comandero));
    await asentar(tester, frames: 10);

    expect(find.byType(HostHomePage), findsNothing);
    expect(find.byType(ComanderoHome), findsOneWidget);
    expect(hooks.activo, isFalse);
    expect(hooks.llamadas.last, 'liberar');
    // El runtime del host se ha cerrado (su servidor TCP con él).
    await expectLater(runtime.start(), throwsStateError);

    await harness.dispose(tester);
  });

  testWidgets('desde los ajustes del host se cambia a comandero y se vuelve '
      'a la raíz', (tester) async {
    final harness = HostHarness();
    await montar(tester, overrides: harness.overrides);
    for (var i = 0; i < 20 && !hooks.activo; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    await harness.settle(tester);

    await tester.tap(find.byKey(const Key('accion-ajustes')));
    await asentar(tester);
    expect(find.byType(SettingsPage), findsOneWidget);
    expect(find.text('ERP FacturaScripts'), findsOneWidget);

    await tester.tap(find.text('Comandero').first);
    await asentar(tester);
    expect(find.textContaining('cambiará de modo'), findsOneWidget);
    await tester.tap(find.byKey(const Key('ajustes-guardar')));
    await asentar(tester);
    expect(find.text('Cambiar de modo'), findsWidgets);
    expect(
      find.textContaining('El dispositivo pasa a funcionar como Comandero.'),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('ajustes-confirmar-cambio-modo')));
    await asentar(tester, frames: 30);

    expect(find.byType(SettingsPage), findsNothing);
    expect(find.byType(ComanderoHome), findsOneWidget);
    expect(hooks.activo, isFalse);

    await harness.dispose(tester);
  });

  group('u3: cambio de modo con pantallas apiladas', () {
    late List<FakeComanderoGateway> gateways;

    setUp(() => gateways = []);

    Override fabricaComandero() =>
        comanderoControllerProvider.overrideWith((ref) async {
          final creado = FakeComanderoGateway(
            state: Conectado(host: kHostPrueba, sala: salaPrueba()),
          );
          gateways.add(creado);
          ref.onDispose(() => unawaited(creado.dispose()));
          return creado;
        });

    Future<AppSettings> guardados(WidgetTester tester) async =>
        (await (await contenedor(tester)
                .read(settingsRepositoryProvider.future))
            .load())!;

    /// Comandero conectado en MesasPage → Conexión → Ajustes.
    Future<void> abrirAjustesSobreConexion(WidgetTester tester) async {
      final harness = HostHarness(
        ajustes: ajustesPrueba().copyWith(rol: DeviceRole.comandero),
      );
      addTearDown(() async {
        for (final creado in gateways) {
          await creado.dispose();
        }
      });
      // Aunque el test falle: el runtime del host no debe quedar vivo.
      addTearDown(() => harness.dispose(tester));
      await montar(
        tester,
        overrides: harness.overrides,
        comandero: fabricaComandero(),
      );
      expect(find.byType(MesasPage), findsOneWidget);
      await tester.tap(find.byTooltip('Conexión'));
      await asentar(tester, frames: 20);
      expect(find.byType(ConexionPage), findsOneWidget);
      await tester.tap(find.byTooltip('Ajustes').last);
      await asentar(tester, frames: 20);
      expect(find.byType(SettingsPage), findsOneWidget);
      expect(gateways, hasLength(1));
    }

    testWidgets('u3: de comandero a host desde Ajustes sobre ConexionPage no '
        'recrea el comandero', (tester) async {
      await abrirAjustesSobreConexion(tester);

      await tester.tap(find.text('Servidor TPV'));
      await asentar(tester);
      await tester.tap(find.byKey(const Key('ajustes-guardar')));
      await asentar(tester);
      await tester.tap(find.byKey(const Key('ajustes-confirmar-cambio-modo')));
      await asentar(tester, frames: 40);

      expect(find.byType(HostHomePage), findsOneWidget);
      expect(find.byType(SettingsPage), findsNothing);
      expect(find.byType(ConexionPage), findsNothing);
      expect(
        gateways,
        hasLength(1),
        reason: 'ninguna pantalla del comandero reconstruye el proveedor',
      );
      expect(gateways.single.disposed, isTrue);
      expect((await guardados(tester)).rol, DeviceRole.host);
    });

    testWidgets('u3: cancelar el cambio de modo no cierra nada ni guarda', (
      tester,
    ) async {
      await abrirAjustesSobreConexion(tester);

      await tester.tap(find.text('Servidor TPV'));
      await asentar(tester);
      await tester.tap(find.byKey(const Key('ajustes-guardar')));
      await asentar(tester);
      await tester.tap(find.text('Cancelar'));
      await asentar(tester, frames: 20);

      expect(find.byType(SettingsPage), findsOneWidget);
      expect(gateways.single.disposed, isFalse);
      expect((await guardados(tester)).rol, DeviceRole.comandero);
    });

    testWidgets('u3: Restablecer desde Ajustes sobre ConexionPage no recrea '
        'el comandero', (tester) async {
      await abrirAjustesSobreConexion(tester);

      await tester.tap(find.byKey(const Key('ajustes-menu')));
      await asentar(tester, frames: 20);
      await tester.tap(find.text('Restablecer ajustes'));
      await asentar(tester, frames: 20);
      await tester.tap(find.widgetWithText(FilledButton, 'Restablecer'));
      await asentar(tester, frames: 40);

      expect(find.byType(RoleSelectionPage), findsOneWidget);
      expect(find.byType(ConexionPage), findsNothing);
      expect(gateways, hasLength(1));
      expect(gateways.single.disposed, isTrue);
      final ajustes = await guardados(tester);
      expect(ajustes.rol, isNull);
      expect(ajustes.deviceId, 'tablet-test');
    });
  });

  testWidgets('u5: Restablecer desde la pantalla de error conserva la '
      'identidad del dispositivo si es legible', (tester) async {
    final repo = CorruptSettingsRepository(
      identidad: const IdentidadDispositivo(
        deviceId: 'movil-42',
        deviceName: 'Camarero 2',
      ),
    );
    await montar(
      tester,
      overrides: [settingsRepositoryProvider.overrideWith((ref) => repo)],
    );
    expect(find.text('No se pudieron cargar los ajustes'), findsOneWidget);

    await tester.tap(find.text('Restablecer ajustes'));
    await asentar(tester);
    expect(
      find.textContaining('se conservan el identificador'),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('confirmar-restablecer')));
    await asentar(tester);

    expect(find.byType(RoleSelectionPage), findsOneWidget);
    expect(repo.guardados!.deviceId, 'movil-42');
    expect(repo.guardados!.deviceName, 'Camarero 2');
    expect(repo.guardados!.rol, isNull);
    expect(repo.guardados!.fsApi, isNull);
  });

  testWidgets('si los ajustes no cargan ofrece reintentar y restablecer', (
    tester,
  ) async {
    final repo = CorruptSettingsRepository();
    await montar(
      tester,
      overrides: [settingsRepositoryProvider.overrideWith((ref) => repo)],
    );

    expect(find.text('No se pudieron cargar los ajustes'), findsOneWidget);
    expect(find.textContaining('puerto fuera de rango'), findsOneWidget);
    expect(find.text('Reintentar'), findsOneWidget);

    // Reintentar con los datos aún corruptos vuelve a fallar.
    await tester.tap(find.text('Reintentar'));
    await asentar(tester);
    expect(find.text('No se pudieron cargar los ajustes'), findsOneWidget);

    await tester.tap(find.text('Restablecer ajustes'));
    await asentar(tester);
    await tester.tap(find.byKey(const Key('confirmar-restablecer')));
    await asentar(tester);

    expect(repo.clears, 1);
    expect(find.byType(RoleSelectionPage), findsOneWidget);
    expect(repo.guardados, isNotNull, reason: 'se guardan valores nuevos');
    expect(repo.guardados!.rol, isNull);
  });
}
