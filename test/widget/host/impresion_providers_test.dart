/// Proveedores derivados de la impresión del host (§7.11): con el runtime en
/// marcha y sin él (rol de comandero), donde no lanzan.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;
import 'package:flutter_test/flutter_test.dart';
import 'package:proyecto_comandero/core/isolates/escpos/ticket_documents.dart'
    show EmpresaTicket;
import 'package:proyecto_comandero/core/isolates/isolate_runner.dart';
import 'package:proyecto_comandero/features/host/application/host_runtime.dart';
import 'package:proyecto_comandero/features/host/data/in_memory_host_state_repository.dart';
import 'package:proyecto_comandero/features/host/domain/empresa_emisora.dart';
import 'package:proyecto_comandero/features/host/presentation/host_settings_mapper.dart';
import 'package:proyecto_comandero/features/host/presentation/impresion_providers.dart';
import 'package:proyecto_comandero/features/host/presentation/providers.dart';
import 'package:proyecto_comandero/features/impresion/domain/formato_impresion.dart';
import 'package:proyecto_comandero/features/sala/domain/pases.dart';
import 'package:proyecto_comandero/features/sala/domain/ticket.dart';
import 'package:proyecto_comandero/features/settings/domain/app_settings.dart';
import 'package:proyecto_comandero/features/settings/presentation/settings_providers.dart';

import '../../features/host/support/host_test_support.dart' show submit;
import 'support/host_harness.dart';

const PasesConfig _pases = PasesConfig(
  nombres: ['Bebidas', 'Entrantes', 'Principales'],
);

const FormatoImpresion _formato = FormatoImpresion(
  pases: _pases,
  ticket: FormatoTicket(nombreComercial: 'La Tasca', pie: 'Gracias'),
);

EmpresaEmisora _empresa({String? cifnif = 'B12345678'}) => EmpresaEmisora(
  nombre: 'Hostelería Manolo SL',
  nombrecorto: 'Bar Manolo',
  cifnif: cifnif,
  obtenidaEn: DateTime(2026, 10, 7, 12),
);

/// Deja correr los futuros y los streams de los proveedores.
Future<void> _esperar() async {
  for (var i = 0; i < 10; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

/// Contenedor sobre [h] que mantiene vivos los proveedores de impresión y
/// cierra el runtime al terminar.
ProviderContainer _contenedor(HostHarness h) {
  final container = ProviderContainer(overrides: h.overrides);
  for (final proveedor in <ProviderListenable<Object?>>[
    pasesConfigProvider,
    nombreTpvProvider,
    cabeceraEmisorProvider,
    cabeceraFiscalCompletaProvider,
    emisionesPendientesProvider,
  ]) {
    container.listen(proveedor, (_, _) {});
  }
  addTearDown(() async {
    final creados = List<HostRuntime>.of(h.creados);
    container.dispose();
    for (final runtime in creados) {
      await runtime.dispose();
    }
  });
  return container;
}

void main() {
  group('sin runtime (rol de comandero)', () {
    late HostHarness h;
    late ProviderContainer container;

    setUp(() {
      h = HostHarness(
        ajustes: ajustesPrueba(formato: _formato)
            .copyWith(rol: DeviceRole.comandero),
      );
      container = _contenedor(h);
    });

    test('mientras cargan los ajustes dan los valores por defecto', () async {
      expect(container.read(pasesConfigProvider), const PasesConfig());
      expect(container.read(nombreTpvProvider), '');
      expect(
        container.read(cabeceraEmisorProvider),
        const EmpresaTicket(nombre: ''),
      );
      expect(container.read(cabeceraFiscalCompletaProvider), isFalse);
      // Deja terminar la carga antes de desechar el contenedor.
      await container.read(appSettingsProvider.future);
      await _esperar();
    });

    test('pases, nombre y cabecera salen de los ajustes; las emisiones, '
        'vacías', () async {
      await container.read(appSettingsProvider.future);
      await _esperar();

      expect(container.read(pasesConfigProvider), _pases);
      expect(container.read(nombreTpvProvider), 'TPV Prueba');
      expect(
        container.read(cabeceraEmisorProvider),
        const EmpresaTicket(nombre: 'La Tasca', pie: 'Gracias'),
      );
      expect(container.read(cabeceraFiscalCompletaProvider), isFalse);
      expect(container.read(emisionesPendientesProvider).value, isEmpty);
      expect(h.creados, isEmpty);
    });

    test('un cambio de ajustes se refleja al instante', () async {
      await container.read(appSettingsProvider.future);
      await container
          .read(appSettingsProvider.notifier)
          .actualizar(
            (s) => s.copyWith(
              impresion: s.impresion.copyWith(
                formato: const FormatoImpresion(
                  pases: PasesConfig(activos: false),
                ),
              ),
            ),
          );
      await _esperar();
      expect(container.read(pasesConfigProvider).activos, isFalse);
      expect(container.read(cabeceraEmisorProvider).nombre, 'TPV Prueba');
    });
  });

  group('con runtime', () {
    test('mientras cargan los ajustes, el nombre del TPV sale del '
        'runtime', () async {
      final runtime = await HostRuntime.create(
        settings: hostSettingsFromApp(ajustesPrueba())
            .copyWith(nombreTpv: 'Caja Runtime'),
        stateRepo: InMemoryHostStateRepository(snapshotPrueba()),
        runner: const InlineIsolateRunner(),
        discoveryEnabled: false,
      );
      addTearDown(runtime.dispose);
      // Los ajustes no terminan de cargar nunca; el runtime ya está listo.
      final container = ProviderContainer(
        overrides: [
          appSettingsProvider.overrideWithBuild(
            (ref, notifier) => Completer<AppSettings>().future,
          ),
          hostRuntimeProvider.overrideWithBuild(
            (ref, notifier) async => runtime,
          ),
        ],
      );
      addTearDown(container.dispose);
      container.listen(nombreTpvProvider, (_, _) {});
      expect(container.read(nombreTpvProvider), '');

      await container.read(hostRuntimeProvider.future);
      expect(container.read(nombreTpvProvider), 'Caja Runtime');
    });

    test('la cabecera sale de la empresa en caché del diario y sigue sus '
        'cambios', () async {
      final h = HostHarness(
        ajustes: ajustesPrueba(formato: _formato),
        inicial: snapshotPrueba(extra: (s) => s.copyWith(empresa: _empresa())),
      );
      final container = _contenedor(h);
      final runtime = await container.read(hostRuntimeProvider.future);
      await _esperar();

      final cabecera = container.read(cabeceraEmisorProvider);
      expect(cabecera.nombre, 'Hostelería Manolo SL');
      expect(cabecera.nombreComercial, 'La Tasca');
      expect(cabecera.cifnif, 'B12345678');
      expect(cabecera.pie, 'Gracias');
      expect(container.read(cabeceraFiscalCompletaProvider), isTrue);
      expect(container.read(nombreTpvProvider), 'TPV Prueba');
      expect(container.read(pasesConfigProvider), _pases);

      await runtime.store.update(
        (s) => s.copyWith(empresa: _empresa(cifnif: null)),
      );
      await _esperar();
      expect(container.read(cabeceraFiscalCompletaProvider), isFalse);
    });

    test(
      'las emisiones pendientes siguen a printing.emisionesPendientes',
      () async {
        final h = HostHarness(
          ajustes: ajustesPrueba(
            conImpresora: true,
            formato: const FormatoImpresion(
              emision: EmisionTicket(
                modo: ModoEmision.facturaAlCobrar,
                esperaSegundos: 30,
              ),
            ),
          ),
          impresora: FakePrinterPort(),
        );
        final container = _contenedor(h);
        final runtime = await container.read(hostRuntimeProvider.future);
        await _esperar();
        expect(container.read(emisionesPendientesProvider).value, isEmpty);

        await runtime.sala.aceptarLineas(
          submit('m1', [linea('l1', 'CANA', 1)]),
        );
        final ticket = await runtime.sala.cobrar('m1', MetodoPago.tarjeta);
        await _esperar();
        expect(container.read(emisionesPendientesProvider).value, {ticket.id});

        runtime.printing.cancelarEsperas();
        await runtime.sala.idle();
        await _esperar();
        expect(container.read(emisionesPendientesProvider).value, isEmpty);
      },
    );
  });
}
