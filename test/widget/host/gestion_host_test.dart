import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proyecto_comandero/app/app.dart';
import 'package:proyecto_comandero/core/facturascripts/catalog/catalog_models.dart';
import 'package:proyecto_comandero/core/inventory/inventory_models.dart';
import 'package:proyecto_comandero/core/money/money.dart';
import 'package:proyecto_comandero/features/escandallos/presentation/escandallos_page.dart';
import 'package:proyecto_comandero/features/escandallos/presentation/escandallos_providers.dart';
import 'package:proyecto_comandero/features/host/domain/host_snapshot.dart';
import 'package:proyecto_comandero/features/host/domain/sync_job.dart';
import 'package:proyecto_comandero/features/host/presentation/providers.dart';
import 'package:proyecto_comandero/features/host/presentation/reposicion_page.dart';
import 'package:proyecto_comandero/features/sala/domain/mesa.dart';
import 'package:proyecto_comandero/features/sala/domain/ticket.dart';
import 'package:proyecto_comandero/features/settings/presentation/settings_providers.dart';

import 'support/host_harness.dart';

final class _FakeGateway implements EscandallosGateway {
  _FakeGateway(this.lineas);

  List<RecetaLinea> lineas;
  final List<(String, List<RecetaLinea>)> guardados = [];

  @override
  Future<List<RecetaLinea>> listAll() async => List.of(lineas);

  @override
  Future<void> guardarPlato(String refPlato, List<RecetaLinea> nuevas) async {
    guardados.add((refPlato, nuevas));
    lineas = [
      for (final l in lineas)
        if (l.refPlato != refPlato) l,
      ...nuevas,
    ];
  }
}

Ticket _ticketEfectivo(FakeClock clock) => Ticket(
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
  metodoPago: MetodoPago.efectivo,
  entregadoCents: 200,
);

Text _texto(WidgetTester tester, String key) =>
    tester.widget<Text>(find.byKey(Key(key)));

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
  await tester.pump();
}

void main() {
  group('cola de sincronización', () {
    testWidgets('muestra un trabajo en error y permite reintentarlo', (
      tester,
    ) async {
      final clock = FakeClock();
      final h = HostHarness(
        inicial: snapshotPrueba(
          extra: (s) => s.copyWith(
            cola: [
              SyncJob(
                id: 'factura:t7',
                tipo: SyncJobTipo.factura,
                payload: const {
                  'ticket': {'numeroLocal': 7},
                },
                creadoEn: clock.now,
                intentos: 1,
                estado: SyncJobEstado.error,
                ultimoError: 'FacturaScripts rechazó la factura',
              ),
            ],
          ),
        ),
      );
      await h.pump(tester);

      expect(find.text('1 con error'), findsOneWidget);
      await tester.tap(find.byKey(const Key('sync-chip')));
      await h.settle(tester);

      expect(find.text('Sincronización'), findsOneWidget);
      expect(find.text('Factura ticket 7'), findsOneWidget);
      expect(find.text('FacturaScripts rechazó la factura'), findsOneWidget);
      expect(find.byKey(const Key('reintentar-factura:t7')), findsOneWidget);
      expect(find.byKey(const Key('descartar-factura:t7')), findsOneWidget);

      await tester.tap(find.byKey(const Key('reintentar-factura:t7')));
      await h.settle(tester);

      expect(h.runtime.outbox.jobs.single.estado, SyncJobEstado.pendiente);
      expect(find.byKey(const Key('reintentar-factura:t7')), findsNothing);
      expect(find.textContaining('Pendiente ·'), findsOneWidget);

      await h.dispose(tester);
    });

    testWidgets('descartar pide confirmación y retira el trabajo', (
      tester,
    ) async {
      final clock = FakeClock();
      final h = HostHarness(
        inicial: snapshotPrueba(
          extra: (s) => s.copyWith(
            cola: [
              SyncJob(
                id: 'stock:l1',
                tipo: SyncJobTipo.descuentoStock,
                payload: const {'operacion': 'l1'},
                creadoEn: clock.now,
                estado: SyncJobEstado.error,
                ultimoError: 'Referencia desconocida',
              ),
            ],
          ),
        ),
      );
      await h.pump(tester);
      await tester.tap(find.byKey(const Key('sync-chip')));
      await h.settle(tester);

      await tester.tap(find.byKey(const Key('descartar-stock:l1')));
      await h.settle(tester);
      expect(find.textContaining('no se descontará'), findsOneWidget);
      await tester.tap(find.byKey(const Key('confirmar-aceptar')));
      await h.settle(tester);

      expect(h.runtime.outbox.jobs, isEmpty);
      expect(find.text('No hay trabajos pendientes'), findsOneWidget);

      await h.dispose(tester);
    });
  });

  group('Cierre Z', () {
    testWidgets('muestra el informe, el arqueo y un asiento con Debe == Haber', (
      tester,
    ) async {
      final clock = FakeClock();
      final h = HostHarness(
        inicial: snapshotPrueba(
          extra: (s) => s.copyWith(
            ticketsTurno: [_ticketEfectivo(clock)],
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

      expect(find.text('Caja y Cierre Z'), findsOneWidget);
      expect(_texto(tester, 'z-tickets').data, '1');
      expect(_texto(tester, 'z-ventas').data, formatCents(190));
      expect(_texto(tester, 'efectivo-esperado').data, formatCents(10190));
      // Sin arqueo no hay descuadre ni nada que contabilizar.
      expect(find.byKey(const Key('asiento-vacio')), findsOneWidget);

      await _tap(tester, find.byKey(const Key('contar-efectivo')));
      await h.settle(tester);
      for (final tecla in ['1', '0', '0', '0', '0']) {
        await tester.tap(find.byKey(Key('tecla-$tecla')));
        await tester.pump();
      }
      await tester.tap(find.byKey(const Key('importe-aceptar')));
      await h.settle(tester);

      expect(_texto(tester, 'efectivo-contado').data, formatCents(10000));
      expect(_texto(tester, 'descuadre').data, formatCents(-190));
      final debe = _texto(tester, 'asiento-debe-total').data;
      final haber = _texto(tester, 'asiento-haber-total').data;
      expect(debe, formatCents(190));
      expect(haber, debe);
      expect(_texto(tester, 'asiento-cuadrado').data, contains('Cuadrado'));
      // Faltante: 659 al Debe contra 570 al Haber (cuentas genéricas sin ERP).
      expect(find.text('659'), findsOneWidget);
      expect(find.text('570'), findsOneWidget);
      expect(find.textContaining('ERP no configurado'), findsOneWidget);

      await _tap(tester, find.byKey(const Key('cerrar-turno')));
      await h.settle(tester);
      await tester.tap(find.byKey(const Key('confirmar-aceptar')));
      await h.settle(tester);

      final snapshot = h.runtime.store.snapshot;
      expect(snapshot.ticketsTurno, isEmpty);
      expect(snapshot.cierreAbierto, isNull);
      final cierre = snapshot.historialCierres.single;
      expect(cierre.descuadreCents, -190);
      expect(cierre.efectivoContadoCents, 10000);
      expect(
        find.text('Todavía no hay tickets en este turno.'),
        findsOneWidget,
      );

      await h.dispose(tester);
    });

    testWidgets('abrir turno propone el fondo de caja de los ajustes', (
      tester,
    ) async {
      final h = HostHarness();
      await h.pump(tester);
      await tester.tap(find.byKey(const Key('accion-cierre-z')));
      await h.settle(tester);

      await _tap(tester, find.byKey(const Key('abrir-turno')));
      await h.settle(tester);
      expect(_texto(tester, 'importe-tecleado').data, formatCents(10000));
      await tester.tap(find.byKey(const Key('importe-aceptar')));
      await h.settle(tester);

      expect(h.runtime.cierreZ.turno?.fondoCajaCents, 10000);
      expect(find.byKey(const Key('abrir-turno')), findsNothing);

      await h.dispose(tester);
    });
  });

  group('escandallos', () {
    testWidgets('sin MySQL explica que hace falta configurarlo', (
      tester,
    ) async {
      final h = HostHarness();
      await h.pump(tester);
      await tester.tap(find.byKey(const Key('accion-escandallos')));
      await h.settle(tester);

      expect(find.text('Los escandallos necesitan MySQL'), findsOneWidget);

      await h.dispose(tester);
    });

    testWidgets('lista platos con coste y margen y guarda una receta', (
      tester,
    ) async {
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
      final gateway = _FakeGateway([
        const RecetaLinea(
          refPlato: 'PAELLA',
          refIngrediente: 'ARROZ',
          cantidadNeta: 0.1,
        ),
        const RecetaLinea(
          refPlato: 'PAELLA',
          refIngrediente: 'GAMBA',
          cantidadNeta: 0.05,
          mermaPct: 20,
        ),
      ]);
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

      // Coste: 0,1 × 1,20 + 0,05 / 0,8 × 12 = 0,87 €; margen sobre 10,91 €.
      expect(find.text('Paella'), findsOneWidget);
      expect(find.textContaining('coste ${formatCents(87)}'), findsOneWidget);
      expect(find.textContaining('margen 92,0 %'), findsOneWidget);

      await tester.tap(find.byKey(const Key('plato-PAELLA')));
      await h.settle(tester);
      expect(find.text('Receta de Paella'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('cantidad-ARROZ')), '0,2');
      await tester.pump();
      await _tap(tester, find.byKey(const Key('guardar-escandallo')));
      await h.settle(tester);

      final (plato, lineas) = gateway.guardados.single;
      expect(plato, 'PAELLA');
      expect(
        lineas,
        containsAll(const [
          RecetaLinea(
            refPlato: 'PAELLA',
            refIngrediente: 'ARROZ',
            cantidadNeta: 0.2,
          ),
          RecetaLinea(
            refPlato: 'PAELLA',
            refIngrediente: 'GAMBA',
            cantidadNeta: 0.05,
            mermaPct: 20,
          ),
        ]),
      );
      // Vuelve a la lista con el coste recalculado (0,24 + 0,75).
      expect(find.textContaining('coste ${formatCents(99)}'), findsOneWidget);

      await h.dispose(tester);
    });
  });

  testWidgets('reposición sin MySQL muestra que no está disponible', (
    tester,
  ) async {
    final h = HostHarness();
    await h.pump(tester);
    await tester.tap(find.byKey(const Key('accion-reposicion')));
    await h.settle(tester);

    expect(find.text('Reposición no disponible'), findsOneWidget);
    expect(find.byType(ReposicionPage), findsOneWidget);

    await h.dispose(tester);
  });

  testWidgets('los cambios de ajustes se aplican en caliente al runtime', (
    tester,
  ) async {
    final h = HostHarness();
    await h.pump(tester);
    final runtime = h.runtime;
    expect(find.text('TPV Prueba'), findsOneWidget);

    final container = ProviderScope.containerOf(
      tester.element(find.byKey(const Key('mesa-m1'))),
    );
    await container
        .read(appSettingsProvider.notifier)
        .actualizar(
          (s) => s.copyWith(
            fiscal: s.fiscal.copyWith(nombreTpv: 'Terraza'),
            mesas: [
              ...s.mesas,
              const Mesa(id: 'm9', nombre: 'Mesa 9'),
            ],
          ),
        );
    await h.settle(tester);

    expect(h.runtime, same(runtime), reason: 'no se reconstruye el runtime');
    expect(runtime.settings.nombreTpv, 'Terraza');
    expect(find.text('Terraza'), findsOneWidget);
    expect(find.byKey(const Key('mesa-m9')), findsOneWidget);

    await h.dispose(tester);
  });
}

/// Espera a que el runtime exista antes de mostrar [child] (las pantallas
/// secundarias se abren siempre desde el salón, con el runtime listo).
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
