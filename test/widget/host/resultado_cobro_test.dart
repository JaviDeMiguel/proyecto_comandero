import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proyecto_comandero/core/isolates/escpos/ticket_documents.dart'
    show EmpresaTicket;
import 'package:proyecto_comandero/core/money/money.dart';
import 'package:proyecto_comandero/features/host/application/host_state_repository.dart';
import 'package:proyecto_comandero/features/host/data/in_memory_host_state_repository.dart';
import 'package:proyecto_comandero/features/host/domain/empresa_emisora.dart';
import 'package:proyecto_comandero/features/host/domain/host_settings.dart'
    show FiscalSettings;
import 'package:proyecto_comandero/features/host/domain/host_snapshot.dart';
import 'package:proyecto_comandero/features/host/presentation/resultado_cobro_dialog.dart';
import 'package:proyecto_comandero/features/impresion/domain/formato_impresion.dart';
import 'package:proyecto_comandero/features/sala/domain/ticket.dart';

import 'support/host_harness.dart';

final EmpresaEmisora _empresa = EmpresaEmisora(
  nombre: 'Bar Prueba SL',
  cifnif: 'B12345678',
  obtenidaEn: DateTime(2026, 10, 7, 9),
);

/// Diario en memoria cuya escritura puede quedarse esperando: retiene la
/// impresión de la factura, que se encola después de guardar la marca.
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

const FormatoImpresion _modoFactura = FormatoImpresion(
  emision: EmisionTicket(modo: ModoEmision.facturaAlCobrar),
);

const Key _kFactura = Key('imprimir-factura');
const Key _kProvisional = Key('copia-provisional');

String? _texto(WidgetTester tester, String key) =>
    tester.widget<Text>(find.byKey(Key(key))).data;

bool _activo(WidgetTester tester, Key key) =>
    tester.widget<ButtonStyleButton>(find.byKey(key)).onPressed != null;

/// Tooltip que explica por qué «Imprimir factura» está desactivado (nulo si
/// no hay).
String? _motivo(WidgetTester tester) {
  final tooltip = find.ancestor(
    of: find.byKey(_kFactura),
    matching: find.byType(Tooltip),
  );
  if (tooltip.evaluate().isEmpty) return null;
  return tester.widget<Tooltip>(tooltip.first).message;
}

String _etiquetaFactura(WidgetTester tester) => tester
    .widget<Text>(
      find.descendant(of: find.byKey(_kFactura), matching: find.byType(Text)),
    )
    .data!;

Future<void> _tap(WidgetTester tester, HostHarness h, Key key) async {
  await tester.ensureVisible(find.byKey(key));
  await tester.pump();
  await tester.tap(find.byKey(key));
  await h.settle(tester);
}

/// Mesa 1 con 2 cañas (1,90 €) cobrada con tarjeta desde la interfaz, con
/// una impresora por rol. [conNif]: la empresa del ERP (con NIF) en el
/// diario. Con [erp], la facturación usa ese puerto y la cola arranca.
Future<HostHarness> _cobrar(
  WidgetTester tester, {
  FormatoImpresion formato = const FormatoImpresion(),
  bool conNif = true,
  bool conImpresora = true,
  bool repoLento = false,
  FakeInvoicePort? erp,
}) async {
  final clock = FakeClock();
  final inicial = snapshotPrueba(
    comandas: [
      comandaPrueba('m1', [linea('l1', 'CANA', 2)], clock: clock),
    ],
    extra: conNif ? (s) => s.copyWith(empresa: _empresa) : null,
  );
  final h = HostHarness(
    inicial: inicial,
    repo: repoLento ? _RepoLento(inicial) : null,
    ajustes: ajustesPrueba(conImpresora: conImpresora, formato: formato),
    impresora: FakePrinterPort(),
  );
  await h.pump(tester);
  if (erp != null) {
    h.runtime.billing.configurar(
      fiscal: const FiscalSettings(
        codcliente: 'TPV',
        codpagoEfectivo: 'TPVEFE',
        codpagoTarjeta: 'TPVTAR',
        codalmacen: 'ALG',
        emitirFacturas: false,
      ),
      invoice: erp,
    );
    await h.runtime.outbox.start();
  }
  await tester.tap(find.byKey(const Key('mesa-m1')));
  await h.settle(tester);
  await tester.tap(find.byKey(const Key('cobrar')));
  await h.settle(tester);
  await tester.tap(find.text('Tarjeta'));
  await tester.pump();
  await tester.tap(find.byKey(const Key('cobro-confirmar')));
  await h.settle(tester);
  expect(find.text('Ticket nº 1 cobrado'), findsOneWidget);
  return h;
}

/// Simula la llegada de la factura de FS escribiendo `ticket.conFactura`
/// en el diario del runtime.
Future<void> _recibirFactura(
  WidgetTester tester,
  HostHarness h, {
  DateTime? fecha,
  bool conFecha = true,
  int? totalFsCents,
}) async {
  final store = h.runtime.store;
  final ticket = store.snapshot.ticketsTurno.single;
  await store.update(
    (s) => s.conTicket(
      ticket.conFactura(
        FacturaSincronizada(
          estado: EstadoSincronizacion.sincronizado,
          idfactura: 7,
          codigo: 'F2026S7',
          numero: 7,
          fecha: conFecha ? (fecha ?? DateTime(2026, 10, 7, 13, 31)) : null,
          totalFsCents: totalFsCents ?? ticket.totalCents,
        ),
      ),
    ),
  );
  await h.settle(tester);
}

List<String> _trabajos(HostHarness h) => [
  for (final job in h.impresora!.jobs) job.description,
];

void main() {
  testWidgets('el código aparece cuando el diario recibe la factura', (
    tester,
  ) async {
    final h = await _cobrar(tester);

    // Contrato de siempre.
    expect(
      _texto(tester, 'resultado-total'),
      'Total ${formatCents(190)} · '
      'Tarjeta',
    );
    expect(find.byKey(const Key('volver-salon')), findsOneWidget);
    // Lo nuevo: factura pendiente y provisional impreso al instante.
    expect(_texto(tester, 'resultado-factura'), 'Enviando a FacturaScripts…');
    expect(
      _texto(tester, 'resultado-impresion'),
      'Documento provisional '
      'impreso',
    );
    expect(_trabajos(h), ['Ticket 1 · provisional']);
    expect(_activo(tester, _kFactura), isFalse);
    expect(_motivo(tester), contains('aún no tiene número de FacturaScripts'));
    expect(find.byKey(_kProvisional), findsOneWidget);

    await _recibirFactura(tester, h);

    expect(_texto(tester, 'resultado-factura'), 'Factura F2026S7');
    expect(_activo(tester, _kFactura), isTrue);
    expect(_motivo(tester), isNull);
    expect(_etiquetaFactura(tester), 'Imprimir factura');
    // Con la factura imprimible ya no se ofrece la copia provisional.
    expect(find.byKey(_kProvisional), findsNothing);

    await h.dispose(tester);
  });

  testWidgets('la factura en error se muestra con su motivo', (tester) async {
    final h = await _cobrar(tester);
    final store = h.runtime.store;
    final ticket = store.snapshot.ticketsTurno.single;
    await store.update(
      (s) => s.conTicket(
        ticket.conFactura(
          FacturaSincronizada(
            estado: EstadoSincronizacion.error,
            error: 'fecha no válida',
          ),
        ),
      ),
    );
    await h.settle(tester);

    expect(
      _texto(tester, 'resultado-factura'),
      'Factura con error: fecha no válida',
    );
    expect(_activo(tester, _kFactura), isFalse);
    expect(_activo(tester, _kProvisional), isTrue);

    await h.dispose(tester);
  });

  group('«Imprimir factura» solo está activo con código, fecha y total de FS '
      'y NIF', () {
    testWidgets('sin NIF del emisor', (tester) async {
      final h = await _cobrar(tester, conNif: false);
      await _recibirFactura(tester, h);

      expect(_activo(tester, _kFactura), isFalse);
      expect(_motivo(tester), startsWith('Falta el NIF del emisor'));
      expect(find.byKey(_kProvisional), findsOneWidget);

      await h.dispose(tester);
    });

    testWidgets('sin la fecha de FS', (tester) async {
      final h = await _cobrar(tester);
      await _recibirFactura(tester, h, conFecha: false);

      expect(_activo(tester, _kFactura), isFalse);
      expect(_motivo(tester), contains('no tiene la fecha o el total'));

      await h.dispose(tester);
    });

    testWidgets('con un total de FS distinto del ticket', (tester) async {
      final h = await _cobrar(tester);
      await _recibirFactura(tester, h, totalFsCents: 191);

      expect(_activo(tester, _kFactura), isFalse);
      expect(_motivo(tester), contains('no coincide con el del ticket'));

      await h.dispose(tester);
    });
  });

  testWidgets('la 1ª vez es un trabajo ORIGINAL y después el botón dice '
      '«Imprimir duplicado»', (tester) async {
    final h = await _cobrar(tester);
    await _recibirFactura(tester, h);

    await _tap(tester, h, _kFactura);

    expect(_trabajos(h).last, 'Factura F2026S7 (original)');
    expect(find.text('Factura enviada a la impresora'), findsOneWidget);
    expect(_etiquetaFactura(tester), 'Imprimir duplicado');
    expect(_texto(tester, 'resultado-impresion'), 'Factura impresa (original)');
    final ticket = h.runtime.store.snapshot.ticketsTurno.single;
    expect(ticket.impresion.originalImpreso, isTrue);

    await _tap(tester, h, _kFactura);

    expect(_trabajos(h).last, 'Factura F2026S7 (duplicado 1)');
    expect(
      _texto(tester, 'resultado-impresion'),
      'Factura impresa (original) · 1 duplicado',
    );
    expect(_etiquetaFactura(tester), 'Imprimir duplicado');

    await h.dispose(tester);
  });

  testWidgets('«Copia provisional» reimprime el provisional con COPIA', (
    tester,
  ) async {
    final h = await _cobrar(tester);

    await _tap(tester, h, _kProvisional);

    expect(_trabajos(h), [
      'Ticket 1 · provisional',
      'Ticket 1 · provisional (copia)',
    ]);
    expect(
      find.text('Copia provisional enviada a la impresora'),
      findsOneWidget,
    );
    expect(
      _texto(tester, 'resultado-impresion'),
      'Documento provisional impreso · 1 copia',
    );
    expect(
      h.runtime.store.snapshot.ticketsTurno.single.impresion.copiasProvisional,
      1,
    );

    await h.dispose(tester);
  });

  testWidgets('modo factura: espera con la factura retenida, sin dejar '
      'imprimir, y después imprime el ORIGINAL', (tester) async {
    final erp = FakeInvoicePort()..puerta = Completer<void>();
    addTearDown(erp.abrirPuerta);
    final h = await _cobrar(tester, formato: _modoFactura, erp: erp);

    expect(erp.retenidas, 1);
    expect(_texto(tester, 'resultado-factura'), 'Enviando a FacturaScripts…');
    expect(
      _texto(tester, 'resultado-impresion'),
      'Esperando la factura (10 s)…',
    );
    expect(_activo(tester, _kFactura), isFalse);
    expect(_motivo(tester), textoEmisionEnCurso);
    expect(_trabajos(h), isEmpty);

    erp.abrirPuerta();
    await h.settle(tester);

    expect(_texto(tester, 'resultado-factura'), 'Factura F2026S1');
    expect(_trabajos(h), ['Factura F2026S1 (original)']);
    expect(_texto(tester, 'resultado-impresion'), 'Factura impresa (original)');
    expect(_activo(tester, _kFactura), isTrue);
    expect(_etiquetaFactura(tester), 'Imprimir duplicado');
    expect(find.byKey(_kProvisional), findsNothing);

    await h.dispose(tester);
  });

  testWidgets('una factura imprimible sigue inactiva mientras la '
      'emisión automática está pendiente', (tester) async {
    final erp = FakeInvoicePort()..puerta = Completer<void>();
    addTearDown(erp.abrirPuerta);
    final h = await _cobrar(tester, formato: _modoFactura, erp: erp);
    final ticket = h.runtime.store.snapshot.ticketsTurno.single;
    expect(h.runtime.printing.emisionPendiente(ticket.id), isTrue);

    // Una factura ya imprimible (código, fecha, total de FS y NIF) con la
    // emisión aún en curso: el botón no compite con la impresión automática.
    final imprimible = ticket.conFactura(
      FacturaSincronizada(
        estado: EstadoSincronizacion.sincronizado,
        codigo: 'F2026S9',
        fecha: DateTime(2026, 10, 7, 13, 31),
        totalFsCents: ticket.totalCents,
      ),
    );
    const cabecera = EmpresaTicket(nombre: 'Bar Prueba', cifnif: 'B12345678');
    final pendiente = EstadoAccionesTicket.de(
      imprimible,
      cabecera: cabecera,
      enTurno: true,
      emisionPendiente: true,
    );
    expect(pendiente.facturaActiva, isFalse);
    expect(pendiente.motivoFacturaInactiva, textoEmisionEnCurso);
    expect(pendiente.mostrarProvisional, isFalse);
    final libre = EstadoAccionesTicket.de(
      imprimible,
      cabecera: cabecera,
      enTurno: true,
      emisionPendiente: false,
    );
    expect(libre.facturaActiva, isTrue);
    expect(libre.etiquetaFactura, textoImprimirFactura);

    erp.abrirPuerta();
    await h.settle(tester);
    await h.dispose(tester);
  });

  testWidgets('dos toques seguidos en «Imprimir factura» con el envío '
      'retenido dan un solo trabajo y el botón queda inactivo', (tester) async {
    final h = await _cobrar(tester, repoLento: true);
    await _recibirFactura(tester, h);
    final repo = h.repo as _RepoLento;
    final escritura = repo.bloqueo = Completer<void>();
    addTearDown(() {
      if (!escritura.isCompleted) escritura.complete();
    });

    await tester.tap(find.byKey(_kFactura));
    await tester.pump();
    await tester.pump();

    // La marca del ORIGINAL espera a guardarse: aún no hay trabajo y el
    // botón (ya «Imprimir duplicado») no admite otra petición.
    expect(_trabajos(h), ['Ticket 1 · provisional']);
    expect(_activo(tester, _kFactura), isFalse);
    expect(find.byKey(_kProvisional), findsNothing);

    await tester.tap(find.byKey(_kFactura), warnIfMissed: false);
    await tester.pump();

    repo.bloqueo = null;
    escritura.complete();
    await h.settle(tester);

    expect(_trabajos(h), [
      'Ticket 1 · provisional',
      'Factura F2026S7 (original)',
    ]);
    final ticket = h.runtime.store.snapshot.ticketsTurno.single;
    expect(ticket.impresion.duplicados, 0);
    expect(_activo(tester, _kFactura), isTrue);
    expect(_etiquetaFactura(tester), 'Imprimir duplicado');

    await h.dispose(tester);
  });

  testWidgets('sin impresora de tickets, «Copia provisional» muestra el '
      'error y no marca nada', (tester) async {
    final h = await _cobrar(tester, conImpresora: false);
    expect(_texto(tester, 'resultado-impresion'), 'Sin imprimir');

    await _tap(tester, h, _kProvisional);

    expect(
      find.text('No hay impresora de tickets configurada'),
      findsOneWidget,
    );
    expect(h.impresora!.jobs, isEmpty);
    final ticket = h.runtime.store.snapshot.ticketsTurno.single;
    expect(ticket.impresion.copiasProvisional, 0);
    expect(ticket.impresion.provisionalEn, isNull);
    expect(_texto(tester, 'resultado-impresion'), 'Sin imprimir');
    expect(_activo(tester, _kProvisional), isTrue);

    await h.dispose(tester);
  });

  testWidgets('tras el Cierre Z el ticket recibido sirve de respaldo', (
    tester,
  ) async {
    final h = await _cobrar(tester);

    await h.runtime.store.update((s) => s.copyWith(ticketsTurno: const []));
    await h.settle(tester);

    expect(find.text('Ticket nº 1 cobrado'), findsOneWidget);
    expect(
      _texto(tester, 'resultado-total'),
      'Total ${formatCents(190)} · '
      'Tarjeta',
    );
    expect(_activo(tester, _kFactura), isFalse);
    expect(_motivo(tester), textoTurnoCerrado);
    expect(_activo(tester, _kProvisional), isFalse);

    await h.dispose(tester);
  });
}
