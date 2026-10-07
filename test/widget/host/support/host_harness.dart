/// Banco de pruebas de las pantallas del host: un [HostRuntime] real sobre
/// un diario en memoria, sin red, ERP, MySQL ni impresora, y los ajustes en
/// un repositorio en memoria.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:proyecto_comandero/app/app.dart';
import 'package:proyecto_comandero/core/facturascripts/catalog/catalog_models.dart';
import 'package:proyecto_comandero/core/isolates/isolate_runner.dart';
import 'package:proyecto_comandero/features/host/application/catalog_service.dart';
import 'package:proyecto_comandero/features/host/application/host_runtime.dart';
import 'package:proyecto_comandero/features/host/application/host_state_repository.dart';
import 'package:proyecto_comandero/features/host/data/in_memory_host_state_repository.dart';
import 'package:proyecto_comandero/features/host/domain/host_snapshot.dart';
import 'package:proyecto_comandero/features/host/presentation/host_home_page.dart';
import 'package:proyecto_comandero/features/host/presentation/providers.dart';
import 'package:proyecto_comandero/features/sala/domain/comanda.dart';
import 'package:proyecto_comandero/features/sala/domain/linea_comanda.dart';
import 'package:proyecto_comandero/features/settings/data/in_memory_settings_repository.dart';
import 'package:proyecto_comandero/features/settings/domain/app_settings.dart';
import 'package:proyecto_comandero/features/settings/presentation/settings_providers.dart';

import '../../../features/host/fakes/fake_ports.dart';
import '../../../features/host/support/host_test_support.dart';

export '../../../features/host/fakes/fake_ports.dart' show FakeClock;
export '../../../features/host/support/host_test_support.dart'
    show catalogoPrueba, linea, mesasPrueba;

/// Ajustes de un host de prueba con las mesas de `mesasPrueba`.
AppSettings ajustesPrueba() => AppSettings(
  deviceId: 'tablet-test',
  deviceName: 'Tablet test',
  rol: DeviceRole.host,
  fiscal: const FiscalSettings(codalmacen: 'ALG', nombreTpv: 'TPV Prueba'),
  fondoCajaCents: 10000,
  mesas: mesasPrueba,
);

/// Diario inicial con las mesas y el catálogo de prueba.
HostSnapshot snapshotPrueba({
  List<Comanda> comandas = const [],
  CatalogSnapshot? catalogo,
  HostSnapshot Function(HostSnapshot base)? extra,
}) {
  final cat = catalogo ?? catalogoPrueba();
  final base = HostSnapshot(
    mesas: mesasPrueba,
    comandas: comandas,
    catalogo: cat,
    catalogoVersion: CatalogService.versionDe(cat),
  );
  return extra == null ? base : extra(base);
}

/// Comanda abierta en [mesaId] con [lineas], abierta hace [hace].
Comanda comandaPrueba(
  String mesaId,
  List<LineaComanda> lineas, {
  required FakeClock clock,
  Duration hace = const Duration(minutes: 25),
  bool cuentaSolicitada = false,
}) => Comanda(
  id: 'comanda-$mesaId',
  mesaId: mesaId,
  abiertaEn: clock.now.subtract(hace),
  lineas: lineas,
  cuentaSolicitada: cuentaSolicitada,
);

final class HostHarness {
  /// [repo] sustituye al diario en memoria (por ejemplo, uno de escritura
  /// lenta); entonces [inicial] se ignora.
  HostHarness({
    HostSnapshot? inicial,
    AppSettings? ajustes,
    HostStateRepository? repo,
  }) : repo = repo ?? InMemoryHostStateRepository(inicial ?? snapshotPrueba()),
       ajustes = ajustes ?? ajustesPrueba();

  final FakeClock clock = FakeClock();
  final HostStateRepository repo;
  final AppSettings ajustes;
  HostRuntime? _runtime;

  /// Runtimes creados por la fábrica (uno por cada construcción).
  final List<HostRuntime> creados = [];

  HostRuntime get runtime =>
      _runtime ?? (throw StateError('El runtime aún no se ha creado'));

  List<Override> get overrides => [
    settingsRepositoryProvider.overrideWith(
      (ref) => InMemorySettingsRepository(initial: ajustes),
    ),
    isolateRunnerProvider.overrideWithValue(const InlineIsolateRunner()),
    hostAutoStartProvider.overrideWithValue(false),
    relojProvider.overrideWithValue(clock.call),
    hostRuntimeFactoryProvider.overrideWithValue((ref, settings) async {
      final runtime = await HostRuntime.create(
        settings: settings,
        stateRepo: repo,
        runner: ref.read(isolateRunnerProvider),
        now: clock.call,
        discoveryEnabled: false,
      );
      _runtime = runtime;
      creados.add(runtime);
      return runtime;
    }),
  ];

  /// Monta la app con [home] (por defecto el salón) en una tablet apaisada
  /// y espera a que el runtime esté listo.
  Future<void> pump(WidgetTester tester, {Widget? home}) async {
    tester.view
      ..physicalSize = const Size(1280, 800)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: overrides,
        child: TpvComanderoApp(home: home ?? const HostHomePage()),
      ),
    );
    for (var i = 0; i < 20 && _runtime == null; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    await settle(tester);
  }

  /// Avanza frames y microtareas sin esperar animaciones infinitas.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pumpAndSettle();
  }

  /// Desmonta el árbol (cierra el runtime) y deja terminar sus futuros.
  Future<void> dispose(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 100));
    await _runtime?.dispose();
  }
}
