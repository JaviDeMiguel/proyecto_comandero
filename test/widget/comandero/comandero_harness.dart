/// Montaje común de las pantallas del comandero en los tests de widgets.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proyecto_comandero/app/theme.dart';
import 'package:proyecto_comandero/features/comandero/presentation/providers.dart';
import 'package:proyecto_comandero/features/settings/data/in_memory_settings_repository.dart';
import 'package:proyecto_comandero/features/settings/domain/app_settings.dart';
import 'package:proyecto_comandero/features/settings/presentation/settings_providers.dart';

import 'fake_comandero_gateway.dart';

/// Tamaño de un teléfono en vertical.
const Size kTelefono = Size(420, 900);

AppSettings ajustesPrueba({String? pairingCode, String? hostManual}) =>
    AppSettings.defaults(deviceId: 'dev-1', deviceName: 'Móvil 1').copyWith(
      rol: DeviceRole.comandero,
      red: NetworkSettings(pairingCode: pairingCode, hostManual: hostManual),
    );

/// Monta [home] con el doble [gateway] y ajustes en memoria. Devuelve el
/// repositorio de ajustes para comprobar lo guardado.
Future<InMemorySettingsRepository> montar(
  WidgetTester tester,
  Widget home, {
  required FakeComanderoGateway gateway,
  AppSettings? ajustes,
  Size size = kTelefono,
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  addTearDown(gateway.dispose);
  final repository = InMemorySettingsRepository(
    initial: ajustes ?? ajustesPrueba(),
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        settingsRepositoryProvider.overrideWith((ref) => repository),
        comanderoControllerProvider.overrideWith((ref) async => gateway),
      ],
      child: MaterialApp(theme: AppTheme.light(), home: home),
    ),
  );
  await asentar(tester);
  return repository;
}

/// Deja correr microtareas y frames pendientes (streams, futures del doble).
Future<void> asentar(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 10));
  }
}
