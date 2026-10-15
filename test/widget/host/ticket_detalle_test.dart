import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proyecto_comandero/core/money/money.dart';
import 'package:proyecto_comandero/features/host/domain/empresa_emisora.dart';
import 'package:proyecto_comandero/features/host/domain/host_snapshot.dart';
import 'package:proyecto_comandero/features/host/domain/sync_job.dart';
import 'package:proyecto_comandero/features/host/presentation/resultado_cobro_dialog.dart'
    show textoTurnoCerrado;
import 'package:proyecto_comandero/features/host/presentation/widgets/ticket_detalle_dialog.dart';
import 'package:proyecto_comandero/features/sala/domain/precuenta_emitida.dart';
import 'package:proyecto_comandero/features/sala/domain/ticket.dart';

import 'support/host_harness.dart';

const String _ticketId = 'ticket-1';

final EmpresaEmisora _empresa = EmpresaEmisora(
  nombre: 'Bar Prueba SL',
  cifnif: 'B12345678',
  obtenidaEn: DateTime(2026, 10, 7, 9),
);

TotalesTicket _totales() => TotalesTicket(
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
);

/// Ticket nº 1 de la Mesa 1 (2 cañas, 1,90 € con tarjeta) cobrado a las
/// 13:30, con la precuenta nº 1 de las 13:20 y el provisional impreso.
Ticket _ticket(FakeClock clock, {required FacturaSincronizada factura}) =>
    Ticket(
      id: _ticketId,
      numeroLocal: 1,
      mesaId: 'm1',
      nombreMesa: 'Mesa 1',
      comandaId: 'comanda-m1',
      fechaHora: clock.now,
      lineas: [linea('l1', 'CANA', 2)],
      totales: _totales(),
      metodoPago: MetodoPago.tarjeta,
      factura: factura,
      precuentas: [
        PrecuentaEmitida(
          numero: 1,
          emitidaEn: clock.now.subtract(const Duration(minutes: 10)),
          comandaId: 'comanda-m1',
          nombreMesa: 'Mesa 1',
          lineas: const [
            LineaPrecuenta(
              descripcion: 'Caña',
              cantidad: 2,
              pvpUnitarioCents: 95,
              importeCents: 190,
              ivaBp: 1000,
            ),
          ],
          totales: _totales(),
        ),
      ],
      impresion: ImpresionTicket(provisionalEn: clock.now),
    );

FacturaSincronizada _facturaImprimible() => FacturaSincronizada(
  estado: EstadoSincronizacion.sincronizado,
  idfactura: 7,
  codigo: 'F2026S7',
  numero: 7,
  fecha: DateTime(2026, 10, 7, 13, 31),
  totalFsCents: 190,
);

FacturaSincronizada _facturaEnError() => FacturaSincronizada(
  estado: EstadoSincronizacion.error,
  error: 'fecha no válida',
);

/// Host con el ticket en el turno, la empresa con NIF y, si se pasa,
/// [trabajo] en la cola.
HostHarness _harness(
  FakeClock clock, {
  required Ticket ticket,
  SyncJob? trabajo,
}) => HostHarness(
  inicial: snapshotPrueba(
    extra: (s) => s.copyWith(
      ticketsTurno: [ticket],
      cierreAbierto: CierreAbierto(
        id: 'turno-1',
        abiertoEn: clock.now.subtract(const Duration(hours: 4)),
        fondoCajaCents: 10000,
      ),
      empresa: _empresa,
      cola: [?trabajo],
    ),
  ),
  ajustes: ajustesPrueba(conImpresora: true),
  impresora: FakePrinterPort(),
);

String? _texto(WidgetTester tester, String key) =>
    tester.widget<Text>(find.byKey(Key(key))).data;

bool _activo(WidgetTester tester, String key) =>
    tester.widget<ButtonStyleButton>(find.byKey(Key(key))).onPressed != null;

Future<void> _tap(WidgetTester tester, HostHarness h, String key) async {
  await tester.ensureVisible(find.byKey(Key(key)));
  await tester.pump();
  await tester.tap(find.byKey(Key(key)));
  await h.settle(tester);
}

/// Abre «Caja y Cierre Z» y toca la fila del ticket.
Future<void> _abrirDetalle(WidgetTester tester, HostHarness h) async {
  await h.pump(tester);
  await tester.tap(find.byKey(const Key('accion-cierre-z')));
  await h.settle(tester);
  await _tap(tester, h, 'ticket-$_ticketId');
  expect(find.byType(TicketDetalleDialog), findsOneWidget);
}

Finder _enVistaPrevia(String texto) => find.descendant(
  of: find.byKey(const Key('detalle-vista-previa')),
  matching: find.textContaining(texto),
);

List<String> _trabajos(HostHarness h) => [
  for (final job in h.impresora!.jobs) job.description,
];

void main() {
  testWidgets('se abre desde la fila de «Caja y Cierre Z» con los datos, las '
      'precuentas, el estado de impresión y la vista previa; «Imprimir '
      'factura» imprime el ORIGINAL', (tester) async {
    final clock = FakeClock();
    final h = _harness(
      clock,
      ticket: _ticket(clock, factura: _facturaImprimible()),
    );
    await _abrirDetalle(tester, h);

    expect(_texto(tester, 'detalle-titulo'), 'Ticket nº 1');
    expect(
      _texto(tester, 'detalle-total'),
      'Total ${formatCents(190)} · '
      'Tarjeta',
    );
    expect(
      _texto(tester, 'detalle-precuenta-1'),
      'Precuenta nº 1 · 13:20 · ${formatCents(190)}',
    );
    expect(_texto(tester, 'detalle-factura'), 'Factura F2026S7');
    expect(find.byKey(const Key('reintentar-factura')), findsNothing);
    expect(
      _texto(tester, 'detalle-impresion'),
      'Provisional impreso a las 13:30\nFactura sin imprimir',
    );
    // Vista previa de la factura imprimible (el ORIGINAL que saldría).
    expect(find.byKey(const Key('detalle-motivo')), findsNothing);
    expect(_enVistaPrevia('FACTURA SIMPLIFICADA'), findsWidgets);
    expect(_enVistaPrevia('F2026S7'), findsWidgets);
    expect(_enVistaPrevia('DUPLICADO'), findsNothing);
    expect(find.byKey(const Key('copia-provisional')), findsNothing);
    expect(_activo(tester, 'imprimir-factura'), isTrue);

    await _tap(tester, h, 'imprimir-factura');

    expect(_trabajos(h), ['Factura F2026S7 (original)']);
    expect(
      _texto(tester, 'detalle-impresion'),
      'Provisional impreso a las 13:30\nOriginal impreso a las 13:30\n'
      'Duplicados: 0',
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('imprimir-factura')),
        matching: find.text('Imprimir duplicado'),
      ),
      findsOneWidget,
    );
    // La vista previa pasa a ser la del DUPLICADO nº 1.
    expect(_enVistaPrevia('DUPLICADO'), findsWidgets);

    await _tap(tester, h, 'detalle-cerrar');
    expect(find.byType(TicketDetalleDialog), findsNothing);

    await h.dispose(tester);
  });

  testWidgets('factura en error: motivo, vista previa del provisional, '
      '«Reintentar factura» y «Copia provisional»', (tester) async {
    final clock = FakeClock();
    final ticket = _ticket(clock, factura: _facturaEnError());
    final h = _harness(
      clock,
      ticket: ticket,
      trabajo: SyncJob(
        id: 'factura:$_ticketId',
        tipo: SyncJobTipo.factura,
        payload: {'ticket': ticket.toJson()},
        creadoEn: clock.now,
        intentos: 1,
        estado: SyncJobEstado.error,
        ultimoError: 'fecha no válida',
      ),
    );
    await _abrirDetalle(tester, h);

    expect(
      _texto(tester, 'detalle-factura'),
      'Factura con error: fecha no válida',
    );
    expect(
      _texto(tester, 'detalle-motivo'),
      contains('aún no tiene número de FacturaScripts'),
    );
    expect(_enVistaPrevia('DOCUMENTO PROVISIONAL'), findsWidgets);
    expect(_enVistaPrevia('COPIA'), findsWidgets);
    expect(_activo(tester, 'imprimir-factura'), isFalse);

    await _tap(tester, h, 'reintentar-factura');

    final job = h.runtime.store.snapshot.jobPorId('factura:$_ticketId')!;
    expect(job.estado, SyncJobEstado.pendiente);
    expect(
      find.text('Factura reenviada a la cola de sincronización'),
      findsOneWidget,
    );

    await _tap(tester, h, 'copia-provisional');

    expect(_trabajos(h), ['Ticket 1 · provisional (copia)']);
    expect(
      _texto(tester, 'detalle-impresion'),
      'Provisional impreso a las 13:30 · 1 copia\nFactura sin imprimir',
    );

    await h.dispose(tester);
  });

  testWidgets('si el ticket sale del turno lo indica y no ofrece acciones', (
    tester,
  ) async {
    final clock = FakeClock();
    final h = _harness(
      clock,
      ticket: _ticket(clock, factura: _facturaImprimible()),
    );
    await _abrirDetalle(tester, h);

    await h.runtime.store.update((s) => s.copyWith(ticketsTurno: const []));
    await h.settle(tester);

    expect(_texto(tester, 'detalle-turno-cerrado'), textoTurnoCerrado);
    expect(_texto(tester, 'detalle-titulo'), 'Ticket nº 1');
    expect(find.byKey(const Key('detalle-vista-previa')), findsNothing);
    expect(_activo(tester, 'imprimir-factura'), isFalse);

    await h.dispose(tester);
  });
}
