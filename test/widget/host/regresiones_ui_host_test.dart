/// Regresiones de la revisión de la interfaz del host (u1..u7 y la guarda de
/// rol de `hostRuntimeProvider`).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proyecto_comandero/app/app.dart';
import 'package:proyecto_comandero/core/errors/app_exception.dart';
import 'package:proyecto_comandero/core/facturascripts/catalog/catalog_models.dart';
import 'package:proyecto_comandero/core/inventory/inventory_models.dart';
import 'package:proyecto_comandero/core/money/money.dart';
import 'package:proyecto_comandero/features/escandallos/presentation/escandallos_page.dart';
import 'package:proyecto_comandero/features/escandallos/presentation/escandallos_providers.dart';
import 'package:proyecto_comandero/features/host/application/host_state_repository.dart';
import 'package:proyecto_comandero/features/host/data/in_memory_host_state_repository.dart';
import 'package:proyecto_comandero/features/host/domain/host_snapshot.dart';
import 'package:proyecto_comandero/features/host/presentation/mesa_page.dart';
import 'package:proyecto_comandero/features/host/presentation/providers.dart';
import 'package:proyecto_comandero/features/sala/domain/ticket.dart';
import 'package:proyecto_comandero/features/settings/domain/app_settings.dart';
import 'package:proyecto_comandero/features/settings/presentation/settings_providers.dart';

import 'support/host_harness.dart';

/// Diario en memoria cuya escritura puede quedarse esperando.
final class _RepoLento implements HostStateRepository {
  _RepoLento(HostSnapshot inicial)
    : _interno = InMemoryHostStateRepository(inicial);

  final InMemoryHostStateRepository _interno;

  /// Mientras no sea nulo, cada escritura espera a que se complete.
  Completer<void>? bloqueo;

  @override
  Future<HostSnapshot?> load() => _interno.load();

  @override
  Future<void> save(HostSnapshot snapshot) async {
    final espera = bloqueo;
    if (espera != null) await espera.future;
    await _interno.save(snapshot);
  }
}

/// Pasarela de escandallos cuya primera lectura falla.
final class _GatewayInestable implements EscandallosGateway {
  _GatewayInestable(this.lineas);

  List<RecetaLinea> lineas;
  int lecturas = 0;
  final List<(String, List<RecetaLinea>)> guardados = [];

  @override
  Future<List<RecetaLinea>> listAll() async {
    lecturas++;
    if (lecturas == 1) {
      throw const DatabaseException('MySQL no responde');
    }
    return List.of(lineas);
  }

  @override
  Future<void> guardarPlato(String refPlato, List<RecetaLinea> nuevas) async {
    guardados.add((refPlato, nuevas));
  }
}

const List<RecetaLinea> _recetaPaella = [
  RecetaLinea(refPlato: 'PAELLA', refIngrediente: 'ARROZ', cantidadNeta: 0.1),
  RecetaLinea(refPlato: 'PAELLA', refIngrediente: 'GAMBA', cantidadNeta: 0.05),
];

Text _texto(WidgetTester tester, String key) =>
    tester.widget<Text>(find.byKey(Key(key)));

ButtonStyleButton _boton(WidgetTester tester, String key) =>
    tester.widget<ButtonStyleButton>(find.byKey(Key(key)));

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
  await tester.pump();
}

Future<void> _teclear(WidgetTester tester, List<String> teclas) async {
  for (final tecla in teclas) {
    await tester.tap(find.byKey(Key('tecla-$tecla')));
    await tester.pump();
  }
}

/// Avanza frames sin `pumpAndSettle` (hay indicadores de progreso).
Future<void> _frames(WidgetTester tester, [int n = 10]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

ProviderContainer _container(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(TpvComanderoApp)));

void main() {
  group('hostRuntimeProvider', () {
    testWidgets('u1: tras invalidar el runtime los ajustes se siguen aplicando '
        'al runtime nuevo', (tester) async {
      final h = HostHarness();
      await h.pump(tester);
      final anterior = h.runtime;
      final container = _container(tester);

      container.invalidate(hostRuntimeProvider);
      // El runtime nuevo espera al cierre del anterior, que termina con
      // asincronía real (no basta con avanzar el reloj falso).
      for (var i = 0; i < 100 && h.creados.length < 2; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 10));
      }
      await h.settle(tester);
      expect(h.creados, hasLength(2));
      final nuevo = h.runtime;
      expect(nuevo, isNot(same(anterior)));

      await container
          .read(appSettingsProvider.notifier)
          .actualizar(
            (s) => s.copyWith(fiscal: s.fiscal.copyWith(nombreTpv: 'Terraza')),
          );
      await h.settle(tester);

      expect(nuevo.settings.nombreTpv, 'Terraza');
      expect(find.text('Terraza'), findsOneWidget);

      await h.dispose(tester);
    });

    test(
      'u3: con el rol guardado de comandero no crea ningún runtime',
      () async {
        final h = HostHarness(
          ajustes: ajustesPrueba().copyWith(rol: DeviceRole.comandero),
        );
        final container = ProviderContainer(overrides: h.overrides);
        addTearDown(container.dispose);

        await expectLater(
          container.read(hostRuntimeProvider.future),
          throwsA(isA<ConfigException>()),
        );
        expect(h.creados, isEmpty);
      },
    );

    test('u3: al pasar a comandero cierra el runtime y no crea otro', () async {
      final h = HostHarness();
      final container = ProviderContainer(overrides: h.overrides);
      addTearDown(container.dispose);
      final sub = container.listen(hostRuntimeProvider, (_, _) {});
      addTearDown(sub.close);

      final runtime = await container.read(hostRuntimeProvider.future);
      expect(h.creados, [runtime]);

      await container
          .read(appSettingsProvider.notifier)
          .actualizar((s) => s.copyWith(rol: DeviceRole.comandero));
      for (var i = 0; i < 20; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }

      final estado = container.read(hostRuntimeProvider);
      expect(estado.hasError, isTrue);
      expect(estado.error, isA<ConfigException>());
      expect(h.creados, hasLength(1), reason: 'no se crea otro runtime');
      // El runtime anterior quedó cerrado: ya no se puede arrancar.
      await expectLater(runtime.start(), throwsA(isA<StateError>()));
    });
  });

  testWidgets('u2: durante el cobro el diálogo no ofrece cerrarse y al '
      'terminar muestra el cambio sin desapilar la mesa', (tester) async {
    final clock = FakeClock();
    final repo = _RepoLento(
      snapshotPrueba(
        comandas: [
          comandaPrueba('m1', [linea('l1', 'CANA', 2)], clock: clock),
        ],
      ),
    );
    final h = HostHarness(repo: repo);
    await h.pump(tester);
    await tester.tap(find.byKey(const Key('mesa-m1')));
    await h.settle(tester);
    await tester.tap(find.byKey(const Key('cobrar')));
    await h.settle(tester);
    await _teclear(tester, ['5', '0', '0']);

    final escritura = repo.bloqueo = Completer<void>();
    await tester.tap(find.byKey(const Key('cobro-confirmar')));
    await _frames(tester);

    // La comanda ya salió del diario pero el cobro no ha terminado.
    expect(find.byKey(const Key('cobro-en-curso')), findsOneWidget);
    expect(
      find.text('La mesa no tiene nada pendiente de cobro.'),
      findsNothing,
    );
    expect(find.text('Cerrar'), findsNothing);

    // El atrás del sistema no cierra el diálogo mientras se cobra.
    await tester.binding.handlePopRoute();
    await _frames(tester);
    expect(find.byKey(const Key('cobro-en-curso')), findsOneWidget);
    expect(find.byType(MesaPage), findsOneWidget);

    repo.bloqueo = null;
    escritura.complete();
    await h.settle(tester);

    expect(find.text('Ticket nº 1 cobrado'), findsOneWidget);
    expect(
      _texto(tester, 'resultado-cambio').data,
      'Cambio ${formatCents(310)}',
    );
    expect(find.byType(MesaPage), findsOneWidget);
    expect(h.runtime.store.snapshot.ticketsTurno, hasLength(1));

    await h.dispose(tester);
  });

  testWidgets('u5: la primera tecla sustituye el fondo de caja propuesto', (
    tester,
  ) async {
    final h = HostHarness();
    await h.pump(tester);
    await tester.tap(find.byKey(const Key('accion-cierre-z')));
    await h.settle(tester);

    await _tap(tester, find.byKey(const Key('abrir-turno')));
    await h.settle(tester);
    expect(_texto(tester, 'importe-tecleado').data, formatCents(10000));
    expect(find.byKey(const Key('importe-propuesto')), findsOneWidget);

    await _teclear(tester, ['1', '5', '0', '0', '0']);
    expect(_texto(tester, 'importe-tecleado').data, formatCents(15000));
    expect(find.byKey(const Key('importe-propuesto')), findsNothing);
    await tester.tap(find.byKey(const Key('importe-aceptar')));
    await h.settle(tester);

    expect(h.runtime.cierreZ.turno?.fondoCajaCents, 15000);

    await h.dispose(tester);
  });

  group('Cierre Z', () {
    testWidgets('u6: sin turno ni tickets no se puede cerrar el turno', (
      tester,
    ) async {
      final h = HostHarness();
      await h.pump(tester);
      await tester.tap(find.byKey(const Key('accion-cierre-z')));
      await h.settle(tester);

      expect(find.byKey(const Key('nada-que-cerrar')), findsOneWidget);
      expect(_boton(tester, 'cerrar-turno').onPressed, isNull);

      await h.dispose(tester);
    });

    testWidgets('u6: tras un cierre el botón de cerrar queda desactivado', (
      tester,
    ) async {
      final clock = FakeClock();
      final h = HostHarness(
        inicial: snapshotPrueba(
          extra: (s) => s.copyWith(
            ticketsTurno: [
              Ticket(
                id: 'ticket-1',
                numeroLocal: 1,
                mesaId: 'm1',
                nombreMesa: 'Mesa 1',
                comandaId: 'comanda-m1',
                fechaHora: clock.now,
                lineas: [linea('l1', 'CANA', 2)],
                totales: TotalesTicket(
                  netoCents: 173,
                  ivaCents: 17,
                  totalCents: 190,
                  desglose: const [
                    DesgloseIva(
                      codimpuesto: 'IVA10',
                      ivaBp: 1000,
                      baseCents: 173,
                      cuotaCents: 17,
                    ),
                  ],
                ),
                metodoPago: MetodoPago.tarjeta,
              ),
            ],
            cierreAbierto: CierreAbierto(
              id: 'turno-1',
              abiertoEn: clock.now.subtract(const Duration(hours: 4)),
              fondoCajaCents: 10000,
            ),
          ),
        ),
      );
      await h.pump(tester);
      await tester.tap(find.byKey(const Key('accion-cierre-z')));
      await h.settle(tester);
      expect(find.byKey(const Key('nada-que-cerrar')), findsNothing);
      expect(_boton(tester, 'cerrar-turno').onPressed, isNotNull);

      await _tap(tester, find.byKey(const Key('contar-efectivo')));
      await h.settle(tester);
      await _teclear(tester, ['1', '0', '0', '0', '0']);
      await tester.tap(find.byKey(const Key('importe-aceptar')));
      await h.settle(tester);
      await _tap(tester, find.byKey(const Key('cerrar-turno')));
      await h.settle(tester);
      await tester.tap(find.byKey(const Key('confirmar-aceptar')));
      await h.settle(tester);

      expect(h.runtime.store.snapshot.historialCierres, hasLength(1));
      expect(find.byKey(const Key('nada-que-cerrar')), findsOneWidget);
      expect(_boton(tester, 'cerrar-turno').onPressed, isNull);

      await h.dispose(tester);
    });
  });

  testWidgets('u7: en un teléfono con el teclado abierto el diálogo de motivo '
      'no se desborda', (tester) async {
    final clock = FakeClock();
    final h = HostHarness(
      inicial: snapshotPrueba(
        comandas: [
          comandaPrueba('m1', [linea('l1', 'CANA', 2)], clock: clock),
        ],
      ),
    );
    await h.pump(tester, home: const _ConRuntime(MesaPage(mesaId: 'm1')));
    tester.view.physicalSize = const Size(360, 640);
    await h.settle(tester);

    await _tap(tester, find.byKey(const Key('anular-l1')));
    // El teclado del TextField con autofocus ocupa 280 px.
    tester.view.viewInsets = const FakeViewPadding(bottom: 280);
    await h.settle(tester);

    expect(tester.takeException(), isNull);
    final sugerencia = find.text('Error de comanda');
    expect(sugerencia, findsOneWidget);
    await tester.ensureVisible(sugerencia);
    await tester.pump();
    await tester.tap(sugerencia);
    await tester.pump();
    await tester.ensureVisible(find.byKey(const Key('texto-aceptar')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('texto-aceptar')));
    await h.settle(tester);

    final anulada = h.runtime.sala.comandaDeMesa('m1')?.lineaPorId('l1');
    expect(anulada?.motivoAnulacion, 'Error de comanda');

    await h.dispose(tester);
  });

  group('escandallos', () {
    final base = catalogoPrueba();
    final catalogo = CatalogSnapshot(
      familias: base.familias,
      impuestos: base.impuestos,
      articulos: [
        ...base.articulos,
        const ArticuloCatalogo(
          referencia: 'ARROZ',
          idproducto: 10,
          idvariante: 10,
          descripcion: 'Arroz bomba',
          ivaBp: 1000,
          precioNeto: 2,
          pvpCents: 220,
          sevende: false,
          coste: 1.2,
        ),
        const ArticuloCatalogo(
          referencia: 'GAMBA',
          idproducto: 11,
          idvariante: 11,
          descripcion: 'Gamba roja',
          ivaBp: 1000,
          precioNeto: 20,
          pvpCents: 2200,
          sevende: false,
          coste: 12,
        ),
      ],
      avisos: const [],
      obtenidoEn: base.obtenidoEn,
    );

    Future<HostHarness> montar(
      WidgetTester tester,
      _GatewayInestable gateway,
    ) async {
      final h = HostHarness(inicial: snapshotPrueba(catalogo: catalogo));
      tester.view
        ..physicalSize = const Size(1280, 800)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            ...h.overrides,
            escandallosGatewayProvider.overrideWithValue(gateway),
          ],
          child: const TpvComanderoApp(home: _ConRuntime(EscandallosPage())),
        ),
      );
      await h.settle(tester);
      return h;
    }

    FloatingActionButton fab(WidgetTester tester) =>
        tester.widget<FloatingActionButton>(
          find.byKey(const Key('nuevo-escandallo')),
        );

    testWidgets('u4: con las recetas en error "Nuevo escandallo" está '
        'desactivado', (tester) async {
      final gateway = _GatewayInestable(List.of(_recetaPaella));
      final h = await montar(tester, gateway);

      expect(find.text('No se pudieron leer los escandallos'), findsOneWidget);
      expect(fab(tester).onPressed, isNull);

      await tester.tap(find.text('Reintentar'));
      await h.settle(tester);
      expect(find.byKey(const Key('plato-PAELLA')), findsOneWidget);
      expect(fab(tester).onPressed, isNotNull);

      await h.dispose(tester);
    });

    testWidgets('u4: "Nuevo escandallo" de un plato con receta la abre con '
        'sus ingredientes y vaciarla pide confirmación', (tester) async {
      final gateway = _GatewayInestable(List.of(_recetaPaella))
        // Sin el fallo inicial: la lista se lee a la primera.
        ..lecturas = 1;
      final h = await montar(tester, gateway);
      expect(find.byKey(const Key('plato-PAELLA')), findsOneWidget);

      await tester.tap(find.byKey(const Key('nuevo-escandallo')));
      await h.settle(tester);
      await tester.tap(find.byKey(const Key('selector-PAELLA')));
      await h.settle(tester);

      expect(find.byKey(const Key('ingrediente-ARROZ')), findsOneWidget);
      expect(find.byKey(const Key('ingrediente-GAMBA')), findsOneWidget);
      expect(find.byKey(const Key('borrar-escandallo')), findsOneWidget);

      // Quitar todos los ingredientes y guardar equivale a borrar la receta.
      for (var i = 0; i < 2; i++) {
        await tester.tap(find.byTooltip('Quitar ingrediente').first);
        await tester.pump();
      }
      await _tap(tester, find.byKey(const Key('guardar-escandallo')));
      await h.settle(tester);
      expect(find.text('Borrar receta'), findsOneWidget);
      await tester.tap(find.text('Cancelar'));
      await h.settle(tester);

      expect(gateway.guardados, isEmpty);

      await h.dispose(tester);
    });
  });
}

/// Espera a que el runtime exista antes de mostrar [child].
class _ConRuntime extends ConsumerWidget {
  const _ConRuntime(this.child);

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final runtime = ref.watch(hostRuntimeProvider);
    return runtime.hasValue
        ? child
        : const Center(child: CircularProgressIndicator());
  }
}
