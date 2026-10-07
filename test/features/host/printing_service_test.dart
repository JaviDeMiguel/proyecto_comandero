import 'dart:typed_data';

import 'package:proyecto_comandero/core/errors/app_exception.dart';
import 'package:proyecto_comandero/core/isolates/escpos/escpos.dart';
import 'package:proyecto_comandero/core/isolates/isolate_runner.dart';
import 'package:proyecto_comandero/core/network/printing/raw_printer_transport.dart';
import 'package:proyecto_comandero/features/host/application/printing_service.dart';
import 'package:proyecto_comandero/features/host/domain/host_settings.dart';
import 'package:proyecto_comandero/features/sala/domain/enrutamiento_comandas.dart';
import 'package:proyecto_comandero/features/sala/domain/linea_comanda.dart';
import 'package:proyecto_comandero/features/sala/domain/ticket.dart';
import 'package:test/test.dart';

import '../../core/isolates/escpos/escpos_decoder.dart';
import 'fakes/fake_ports.dart';
import 'support/host_test_support.dart';

String textoDe(Uint8List bytes) => decodeEscPos(bytes).texts.join('|');

bool abreCajon(Uint8List bytes) =>
    decodeEscPos(bytes).named('drawer').isNotEmpty;

void main() {
  late SalaFixture f;
  late FakePrinterPort printer;
  late PrintingService service;
  final cocina = PrinterEndpoint('10.0.0.10');
  final barra = PrinterEndpoint('10.0.0.11');
  final tickets = PrinterEndpoint('10.0.0.12');

  setUp(() async {
    // Bebidas (y sus subfamilias) a barra; el resto, a cocina.
    f = await SalaFixture.create(
      catalogo: catalogoConSubfamilias(),
      enrutamiento: const EnrutamientoComandas(
        porFamilia: {'BEB': DestinoPreparacion.barra},
      ),
    );
    printer = FakePrinterPort();
    service = PrintingService(
      alerts: f.alerts,
      runner: const InlineIsolateRunner(),
      settings: ImpresionSettings(
        cocina: cocina,
        barra: barra,
        tickets: tickets,
        abrirCajonEfectivo: true,
      ),
      nombreTpv: 'Barra',
      printer: printer,
      empresa: const EmpresaTicket(nombre: 'Bar Manolo', cifnif: 'B12345678'),
      now: f.clock.call,
    );
    f.sala.addEffects(service);
  });

  tearDown(() async {
    await service.idle();
    await f.dispose();
  });

  Future<void> settle() async {
    await f.sala.idle();
    await service.idle();
  }

  test('al aceptar líneas imprime una comanda por destino', () async {
    await f.sala.aceptarLineas(
      submit('m1', [
        linea('l1', 'PAELLA', 2, nota: 'sin marisco'),
        // El comandero dice cocina, pero la familia (Cervezas ⊂ Bebidas)
        // manda: el host la enruta a barra.
        linea('l2', 'CANA', 3),
      ], camarero: 'Ana'),
    );
    await settle();

    expect(printer.jobs, hasLength(2));
    final porEndpoint = {for (final j in printer.jobs) j.endpoint: j};
    final textoCocina = textoDe(porEndpoint[cocina]!.bytes);
    expect(textoCocina, contains('COCINA'));
    expect(textoCocina, contains('Mesa 1'));
    expect(textoCocina, contains('Paella'));
    expect(textoCocina, contains('sin marisco'));
    expect(textoCocina, isNot(contains('Caña')));
    expect(textoCocina, contains('Ana'));
    final textoBarra = textoDe(porEndpoint[barra]!.bytes);
    expect(textoBarra, contains('BARRA'));
    expect(textoBarra, contains('Caña'));
    expect(porEndpoint[cocina]!.description, contains('cocina'));

    // Una retransmisión sin líneas nuevas no imprime otra vez.
    await f.sala.aceptarLineas(submit('m1', [linea('l1', 'PAELLA', 2)]));
    await settle();
    expect(printer.jobs, hasLength(2));
  });

  test('sin impresora de barra las líneas de barra salen por cocina', () async {
    service.configurar(settings: ImpresionSettings(cocina: cocina));
    await f.sala.aceptarLineas(
      submit('m1', [linea('l2', 'CANA', 1, destino: DestinoPreparacion.barra)]),
    );
    await settle();
    expect(printer.jobs.single.endpoint, cocina);
  });

  test('r1: un fallo no tipado al generar el ticket de cocina no impide '
      'que salga el de barra y avisa del de cocina', () async {
    // Servicio propio con su impresora: el del setUp sigue imprimiendo en
    // `printer` con un runner que no falla y no interviene en el test.
    final runner = _RunnerQueFallaLaPrimeraVez();
    final otraImpresora = FakePrinterPort();
    final conFallo = PrintingService(
      alerts: f.alerts,
      runner: runner,
      settings: ImpresionSettings(cocina: cocina, barra: barra),
      nombreTpv: 'Barra',
      printer: otraImpresora,
      now: f.clock.call,
    );
    f.sala.addEffects(conFallo);

    await f.sala.aceptarLineas(
      submit('m1', [linea('l1', 'PAELLA', 1), linea('l2', 'CANA', 2)]),
    );
    await settle();
    await conFallo.idle();

    // Se intentó cocina (falló) y después barra (salió).
    expect(runner.llamadas, 2);
    expect(otraImpresora.jobs.single.endpoint, barra);
    expect(textoDe(otraImpresora.jobs.single.bytes), contains('Caña'));
    final avisos = f.alerts.recientes.where((a) => a.origen == 'impresion');
    expect(
      avisos.single.titulo,
      'No se pudo imprimir la comanda de cocina de Mesa 1',
    );
    expect(avisos.single.detalle, contains('isolate caído'));
  });

  test('al cobrar imprime el ticket con cajón para efectivo', () async {
    await f.sala.aceptarLineas(submit('m1', [linea('l1', 'CANA', 7)]));
    await settle();
    printer.jobs.clear();
    final ticket = await f.sala.cobrar(
      'm1',
      MetodoPago.efectivo,
      entregadoCents: 1000,
    );
    await settle();

    final job = printer.jobs.single;
    expect(job.endpoint, tickets);
    expect(job.description, 'Ticket 1');
    final texto = textoDe(job.bytes);
    expect(texto, contains('Bar Manolo'));
    expect(texto, contains('TICKET'));
    expect(texto, contains('6,65'));
    expect(texto, contains('3,35'));
    expect(texto, contains(ticket.claveFactura));
    expect(abreCajon(job.bytes), isTrue);
  });

  test('cobro mixto: ticket con el desglose, cambio sobre el efectivo y '
      'cajón', () async {
    await f.sala.aceptarLineas(submit('m1', [linea('l1', 'CANA', 7)]));
    await settle();
    printer.jobs.clear();
    final ticket = await f.sala.cobrarMixto(
      'm1',
      efectivoCents: 400,
      entregadoCents: 500,
    );
    await settle();

    final job = printer.jobs.single;
    expect(job.endpoint, tickets);
    final textos = decodeEscPos(job.bytes).texts;
    final texto = textos.join('|');
    expect(texto, contains('6,65'));
    expect(texto, contains('Mixto'));
    expect(
      textos.where((t) => t.startsWith('Efectivo') && t.contains('4,00')),
      hasLength(1),
    );
    expect(
      textos.where((t) => t.startsWith('Tarjeta') && t.contains('2,65')),
      hasLength(1),
    );
    expect(
      textos.where((t) => t.startsWith('Entregado')).single,
      contains('5,00'),
    );
    expect(
      textos.where((t) => t.startsWith('Cambio')).single,
      contains('1,00'),
    );
    expect(abreCajon(job.bytes), isTrue, reason: 'hay parte en efectivo');

    // La reimpresión lleva el mismo desglose y nunca abre el cajón.
    printer.jobs.clear();
    await service.imprimirTicket(ticket, reimpresion: true);
    await service.idle();
    final copia = textoDe(printer.jobs.single.bytes);
    expect(copia, contains('Mixto'));
    expect(copia, contains('COPIA'));
    expect(abreCajon(printer.jobs.single.bytes), isFalse);
  });

  test('cobro mixto sin abrirCajonEfectivo no abre el cajón; tarjeta sola '
      'tampoco', () async {
    service.configurar(settings: ImpresionSettings(tickets: tickets));
    await f.sala.aceptarLineas(submit('m1', [linea('l1', 'CANA', 7)]));
    await f.sala.cobrarMixto('m1', efectivoCents: 400);
    await settle();
    expect(abreCajon(printer.jobs.single.bytes), isFalse);

    service.configurar(
      settings: ImpresionSettings(tickets: tickets, abrirCajonEfectivo: true),
    );
    printer.jobs.clear();
    await f.sala.aceptarLineas(submit('m2', [linea('l2', 'CANA', 1)]));
    await f.sala.cobrar('m2', MetodoPago.tarjeta);
    await settle();
    final texto = textoDe(printer.jobs.single.bytes);
    expect(texto, contains('Tarjeta'));
    expect(texto, isNot(contains('Mixto')));
    expect(abreCajon(printer.jobs.single.bytes), isFalse);
  });

  test('pago único: mismos bytes que sin desglose', () async {
    await f.sala.aceptarLineas(submit('m1', [linea('l1', 'CANA', 7)]));
    await settle();
    printer.jobs.clear();
    final ticket = await f.sala.cobrar(
      'm1',
      MetodoPago.efectivo,
      entregadoCents: 1000,
    );
    await settle();
    final esperado = generarTicket(
      TicketPrintData(
        empresa: const EmpresaTicket(nombre: 'Bar Manolo', cifnif: 'B12345678'),
        tituloDocumento: 'TICKET',
        numero2: ticket.claveFactura,
        fechaHora: ticket.fechaHora,
        mesa: ticket.nombreMesa,
        lineas: [
          for (final l in ticket.lineas)
            LineaTicket(
              descripcion: l.descripcion,
              cantidad: l.cantidad,
              pvpUnitarioCents: l.pvpUnitarioCents,
              importeCents: l.importeCents,
            ),
        ],
        desglose: const [
          DesgloseIvaTicketPrint(ivaPct: 10, baseCents: 605, cuotaCents: 60),
        ],
        totalCents: 665,
        metodoPago: 'Efectivo',
        entregadoCents: 1000,
        cambioCents: 335,
        abrirCajon: true,
      ),
    );
    expect(printer.jobs.single.bytes, esperado);
  });

  test(
    'reimprimir con factura muestra el código y la marca de copia',
    () async {
      await f.sala.aceptarLineas(submit('m1', [linea('l1', 'CANA', 1)]));
      final ticket = await f.sala.cobrar('m1', MetodoPago.tarjeta);
      await settle();
      printer.jobs.clear();
      final facturado = ticket.conFactura(
        FacturaSincronizada(
          estado: EstadoSincronizacion.sincronizado,
          codigo: 'F2026S9',
        ),
      );
      await service.imprimirTicket(facturado, reimpresion: true);
      await service.idle();
      final texto = textoDe(printer.jobs.single.bytes);
      expect(texto, contains('FACTURA SIMPLIFICADA'));
      expect(texto, contains('F2026S9'));
      expect(texto, contains('COPIA'));
      expect(abreCajon(printer.jobs.single.bytes), isFalse);
    },
  );

  test(
    'desactivar imprimirTicketAlCobrar o no tener impresora no imprime',
    () async {
      service.configurar(
        settings: ImpresionSettings(
          tickets: tickets,
          imprimirTicketAlCobrar: false,
        ),
      );
      await f.sala.aceptarLineas(submit('m1', [linea('l1', 'CANA', 1)]));
      await f.sala.cobrar('m1', MetodoPago.tarjeta);
      await settle();
      expect(printer.jobs, isEmpty);

      service.configurar(settings: const ImpresionSettings());
      expect(service.disponible, isFalse);
      await f.sala.aceptarLineas(submit('m2', [linea('l2', 'CANA', 1)]));
      final ticket = await f.sala.cobrar('m2', MetodoPago.tarjeta);
      await settle();
      expect(printer.jobs, isEmpty);
      expect(
        () => service.imprimirTicket(ticket, reimpresion: true),
        throwsA(isA<PrinterException>()),
      );
    },
  );

  test(
    'precuenta: documento propio sin validez fiscal, sin clave ni cajón',
    () async {
      await f.sala.aceptarLineas(
        submit('m1', [
          linea('l1', 'CANA', 7),
          linea('l2', 'PAELLA', 1),
        ], camarero: 'Ana'),
      );
      await settle();
      await f.sala.anularLinea('m1', 'l2');
      await settle(); // el aviso de anulación a cocina
      printer.jobs.clear();
      final comanda = f.sala.comandaDeMesa('m1')!;
      final totales = f.sala.calcularTotales(comanda.lineasActivas.toList());

      await service.imprimirPrecuenta(f.sala.mesa('m1')!, comanda, totales);
      await service.idle();

      final job = printer.jobs.single;
      expect(job.endpoint, tickets);
      expect(job.description, 'Precuenta Mesa 1');
      final texto = textoDe(job.bytes);
      expect(texto, contains('PRECUENTA'));
      expect(texto, contains('DOCUMENTO SIN VALIDEZ FISCAL'));
      expect(texto, contains('Ana'));
      expect(texto, contains('6,65'));
      expect(texto, isNot(contains('Paella')));
      expect(texto, isNot(contains('TICKET')));
      expect(texto, isNot(contains('Forma de pago')));
      expect(texto, isNot(contains('TPV-')));
      expect(abreCajon(job.bytes), isFalse);
      // Imprimirla no cobra la mesa ni crea tickets.
      expect(f.sala.comandaDeMesa('m1'), isNotNull);
      expect(f.store.snapshot.ticketsTurno, isEmpty);
    },
  );

  test('precuenta sin impresora de tickets o sin líneas avisa', () async {
    await f.sala.aceptarLineas(submit('m1', [linea('l1', 'CANA', 1)]));
    await settle();
    final mesa = f.sala.mesa('m1')!;
    final comanda = f.sala.comandaDeMesa('m1')!;
    final totales = f.sala.calcularTotales(comanda.lineasActivas.toList());

    final vacia = comanda.conLineaActualizada(
      comanda.lineaPorId('l1')!.anular(cuando: f.clock()),
    );
    expect(
      () => service.imprimirPrecuenta(mesa, vacia, totales),
      throwsA(isA<ValidationException>()),
    );

    // Sin impresora de tickets se usa la de cocina; sin ninguna, error.
    service.configurar(settings: const ImpresionSettings());
    expect(
      () => service.imprimirPrecuenta(mesa, comanda, totales),
      throwsA(isA<PrinterException>()),
    );
  });

  test('un fallo de la impresora se convierte en aviso', () async {
    printer.error = 'conexión rechazada';
    await f.sala.aceptarLineas(submit('m1', [linea('l1', 'PAELLA', 1)]));
    await settle();
    expect(f.alerts.recientes.single.titulo, contains('Fallo de impresión'));
    expect(f.alerts.recientes.single.detalle, contains('conexión rechazada'));
  });

  group('enrutamiento por familias', () {
    final cat = catalogoConSubfamilias();
    LineaComanda l(String id, String referencia, double cantidad) =>
        linea(id, referencia, cantidad, catalogo: cat);

    List<LineaComanda> variasFamilias() => [
      l('l1', 'PAELLA', 1), // Comidas → cocina (regla por defecto)
      l('l2', 'FLAN', 2), // Postres ⊂ Comidas → cocina
      l('l3', 'CANA', 3), // Cervezas ⊂ Bebidas → barra
      l('l4', 'CAFE', 1), // Cafés ⊂ Bebidas → barra
      l('l5', 'AGUA', 1), // Bebidas → barra
      l('l6', 'PAN', 1), // sin familia → por defecto (cocina)
    ];

    test('una comanda de varias familias sale en un ticket por puesto, '
        'cada uno solo con lo suyo', () async {
      await f.sala.aceptarLineas(submit('m1', variasFamilias()));
      await settle();

      expect(printer.jobs, hasLength(2));
      final porEndpoint = {for (final j in printer.jobs) j.endpoint: j};
      final textoCocina = textoDe(porEndpoint[cocina]!.bytes);
      final textoBarra = textoDe(porEndpoint[barra]!.bytes);
      for (final plato in ['Paella', 'Flan', 'Pan']) {
        expect(textoCocina, contains(plato));
        expect(textoBarra, isNot(contains(plato)));
      }
      for (final bebida in ['Caña', 'Café', 'Agua']) {
        expect(textoBarra, contains(bebida));
        expect(textoCocina, isNot(contains(bebida)));
      }
      expect(textoCocina, startsWith('COCINA'));
      expect(textoBarra, startsWith('BARRA'));
      expect(textoBarra, isNot(contains('Sin impresora')));
    });

    test('sin impresora de barra: dos tickets por la de cocina, uno por '
        'puesto, y el de barra indica que hay que llevarlo', () async {
      service.configurar(
        settings: ImpresionSettings(cocina: cocina, tickets: tickets),
      );
      await f.sala.aceptarLineas(submit('m1', variasFamilias()));
      await settle();

      expect(printer.jobs, hasLength(2));
      expect(printer.jobs.map((j) => j.endpoint), everyElement(cocina));
      final textos = [for (final j in printer.jobs) textoDe(j.bytes)];
      final textoCocina = textos.singleWhere((t) => t.startsWith('COCINA'));
      final textoBarra = textos.singleWhere((t) => t.startsWith('BARRA'));
      // Ninguna línea se pierde y cada una va en el ticket de su puesto.
      for (final plato in ['Paella', 'Flan', 'Pan']) {
        expect(textoCocina, contains(plato));
      }
      for (final bebida in ['Caña', 'Café', 'Agua']) {
        expect(textoBarra, contains(bebida));
        expect(textoCocina, isNot(contains(bebida)));
      }
      expect(textoBarra, contains('Sin impresora de barra'));
      expect(textoBarra, contains('llevar a barra'));
      expect(textoCocina, isNot(contains('Sin impresora')));
    });

    test('sin impresora de cocina lo de cocina sale por la de barra', () async {
      service.configurar(settings: ImpresionSettings(barra: barra));
      await f.sala.aceptarLineas(submit('m1', [l('l1', 'PAELLA', 1)]));
      await settle();
      final job = printer.jobs.single;
      expect(job.endpoint, barra);
      expect(textoDe(job.bytes), startsWith('COCINA'));
      expect(textoDe(job.bytes), contains('Sin impresora de cocina'));
    });

    test('cocina y barra en la misma dirección: dos tickets sin aviso de '
        'respaldo', () async {
      service.configurar(
        settings: ImpresionSettings(cocina: cocina, barra: cocina),
      );
      await f.sala.aceptarLineas(
        submit('m1', [l('l1', 'PAELLA', 1), l('l2', 'CANA', 1)]),
      );
      await settle();
      expect(printer.jobs, hasLength(2));
      expect(printer.jobs.map((j) => j.endpoint), everyElement(cocina));
      for (final job in printer.jobs) {
        expect(textoDe(job.bytes), isNot(contains('Sin impresora')));
      }
    });

    test('anular una línea imprime la anulación en su puesto', () async {
      await f.sala.aceptarLineas(
        submit('m1', [l('l1', 'PAELLA', 1), l('l2', 'CANA', 2)]),
      );
      await settle();
      printer.jobs.clear();

      await f.sala.anularLinea('m1', 'l2', motivo: 'se equivocó');
      await settle();
      final job = printer.jobs.single;
      expect(job.endpoint, barra);
      expect(job.description, 'Anulación Mesa 1 · barra');
      final texto = textoDe(job.bytes);
      expect(texto, startsWith('ANULACIÓN BARRA'));
      expect(texto, contains('** ANULADA **'));
      expect(texto, contains('Caña'));
      expect(texto, contains('Motivo: se equivocó'));
      expect(texto, isNot(contains('Paella')));

      // Anular otra vez la misma línea no vuelve a imprimir.
      await f.sala.anularLinea('m1', 'l2');
      await settle();
      expect(printer.jobs, hasLength(1));
    });

    test('vaciar la mesa imprime una anulación por puesto', () async {
      await f.sala.aceptarLineas(
        submit('m1', [
          l('l1', 'PAELLA', 1),
          l('l2', 'FLAN', 1),
          l('l3', 'CANA', 2),
        ]),
      );
      await settle();
      printer.jobs.clear();

      await f.sala.vaciarMesa('m1');
      await settle();
      expect(printer.jobs, hasLength(2));
      final porEndpoint = {for (final j in printer.jobs) j.endpoint: j};
      final textoCocina = textoDe(porEndpoint[cocina]!.bytes);
      expect(textoCocina, startsWith('ANULACIÓN COCINA'));
      expect(textoCocina, contains('Paella'));
      expect(textoCocina, contains('Flan'));
      expect(textoCocina, contains('Motivo: mesa vaciada'));
      final textoBarra = textoDe(porEndpoint[barra]!.bytes);
      expect(textoBarra, startsWith('ANULACIÓN BARRA'));
      expect(textoBarra, contains('Caña'));
    });

    test('con la impresión de comandas desactivada no se imprimen las '
        'anulaciones', () async {
      await f.sala.aceptarLineas(submit('m1', [l('l1', 'PAELLA', 1)]));
      await settle();
      printer.jobs.clear();
      service.configurar(
        settings: ImpresionSettings(
          cocina: cocina,
          barra: barra,
          imprimirComandas: false,
        ),
      );
      await f.sala.anularLinea('m1', 'l1');
      await settle();
      expect(printer.jobs, isEmpty);
    });
  });
}

/// Runner que lanza un error no tipado (como un `IsolateSpawnException`) en
/// la primera llamada y ejecuta en línea las siguientes.
final class _RunnerQueFallaLaPrimeraVez implements IsolateRunner {
  int llamadas = 0;

  @override
  Future<R> run<M, R>(
    IsolateEntryPoint<M, R> entryPoint,
    M message, {
    String? debugName,
  }) {
    llamadas++;
    if (llamadas == 1) {
      return Future<R>.error(StateError('isolate caído'));
    }
    return const InlineIsolateRunner().run(
      entryPoint,
      message,
      debugName: debugName,
    );
  }
}
