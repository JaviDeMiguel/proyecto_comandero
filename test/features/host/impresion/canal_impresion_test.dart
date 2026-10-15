/// Canal de impresión (§5.12 del diseño): copias en un solo trabajo, aviso
/// sonoro una vez al final y solo en preparación, perfil resuelto por
/// impresora, política de reintento hasta el puerto y errores.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:proyecto_comandero/core/errors/app_exception.dart';
import 'package:proyecto_comandero/core/isolates/escpos/escpos.dart';
import 'package:proyecto_comandero/core/isolates/isolate_runner.dart';
import 'package:proyecto_comandero/core/logging/app_logger.dart';
import 'package:proyecto_comandero/core/network/printing/print_queue.dart'
    show PrintRetryPolicy;
import 'package:proyecto_comandero/core/network/printing/raw_printer_transport.dart';
import 'package:proyecto_comandero/features/host/application/alert_bus.dart';
import 'package:proyecto_comandero/features/host/application/impresion/canal_impresion.dart';
import 'package:proyecto_comandero/features/host/application/impresion/mapeo_documentos.dart';
import 'package:proyecto_comandero/features/host/application/ports.dart';
import 'package:proyecto_comandero/features/host/domain/host_settings.dart';
import 'package:proyecto_comandero/features/host/domain/operational_alert.dart';
import 'package:proyecto_comandero/features/impresion/domain/formato_impresion.dart';
import 'package:proyecto_comandero/features/sala/domain/comanda.dart';
import 'package:proyecto_comandero/features/sala/domain/linea_comanda.dart';
import 'package:proyecto_comandero/features/sala/domain/mesa.dart';
import 'package:proyecto_comandero/features/sala/domain/pases.dart';
import 'package:proyecto_comandero/features/sala/domain/ticket.dart';
import 'package:test/test.dart';

import '../../../core/isolates/escpos/escpos_decoder.dart';
import '../fakes/fake_ports.dart';

final tickets = PrinterEndpoint('10.0.0.12');
final cocina = PrinterEndpoint('10.0.0.10');
final barra = PrinterEndpoint('10.0.0.11');
final ahora = DateTime(2026, 10, 9, 21, 14);

/// Comanda corta de cocina con el papel y el avance del [perfil].
Uint8List comanda(PerfilImpresora perfil) => generarComandaCocina(
  KitchenOrderPrintData(
    titulo: 'COCINA',
    mesa: 'Mesa 7',
    fechaHora: ahora,
    lineas: const [LineaComandaPrint(cantidad: 2, descripcion: 'Croquetas')],
    avanceInicial: perfil.lineasIniciales,
    paper: perfil.papel,
  ),
);

/// Documento provisional corto con el papel del [perfil].
Uint8List ticket(PerfilImpresora perfil) => generarTicket(
  TicketPrintData(
    empresa: const EmpresaTicket(nombre: 'Bar Manolo'),
    tituloDocumento: 'DOCUMENTO PROVISIONAL',
    provisional: true,
    fechaHora: ahora,
    lineas: const [
      LineaTicket(
        descripcion: 'Caña',
        cantidad: 1,
        pvpUnitarioCents: 200,
        importeCents: 200,
      ),
    ],
    desglose: const [],
    totalCents: 200,
    metodoPago: 'Efectivo',
    paper: perfil.papel,
  ),
);

/// Bytes concatenados.
List<int> unidos(List<List<int>> partes) => [for (final p in partes) ...p];

/// ¿Terminan los [bytes] con [cola]?
bool terminaCon(List<int> bytes, List<int> cola) =>
    bytes.length >= cola.length &&
    _iguales(bytes.sublist(bytes.length - cola.length), cola);

bool _iguales(List<int> a, List<int> b) {
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Líneas en blanco con las que empieza el papel (`ESC d n` tras el init).
int? avanceInicialDe(Uint8List bytes) {
  final primero = decodeEscPos(bytes).elements.first;
  return primero is ElementoMarca && primero.comando.name == 'feed'
      ? primero.comando.args.single
      : null;
}

/// Cola que encola siempre, pero cuyo seguimiento falla (p. ej. cerrada a
/// mitad del trabajo).
final class _ColaQueFallaAlSeguir implements PrinterPort {
  @override
  String imprimir(
    PrinterEndpoint endpoint,
    Uint8List bytes, {
    required String description,
    PrintRetryPolicy reintento = PrintRetryPolicy.always,
  }) => 'trabajo-1';

  @override
  Future<String?> terminado(String jobId) =>
      Future.error(StateError('cola cerrada'));
}

/// Cola cuyo trabajo no termina hasta que el test completa [fin] (con el
/// motivo del fallo, o `null` si salió bien).
final class _ColaRetenida implements PrinterPort {
  final fin = Completer<String?>();

  @override
  String imprimir(
    PrinterEndpoint endpoint,
    Uint8List bytes, {
    required String description,
    PrintRetryPolicy reintento = PrintRetryPolicy.always,
  }) => 'trabajo-1';

  @override
  Future<String?> terminado(String jobId) => fin.future;
}

/// Cola con un fallo de programación: [imprimir] lanza un error no tipado.
final class _ColaRota implements PrinterPort {
  _ColaRota(this.error);

  final Error error;

  @override
  String imprimir(
    PrinterEndpoint endpoint,
    Uint8List bytes, {
    required String description,
    PrintRetryPolicy reintento = PrintRetryPolicy.always,
  }) => throw error;

  @override
  Future<String?> terminado(String jobId) async => null;
}

void main() {
  late AlertBus alerts;
  late FakePrinterPort printer;
  late ImpresionSettings settings;
  late PrinterPort? Function() puerto;
  late CanalImpresion canal;

  setUp(() {
    alerts = AlertBus(now: () => ahora);
    printer = FakePrinterPort();
    settings = ImpresionSettings(
      tickets: tickets,
      cocina: cocina,
      barra: barra,
    );
    puerto = () => printer;
    canal = CanalImpresion(
      alerts: alerts,
      runner: const InlineIsolateRunner(),
      settings: () => settings,
      printer: () => puerto(),
    );
  });

  tearDown(() async {
    await canal.idle();
    await alerts.dispose();
  });

  /// Ajustes con [perfiles] guardados para la dirección de cada rol.
  ImpresionSettings conPerfiles(
    Map<RolImpresora, PerfilImpresora> perfiles, {
    PrinterEndpoint? t,
    PrinterEndpoint? c,
    PrinterEndpoint? b,
  }) => ImpresionSettings(
    tickets: t ?? tickets,
    cocina: c ?? cocina,
    barra: b ?? barra,
    formato: FormatoImpresion(perfiles: perfiles),
  );

  group('copias y aviso sonoro', () {
    test('2 copias son los bytes del documento dos veces en UN trabajo, y el '
        'aviso va una sola vez, al final', () async {
      final perfil = PerfilImpresora(
        copias: 2,
        zumbador: ZumbadorModo.generico,
        pitidos: 3,
        direccion: claveImpresora(cocina),
      );
      settings = conPerfiles({RolImpresora.cocina: perfil});

      final id = await canal.enviar(
        cocina,
        'Comanda Nº 12 · Mesa 7 · cocina',
        (p) async => comanda(p),
        preparacion: true,
      );

      final job = printer.jobs.single;
      expect(job.id, id);
      expect(job.endpoint, cocina);
      expect(job.description, 'Comanda Nº 12 · Mesa 7 · cocina');
      final documento = comanda(perfil);
      expect(
        job.bytes,
        unidos([
          documento,
          documento,
          bytesAviso(ZumbadorModo.generico, pitidos: 3),
        ]),
      );
      final decoded = decodeEscPos(job.bytes);
      expect(decoded.named('init'), hasLength(2));
      expect(decoded.named('cut'), hasLength(2));
      expect(decoded.named('beep'), hasLength(1));
      expect(decoded.commands.last.name, 'beep');
      expect(decoded.commands.last.args, [3, 2]);
    });

    test(
      'las copias forzadas mandan sobre el perfil (reimpresión: 1)',
      () async {
        final perfil = PerfilImpresora(
          copias: 3,
          zumbador: ZumbadorModo.generico,
          direccion: claveImpresora(cocina),
        );
        settings = conPerfiles({RolImpresora.cocina: perfil});
        await canal.enviar(
          cocina,
          'Reimpresión',
          (p) async => comanda(p),
          preparacion: true,
          copias: 1,
        );
        expect(
          printer.jobs.single.bytes,
          unidos([comanda(perfil), bytesAviso(ZumbadorModo.generico)]),
        );
        await expectLater(
          canal.enviar(
            cocina,
            'x',
            (p) async => comanda(p),
            preparacion: true,
            copias: 0,
          ),
          throwsArgumentError,
        );
      },
    );

    test('los tickets nunca llevan copias ni aviso, aunque el perfil los '
        'tenga', () async {
      final perfil = PerfilImpresora(
        copias: 3,
        zumbador: ZumbadorModo.generico,
        direccion: claveImpresora(tickets),
      );
      settings = conPerfiles({RolImpresora.tickets: perfil});
      await canal.enviar(tickets, 'Ticket 15 · provisional', (p) async {
        return ticket(p);
      });
      await canal.enviar(
        tickets,
        'Ticket 15 · provisional',
        (p) async => ticket(p),
        copias: 2,
      );
      for (final job in printer.jobs) {
        expect(job.bytes, ticket(perfil));
        expect(decodeEscPos(job.bytes).named('beep'), isEmpty);
        expect(decodeEscPos(job.bytes).named('drawer'), isEmpty);
      }
      expect(printer.jobs, hasLength(2));
    });

    test('sin perfiles, una copia y sin aviso: los bytes de siempre', () async {
      await canal.enviar(
        cocina,
        'Comanda',
        (p) async => comanda(p),
        preparacion: true,
      );
      expect(printer.jobs.single.bytes, comanda(const PerfilImpresora()));
    });
  });

  group('perfil resuelto', () {
    test(
      'el zumbador del conector del cajón no suena en la impresora que '
      'sirve a los tickets (y queda un registro fine, una vez por '
      'impresora); en una impresora de cocina aparte, pin 5 y pin 2',
      () async {
        final registros = <LogRecord>[];
        configureLogging(level: Level.ALL, onRecord: registros.add);
        addTearDown(configureLogging);

        // La barra imprime en la impresora de los tickets.
        final cajon = PerfilImpresora(
          zumbador: ZumbadorModo.puertoCajon,
          direccion: claveImpresora(tickets),
        );
        final pin5 = PerfilImpresora(
          zumbador: ZumbadorModo.puertoCajon,
          pitidos: 1,
          direccion: claveImpresora(cocina),
        );
        settings = conPerfiles({
          RolImpresora.tickets: cajon,
          RolImpresora.barra: cajon,
          RolImpresora.cocina: pin5,
        }, b: tickets);

        await canal.enviar(
          tickets,
          'Comanda · barra',
          (p) async => comanda(p),
          preparacion: true,
        );
        await canal.enviar(
          tickets,
          'Otra comanda · barra',
          (p) async => comanda(p),
          preparacion: true,
        );
        final enTickets = printer.jobs.take(2).toList();
        for (final job in enTickets) {
          expect(decodeEscPos(job.bytes).named('drawer'), isEmpty);
          expect(job.bytes, comanda(cajon));
        }
        final avisos = registros.where(
          (r) =>
              r.level == Level.FINE && r.message.contains('conector del cajón'),
        );
        expect(avisos, hasLength(1));
        expect(avisos.single.message, contains('10.0.0.12:9100'));

        await canal.enviar(
          cocina,
          'Comanda · cocina',
          (p) async => comanda(p),
          preparacion: true,
        );
        final conPin5 = printer.jobs.last.bytes;
        expect(terminaCon(conPin5, [0x1B, 0x70, 0x01, 0x32, 0x64]), isTrue);
        expect(decodeEscPos(conPin5).named('drawer'), hasLength(1));

        settings = conPerfiles({
          RolImpresora.cocina: pin5.copyWith(pinZumbador: 2, pitidos: 2),
        });
        await canal.enviar(
          cocina,
          'Comanda · cocina',
          (p) async => comanda(p),
          preparacion: true,
        );
        final conPin2 = printer.jobs.last.bytes;
        expect(
          terminaCon(conPin2, [
            0x1B, 0x70, 0x00, 0x32, 0x64, //
            0x1B, 0x70, 0x00, 0x32, 0x64,
          ]),
          isTrue,
        );
        // Ningún otro registro del cajón por la impresora de cocina.
        expect(
          registros.where((r) => r.message.contains('conector del cajón')),
          hasLength(1),
        );
      },
    );

    test('sin el conector del cajón en el perfil guardado no queda registro '
        'del cajón, ni con «ninguno» ni con el pitido ESC B, que sí suena '
        'en la impresora de los tickets', () async {
      final registros = <LogRecord>[];
      configureLogging(level: Level.ALL, onRecord: registros.add);
      addTearDown(configureLogging);

      for (final (enTickets, enCocina) in [
        (ZumbadorModo.ninguno, ZumbadorModo.generico),
        (ZumbadorModo.generico, ZumbadorModo.ninguno),
      ]) {
        settings = conPerfiles({
          RolImpresora.tickets: PerfilImpresora(
            zumbador: enTickets,
            direccion: claveImpresora(tickets),
          ),
          RolImpresora.cocina: PerfilImpresora(
            zumbador: enCocina,
            direccion: claveImpresora(cocina),
          ),
        });
        for (final endpoint in [tickets, cocina]) {
          await canal.enviar(
            endpoint,
            'Comanda',
            (p) async => comanda(p),
            preparacion: true,
          );
        }
      }
      expect(
        [
          for (final job in printer.jobs)
            (job.endpoint, decodeEscPos(job.bytes).named('beep').length),
        ],
        [(tickets, 0), (cocina, 1), (tickets, 1), (cocina, 0)],
      );
      expect(
        registros.where((r) => r.message.contains('conector del cajón')),
        isEmpty,
      );
    });

    test('generar recibe el perfil de la impresora real: la barra sin '
        'impresora propia usa el de cocina', () async {
      final perfilCocina = PerfilImpresora(
        papel: PaperWidth.mm58,
        lineasIniciales: 2,
        direccion: claveImpresora(cocina),
      );
      settings = ImpresionSettings(
        cocina: cocina,
        formato: FormatoImpresion(
          perfiles: {RolImpresora.cocina: perfilCocina},
        ),
      );
      final destino = settings.impresoraDe(DestinoPreparacion.barra)!;
      expect(destino.respaldo, isTrue);
      PerfilImpresora? recibido;
      await canal.enviar(destino.endpoint, 'Comanda · barra', (p) async {
        recibido = p;
        return comanda(p);
      }, preparacion: true);
      expect(recibido, perfilCocina);
      expect(printer.jobs.single.endpoint, cocina);
    });

    test('un perfil explícito (el del borrador, en una muestra) manda sobre el '
        'de los ajustes: papel, copias y aviso', () async {
      final registros = <LogRecord>[];
      configureLogging(level: Level.ALL, onRecord: registros.add);
      addTearDown(configureLogging);
      // Guardado: 3 copias y pitido; con el conector del cajón en tickets.
      settings = conPerfiles({
        RolImpresora.cocina: PerfilImpresora(
          copias: 3,
          zumbador: ZumbadorModo.generico,
          direccion: claveImpresora(cocina),
        ),
        RolImpresora.tickets: PerfilImpresora(
          zumbador: ZumbadorModo.puertoCajon,
          direccion: claveImpresora(tickets),
        ),
      });
      // Borrador de la página: 58 mm, 2 copias y el conector del cajón (pin 2).
      const borrador = PerfilImpresora(
        papel: PaperWidth.mm58,
        copias: 2,
        zumbador: ZumbadorModo.puertoCajon,
        pitidos: 1,
        pinZumbador: 2,
      );
      PerfilImpresora? recibido;
      await canal.enviar(
        cocina,
        'Muestra · Comanda de cocina',
        (p) async {
          recibido = p;
          return comanda(p);
        },
        preparacion: true,
        perfil: borrador,
      );
      expect(recibido, borrador);
      expect(
        printer.jobs.single.bytes,
        unidos([
          comanda(borrador),
          comanda(borrador),
          bytesAviso(ZumbadorModo.puertoCajon, pitidos: 1, pin: 2),
        ]),
      );

      // Con perfil explícito no se registra el cajón anulado de los ajustes,
      // aunque coincida con el guardado ya sin zumbador.
      await canal.enviar(
        tickets,
        'Muestra · Comanda de barra',
        (p) async => comanda(p),
        preparacion: true,
        perfil: PerfilImpresora(direccion: claveImpresora(tickets)),
      );
      expect(
        registros.where((r) => r.message.contains('conector del cajón')),
        isEmpty,
      );
    });

    test('los documentos de preparación empiezan con perfil.lineasIniciales '
        'líneas en blanco y los de cliente no', () async {
      final perfil = PerfilImpresora(
        lineasIniciales: 3,
        direccion: claveImpresora(cocina),
      );
      final perfilTickets = PerfilImpresora(
        lineasIniciales: 3,
        direccion: claveImpresora(tickets),
      );
      settings = conPerfiles({
        RolImpresora.cocina: perfil,
        RolImpresora.tickets: perfilTickets,
      });
      const mesa = Mesa(id: 'm7', nombre: 'Mesa 7', zona: 'Terraza');
      final linea = LineaComanda(
        id: 'l1',
        referencia: 'CROQ',
        descripcion: 'Croquetas de jamón',
        cantidad: 2,
        pvpUnitarioCents: 900,
        pvpUnitarioNeto: 8.18182,
        ivaBp: 1000,
        codimpuesto: 'IVA10',
        envio: 12,
        creadaEn: ahora,
      );
      final abierta = Comanda(
        id: 'c1',
        mesaId: 'm7',
        abiertaEn: ahora,
        lineas: [linea],
      );
      await canal.enviar(
        cocina,
        'Comanda Nº 12 · Mesa 7 · cocina',
        (p) => generarComandaCocinaEnIsolate(
          datosComanda(
            mesa,
            abierta,
            [linea],
            destino: DestinoPreparacion.cocina,
            pases: const PasesConfig(),
            perfil: p,
            ahora: ahora,
          ),
          runner: canal.runner,
        ),
        preparacion: true,
      );
      expect(avanceInicialDe(printer.jobs.last.bytes), 3);

      final cobrado = Ticket(
        id: 'ticket-15',
        numeroLocal: 15,
        mesaId: 'm7',
        nombreMesa: 'Mesa 7',
        comandaId: 'c1',
        fechaHora: ahora,
        lineas: [linea],
        totales: TotalesTicket(
          netoCents: 1636,
          ivaCents: 164,
          totalCents: 1800,
        ),
        metodoPago: MetodoPago.tarjeta,
      );
      await canal.enviar(
        tickets,
        'Ticket 15 · provisional',
        (p) => generarTicketEnIsolate(
          datosProvisional(
            cobrado,
            cabecera: const EmpresaTicket(nombre: 'Bar Manolo'),
            formato: const FormatoTicket(),
            perfil: p,
          ),
          runner: canal.runner,
        ),
      );
      expect(avanceInicialDe(printer.jobs.last.bytes), isNull);
    });
  });

  group('cola y errores', () {
    test('la política de reintento llega al puerto (facturas: '
        'connectOnly); el cajón suelto y lo demás, always', () async {
      await canal.enviar(
        tickets,
        'Factura F2026S12 (original)',
        (p) async => ticket(p),
        lanzarErrores: true,
        reintento: PrintRetryPolicy.connectOnly,
      );
      await canal.enviar(tickets, 'Ticket 15 · provisional', (p) async {
        return ticket(p);
      });
      await canal.enviarCrudo(tickets, 'Cajón · ticket 15', bytesAbrirCajon());
      expect(printer.jobs.map((j) => j.reintento), [
        PrintRetryPolicy.connectOnly,
        PrintRetryPolicy.always,
        PrintRetryPolicy.always,
      ]);
      expect(printer.jobs.last.bytes, [0x1B, 0x70, 0x00, 0x19, 0xFA]);
      expect(printer.jobs.last.description, 'Cajón · ticket 15');
    });

    test('un fallo al generar: sin lanzarErrores, aviso y null; con él, se '
        'relanza la AppException', () async {
      final id = await canal.enviar(
        cocina,
        'Comanda Nº 12',
        (p) async => throw const ValidationException('El QR no cabe'),
      );
      expect(id, isNull);
      expect(printer.jobs, isEmpty);
      final aviso = alerts.recientes.single;
      expect(aviso.nivel, AlertaNivel.error);
      expect(aviso.titulo, 'No se pudo generar "Comanda Nº 12"');
      expect(aviso.detalle, 'El QR no cabe');
      expect(aviso.origen, 'impresion');

      await expectLater(
        canal.enviar(
          cocina,
          'Factura',
          (p) async => throw const ValidationException('El QR no cabe'),
          lanzarErrores: true,
        ),
        throwsA(isA<ValidationException>()),
      );
      expect(alerts.recientes, hasLength(1));
    });

    test('un fallo no tipado al generar (isolate caído): sin lanzarErrores se '
        'relanza tal cual y sin aviso, como hoy (lo recoge el aislamiento '
        'por puesto de quien llama); con él, PrinterException con la '
        'causa', () async {
      final caido = StateError('isolate caído');
      await expectLater(
        canal.enviar(
          cocina,
          'Comanda Nº 12',
          (p) async => throw caido,
          preparacion: true,
        ),
        throwsA(same(caido)),
      );
      expect(printer.jobs, isEmpty);
      expect(alerts.recientes, isEmpty);

      await expectLater(
        canal.enviar(
          cocina,
          'Muestra',
          (p) async => throw caido,
          lanzarErrores: true,
        ),
        throwsA(
          isA<PrinterException>()
              .having(
                (e) => e.message,
                'message',
                'No se pudo generar "Muestra"',
              )
              .having((e) => e.cause, 'cause', same(caido)),
        ),
      );
      expect(alerts.recientes, isEmpty);
    });

    test('un fallo no tipado al encolar se trata igual: relanzado sin '
        'lanzarErrores (también el cajón suelto) y PrinterException con '
        'él', () async {
      final roto = StateError('cola rota');
      puerto = () => _ColaRota(roto);
      await expectLater(
        canal.enviar(cocina, 'Comanda Nº 12', (p) async => comanda(p)),
        throwsA(same(roto)),
      );
      await expectLater(
        canal.enviarCrudo(tickets, 'Cajón · ticket 15', bytesAbrirCajon()),
        throwsA(same(roto)),
      );
      expect(alerts.recientes, isEmpty);
      await expectLater(
        canal.enviar(
          tickets,
          'Factura F2026S12 (original)',
          (p) async => ticket(p),
          lanzarErrores: true,
        ),
        throwsA(
          isA<PrinterException>()
              .having(
                (e) => e.message,
                'message',
                'No se pudo encolar "Factura F2026S12 (original)"',
              )
              .having((e) => e.cause, 'cause', same(roto)),
        ),
      );
    });

    test('errorAlEncolar: sin lanzarErrores, aviso y null; con él, la '
        'PrinterException de la cola', () async {
      printer.errorAlEncolar = const PrinterException('La cola está llena');
      final id = await canal.enviar(
        cocina,
        'Comanda Nº 12',
        (p) async => comanda(p),
        preparacion: true,
      );
      expect(id, isNull);
      expect(printer.jobs, isEmpty);
      expect(
        alerts.recientes.single.titulo,
        'No se pudo encolar "Comanda Nº 12"',
      );
      expect(alerts.recientes.single.detalle, 'La cola está llena');

      await expectLater(
        canal.enviar(
          tickets,
          'Factura F2026S12 (original)',
          (p) async => ticket(p),
          lanzarErrores: true,
        ),
        throwsA(
          isA<PrinterException>().having(
            (e) => e.message,
            'message',
            'La cola está llena',
          ),
        ),
      );
      expect(
        await canal.enviarCrudo(tickets, 'Cajón', bytesAbrirCajon()),
        isNull,
      );
      expect(alerts.recientes.last.titulo, 'No se pudo encolar "Cajón"');
      await expectLater(
        canal.enviarCrudo(
          tickets,
          'Cajón',
          bytesAbrirCajon(),
          lanzarErrores: true,
        ),
        throwsA(isA<PrinterException>()),
      );
    });

    test('idle no completa mientras un trabajo sigue en curso; cuando '
        'termina con un fallo, el aviso ya está emitido', () async {
      final cola = _ColaRetenida();
      puerto = () => cola;
      final id = await canal.enviar(
        cocina,
        'Comanda Nº 12',
        (p) async => comanda(p),
        preparacion: true,
      );
      expect(id, 'trabajo-1');

      var enReposo = false;
      final espera = canal.idle().then((_) => enReposo = true);
      await pumpEventQueue();
      expect(enReposo, isFalse);
      expect(alerts.recientes, isEmpty);

      cola.fin.complete('Sin papel');
      await espera;
      expect(enReposo, isTrue);
      final aviso = alerts.recientes.single;
      expect(aviso.titulo, 'Fallo de impresión: Comanda Nº 12');
      expect(aviso.detalle, '10.0.0.10:9100: Sin papel');
    });

    test('se sigue el trabajo: si falla en la impresora, aviso «Fallo de '
        'impresión» con la dirección; si sale bien, ninguno', () async {
      printer.error = 'Sin papel';
      final id = await canal.enviar(
        cocina,
        'Comanda Nº 12',
        (p) async => comanda(p),
        preparacion: true,
      );
      expect(id, 'print-1');
      await canal.idle();
      final aviso = alerts.recientes.single;
      expect(aviso.titulo, 'Fallo de impresión: Comanda Nº 12');
      expect(aviso.detalle, '10.0.0.10:9100: Sin papel');
      expect(aviso.nivel, AlertaNivel.error);

      printer.error = null;
      await canal.enviar(tickets, 'Ticket', (p) async => ticket(p));
      await canal.idle();
      expect(alerts.recientes, hasLength(1));
    });

    test('un seguimiento que falla solo deja un registro de aviso, sin '
        'romper nada', () async {
      final registros = <LogRecord>[];
      configureLogging(level: Level.ALL, onRecord: registros.add);
      addTearDown(configureLogging);
      final cola = _ColaQueFallaAlSeguir();
      puerto = () => cola;
      expect(
        await canal.enviar(cocina, 'Comanda', (p) async => comanda(p)),
        'trabajo-1',
      );
      await canal.idle();
      expect(alerts.recientes, isEmpty);
      expect(
        registros.where(
          (r) =>
              r.level == Level.WARNING &&
              r.message == 'Seguimiento de "Comanda" falló' &&
              r.error is StateError,
        ),
        hasLength(1),
      );
    });

    test('sin cola de impresión: null sin aviso, o PrinterException con '
        'lanzarErrores', () async {
      puerto = () => null;
      expect(
        await canal.enviar(cocina, 'Comanda', (p) async => comanda(p)),
        isNull,
      );
      expect(
        await canal.enviarCrudo(tickets, 'Cajón', bytesAbrirCajon()),
        isNull,
      );
      expect(alerts.recientes, isEmpty);
      await expectLater(
        canal.enviar(
          tickets,
          'Factura',
          (p) async => ticket(p),
          lanzarErrores: true,
        ),
        throwsA(isA<PrinterException>()),
      );
      await expectLater(
        canal.enviarCrudo(
          tickets,
          'Cajón',
          bytesAbrirCajon(),
          lanzarErrores: true,
        ),
        throwsA(isA<PrinterException>()),
      );
    });
  });
}
