import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proyecto_comandero/core/errors/app_exception.dart';
import 'package:proyecto_comandero/core/isolates/escpos/escpos_builder.dart';
import 'package:proyecto_comandero/features/host/domain/host_snapshot.dart';

import 'support/host_harness.dart';

/// Host con el turno abierto y, con [conImpresora], una impresora por rol.
HostHarness _banco({required bool conImpresora, FakePrinterPort? impresora}) {
  final clock = FakeClock();
  return HostHarness(
    inicial: snapshotPrueba(
      extra: (s) => s.copyWith(
        cierreAbierto: CierreAbierto(
          id: 'turno-1',
          abiertoEn: clock.now.subtract(const Duration(hours: 2)),
          fondoCajaCents: 10000,
        ),
      ),
    ),
    ajustes: ajustesPrueba(conImpresora: conImpresora),
    impresora: impresora ?? FakePrinterPort(),
  );
}

/// Abre «Caja y Cierre Z» y pulsa «Abrir cajón».
Future<void> _abrirCajon(WidgetTester tester, HostHarness h) async {
  await h.pump(tester);
  await tester.tap(find.byKey(const Key('accion-cierre-z')));
  await h.settle(tester);
  final boton = find.byKey(const Key('abrir-cajon'));
  expect(
    find.descendant(of: boton, matching: find.text('Abrir cajón')),
    findsOneWidget,
  );
  await tester.ensureVisible(boton);
  await tester.pump();
  await tester.tap(boton);
  await h.settle(tester);
}

void main() {
  testWidgets('«Abrir cajón» envía el pulso a la impresora de tickets en un '
      'trabajo propio y no toca el turno', (tester) async {
    final h = _banco(conImpresora: true);
    await _abrirCajon(tester, h);

    final trabajo = h.impresora!.jobs.single;
    expect(trabajo.description, 'Cajón · apertura manual');
    expect(trabajo.endpoint, impresoraTicketsPrueba);
    expect(trabajo.bytes, bytesAbrirCajon());
    expect(
      find.text('Apertura del cajón enviada a la impresora'),
      findsOneWidget,
    );
    final turno = h.runtime.store.snapshot.cierreAbierto!;
    expect(turno.retiradasCents, 0);
    expect(h.runtime.store.snapshot.ticketsTurno, isEmpty);

    await h.dispose(tester);
  });

  testWidgets('sin impresora de tickets avisa del error y no imprime nada', (
    tester,
  ) async {
    final h = _banco(conImpresora: false);
    await _abrirCajon(tester, h);

    expect(h.impresora!.jobs, isEmpty);
    expect(
      find.text('No hay impresora de tickets configurada'),
      findsOneWidget,
    );
    expect(
      find.text('Apertura del cajón enviada a la impresora'),
      findsNothing,
    );

    await h.dispose(tester);
  });

  testWidgets('si la cola no acepta el trabajo, muestra el motivo', (
    tester,
  ) async {
    final impresora = FakePrinterPort()
      ..errorAlEncolar = const PrinterException('Cola de impresión llena');
    final h = _banco(conImpresora: true, impresora: impresora);
    await _abrirCajon(tester, h);

    expect(impresora.jobs, isEmpty);
    expect(find.textContaining('Cola de impresión llena'), findsOneWidget);
    expect(
      find.text('Apertura del cajón enviada a la impresora'),
      findsNothing,
    );

    await h.dispose(tester);
  });
}
