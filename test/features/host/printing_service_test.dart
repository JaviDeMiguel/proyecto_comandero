import 'dart:async';
import 'dart:typed_data';

import 'package:proyecto_comandero/core/errors/app_exception.dart';
import 'package:proyecto_comandero/core/isolates/escpos/escpos.dart';
import 'package:proyecto_comandero/core/isolates/isolate_runner.dart';
import 'package:proyecto_comandero/core/network/printing/raw_printer_transport.dart';
import 'package:proyecto_comandero/features/host/application/impresion/mapeo_documentos.dart'
    show referenciaCorta;
import 'package:proyecto_comandero/features/host/application/printing_service.dart';
import 'package:proyecto_comandero/features/host/domain/empresa_emisora.dart';
import 'package:proyecto_comandero/features/host/domain/host_settings.dart';
import 'package:proyecto_comandero/features/impresion/domain/formato_impresion.dart';
import 'package:proyecto_comandero/features/sala/domain/enrutamiento_comandas.dart';
import 'package:proyecto_comandero/features/sala/domain/linea_comanda.dart';
import 'package:proyecto_comandero/features/sala/domain/pases.dart';
import 'package:proyecto_comandero/features/sala/domain/ticket.dart';
import 'package:test/test.dart';

import '../../core/isolates/escpos/escpos_decoder.dart';
import 'fakes/fake_ports.dart';
import 'support/host_test_support.dart';

String textoDe(Uint8List bytes) => decodeEscPos(bytes).texts.join('|');

bool abreCajon(Uint8List bytes) =>
    decodeEscPos(bytes).named('drawer').isNotEmpty;

const EmpresaTicket _empresa = EmpresaTicket(
  nombre: 'Bar Manolo',
  cifnif: 'B12345678',
);

void main() {
  late SalaFixture f;
  late FakePrinterPort printer;
  late PrintingService service;
  final cocina = PrinterEndpoint('10.0.0.10');
  final barra = PrinterEndpoint('10.0.0.11');
  final tickets = PrinterEndpoint('10.0.0.12');

  ImpresionSettings ajustes({
    FormatoImpresion formato = const FormatoImpresion(),
    bool abrirCajon = true,
  }) => ImpresionSettings(
    cocina: cocina,
    barra: barra,
    tickets: tickets,
    abrirCajonEfectivo: abrirCajon,
    formato: formato,
  );

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
      settings: ajustes(),
      nombreTpv: 'Barra',
      store: f.store,
      printer: printer,
      empresa: _empresa,
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

  /// Marca [ticketId] como sincronizado con FS con su fecha y su total.
  Future<void> sincronizar(String ticketId, {String codigo = 'F2026S9'}) =>
      f.store.update((s) {
        final t = s.ticketPorId(ticketId)!;
        return s.conTicket(
          t.conFactura(
            FacturaSincronizada(
              estado: EstadoSincronizacion.sincronizado,
              codigo: codigo,
              fecha: DateTime(2026, 10, 7, 13, 5),
              totalFsCents: t.totalCents,
            ),
          ),
        );
      });

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

  test('la cabecera de la comanda lleva el nº de envío, la mesa con su zona, '
      'los comensales y el camarero del envío', () async {
    await f.sala.aceptarLineas(
      submit('m1', [linea('l1', 'PAELLA', 1)], camarero: 'Ana', comensales: 4),
    );
    await f.sala.aceptarLineas(
      submit('m1', [
        linea('l2', 'FLAN', 1, catalogo: catalogoConSubfamilias()),
      ], camarero: 'Luis'),
    );
    await settle();

    final comandas = printer.jobs.where((j) => j.endpoint == cocina).toList();
    expect(comandas, hasLength(2));
    expect(comandas.first.description, 'Comanda Nº 1 · Mesa 1 · cocina');
    expect(comandas.last.description, 'Comanda Nº 2 · Mesa 1 · cocina');
    final primera = decodeEscPos(comandas.first.bytes).texts;
    expect(primera.join('|'), startsWith('COCINA'));
    expect(primera, contains(startsWith('COMANDA Nº 1 · ')));
    expect(primera.take(3), ['COCINA', 'Mesa 1', 'Salón']);
    expect(primera, contains(endsWith('4 comensales')));
    expect(primera, contains(startsWith('Camarero: Ana')));
    expect(primera, contains(startsWith('1º envío de la mesa')));
    final segunda = textoDe(comandas.last.bytes);
    expect(segunda, contains('COMANDA Nº 2 · '));
    expect(segunda, contains('Luis'), reason: 'el camarero de ese envío');
    expect(segunda, contains('Flan'));
    expect(segunda, isNot(contains('Paella')));
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
      store: f.store,
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

  test('al cobrar imprime el documento provisional con cajón para '
      'efectivo', () async {
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
    expect(job.description, 'Ticket 1 · provisional');
    final texto = textoDe(job.bytes);
    expect(texto, contains('Bar Manolo'));
    expect(texto, contains('DOCUMENTO PROVISIONAL'));
    expect(texto, contains('6,65'));
    expect(texto, contains('3,35'));
    expect(texto, contains(referenciaCorta(ticket)));
    expect(abreCajon(job.bytes), isTrue);
    expect(
      f.store.snapshot.ticketPorId(ticket.id)!.impresion.provisionalEn,
      isNotNull,
    );
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
    await service.reimprimirProvisional(ticket.id);
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

  test('pago único: los bytes de un TicketPrintData escrito a mano', () async {
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
        empresa: _empresa,
        tituloDocumento: 'DOCUMENTO PROVISIONAL',
        provisional: true,
        numeroLocal: 1,
        numero2: referenciaCorta(ticket),
        fechaHora: ticket.fechaHora,
        mesa: 'Mesa 1',
        zona: 'Salón',
        lineas: const [
          LineaTicket(
            descripcion: 'Caña',
            cantidad: 7,
            pvpUnitarioCents: 95,
            importeCents: 665,
          ),
        ],
        desglose: const [
          DesgloseIvaTicketPrint(ivaPct: 10, baseCents: 605, cuotaCents: 60),
        ],
        totalCents: 665,
        metodoPago: 'Efectivo',
        entregadoCents: 1000,
        cambioCents: 335,
        ivaIncluido: true,
        abrirCajon: true,
      ),
    );
    expect(printer.jobs.single.bytes, esperado);
  });

  test('las líneas iguales salen juntas y las notas solo con '
      'mostrarNotas', () async {
    await f.sala.aceptarLineas(
      submit('m1', [linea('l1', 'CANA', 2, nota: 'con limón')]),
    );
    await f.sala.aceptarLineas(submit('m1', [linea('l2', 'CANA', 3)]));
    await settle();
    printer.jobs.clear();
    await f.sala.cobrar('m1', MetodoPago.tarjeta);
    await settle();
    var texto = textoDe(printer.jobs.single.bytes);
    // Sin mostrarNotas, la nota no cuenta: una sola línea de 5 cañas.
    expect(texto, contains('5 x Caña'));
    expect(texto, isNot(contains('con limón')));

    service.configurar(
      settings: ajustes(
        formato: const FormatoImpresion(
          ticket: FormatoTicket(mostrarNotas: true),
        ),
      ),
    );
    await f.sala.aceptarLineas(
      submit('m2', [
        linea('l3', 'CANA', 2, nota: 'con limón'),
        linea('l4', 'CANA', 3),
        linea('l5', 'CANA', 1, nota: ' con limón '),
      ]),
    );
    await settle();
    printer.jobs.clear();
    await f.sala.cobrar('m2', MetodoPago.tarjeta);
    await settle();
    texto = textoDe(printer.jobs.single.bytes);
    expect(texto, contains('con limón'));
    expect(texto, contains('3 x Caña'), reason: 'las dos con la misma nota');
    expect(texto, isNot(contains('6 x Caña')));
  });

  test('la factura se imprime ORIGINAL la primera vez y DUPLICADO las '
      'siguientes', () async {
    await f.sala.aceptarLineas(submit('m1', [linea('l1', 'CANA', 1)]));
    final ticket = await f.sala.cobrar('m1', MetodoPago.tarjeta);
    await settle();
    printer.jobs.clear();
    await sincronizar(ticket.id);

    await service.imprimirFactura(ticket.id);
    await service.idle();
    final original = printer.jobs.single;
    expect(original.description, 'Factura F2026S9 (original)');
    final texto = textoDe(original.bytes);
    expect(texto, contains('FACTURA SIMPLIFICADA'));
    expect(texto, contains('F2026S9'));
    expect(texto, isNot(contains('COPIA')));
    expect(texto, isNot(contains('DUPLICADO')));
    expect(abreCajon(original.bytes), isFalse);

    printer.jobs.clear();
    await service.imprimirFactura(ticket.id);
    await service.idle();
    expect(printer.jobs.single.description, 'Factura F2026S9 (duplicado 1)');
    expect(textoDe(printer.jobs.single.bytes), contains('DUPLICADO'));
    final impresion = f.store.snapshot.ticketPorId(ticket.id)!.impresion;
    expect(impresion.originalImpreso, isTrue);
    expect(impresion.duplicados, 1);
  });

  test('imprimirDocumentoTicket y la vista previa: la factura si se puede y, '
      'si no, el provisional', () async {
    await f.sala.aceptarLineas(submit('m1', [linea('l1', 'CANA', 1)]));
    final ticket = await f.sala.cobrar('m1', MetodoPago.tarjeta);
    await settle();
    printer.jobs.clear();

    // Sin factura de FS: copia del provisional.
    expect(
      textoDe(await service.vistaPreviaTicket(ticket.id)),
      contains('COPIA'),
    );
    await service.imprimirDocumentoTicket(ticket.id);
    await service.idle();
    expect(printer.jobs.single.description, 'Ticket 1 · provisional (copia)');

    await sincronizar(ticket.id);
    expect(
      textoDe(await service.vistaPreviaTicket(ticket.id)),
      contains('FACTURA SIMPLIFICADA'),
    );
    printer.jobs.clear();
    await service.imprimirDocumentoTicket(ticket.id);
    await service.idle();
    expect(printer.jobs.single.description, 'Factura F2026S9 (original)');

    expect(
      () => service.imprimirDocumentoTicket('nope'),
      throwsA(isA<ValidationException>()),
    );
  });

  test('sin NIF del emisor la factura no se imprime', () async {
    service.configurar(empresa: const EmpresaTicket(nombre: 'Bar Manolo'));
    expect(service.cabeceraFiscalCompleta, isFalse);
    await f.sala.aceptarLineas(submit('m1', [linea('l1', 'CANA', 1)]));
    final ticket = await f.sala.cobrar('m1', MetodoPago.tarjeta);
    await settle();
    await sincronizar(ticket.id);
    await expectLater(
      service.imprimirFactura(ticket.id),
      throwsA(
        isA<ValidationException>().having(
          (e) => e.message,
          'message',
          contains('NIF'),
        ),
      ),
    );
  });

  test('la empresa del ERP compone la cabecera si los ajustes no la '
      'fijan', () async {
    final sinAjustes = PrintingService(
      alerts: f.alerts,
      runner: const InlineIsolateRunner(),
      settings: ImpresionSettings(tickets: tickets),
      nombreTpv: 'Barra',
      store: f.store,
      printer: printer,
      now: f.clock.call,
    );
    expect(sinAjustes.cabeceraFiscalCompleta, isFalse);
    sinAjustes.configurar(
      empresaErp: EmpresaEmisora(
        nombre: 'Hostelería Manolo SL',
        cifnif: 'B87654321',
        obtenidaEn: f.clock(),
      ),
    );
    expect(sinAjustes.cabeceraFiscalCompleta, isTrue);
    await f.sala.aceptarLineas(submit('m1', [linea('l1', 'CANA', 1)]));
    final ticket = await f.sala.cobrar('m1', MetodoPago.tarjeta);
    await settle();
    final texto = textoDe(await sinAjustes.vistaPreviaTicket(ticket.id));
    expect(texto, contains('Hostelería Manolo SL'));
    expect(texto, contains('B87654321'));
  });

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
      expect(service.hayImpresoraTickets, isFalse);
      await f.sala.aceptarLineas(submit('m2', [linea('l2', 'CANA', 1)]));
      final ticket = await f.sala.cobrar('m2', MetodoPago.tarjeta);
      await settle();
      expect(printer.jobs, isEmpty);
      expect(
        () => service.reimprimirProvisional(ticket.id),
        throwsA(isA<PrinterException>()),
      );
    },
  );

  test('sin cola de impresión el cobro no espera ni imprime, aunque haya '
      'impresora en los ajustes', () async {
    final sinCola = PrintingService(
      alerts: f.alerts,
      runner: const InlineIsolateRunner(),
      settings: ImpresionSettings(
        tickets: tickets,
        abrirCajonEfectivo: true,
        formato: const FormatoImpresion(
          emision: EmisionTicket(
            modo: ModoEmision.facturaAlCobrar,
            esperaSegundos: 30,
          ),
        ),
      ),
      nombreTpv: 'Barra',
      store: f.store,
      now: f.clock.call,
    );
    expect(sinCola.hayImpresoraTickets, isFalse);
    final pendientes = <Set<String>>[];
    final sub = sinCola.emisionesPendientes.listen(pendientes.add);
    addTearDown(sub.cancel);
    f.sala.addEffects(sinCola);
    service.configurar(settings: const ImpresionSettings());
    await f.sala.aceptarLineas(submit('m1', [linea('l1', 'CANA', 1)]));
    final ticket = await f.sala.cobrar(
      'm1',
      MetodoPago.efectivo,
      entregadoCents: 100,
    );
    expect(sinCola.emisionPendiente(ticket.id), isFalse);
    // Sin la espera de la factura, los efectos terminan enseguida.
    await f.sala.idle().timeout(const Duration(seconds: 5));
    expect(pendientes, [<String>{}]);
    expect(
      f.store.snapshot.ticketPorId(ticket.id)!.impresion.provisionalEn,
      isNull,
    );
  });

  test('con «Emitir factura al cobrar» el ticket queda pendiente hasta que '
      'llega la factura o se cancelan las esperas', () async {
    service.configurar(
      settings: ajustes(
        abrirCajon: false,
        formato: const FormatoImpresion(
          emision: EmisionTicket(
            modo: ModoEmision.facturaAlCobrar,
            esperaSegundos: 30,
          ),
        ),
      ),
    );
    final pendientes = <Set<String>>[];
    final sub = service.emisionesPendientes.listen(pendientes.add);
    addTearDown(sub.cancel);
    await f.sala.aceptarLineas(submit('m1', [linea('l1', 'CANA', 1)]));
    await settle();
    printer.jobs.clear();
    final ticket = await f.sala.cobrar('m1', MetodoPago.tarjeta);
    expect(service.emisionPendiente(ticket.id), isTrue);

    service.cancelarEsperas();
    await settle();
    await Future<void>.delayed(Duration.zero);
    expect(service.emisionPendiente(ticket.id), isFalse);
    expect(pendientes.first, isEmpty);
    expect(pendientes.where((p) => p.contains(ticket.id)), isNotEmpty);
    expect(pendientes.last, isEmpty);
    // Sin factura a tiempo: el provisional, sin cajón.
    expect(printer.jobs.single.description, 'Ticket 1 · provisional');
  });

  test('precuenta: documento propio sin validez fiscal, sin clave ni '
      'cajón', () async {
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

    final precuenta = await f.sala.emitirPrecuenta('m1', emitidaPor: 'Ana');
    await service.imprimirPrecuenta(precuenta, zona: 'Terraza');
    await service.idle();

    final job = printer.jobs.single;
    expect(job.endpoint, tickets);
    expect(job.description, 'Precuenta nº 1 · Mesa 1');
    final texto = textoDe(job.bytes);
    expect(texto, contains('PRECUENTA Nº 1'));
    expect(texto, contains('DOCUMENTO SIN VALIDEZ FISCAL'));
    expect(texto, contains('Ana'));
    expect(texto, contains('Terraza'));
    expect(texto, contains('6,65'));
    expect(texto, isNot(contains('Paella')));
    expect(texto, isNot(contains('PROVISIONAL')));
    expect(texto, isNot(contains('Forma de pago')));
    expect(texto, isNot(contains('TPV-')));
    expect(abreCajon(job.bytes), isFalse);
    // Imprimirla no cobra la mesa ni crea tickets.
    expect(f.sala.comandaDeMesa('m1'), isNotNull);
    expect(f.store.snapshot.ticketsTurno, isEmpty);
  });

  test('precuenta sin líneas o sin impresora de tickets avisa', () async {
    await f.sala.aceptarLineas(submit('m1', [linea('l1', 'CANA', 1)]));
    await settle();
    final precuenta = await f.sala.emitirPrecuenta('m1');

    await f.sala.anularLinea('m1', 'l1');
    expect(
      () => f.sala.emitirPrecuenta('m1'),
      throwsA(isA<ValidationException>()),
    );

    // Sin impresora de tickets se usa la de cocina; sin ninguna, error.
    service.configurar(settings: const ImpresionSettings());
    expect(
      () => service.imprimirPrecuenta(precuenta),
      throwsA(isA<PrinterException>()),
    );
  });

  test('abrir el cajón a mano', () async {
    await service.abrirCajon();
    await service.idle();
    expect(printer.jobs.single.description, 'Cajón · apertura manual');
    expect(printer.jobs.single.endpoint, tickets);
    expect(abreCajon(printer.jobs.single.bytes), isTrue);

    service.configurar(settings: const ImpresionSettings());
    expect(service.abrirCajon, throwsA(isA<PrinterException>()));
  });

  test('marchar un pase imprime el MARCHAR en el puesto de sus '
      'líneas', () async {
    await f.sala.aceptarLineas(
      submit('m1', [
        linea('l1', 'PAELLA', 1, pase: 2),
        linea('l2', 'FLAN', 1, pase: 3, catalogo: catalogoConSubfamilias()),
      ]),
    );
    await settle();
    printer.jobs.clear();
    await f.sala.marcharPase('m1', 2, marchaId: 'marcha-1', camarero: 'Ana');
    await settle();
    final job = printer.jobs.single;
    expect(job.endpoint, cocina);
    expect(job.description, startsWith('Marchar '));
    expect(job.description, endsWith(' · Mesa 1 · cocina'));
    final texto = textoDe(job.bytes);
    expect(texto, contains('Paella'));
    expect(texto, isNot(contains('Flan')));
  });

  test('reimprimir la comanda delega con la banda del motivo', () async {
    await f.sala.aceptarLineas(
      submit('m1', [linea('l1', 'PAELLA', 1), linea('l2', 'CANA', 1)]),
    );
    await settle();
    printer.jobs.clear();
    await service.reimprimirComanda(
      f.sala.mesa('m1')!,
      f.sala.comandaDeMesa('m1')!,
      destinos: {DestinoPreparacion.cocina},
      alcance: AlcanceReimpresion.todo,
      motivo: MotivoReimpresion.noSalio,
      dispositivo: 'Caja 1',
    );
    await service.idle();
    final job = printer.jobs.single;
    expect(job.description, 'Reimpresión de comanda · Mesa 1 · cocina');
    expect(textoDe(job.bytes), contains('REIMPRESIÓN · PREPARAR'));

    expect(
      () => service.reimprimirComanda(
        f.sala.mesa('m1')!,
        f.sala.comandaDeMesa('m1')!,
        destinos: const {},
        alcance: AlcanceReimpresion.todo,
        motivo: MotivoReimpresion.copia,
        dispositivo: 'Caja 1',
      ),
      throwsA(isA<ValidationException>()),
    );
  });

  test('muestras: en la impresora del rol con el perfil del borrador; sin '
      'impresora, error', () async {
    final borrador = ImpresionSettings(
      cocina: cocina,
      tickets: tickets,
      formato: const FormatoImpresion(
        perfiles: {RolImpresora.cocina: PerfilImpresora(copias: 2)},
      ),
    );
    await service.imprimirMuestra(
      DocumentoMuestra.provisional,
      ajustes: borrador,
      rol: RolImpresora.tickets,
    );
    await service.imprimirMuestra(
      DocumentoMuestra.comandaBarra,
      ajustes: borrador,
      rol: RolImpresora.barra,
    );
    await service.idle();
    expect(printer.jobs.map((j) => j.endpoint), [tickets, cocina]);
    expect(printer.jobs.first.description, startsWith('Muestra · '));
    expect(textoDe(printer.jobs.first.bytes), contains('Bar Manolo'));
    expect(textoDe(printer.jobs.first.bytes), contains('MUESTRA'));
    // La barra sale por la de cocina, con las dos copias de su perfil.
    final barraTextos = decodeEscPos(printer.jobs.last.bytes).texts;
    expect(barraTextos.where((t) => t.startsWith('BARRA')), hasLength(2));

    await expectLater(
      service.imprimirMuestra(
        DocumentoMuestra.comandaCocina,
        ajustes: ImpresionSettings(tickets: tickets),
        rol: RolImpresora.cocina,
      ),
      throwsA(isA<PrinterException>()),
    );
  });

  test('muestras: la cabecera sale del formato del borrador, no del '
      'vigente', () async {
    // Sin empresa fija en los ajustes, la cabecera la compone el formato.
    final sinEmpresaFija = PrintingService(
      alerts: f.alerts,
      runner: const InlineIsolateRunner(),
      settings: ImpresionSettings(
        tickets: tickets,
        formato: const FormatoImpresion(
          ticket: FormatoTicket(nombreComercial: 'Casa Vigente'),
        ),
      ),
      nombreTpv: 'Barra',
      store: f.store,
      printer: printer,
      now: f.clock.call,
    );
    await sinEmpresaFija.imprimirMuestra(
      DocumentoMuestra.provisional,
      ajustes: ImpresionSettings(
        tickets: tickets,
        formato: const FormatoImpresion(
          ticket: FormatoTicket(nombreComercial: 'Taberna Borrador'),
        ),
      ),
      rol: RolImpresora.tickets,
    );
    await sinEmpresaFija.idle();
    final texto = textoDe(printer.jobs.single.bytes);
    expect(texto, contains('Taberna Borrador'));
    expect(texto, isNot(contains('Casa Vigente')));
  });

  test('los textos de puesto y forma de pago son los del mapeo', () {
    expect(PrintingService.tituloPuesto(DestinoPreparacion.cocina), 'COCINA');
    expect(PrintingService.tituloPuesto(DestinoPreparacion.barra), 'BARRA');
    expect(PrintingService.formaDePago(MetodoPago.efectivo), 'Efectivo');
    expect(PrintingService.formaDePago(MetodoPago.tarjeta), 'Tarjeta');
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
      final texto = textoDe(job.bytes).trimLeft();
      expect(texto, startsWith('ANULACIÓN BARRA'));
      expect(_primeraLineaEnInverso(job.bytes), isTrue);
      expect(texto, contains('-2 x Caña'));
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
      final textoCocina = textoDe(porEndpoint[cocina]!.bytes).trimLeft();
      expect(textoCocina, startsWith('ANULACIÓN COCINA'));
      expect(_primeraLineaEnInverso(porEndpoint[cocina]!.bytes), isTrue);
      expect(textoCocina, contains('Paella'));
      expect(textoCocina, contains('Flan'));
      expect(textoCocina, contains('Motivo: mesa vaciada'));
      final textoBarra = textoDe(porEndpoint[barra]!.bytes).trimLeft();
      expect(textoBarra, startsWith('ANULACIÓN BARRA'));
      expect(_primeraLineaEnInverso(porEndpoint[barra]!.bytes), isTrue);
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

  test('los pases de los ajustes ordenan la comanda por pase', () async {
    service.configurar(
      settings: ajustes(
        formato: const FormatoImpresion(pases: PasesConfig(activos: true)),
      ),
    );
    await f.sala.aceptarLineas(
      submit('m1', [
        linea('l1', 'FLAN', 1, pase: 3, catalogo: catalogoConSubfamilias()),
        linea('l2', 'PAELLA', 1, pase: 1),
      ]),
    );
    await settle();
    final texto = textoDe(printer.jobs.single.bytes);
    expect(texto.indexOf('Paella'), lessThan(texto.indexOf('Flan')));
  });
}

/// La primera línea con texto del documento va en inverso.
bool _primeraLineaEnInverso(Uint8List bytes) =>
    decodeEscPos(bytes).lines
        .firstWhere((linea) => linea.text.trim().isNotEmpty)
        .inverse;

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
