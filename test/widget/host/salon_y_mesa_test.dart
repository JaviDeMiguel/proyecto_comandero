import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proyecto_comandero/core/money/money.dart';
import 'package:proyecto_comandero/features/host/domain/sync_job.dart';
import 'package:proyecto_comandero/features/sala/domain/ticket.dart';

import 'support/host_harness.dart';

Finder _enMesa(String mesaId, Finder finder) =>
    find.descendant(of: find.byKey(Key('mesa-$mesaId')), matching: finder);

void main() {
  testWidgets('el salón muestra las mesas por zona con su estado e importe', (
    tester,
  ) async {
    final clock = FakeClock();
    final h = HostHarness(
      inicial: snapshotPrueba(
        comandas: [
          comandaPrueba('m1', [linea('l1', 'CANA', 2)], clock: clock),
          comandaPrueba(
            'm2',
            [linea('l2', 'PAELLA', 1)],
            clock: clock,
            cuentaSolicitada: true,
          ),
        ],
      ),
    );
    h.clock.now = clock.now;
    await h.pump(tester);

    expect(find.text('TPV Prueba'), findsOneWidget);
    expect(find.text('Salón'), findsOneWidget);
    expect(find.text('Barra'), findsWidgets);

    expect(_enMesa('m1', find.text('Ocupada')), findsOneWidget);
    expect(_enMesa('m1', find.text(formatCents(190))), findsOneWidget);
    expect(_enMesa('m1', find.textContaining('25 min')), findsOneWidget);
    expect(_enMesa('m2', find.text('Cuenta')), findsOneWidget);
    expect(_enMesa('m2', find.text(formatCents(1200))), findsOneWidget);
    expect(_enMesa('barra', find.text('Libre')), findsOneWidget);

    // Sin ERP ni cola: estado de servidor detenido y todo sincronizado.
    expect(find.text('Servidor detenido'), findsOneWidget);
    expect(find.text('Sincronizado'), findsOneWidget);
    expect(find.text('Sin ERP'), findsOneWidget);

    await h.dispose(tester);
  });

  testWidgets('abrir una mesa libre y añadir una línea actualiza el importe', (
    tester,
  ) async {
    final h = HostHarness();
    await h.pump(tester);

    await tester.tap(find.byKey(const Key('mesa-barra')));
    await h.settle(tester);

    expect(find.textContaining('Mesa libre'), findsOneWidget);
    expect(find.byKey(const Key('cobrar')), findsOneWidget);

    await tester.tap(find.byKey(const Key('articulo-CAFE')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('articulo-CAFE')));
    await tester.pump();
    // Dos cafés pendientes de enviar, aún sin importe en la comanda.
    expect(find.byKey(const Key('pendiente-CAFE')), findsOneWidget);
    expect(find.text('Enviar 1 · ${formatCents(260)}'), findsOneWidget);

    await tester.tap(find.byKey(const Key('enviar-pendientes')));
    await h.settle(tester);

    expect(
      tester.widget<Text>(find.byKey(const Key('total-mesa'))).data,
      formatCents(260),
    );
    final comanda = h.runtime.sala.comandaDeMesa('barra');
    expect(comanda, isNotNull);
    expect(comanda!.lineasActivas.single.referencia, 'CAFE');
    expect(comanda.lineasActivas.single.cantidad, 2);

    // De vuelta al salón la mesa aparece ocupada con su importe.
    await tester.tap(find.byType(BackButton));
    await h.settle(tester);
    expect(_enMesa('barra', find.text('Ocupada')), findsOneWidget);
    expect(_enMesa('barra', find.text(formatCents(260))), findsOneWidget);

    await h.dispose(tester);
  });

  testWidgets('anular una línea la tacha y descuenta su importe', (
    tester,
  ) async {
    final clock = FakeClock();
    final h = HostHarness(
      inicial: snapshotPrueba(
        comandas: [
          comandaPrueba('m1', [
            linea('l1', 'CANA', 2),
            linea('l2', 'CAFE', 1),
          ], clock: clock),
        ],
      ),
    );
    await h.pump(tester);
    await tester.tap(find.byKey(const Key('mesa-m1')));
    await h.settle(tester);
    expect(
      tester.widget<Text>(find.byKey(const Key('total-mesa'))).data,
      formatCents(320),
    );

    await tester.tap(find.byKey(const Key('anular-l2')));
    await h.settle(tester);
    await tester.tap(find.text('Cliente cancela'));
    await tester.pump();
    await tester.tap(find.byKey(const Key('texto-aceptar')));
    await h.settle(tester);

    expect(
      tester.widget<Text>(find.byKey(const Key('total-mesa'))).data,
      formatCents(190),
    );
    expect(find.textContaining('Anulada: Cliente cancela'), findsOneWidget);
    final anulada = h.runtime.sala.comandaDeMesa('m1')!.lineaPorId('l2')!;
    expect(anulada.anulada, isTrue);
    expect(anulada.motivoAnulacion, 'Cliente cancela');

    await h.dispose(tester);
  });

  testWidgets('cobro en efectivo calcula el cambio y libera la mesa', (
    tester,
  ) async {
    final clock = FakeClock();
    final h = HostHarness(
      inicial: snapshotPrueba(
        comandas: [
          comandaPrueba('m1', [linea('l1', 'CANA', 2)], clock: clock),
        ],
      ),
    );
    await h.pump(tester);
    await tester.tap(find.byKey(const Key('mesa-m1')));
    await h.settle(tester);

    await tester.tap(find.byKey(const Key('cobrar')));
    await h.settle(tester);

    // Total legal: 2 × 0,86364 al 10 % → base 1,73 + IVA 0,17 = 1,90 €.
    expect(
      tester.widget<Text>(find.byKey(const Key('cobro-total'))).data,
      formatCents(190),
    );
    for (final tecla in ['5', '0', '0']) {
      await tester.tap(find.byKey(Key('tecla-$tecla')));
      await tester.pump();
    }
    expect(
      tester.widget<Text>(find.byKey(const Key('cobro-entregado'))).data,
      formatCents(500),
    );
    expect(
      tester.widget<Text>(find.byKey(const Key('cobro-cambio'))).data,
      formatCents(310),
    );

    await tester.tap(find.byKey(const Key('cobro-confirmar')));
    await h.settle(tester);

    expect(find.text('Ticket nº 1 cobrado'), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const Key('resultado-cambio'))).data,
      'Cambio ${formatCents(310)}',
    );
    final ticket = h.runtime.store.snapshot.ticketsTurno.single;
    expect(ticket.metodoPago, MetodoPago.efectivo);
    expect(ticket.totalCents, 190);
    expect(ticket.entregadoCents, 500);
    expect(ticket.cambioCents, 310);
    // La factura queda encolada para el ERP.
    expect(
      h.runtime.outbox.jobs.map((j) => j.tipo),
      contains(SyncJobTipo.factura),
    );

    await tester.tap(find.byKey(const Key('volver-salon')));
    await h.settle(tester);

    expect(_enMesa('m1', find.text('Libre')), findsOneWidget);
    expect(h.runtime.sala.comandaDeMesa('m1'), isNull);
    expect(find.text('1 pendientes'), findsOneWidget);

    await h.dispose(tester);
  });

  testWidgets('el efectivo insuficiente no deja confirmar el cobro', (
    tester,
  ) async {
    final clock = FakeClock();
    final h = HostHarness(
      inicial: snapshotPrueba(
        comandas: [
          comandaPrueba('m1', [linea('l1', 'PAELLA', 1)], clock: clock),
        ],
      ),
    );
    await h.pump(tester);
    await tester.tap(find.byKey(const Key('mesa-m1')));
    await h.settle(tester);
    await tester.tap(find.byKey(const Key('cobrar')));
    await h.settle(tester);

    await tester.tap(find.byKey(const Key('tecla-5')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('tecla-00')));
    await tester.pump();

    expect(find.text('Falta'), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const Key('cobro-cambio'))).data,
      formatCents(700),
    );
    final confirmar = tester.widget<FilledButton>(
      find.ancestor(
        of: find.text('Confirmar cobro'),
        matching: find.byWidgetPredicate((w) => w is FilledButton),
      ),
    );
    expect(confirmar.onPressed, isNull);

    // Con tarjeta se cobra el total sin teclear nada.
    await tester.tap(find.text('Tarjeta'));
    await tester.pump();
    await tester.tap(find.byKey(const Key('cobro-confirmar')));
    await h.settle(tester);
    expect(find.text('Ticket nº 1 cobrado'), findsOneWidget);
    expect(
      h.runtime.store.snapshot.ticketsTurno.single.metodoPago,
      MetodoPago.tarjeta,
    );

    await h.dispose(tester);
  });

  testWidgets('en vertical la carta se abre en su propia pantalla', (
    tester,
  ) async {
    final h = HostHarness();
    await h.pump(tester);
    tester.view.physicalSize = const Size(420, 860);
    await h.settle(tester);

    await tester.tap(find.byKey(const Key('mesa-m1')));
    await h.settle(tester);
    expect(find.byKey(const Key('articulo-CANA')), findsNothing);

    await tester.tap(find.byKey(const Key('abrir-carta')));
    await h.settle(tester);
    await tester.tap(find.byKey(const Key('articulo-CANA')));
    await h.settle(tester);
    expect(find.text('Añadido: Caña'), findsOneWidget);
    await tester.tap(find.byType(BackButton));
    await h.settle(tester);

    await tester.tap(find.byKey(const Key('enviar-pendientes')));
    await h.settle(tester);
    expect(
      tester.widget<Text>(find.byKey(const Key('total-mesa'))).data,
      formatCents(95),
    );

    // El aviso "Añadido" desaparece enseguida y no tapa el botón de cobro.
    await tester.pump(const Duration(seconds: 2));
    await h.settle(tester);
    await tester.ensureVisible(find.byKey(const Key('cobrar')));
    await tester.tap(find.byKey(const Key('cobrar')));
    await h.settle(tester);
    expect(find.byKey(const Key('tecla-5')), findsOneWidget);
    await tester.tap(find.text('Cancelar'));
    await h.settle(tester);
    expect(h.runtime.sala.comandaDeMesa('m1'), isNotNull);

    await h.dispose(tester);
  });
}
