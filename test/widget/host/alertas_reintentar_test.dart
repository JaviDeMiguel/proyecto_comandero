/// «Reintentar» en la hoja de avisos del salón (P2, §5.17 del diseño de
/// impresión): solo en los avisos que llevan un trabajo de impresión.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/host_harness.dart';

void main() {
  Future<HostHarness> montarConFallo(
    WidgetTester tester,
    FakePrinterPort impresora,
  ) async {
    final h = HostHarness(
      ajustes: ajustesPrueba(conImpresora: true),
      impresora: impresora,
    );
    await h.pump(tester);
    // Un trabajo que falla en la impresora («Fallo de impresión» con su id)
    // y un aviso cualquiera, sin trabajo.
    await h.runtime.printing.abrirCajon();
    await h.runtime.printing.idle();
    h.runtime.alerts.aviso('Catálogo con incidencias', origen: 'catalogo');
    await h.settle(tester);
    await tester.tap(find.byKey(const Key('accion-alertas')));
    await h.settle(tester);
    return h;
  }

  testWidgets('«Reintentar» solo aparece en los avisos con trabajo', (
    tester,
  ) async {
    final impresora = FakePrinterPort()..error = 'sin papel';
    final h = await montarConFallo(tester, impresora);
    final id = impresora.jobs.single.id;

    expect(find.text('Fallo de impresión: Cajón · apertura manual'), findsOne);
    expect(find.text('Catálogo con incidencias'), findsOneWidget);
    expect(find.text('Reintentar'), findsOneWidget);
    expect(find.byKey(Key('alerta-reintentar-$id')), findsOneWidget);
    final fila = find.ancestor(
      of: find.text('Catálogo con incidencias'),
      matching: find.byType(ListTile),
    );
    expect(
      find.descendant(of: fila, matching: find.text('Reintentar')),
      findsNothing,
    );

    await h.dispose(tester);
  });

  testWidgets('al pulsarlo reencola el trabajo y lo confirma', (tester) async {
    final impresora = FakePrinterPort()..error = 'sin papel';
    final h = await montarConFallo(tester, impresora);
    final id = impresora.jobs.single.id;
    impresora.error = null;

    await tester.tap(find.byKey(Key('alerta-reintentar-$id')));
    await h.settle(tester);

    expect(impresora.reintentados, [id]);
    expect(find.text('Trabajo reenviado a la impresora'), findsOneWidget);
    // Ya salió: el aviso antiguo deja de ofrecer «Reintentar».
    expect(find.byKey(Key('alerta-reintentar-$id')), findsNothing);
    expect(find.text('Reintentar'), findsNothing);

    await h.dispose(tester);
  });

  testWidgets('si el reintento vuelve a fallar, el botón sigue', (
    tester,
  ) async {
    final impresora = FakePrinterPort()..error = 'sin papel';
    final h = await montarConFallo(tester, impresora);
    final id = impresora.jobs.single.id;

    await tester.tap(find.byKey(Key('alerta-reintentar-$id')));
    await h.runtime.printing.idle();
    await h.settle(tester);

    expect(impresora.reintentados, [id]);
    expect(find.byKey(Key('alerta-reintentar-$id')), findsOneWidget);

    await h.dispose(tester);
  });

  testWidgets('sin botón en los avisos de trabajos que ya no se pueden '
      'reintentar', (tester) async {
    final h = HostHarness(
      ajustes: ajustesPrueba(conImpresora: true),
      impresora: FakePrinterPort(),
    );
    await h.pump(tester);
    h.runtime.alerts.error(
      'Fallo de impresión: Comanda antigua',
      origen: 'impresion',
      trabajoImpresion: 'trabajo-olvidado',
    );
    await h.settle(tester);
    await tester.tap(find.byKey(const Key('accion-alertas')));
    await h.settle(tester);

    expect(find.text('Fallo de impresión: Comanda antigua'), findsOneWidget);
    expect(find.text('Reintentar'), findsNothing);

    await h.dispose(tester);
  });
}
