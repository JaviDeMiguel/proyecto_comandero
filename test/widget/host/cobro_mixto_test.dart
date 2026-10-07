import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proyecto_comandero/core/money/money.dart';
import 'package:proyecto_comandero/features/host/domain/host_snapshot.dart';
import 'package:proyecto_comandero/features/host/domain/sync_job.dart';
import 'package:proyecto_comandero/features/host/presentation/cobro_dialog.dart';
import 'package:proyecto_comandero/features/host/presentation/widgets/forma_cobro.dart';
import 'package:proyecto_comandero/features/sala/domain/ticket.dart';
import 'package:proyecto_comandero/features/sala/protocol/sala_messages.dart';

import 'support/host_harness.dart';

String? _texto(WidgetTester tester, String key) =>
    tester.widget<Text>(find.byKey(Key(key))).data;

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
  await tester.pump();
}

Future<void> _teclear(WidgetTester tester, List<String> teclas) async {
  for (final tecla in teclas) {
    await _tap(tester, find.byKey(Key('tecla-$tecla')));
  }
}

bool _confirmable(WidgetTester tester) =>
    tester
        .widget<ButtonStyleButton>(find.byKey(const Key('cobro-confirmar')))
        .onPressed !=
    null;

/// Mesa 1 con 7 cañas (6,65 €) y el diálogo de cobro abierto en "Mixto".
Future<HostHarness> _abrirCobroMixto(WidgetTester tester) async {
  final clock = FakeClock();
  final h = HostHarness(
    inicial: snapshotPrueba(
      comandas: [
        comandaPrueba('m1', [linea('l1', 'CANA', 7)], clock: clock),
      ],
    ),
  );
  await h.pump(tester);
  await tester.tap(find.byKey(const Key('mesa-m1')));
  await h.settle(tester);
  await tester.tap(find.byKey(const Key('cobrar')));
  await h.settle(tester);
  expect(_texto(tester, 'cobro-total'), formatCents(665));
  await _tap(tester, find.byKey(const Key('cobro-modo-mixto')));
  return h;
}

void main() {
  group('RepartoMixto', () {
    test('la parte tecleada fija la otra como resto del total', () {
      final efectivo = RepartoMixto(
        totalCents: 665,
        parteCents: 400,
        parteEnTarjeta: false,
      );
      expect(efectivo.efectivoCents, 400);
      expect(efectivo.tarjetaCents, 265);
      expect(efectivo.entregadoCents, 400, reason: 'sin teclear: exacto');
      expect(efectivo.cambioCents, 0);
      expect(efectivo.valido, isTrue);

      final tarjeta = RepartoMixto(
        totalCents: 665,
        parteCents: 200,
        parteEnTarjeta: true,
        entregadoTecleadoCents: 500,
      );
      expect(tarjeta.efectivoCents, 465);
      expect(tarjeta.tarjetaCents, 200);
      expect(tarjeta.cambioCents, 35);
      expect(tarjeta.valido, isTrue);
    });

    test('ninguna parte puede ser cero ni igualar o superar el total', () {
      for (final (parte, enTarjeta) in [
        (0, false),
        (0, true),
        (665, false),
        (665, true),
        (900, false),
      ]) {
        final r = RepartoMixto(
          totalCents: 665,
          parteCents: parte,
          parteEnTarjeta: enTarjeta,
        );
        expect(r.valido, isFalse, reason: '$parte ${enTarjeta ? 'T' : 'E'}');
        expect(r.problema, isNotNull);
        expect(r.problemaEsError, parte != 0);
      }
      final minimo = RepartoMixto(
        totalCents: 1,
        parteCents: 0,
        parteEnTarjeta: false,
      );
      expect(minimo.problema, contains('no se puede repartir'));
      expect(minimo.problemaEsError, isTrue);
    });

    test('el entregado debe cubrir la parte en efectivo', () {
      final r = RepartoMixto(
        totalCents: 665,
        parteCents: 400,
        parteEnTarjeta: false,
        entregadoTecleadoCents: 300,
      );
      expect(r.problema, isNull);
      expect(r.falta, isTrue);
      expect(r.valido, isFalse);
    });
  });

  testWidgets('cobro mixto completo: efectivo tecleado, tarjeta el resto, '
      'billete y cambio', (tester) async {
    final h = await _abrirCobroMixto(tester);

    // Sin importe: indicación y sin poder confirmar.
    expect(find.byKey(const Key('cobro-mixto-aviso')), findsOneWidget);
    expect(_confirmable(tester), isFalse);

    await _teclear(tester, ['4', '0', '0']);
    expect(_texto(tester, 'mixto-efectivo'), formatCents(400));
    expect(_texto(tester, 'mixto-tarjeta'), formatCents(265));
    expect(_texto(tester, 'mixto-entregado'), formatCents(400));
    expect(_texto(tester, 'mixto-cambio'), formatCents(0));
    expect(find.byKey(const Key('cobro-mixto-aviso')), findsNothing);
    expect(_confirmable(tester), isTrue);

    await _tap(tester, find.byKey(const Key('mixto-billete-500')));
    expect(_texto(tester, 'mixto-entregado'), formatCents(500));
    expect(_texto(tester, 'mixto-cambio'), formatCents(100));

    await _tap(tester, find.byKey(const Key('cobro-confirmar')));
    await h.settle(tester);

    expect(find.text('Ticket nº 1 cobrado'), findsOneWidget);
    expect(
      _texto(tester, 'resultado-total'),
      'Total ${formatCents(665)} · Mixto',
    );
    expect(
      _texto(tester, 'resultado-efectivo'),
      'Efectivo ${formatCents(400)}',
    );
    expect(_texto(tester, 'resultado-tarjeta'), 'Tarjeta ${formatCents(265)}');
    expect(
      _texto(tester, 'resultado-entregado'),
      'Entregado ${formatCents(500)}',
    );
    expect(_texto(tester, 'resultado-cambio'), 'Cambio ${formatCents(100)}');

    final ticket = h.runtime.store.snapshot.ticketsTurno.single;
    expect(ticket.pagos, const [
      PagoTicket(metodo: MetodoPago.efectivo, importeCents: 400),
      PagoTicket(metodo: MetodoPago.tarjeta, importeCents: 265),
    ]);
    expect(ticket.metodoPago, MetodoPago.efectivo);
    expect(ticket.entregadoCents, 500);
    expect(ticket.cambioCents, 100);
    // La factura (con su reparto) queda encolada para el ERP.
    final job = h.runtime.outbox.jobs.singleWhere(
      (j) => j.tipo == SyncJobTipo.factura,
    );
    expect(job.payload['ticket'], ticket.toJson());

    await tester.tap(find.byKey(const Key('volver-salon')));
    await h.settle(tester);
    expect(h.runtime.sala.comandaDeMesa('m1'), isNull);

    await h.dispose(tester);
  });

  testWidgets('se puede teclear la parte con tarjeta y el entregado; el '
      'entregado insuficiente no deja confirmar', (tester) async {
    final h = await _abrirCobroMixto(tester);

    await _tap(tester, find.byKey(const Key('mixto-campo-tarjeta')));
    await _teclear(tester, ['2', '0', '0']);
    expect(_texto(tester, 'mixto-tarjeta'), formatCents(200));
    expect(_texto(tester, 'mixto-efectivo'), formatCents(465));
    expect(find.text('Efectivo (resto)'), findsOneWidget);

    await _tap(tester, find.byKey(const Key('mixto-campo-entregado')));
    await _teclear(tester, ['4', '0', '0']);
    expect(find.text('Falta'), findsOneWidget);
    expect(_texto(tester, 'mixto-cambio'), formatCents(65));
    expect(_confirmable(tester), isFalse);

    await _teclear(tester, ['C', '5', '0', '0']);
    expect(_texto(tester, 'mixto-cambio'), formatCents(35));
    expect(_confirmable(tester), isTrue);

    // Volver a la parte en efectivo conserva el reparto (valor propuesto) y
    // la primera tecla lo sustituye.
    await _tap(tester, find.byKey(const Key('mixto-campo-efectivo')));
    expect(_texto(tester, 'mixto-efectivo'), formatCents(465));
    await _teclear(tester, ['3']);
    expect(_texto(tester, 'mixto-efectivo'), formatCents(3));
    expect(_texto(tester, 'mixto-tarjeta'), formatCents(662));
    await _teclear(tester, ['C', '4', '6', '5']);

    await _tap(tester, find.byKey(const Key('cobro-confirmar')));
    await h.settle(tester);
    final ticket = h.runtime.store.snapshot.ticketsTurno.single;
    expect(ticket.efectivoCents, 465);
    expect(ticket.tarjetaCents, 200);
    expect(ticket.entregadoCents, 500);
    expect(ticket.metodoPago, MetodoPago.efectivo);
    expect(_texto(tester, 'resultado-cambio'), 'Cambio ${formatCents(35)}');

    await h.dispose(tester);
  });

  testWidgets('validaciones: ninguna parte puede igualar o superar el total; '
      'mitad y mitad', (tester) async {
    final h = await _abrirCobroMixto(tester);

    await _teclear(tester, ['6', '6', '5']);
    expect(_texto(tester, 'cobro-mixto-aviso'), contains('menor que el total'));
    expect(_texto(tester, 'cobro-mixto-aviso'), contains('en efectivo'));
    expect(find.byKey(const Key('mixto-cambio')), findsNothing);
    expect(_confirmable(tester), isFalse);

    await _teclear(tester, ['C', '9', '0', '0']);
    expect(_confirmable(tester), isFalse);

    await _tap(tester, find.byKey(const Key('mixto-campo-tarjeta')));
    await _teclear(tester, ['6', '6', '5']);
    expect(_texto(tester, 'cobro-mixto-aviso'), contains('con tarjeta'));
    expect(_confirmable(tester), isFalse);

    await _tap(tester, find.byKey(const Key('mixto-mitad')));
    expect(_texto(tester, 'mixto-efectivo'), formatCents(332));
    expect(_texto(tester, 'mixto-tarjeta'), formatCents(333));
    expect(_confirmable(tester), isTrue);

    await _tap(tester, find.byKey(const Key('cobro-confirmar')));
    await h.settle(tester);
    final ticket = h.runtime.store.snapshot.ticketsTurno.single;
    expect(ticket.metodoPago, MetodoPago.tarjeta, reason: 'mayor importe');
    expect(ticket.efectivoCents, 332);
    expect(ticket.tarjetaCents, 333);

    await h.dispose(tester);
  });

  testWidgets('r1: si la cuenta cambia justo antes de confirmar no se cobra '
      'y se avisa; con el total nuevo sí', (tester) async {
    final h = await _abrirCobroMixto(tester);
    await _teclear(tester, ['4', '0', '0']);
    expect(_texto(tester, 'mixto-tarjeta'), formatCents(265));

    // Un comandero añade una caña y el cajero pulsa antes del siguiente
    // frame: el botón aún tiene el reparto sobre 6,65 €.
    await h.runtime.sala.aceptarLineas(
      ComandaSubmitPayload(mesaId: 'm1', lineas: [linea('l2', 'CANA', 1)]),
    );
    await tester.tap(find.byKey(const Key('cobro-confirmar')));
    await h.settle(tester);

    expect(_texto(tester, 'cobro-error'), contains('ha cambiado'));
    expect(h.runtime.store.snapshot.ticketsTurno, isEmpty);
    expect(_texto(tester, 'cobro-total'), formatCents(760));
    expect(_texto(tester, 'mixto-tarjeta'), formatCents(360));

    // Revisado el reparto, se confirma con el total que se ve.
    await _tap(tester, find.byKey(const Key('cobro-confirmar')));
    await h.settle(tester);
    final ticket = h.runtime.store.snapshot.ticketsTurno.single;
    expect(ticket.totalCents, 760);
    expect(ticket.efectivoCents, 400);
    expect(ticket.tarjetaCents, 360);

    await h.dispose(tester);
  });

  testWidgets('en una pantalla estrecha el cobro mixto cabe (teclado debajo)', (
    tester,
  ) async {
    final h = await _abrirCobroMixto(tester);
    tester.view.physicalSize = const Size(480, 900);
    await tester.pumpAndSettle();
    await _teclear(tester, ['4', '0', '0']);
    expect(_texto(tester, 'mixto-tarjeta'), formatCents(265));
    expect(_confirmable(tester), isTrue);
    expect(tester.takeException(), isNull);
    await h.dispose(tester);
  });

  testWidgets('cambiar de Mixto a Efectivo o Tarjeta sigue cobrando como '
      'siempre', (tester) async {
    final h = await _abrirCobroMixto(tester);
    await _teclear(tester, ['4', '0', '0']);
    await _tap(tester, find.text('Tarjeta'));
    expect(find.byKey(const Key('teclado-mixto')), findsNothing);
    await _tap(tester, find.byKey(const Key('cobro-confirmar')));
    await h.settle(tester);
    final ticket = h.runtime.store.snapshot.ticketsTurno.single;
    expect(ticket.esMixto, isFalse);
    expect(ticket.metodoPago, MetodoPago.tarjeta);
    expect(
      _texto(tester, 'resultado-total'),
      'Total ${formatCents(665)} · '
      'Tarjeta',
    );
    expect(find.byKey(const Key('resultado-cambio')), findsNothing);

    await h.dispose(tester);
  });

  testWidgets('el Cierre Z lista el ticket mixto con su desglose y reparte '
      'las ventas', (tester) async {
    final clock = FakeClock();
    final mixto = Ticket(
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
      pagos: const [
        PagoTicket(metodo: MetodoPago.efectivo, importeCents: 50),
        PagoTicket(metodo: MetodoPago.tarjeta, importeCents: 140),
      ],
      entregadoCents: 100,
    );
    expect(
      formatFormaCobro(mixto),
      'Mixto: efectivo ${formatCents(50)} + tarjeta ${formatCents(140)}',
    );
    final h = HostHarness(
      inicial: snapshotPrueba(
        extra: (s) => s.copyWith(
          ticketsTurno: [mixto],
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

    expect(_texto(tester, 'z-efectivo'), formatCents(50));
    expect(_texto(tester, 'z-tarjeta'), formatCents(140));
    expect(_texto(tester, 'z-mixtos'), '1');
    expect(_texto(tester, 'efectivo-esperado'), formatCents(10050));
    final detalle = find.byKey(const Key('ticket-ticket-1-detalle'));
    await tester.ensureVisible(detalle);
    expect(
      tester.widget<Text>(detalle).data,
      startsWith(formatFormaCobro(mixto)),
    );

    await h.dispose(tester);
  });
}
