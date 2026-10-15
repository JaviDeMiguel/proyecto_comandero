/// Documentos de cliente del host (§5.3, §5.5 y §5.8 del diseño de
/// impresión): provisional y cajón al cobrar, factura simplificada ORIGINAL y
/// DUPLICADO con su QR tributario, copia del provisional, vista previa,
/// precuenta y apertura del cajón, contra un diario en memoria y
/// FakePrinterPort. El modo «Emitir factura al cobrar» está en
/// emision_factura_test.dart.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:proyecto_comandero/core/errors/app_exception.dart';
import 'package:proyecto_comandero/core/fiscal/verifactu_qr.dart';
import 'package:proyecto_comandero/core/isolates/escpos/escpos.dart';
import 'package:proyecto_comandero/core/isolates/escpos/qr_raster.dart';
import 'package:proyecto_comandero/core/isolates/isolate_runner.dart';
import 'package:proyecto_comandero/core/network/printing/print_queue.dart'
    show PrintRetryPolicy;
import 'package:proyecto_comandero/core/network/printing/raw_printer_transport.dart';
import 'package:proyecto_comandero/features/host/application/alert_bus.dart';
import 'package:proyecto_comandero/features/host/application/host_state_store.dart';
import 'package:proyecto_comandero/features/host/application/impresion/canal_impresion.dart';
import 'package:proyecto_comandero/features/host/application/impresion/tickets_impresion.dart';
import 'package:proyecto_comandero/features/host/application/ports.dart';
import 'package:proyecto_comandero/features/host/data/in_memory_host_state_repository.dart';
import 'package:proyecto_comandero/features/host/domain/host_settings.dart';
import 'package:proyecto_comandero/features/host/domain/host_snapshot.dart';
import 'package:proyecto_comandero/features/host/domain/operational_alert.dart';
import 'package:proyecto_comandero/features/impresion/domain/formato_impresion.dart';
import 'package:proyecto_comandero/features/sala/domain/linea_comanda.dart';
import 'package:proyecto_comandero/features/sala/domain/mesa.dart';
import 'package:proyecto_comandero/features/sala/domain/precuenta_emitida.dart';
import 'package:proyecto_comandero/features/sala/domain/ticket.dart';
import 'package:test/test.dart';

import '../../../core/isolates/escpos/escpos_decoder.dart';
import '../fakes/fake_ports.dart';

final impresoraTickets = PrinterEndpoint('192.168.1.50');
final impresoraCocina = PrinterEndpoint('192.168.1.51');
final cobro = DateTime(2026, 10, 9, 14, 32);
final expedicion = DateTime(2026, 10, 9, 14, 33);
const idTicket = '1a2b3c4d-5e6f-4a1b-9c2d-0123456789ab';
const mesa7 = Mesa(id: 'm7', nombre: 'Mesa 7', zona: 'Terraza');

const cabeceraConNif = EmpresaTicket(
  nombre: 'MANOLO GARCÍA HOSTELERÍA, S.L.',
  nombreComercial: 'BAR MANOLO',
  cifnif: 'B12345678',
);

/// QR de la factura F2026S12 (09-10-2026, 67,00 €) en producción y modo
/// VERI*FACTU.
const urlVerifactu =
    'https://www2.agenciatributaria.gob.es/wlpl/TIKE-CONT/ValidarQR'
    '?nif=B12345678&numserie=F2026S12&fecha=09-10-2026&importe=67.00';

const qrVerifactu = QrImpreso(
  url: urlVerifactu,
  leyenda: 'VERI*FACTU',
  modo: 'verifactu',
  entorno: 'produccion',
  nif: 'B12345678',
);

ImpresionSettings ajustesTickets({
  ModoQrVerifactu qr = ModoQrVerifactu.verifactu,
  EntornoVerifactu entorno = EntornoVerifactu.produccion,
  bool abrirCajon = true,
  bool imprimirAlCobrar = true,
  bool conImpresora = true,
  PaperWidth papel = PaperWidth.mm80,
}) => ImpresionSettings(
  tickets: conImpresora ? impresoraTickets : null,
  cocina: conImpresora ? impresoraCocina : null,
  abrirCajonEfectivo: abrirCajon,
  imprimirTicketAlCobrar: imprimirAlCobrar,
  paper: papel,
  formato: FormatoImpresion(
    verifactu: QrVerifactuConfig(modo: qr, entorno: entorno),
  ),
);

LineaComanda lc(
  String id,
  String referencia,
  String descripcion,
  double cantidad,
  int pvpUnitarioCents, {
  int ivaBp = 1000,
  String codimpuesto = 'IVA10',
}) => LineaComanda(
  id: id,
  referencia: referencia,
  descripcion: descripcion,
  cantidad: cantidad,
  pvpUnitarioCents: pvpUnitarioCents,
  pvpUnitarioNeto: pvpUnitarioCents / 100 / (1 + ivaBp / 10000),
  ivaBp: ivaBp,
  codimpuesto: codimpuesto,
  creadaEn: cobro,
);

/// Las líneas de las maquetas de §2: 67,00 € con IVA del 10 % y del 21 %.
List<LineaComanda> lineasMaqueta() => [
  lc('a1', 'CANA', 'Caña', 4, 200),
  lc('a2', 'CROQ', 'Croquetas de jamón', 1, 900),
  lc('a3', 'ENTR', 'Entrecot a la brasa', 2, 1900),
  lc(
    'a4',
    'VINO',
    'Vino Rioja crianza (llevar)',
    1,
    1200,
    ivaBp: 2100,
    codimpuesto: 'IVA21',
  ),
];

TotalesTicket totalesMaqueta() => TotalesTicket(
  netoCents: 5992,
  ivaCents: 708,
  totalCents: 6700,
  desglose: const [
    DesgloseIva(
      codimpuesto: 'IVA10',
      ivaBp: 1000,
      baseCents: 5000,
      cuotaCents: 500,
    ),
    DesgloseIva(
      codimpuesto: 'IVA21',
      ivaBp: 2100,
      baseCents: 992,
      cuotaCents: 208,
    ),
  ],
);

FacturaSincronizada facturaFs({
  int? totalFsCents = 6700,
  bool sinFecha = false,
}) => FacturaSincronizada(
  estado: EstadoSincronizacion.sincronizado,
  codigo: 'F2026S12',
  fecha: sinFecha ? null : expedicion,
  totalFsCents: totalFsCents,
);

final facturaPendiente = FacturaSincronizada(
  estado: EstadoSincronizacion.pendiente,
);

Ticket ticketMaqueta({
  String id = idTicket,
  int numeroLocal = 15,
  FacturaSincronizada? factura,
  MetodoPago metodo = MetodoPago.efectivo,
  List<PagoTicket>? pagos,
}) => Ticket(
  id: id,
  numeroLocal: numeroLocal,
  mesaId: mesa7.id,
  nombreMesa: mesa7.nombre,
  comandaId: 'c1',
  fechaHora: cobro,
  lineas: lineasMaqueta(),
  totales: totalesMaqueta(),
  metodoPago: metodo,
  pagos: pagos,
  entregadoCents: metodo == MetodoPago.efectivo ? 7000 : null,
  camarero: 'Ana',
  comensales: 4,
  factura: factura ?? facturaPendiente,
);

PrecuentaEmitida precuentaMaqueta() => PrecuentaEmitida(
  numero: 2,
  emitidaEn: DateTime(2026, 10, 9, 14, 10),
  comandaId: 'c1',
  nombreMesa: 'Mesa 7',
  lineas: [for (final l in lineasMaqueta()) LineaPrecuenta.desde(l)],
  totales: totalesMaqueta(),
  comensales: 4,
  emitidaPor: 'Ana',
);

/// Diario en memoria con la mesa 7 y los [tickets], canal con
/// FakePrinterPort y el servicio, con ajustes y cabecera cambiables entre
/// llamadas.
final class Banco {
  Banco({
    List<Ticket> tickets = const [],
    ImpresionSettings? ajustes,
    this.cabecera = cabeceraConNif,
    IsolateRunner runner = const InlineIsolateRunner(),
    PrinterPort? puerto,
  }) : ajustes = ajustes ?? ajustesTickets(),
       store = HostStateStore(
         InMemoryHostStateRepository(),
         HostSnapshot(mesas: const [mesa7], ticketsTurno: tickets),
       ) {
    canal = CanalImpresion(
      alerts: alerts,
      runner: runner,
      settings: () => this.ajustes,
      printer: () => puerto ?? impresora,
    );
    servicio = TicketsImpresion(
      store: store,
      canal: canal,
      alerts: alerts,
      settings: () => this.ajustes,
      cabecera: () => cabecera,
      now: reloj.call,
    );
  }

  final alerts = AlertBus();
  final impresora = FakePrinterPort();
  final reloj = FakeClock(DateTime(2026, 10, 9, 14, 40));
  final HostStateStore store;
  ImpresionSettings ajustes;
  EmpresaTicket cabecera;
  late final CanalImpresion canal;
  late final TicketsImpresion servicio;

  Ticket ticket([String id = idTicket]) => store.snapshot.ticketPorId(id)!;

  ImpresionTicket impresion([String id = idTicket]) => ticket(id).impresion;

  List<PrintedJob> get trabajos => impresora.jobs;

  List<String> get descripciones => [
    for (final trabajo in trabajos) trabajo.description,
  ];
}

/// Ejecutor que falla las primeras [fallos] veces con [error] (tras llamar a
/// [antesDeFallar]) y después genera en línea.
final class _RunnerQueFalla implements IsolateRunner {
  _RunnerQueFalla(this.error);

  final Object error;
  int fallos = 1;
  void Function()? antesDeFallar;

  @override
  Future<R> run<M, R>(
    IsolateEntryPoint<M, R> entryPoint,
    M message, {
    String? debugName,
  }) {
    if (fallos > 0) {
      fallos--;
      antesDeFallar?.call();
      return Future<R>.error(error);
    }
    return const InlineIsolateRunner().run(entryPoint, message);
  }
}

/// Cola que lanza un error no tipado al encolar.
final class _PuertoRoto implements PrinterPort {
  @override
  String imprimir(
    PrinterEndpoint endpoint,
    Uint8List bytes, {
    required String description,
    PrintRetryPolicy reintento = PrintRetryPolicy.always,
  }) => throw StateError('cola rota');

  @override
  Future<String?> terminado(String jobId) async => null;
}

/// Ejecutor cuya primera generación se queda a medias hasta [soltar] y
/// entonces falla con un error no tipado; las demás generan en línea.
final class _RunnerRetenido implements IsolateRunner {
  final _empezada = Completer<void>();
  final _soltada = Completer<void>();
  var _primera = true;

  /// Completa cuando la primera generación ya ha empezado, con la marca de
  /// la factura ya puesta en el diario.
  Future<void> get empezada => _empezada.future;

  void soltar() => _soltada.complete();

  @override
  Future<R> run<M, R>(
    IsolateEntryPoint<M, R> entryPoint,
    M message, {
    String? debugName,
  }) {
    if (!_primera) return const InlineIsolateRunner().run(entryPoint, message);
    _primera = false;
    _empezada.complete();
    return _soltada.future.then<R>((_) => throw StateError('isolate caído'));
  }
}

/// La banda en inverso con [texto] (DUPLICADO).
bool tieneBanda(DecodedStream d, String texto) =>
    d.lines.any((linea) => linea.inverse && linea.text.trim() == texto);

int cajonesEn(Uint8List bytes) => decodeEscPos(bytes).named('drawer').length;

Matcher validacion(String motivo) => throwsA(
  isA<ValidationException>().having((e) => e.message, 'message', motivo),
);

/// El error con el que termina [futuro], o `null` si termina bien.
Future<Object?> errorDe(Future<void> futuro) =>
    futuro.then<Object?>((_) => null, onError: (Object error) => error);

void main() {
  group('imprimirFactura: validación antes de marcar', () {
    test('el ticket debe estar en el turno', () async {
      final b = Banco();
      await expectLater(
        b.servicio.imprimirFactura('t-cerrado'),
        validacion('El ticket t-cerrado no está en el turno'),
      );
      expect(b.trabajos, isEmpty);
    });

    final casos =
        <String, ({FacturaSincronizada factura, EmpresaTicket cabecera})>{
          'aún no tiene número de FacturaScripts': (
            factura: facturaPendiente,
            cabecera: cabeceraConNif,
          ),
          'no tiene la fecha o el total de FacturaScripts': (
            factura: facturaFs(sinFecha: true),
            cabecera: cabeceraConNif,
          ),
          'no coincide con el del ticket': (
            factura: facturaFs(totalFsCents: 6701),
            cabecera: cabeceraConNif,
          ),
          'Falta el NIF del emisor': (
            factura: facturaFs(),
            cabecera: const EmpresaTicket(nombre: 'Bar sin NIF'),
          ),
        };
    for (final MapEntry(key: motivo, value: caso) in casos.entries) {
      test('«$motivo»: ValidationException y nada marcado', () async {
        final b = Banco(
          tickets: [ticketMaqueta(factura: caso.factura)],
          cabecera: caso.cabecera,
        );
        await expectLater(
          b.servicio.imprimirFactura(idTicket),
          throwsA(
            isA<ValidationException>().having(
              (e) => e.message,
              'message',
              contains(motivo),
            ),
          ),
        );
        expect(b.trabajos, isEmpty);
        expect(b.impresion(), ImpresionTicket.vacia);
      });
    }

    test('sin total de FS tampoco se imprime', () async {
      final b = Banco(
        tickets: [ticketMaqueta(factura: facturaFs(totalFsCents: null))],
      );
      await expectLater(
        b.servicio.imprimirFactura(idTicket),
        throwsA(isA<ValidationException>()),
      );
      expect(b.impresion(), ImpresionTicket.vacia);
    });

    test('sin impresora de tickets: PrinterException', () async {
      final b = Banco(
        tickets: [ticketMaqueta(factura: facturaFs())],
        ajustes: ajustesTickets(conImpresora: false),
      );
      await expectLater(
        b.servicio.imprimirFactura(idTicket),
        throwsA(isA<PrinterException>()),
      );
      expect(b.impresion(), ImpresionTicket.vacia);
    });

    test('el ticket y la factura se validan antes que la impresora (§5.5, '
        'pasos 1 a 3)', () async {
      final b = Banco(
        tickets: [ticketMaqueta()],
        ajustes: ajustesTickets(conImpresora: false),
      );
      await expectLater(
        b.servicio.imprimirFactura('t-cerrado'),
        validacion('El ticket t-cerrado no está en el turno'),
      );
      await expectLater(
        b.servicio.imprimirFactura(idTicket),
        throwsA(
          isA<ValidationException>().having(
            (e) => e.message,
            'message',
            contains('aún no tiene número de FacturaScripts'),
          ),
        ),
      );
      expect(b.impresion(), ImpresionTicket.vacia);
    });

    test('QR activado y NIF de 8 caracteres: ValidationException y '
        'Ticket.impresion sin cambios', () async {
      final b = Banco(
        tickets: [ticketMaqueta(factura: facturaFs())],
        cabecera: const EmpresaTicket(nombre: 'Bar', cifnif: 'B1234567'),
      );
      final antes = b.store.snapshot;
      await expectLater(
        b.servicio.imprimirFactura(idTicket),
        throwsA(
          isA<ValidationException>().having(
            (e) => e.message,
            'message',
            contains('no sirve para el QR tributario'),
          ),
        ),
      );
      expect(b.trabajos, isEmpty);
      expect(b.impresion(), ImpresionTicket.vacia);
      expect(identical(b.store.snapshot, antes), isTrue);

      // Con el QR desactivado nadie valida el formato del NIF.
      b.ajustes = ajustesTickets(qr: ModoQrVerifactu.desactivado);
      await b.servicio.imprimirFactura(idTicket);
      expect(b.impresion().originalImpreso, isTrue);
      expect(b.impresion().qr, isNull);
    });
  });

  group('ORIGINAL y DUPLICADO (art. 14)', () {
    test(
      'la 1ª vez es el ORIGINAL; la 2ª y la 3ª, DUPLICADO nº 1 y nº 2',
      () async {
        final b = Banco(tickets: [ticketMaqueta(factura: facturaFs())]);
        final enOriginal = b.reloj.now;
        await b.servicio.imprimirFactura(idTicket);
        b.reloj.advance(const Duration(minutes: 5));
        await b.servicio.imprimirFactura(idTicket);
        b.reloj.advance(const Duration(minutes: 5));
        await b.servicio.imprimirFactura(idTicket);
        await b.canal.idle();

        expect(b.descripciones, [
          'Factura F2026S12 (original)',
          'Factura F2026S12 (duplicado 1)',
          'Factura F2026S12 (duplicado 2)',
        ]);
        expect({for (final t in b.trabajos) t.endpoint}, {impresoraTickets});

        final original = decodeEscPos(b.trabajos[0].bytes);
        final texto = original.texts.join('|');
        expect(texto, contains('FACTURA SIMPLIFICADA'));
        expect(texto, contains('Nº F2026S12'));
        expect(texto, isNot(contains('COPIA')));
        expect(texto, isNot(contains('Duplicado')));
        expect(tieneBanda(original, 'DUPLICADO'), isFalse);
        expect(original.named('drawer'), isEmpty);

        for (final (indice, numero, hora) in [
          (1, 1, '14:45'),
          (2, 2, '14:50'),
        ]) {
          final duplicado = decodeEscPos(b.trabajos[indice].bytes);
          expect(tieneBanda(duplicado, 'DUPLICADO'), isTrue);
          final marca = duplicado.texts.singleWhere(
            (t) => t.startsWith('Duplicado nº'),
          );
          expect(marca, startsWith('Duplicado nº $numero '));
          expect(marca, endsWith('09/10/2026 $hora'));
          expect(duplicado.texts.join('|'), isNot(contains('COPIA')));
          expect(duplicado.named('drawer'), isEmpty);
        }

        // En el diario: el ORIGINAL con su hora y su QR, y dos duplicados.
        expect(
          b.impresion(),
          ImpresionTicket(
            facturaOriginalEn: enOriginal,
            qr: qrVerifactu,
            duplicados: 2,
          ),
        );
      },
    );

    test('el ORIGINAL y los DUPLICADOS se encolan con '
        'PrintRetryPolicy.connectOnly', () async {
      final b = Banco(tickets: [ticketMaqueta(factura: facturaFs())]);
      await b.servicio.imprimirFactura(idTicket);
      await b.servicio.imprimirFactura(idTicket);
      expect(
        [for (final t in b.trabajos) t.reintento],
        [PrintRetryPolicy.connectOnly, PrintRetryPolicy.connectOnly],
      );
    });

    test('dos llamadas seguidas no dan dos originales: el ORIGINAL y '
        'después el DUPLICADO nº 1', () async {
      final b = Banco(tickets: [ticketMaqueta(factura: facturaFs())]);
      await Future.wait([
        b.servicio.imprimirFactura(idTicket),
        b.servicio.imprimirFactura(idTicket),
      ]);
      expect(b.descripciones, [
        'Factura F2026S12 (original)',
        'Factura F2026S12 (duplicado 1)',
      ]);
      expect(b.impresion().duplicados, 1);
      expect(b.impresion().qr, qrVerifactu);
    });

    test('dos llamadas seguidas que no se pueden encolar dejan '
        'Ticket.impresion como estaba', () async {
      final b = Banco(tickets: [ticketMaqueta(factura: facturaFs())]);
      b.impresora.errorAlEncolar = const PrinterException('Cola llena');
      final errores = await Future.wait([
        for (var i = 0; i < 2; i++)
          errorDe(b.servicio.imprimirFactura(idTicket)),
      ]);
      expect(errores, everyElement(isA<PrinterException>()));
      expect(b.trabajos, isEmpty);
      expect(b.impresion(), ImpresionTicket.vacia);
    });

    test('si la primera de tres llamadas seguidas falla al generarse, la '
        'segunda es el ORIGINAL y la tercera el DUPLICADO nº 1', () async {
      final b = Banco(
        tickets: [ticketMaqueta(factura: facturaFs())],
        runner: _RunnerQueFalla(StateError('isolate caído')),
      );
      final errores = await Future.wait([
        for (var i = 0; i < 3; i++)
          errorDe(b.servicio.imprimirFactura(idTicket)),
      ]);
      expect(errores.first, isA<PrinterException>());
      expect(errores.skip(1), everyElement(isNull));
      expect(b.descripciones, [
        'Factura F2026S12 (original)',
        'Factura F2026S12 (duplicado 1)',
      ]);
      expect(
        b.impresion(),
        ImpresionTicket(
          facturaOriginalEn: b.reloj.now,
          qr: qrVerifactu,
          duplicados: 1,
        ),
      );
    });

    for (final (error, tipo) in [
      (StateError('isolate caído'), isA<PrinterException>()),
      (const ValidationException('El QR no cabe'), isA<ValidationException>()),
    ]) {
      test('si falla la generación (${error.runtimeType}), la marca se '
          'revierte y la siguiente es el ORIGINAL', () async {
        final b = Banco(
          tickets: [ticketMaqueta(factura: facturaFs())],
          runner: _RunnerQueFalla(error),
        );
        await expectLater(b.servicio.imprimirFactura(idTicket), throwsA(tipo));
        expect(b.trabajos, isEmpty);
        expect(b.impresion(), ImpresionTicket.vacia);

        await b.servicio.imprimirFactura(idTicket);
        expect(b.descripciones, ['Factura F2026S12 (original)']);
        expect(b.impresion().qr, qrVerifactu);
      });
    }

    test(
      'si falla el encolado (errorAlEncolar), la marca se revierte',
      () async {
        final b = Banco(tickets: [ticketMaqueta(factura: facturaFs())]);
        const llena = PrinterException('Cola de impresión llena');
        b.impresora.errorAlEncolar = llena;
        await expectLater(
          b.servicio.imprimirFactura(idTicket),
          throwsA(same(llena)),
        );
        expect(b.impresion(), ImpresionTicket.vacia);

        b.impresora.errorAlEncolar = null;
        await b.servicio.imprimirFactura(idTicket);
        final conOriginal = b.impresion();
        expect(conOriginal.originalImpreso, isTrue);

        // Un DUPLICADO que no se encola tampoco cuenta.
        b.impresora.errorAlEncolar = llena;
        await expectLater(
          b.servicio.imprimirFactura(idTicket),
          throwsA(same(llena)),
        );
        expect(b.impresion(), conOriginal);

        b.impresora.errorAlEncolar = null;
        await b.servicio.imprimirFactura(idTicket);
        expect(b.descripciones, [
          'Factura F2026S12 (original)',
          'Factura F2026S12 (duplicado 1)',
        ]);
      },
    );

    test('si el diario se cierra mientras se genera, llega el error original '
        'y la marca se queda (la siguiente sería un DUPLICADO)', () async {
      final runner = _RunnerQueFalla(StateError('isolate caído'));
      final b = Banco(
        tickets: [ticketMaqueta(factura: facturaFs())],
        runner: runner,
      );
      runner.antesDeFallar = () => unawaited(b.store.dispose());
      await expectLater(
        b.servicio.imprimirFactura(idTicket),
        throwsA(isA<PrinterException>()),
      );
      expect(b.trabajos, isEmpty);
      expect(b.impresion().originalImpreso, isTrue);
    });

    test('la reversión deshace solo la marca de la factura: el provisional '
        'anotado mientras se generaba se queda', () async {
      final runner = _RunnerRetenido();
      final b = Banco(
        tickets: [ticketMaqueta(factura: facturaFs())],
        runner: runner,
      );
      final factura = errorDe(b.servicio.imprimirFactura(idTicket));
      await runner.empezada;
      expect(b.impresion().originalImpreso, isTrue);

      await b.servicio.reimprimirProvisional(idTicket);
      runner.soltar();

      expect(await factura, isA<PrinterException>());
      expect(b.descripciones, ['Ticket 15 · provisional (copia)']);
      expect(b.impresion(), ImpresionTicket(provisionalEn: b.reloj.now));
    });

    test('la reversión no pisa una marca de la factura que otro escritor '
        'del diario cambió entre medias', () async {
      final runner = _RunnerRetenido();
      final b = Banco(
        tickets: [ticketMaqueta(factura: facturaFs())],
        runner: runner,
      );
      final factura = errorDe(b.servicio.imprimirFactura(idTicket));
      await runner.empezada;
      final ajena = ImpresionTicket(facturaOriginalEn: cobro, duplicados: 3);
      await b.store.update(
        (s) => s.conTicket(b.ticket().copyWith(impresion: ajena)),
      );
      runner.soltar();

      expect(await factura, isA<PrinterException>());
      expect(b.impresion(), ajena);
    });

    test('si el ticket sale del turno (Cierre Z) mientras la petición '
        'espera a la anterior, lanza ValidationException', () async {
      final runner = _RunnerRetenido();
      final b = Banco(
        tickets: [ticketMaqueta(factura: facturaFs())],
        runner: runner,
      );
      final primera = errorDe(b.servicio.imprimirFactura(idTicket));
      await runner.empezada;
      final segunda = errorDe(b.servicio.imprimirFactura(idTicket));
      await b.store.update((s) => s.copyWith(ticketsTurno: const []));
      runner.soltar();

      expect(await primera, isA<PrinterException>());
      expect(
        await segunda,
        isA<ValidationException>().having(
          (e) => e.message,
          'message',
          'El ticket $idTicket no está en el turno',
        ),
      );
      expect(b.trabajos, isEmpty);
    });

    test('si la factura deja de ser imprimible mientras la petición espera a '
        'la anterior, lanza ValidationException sin marcar nada', () async {
      final runner = _RunnerRetenido();
      final b = Banco(
        tickets: [ticketMaqueta(factura: facturaFs())],
        runner: runner,
      );
      final primera = errorDe(b.servicio.imprimirFactura(idTicket));
      await runner.empezada;
      final segunda = errorDe(b.servicio.imprimirFactura(idTicket));
      await b.store.update(
        (s) =>
            s.conTicket(b.ticket().conFactura(facturaFs(totalFsCents: 6701))),
      );
      runner.soltar();

      expect(await primera, isA<PrinterException>());
      expect(
        await segunda,
        isA<ValidationException>().having(
          (e) => e.message,
          'message',
          contains('no coincide con el del ticket'),
        ),
      );
      expect(b.trabajos, isEmpty);
      expect(b.impresion(), ImpresionTicket.vacia);
    });

    test('si el trabajo falla en la impresora después de encolarse, la marca '
        'se conserva y la siguiente es «(duplicado 1)» con la banda '
        'DUPLICADO', () async {
      final b = Banco(tickets: [ticketMaqueta(factura: facturaFs())]);
      b.impresora.error = 'Sin papel';
      await b.servicio.imprimirFactura(idTicket);
      await b.canal.idle();
      final fallo = b.alerts.recientes.single;
      expect(fallo.titulo, 'Fallo de impresión: Factura F2026S12 (original)');
      expect(b.impresion().originalImpreso, isTrue);

      b.impresora.error = null;
      await b.servicio.imprimirFactura(idTicket);
      final duplicado = b.trabajos.last;
      expect(duplicado.description, 'Factura F2026S12 (duplicado 1)');
      expect(tieneBanda(decodeEscPos(duplicado.bytes), 'DUPLICADO'), isTrue);
      expect(b.impresion().duplicados, 1);
    });

    test('el DUPLICADO lleva el mismo QR que el ORIGINAL aunque cambien los '
        'ajustes del QR o el NIF en caché', () async {
      final b = Banco(tickets: [ticketMaqueta(factura: facturaFs())]);
      await b.servicio.imprimirFactura(idTicket);
      expect(b.impresion().qr, qrVerifactu);

      b.ajustes = ajustesTickets(
        qr: ModoQrVerifactu.noVerifactu,
        entorno: EntornoVerifactu.pruebas,
      );
      b.cabecera = const EmpresaTicket(
        nombre: 'OTRA RAZÓN SOCIAL, S.L.',
        cifnif: 'A87654321',
      );
      await b.servicio.imprimirFactura(idTicket);

      final original = decodeEscPos(b.trabajos[0].bytes);
      final duplicado = decodeEscPos(b.trabajos[1].bytes);
      final qrOriginal = original.rasters.single;
      final qrDuplicado = duplicado.rasters.single;
      expect(qrDuplicado.width, qrOriginal.width);
      expect(qrDuplicado.height, qrOriginal.height);
      expect(qrDuplicado.bits, qrOriginal.bits);
      // Y es el QR de la URL guardada con el ORIGINAL.
      final esperado = rasterizarQr(
        urlVerifactu,
        dpi: 203,
        anchoMaximoPuntos: 576,
      );
      expect(qrOriginal.bits, esperado.imagen.bits);
      expect(duplicado.texts, contains('VERI*FACTU'));
      expect(b.impresion().qr, qrVerifactu);
      // La cabecera sí es la de ahora.
      expect(duplicado.texts.join('|'), contains('NIF: A87654321'));
    });
  });

  group('QR según los ajustes', () {
    Future<(DecodedStream, QrImpreso?)> imprimir(
      ImpresionSettings ajustes, {
      EmpresaTicket cabecera = cabeceraConNif,
    }) async {
      final b = Banco(
        tickets: [ticketMaqueta(factura: facturaFs())],
        ajustes: ajustes,
        cabecera: cabecera,
      );
      await b.servicio.imprimirFactura(idTicket);
      expect(b.impresion().originalImpreso, isTrue);
      return (decodeEscPos(b.trabajos.single.bytes), b.impresion().qr);
    }

    test('desactivado: sin QR', () async {
      final (d, qr) = await imprimir(
        ajustesTickets(qr: ModoQrVerifactu.desactivado),
      );
      expect(d.rasters, isEmpty);
      expect(d.texts, isNot(contains('QR tributario:')));
      expect(qr, isNull);
    });

    test('VERI*FACTU: con la leyenda y el NIF normalizado', () async {
      final (d, qr) = await imprimir(
        ajustesTickets(),
        cabecera: const EmpresaTicket(nombre: 'Bar', cifnif: 'es b-1234567.8'),
      );
      expect(d.rasters, hasLength(1));
      expect(d.texts.take(2), ['QR tributario:', 'VERI*FACTU']);
      expect(qr, qrVerifactu);
    });

    test('NO VERI*FACTU: ValidarQRNoVerifactu y sin leyenda', () async {
      final (d, qr) = await imprimir(
        ajustesTickets(qr: ModoQrVerifactu.noVerifactu),
      );
      expect(d.rasters, hasLength(1));
      expect(d.texts, isNot(contains('VERI*FACTU')));
      expect(
        qr,
        const QrImpreso(
          url:
              'https://www2.agenciatributaria.gob.es/wlpl/TIKE-CONT/'
              'ValidarQRNoVerifactu?nif=B12345678&numserie=F2026S12'
              '&fecha=09-10-2026&importe=67.00',
          modo: 'noVerifactu',
          entorno: 'produccion',
          nif: 'B12345678',
        ),
      );
    });

    test('pruebas: prewww2', () async {
      final (_, qr) = await imprimir(
        ajustesTickets(entorno: EntornoVerifactu.pruebas),
      );
      expect(
        qr!.url,
        startsWith('https://prewww2.aeat.es/wlpl/TIKE-CONT/ValidarQR?nif='),
      );
      expect(qr.entorno, 'pruebas');
      expect(qr.leyenda, 'VERI*FACTU');
    });

    test('la fecha del QR es la de expedición de FS, aunque sea otro día '
        'que el cobro', () async {
      final b = Banco(
        tickets: [
          ticketMaqueta(
            factura: FacturaSincronizada(
              estado: EstadoSincronizacion.sincronizado,
              codigo: 'F2026S12',
              fecha: DateTime(2026, 10, 10, 0, 5),
              totalFsCents: 6700,
            ),
          ),
        ],
      );
      await b.servicio.imprimirFactura(idTicket);
      expect(b.ticket().fechaHora, cobro);
      expect(b.impresion().qr!.url, contains('&fecha=10-10-2026&'));
    });

    test('nunca hay QR en el provisional ni en la precuenta', () async {
      final b = Banco(tickets: [ticketMaqueta(factura: facturaFs())]);
      await b.servicio.alCobrar(b.ticket());
      await b.servicio.reimprimirProvisional(idTicket);
      await b.servicio.imprimirPrecuenta(precuentaMaqueta());
      expect(b.trabajos, hasLength(3));
      for (final trabajo in b.trabajos) {
        final d = decodeEscPos(trabajo.bytes);
        expect(d.rasters, isEmpty, reason: trabajo.description);
        expect(d.texts, isNot(contains('QR tributario:')));
        expect(d.texts, isNot(contains('VERI*FACTU')));
      }
    });
  });

  group('provisional al cobrar (modo por defecto)', () {
    test(
      'con efectivo: el pulso del cajón va al principio del provisional',
      () async {
        final b = Banco(tickets: [ticketMaqueta()]);
        await b.servicio.alCobrar(b.ticket());
        await b.canal.idle();

        final trabajo = b.trabajos.single;
        expect(trabajo.description, 'Ticket 15 · provisional');
        expect(trabajo.endpoint, impresoraTickets);
        expect(trabajo.reintento, PrintRetryPolicy.always);
        final d = decodeEscPos(trabajo.bytes);
        expect(
          d.elements.first,
          isA<ElementoMarca>().having(
            (m) => m.comando.name,
            'comando',
            'drawer',
          ),
        );
        expect(d.named('drawer'), hasLength(1));
        final texto = d.texts.join('|');
        expect(texto, contains('DOCUMENTO PROVISIONAL'));
        expect(texto, contains('Ticket nº 15'));
        expect(texto, contains('Mesa 7 · Terraza'));
        expect(texto, contains('Ref. TPV-1a2b3c4d'));
        expect(b.impresion(), ImpresionTicket(provisionalEn: b.reloj.now));
        expect(b.alerts.recientes, isEmpty);
      },
    );

    test('con imprimirTicketAlCobrar = false y efectivo: solo el trabajo del '
        'cajón', () async {
      final b = Banco(
        tickets: [ticketMaqueta()],
        ajustes: ajustesTickets(imprimirAlCobrar: false),
      );
      await b.servicio.alCobrar(b.ticket());
      final trabajo = b.trabajos.single;
      expect(trabajo.description, 'Cajón · ticket 15');
      expect(trabajo.bytes, bytesAbrirCajon());
      expect(trabajo.endpoint, impresoraTickets);
      expect(b.impresion(), ImpresionTicket.vacia);
    });

    test('con tarjeta: sin cajón', () async {
      final b = Banco(tickets: [ticketMaqueta(metodo: MetodoPago.tarjeta)]);
      await b.servicio.alCobrar(b.ticket());
      expect(b.descripciones, ['Ticket 15 · provisional']);
      expect(cajonesEn(b.trabajos.single.bytes), 0);

      final sinTicket = Banco(
        tickets: [ticketMaqueta(metodo: MetodoPago.tarjeta)],
        ajustes: ajustesTickets(imprimirAlCobrar: false),
      );
      await sinTicket.servicio.alCobrar(sinTicket.ticket());
      expect(sinTicket.trabajos, isEmpty);
    });

    test(
      'cobro mixto con efectivo: cajón; sin «Abrir el cajón», nunca',
      () async {
        final mixto = ticketMaqueta(
          pagos: const [
            PagoTicket(metodo: MetodoPago.efectivo, importeCents: 4000),
            PagoTicket(metodo: MetodoPago.tarjeta, importeCents: 2700),
          ],
        );
        final b = Banco(tickets: [mixto]);
        await b.servicio.alCobrar(b.ticket());
        expect(cajonesEn(b.trabajos.single.bytes), 1);

        final sinCajon = Banco(
          tickets: [mixto],
          ajustes: ajustesTickets(abrirCajon: false),
        );
        await sinCajon.servicio.alCobrar(sinCajon.ticket());
        expect(cajonesEn(sinCajon.trabajos.single.bytes), 0);
      },
    );

    test('cobro mixto con la tarjeta como forma principal: el cajón se abre '
        'por la parte en efectivo', () async {
      final mixto = ticketMaqueta(
        metodo: MetodoPago.tarjeta,
        pagos: const [
          PagoTicket(metodo: MetodoPago.efectivo, importeCents: 2000),
          PagoTicket(metodo: MetodoPago.tarjeta, importeCents: 4700),
        ],
      );
      expect(mixto.metodoPago, MetodoPago.tarjeta);
      final b = Banco(tickets: [mixto]);
      await b.servicio.alCobrar(b.ticket());
      expect(b.descripciones, ['Ticket 15 · provisional']);
      expect(cajonesEn(b.trabajos.single.bytes), 1);
    });

    for (final error in [
      const ValidationException('Ticket ilegible'),
      StateError('isolate caído'),
    ]) {
      test('si generar el provisional falla (${error.runtimeType}) y hay '
          'efectivo, sale el trabajo propio del cajón', () async {
        final b = Banco(
          tickets: [ticketMaqueta()],
          runner: _RunnerQueFalla(error),
        );
        await b.servicio.alCobrar(b.ticket());

        final trabajo = b.trabajos.single;
        expect(trabajo.description, 'Cajón · ticket 15');
        expect(trabajo.bytes, bytesAbrirCajon());
        expect(b.impresion(), ImpresionTicket.vacia);
        final aviso = b.alerts.recientes.single;
        expect(aviso.nivel, AlertaNivel.error);
        expect(aviso.titulo, contains('"Ticket 15 · provisional"'));
      });
    }

    test(
      'un error no tipado al encolar el cajón se avisa y no se propaga',
      () async {
        final b = Banco(
          tickets: [ticketMaqueta()],
          ajustes: ajustesTickets(imprimirAlCobrar: false),
          puerto: _PuertoRoto(),
        );
        await b.servicio.alCobrar(b.ticket());
        final aviso = b.alerts.recientes.single;
        expect(aviso.nivel, AlertaNivel.error);
        expect(aviso.titulo, 'No se pudo abrir el cajón del ticket 15');
        expect(aviso.detalle, contains('cola rota'));
      },
    );

    test('sin impresora de tickets no imprime nada', () async {
      final b = Banco(
        tickets: [ticketMaqueta()],
        ajustes: ajustesTickets(conImpresora: false),
      );
      await b.servicio.alCobrar(b.ticket());
      expect(b.trabajos, isEmpty);
      expect(b.alerts.recientes, isEmpty);
    });
  });

  group('copia del provisional, documento del ticket y vista previa', () {
    test(
      'reimprimirProvisional pone COPIA, nunca abre el cajón y cuenta',
      () async {
        final b = Banco(tickets: [ticketMaqueta()]);
        await b.servicio.alCobrar(b.ticket());
        final primera = b.reloj.now;
        b.reloj.advance(const Duration(minutes: 3));
        await b.servicio.reimprimirProvisional(idTicket);
        await b.servicio.reimprimirProvisional(idTicket);

        final copias = b.trabajos.skip(1).toList();
        expect(
          [for (final c in copias) c.description],
          [
            'Ticket 15 · provisional (copia)',
            'Ticket 15 · provisional (copia)',
          ],
        );
        for (final copia in copias) {
          final d = decodeEscPos(copia.bytes);
          expect(d.texts, contains('COPIA'));
          expect(d.texts.join('|'), contains('DOCUMENTO PROVISIONAL'));
          expect(d.named('drawer'), isEmpty);
          expect(copia.reintento, PrintRetryPolicy.always);
        }
        expect(
          b.impresion(),
          ImpresionTicket(provisionalEn: primera, copiasProvisional: 2),
        );
      },
    );

    test('reimprimirProvisional: fuera del turno, ValidationException; sin '
        'impresora, PrinterException', () async {
      final b = Banco(tickets: [ticketMaqueta()]);
      await expectLater(
        b.servicio.reimprimirProvisional('t-cerrado'),
        validacion('El ticket t-cerrado no está en el turno'),
      );
      b.ajustes = ajustesTickets(conImpresora: false);
      await expectLater(
        b.servicio.reimprimirProvisional(idTicket),
        throwsA(
          isA<PrinterException>().having(
            (e) => e.message,
            'message',
            'No hay impresora de tickets configurada',
          ),
        ),
      );
      expect(b.impresion(), ImpresionTicket.vacia);
    });

    test('reimprimirProvisional: si no se puede encolar, llega el error y la '
        'copia no cuenta', () async {
      final b = Banco(tickets: [ticketMaqueta()]);
      await b.servicio.alCobrar(b.ticket());
      final antes = b.impresion();
      b.impresora.errorAlEncolar = const PrinterException('Cola llena');
      await expectLater(
        b.servicio.reimprimirProvisional(idTicket),
        throwsA(isA<PrinterException>()),
      );
      expect(b.impresion(), antes);
      expect(b.descripciones, ['Ticket 15 · provisional']);
    });

    test('imprimirDocumentoTicket: la factura si es imprimible y, si no, una '
        'copia del provisional', () async {
      final b = Banco(
        tickets: [
          ticketMaqueta(factura: facturaFs()),
          ticketMaqueta(id: 't-16', numeroLocal: 16),
        ],
      );
      await b.servicio.imprimirDocumentoTicket(idTicket);
      await b.servicio.imprimirDocumentoTicket('t-16');
      await b.servicio.imprimirDocumentoTicket(idTicket);
      expect(b.descripciones, [
        'Factura F2026S12 (original)',
        'Ticket 16 · provisional (copia)',
        'Factura F2026S12 (duplicado 1)',
      ]);
      await expectLater(
        b.servicio.imprimirDocumentoTicket('t-cerrado'),
        validacion('El ticket t-cerrado no está en el turno'),
      );
    });

    test('vistaPreviaTicket no tiene efectos: es la siguiente impresión, sin '
        'marcar ni encolar', () async {
      final b = Banco(tickets: [ticketMaqueta(factura: facturaFs())]);
      final antes = b.store.snapshot;
      final previa = await b.servicio.vistaPreviaTicket(idTicket);
      expect(b.trabajos, isEmpty);
      expect(identical(b.store.snapshot, antes), isTrue);

      await b.servicio.imprimirFactura(idTicket);
      expect(previa, b.trabajos.single.bytes);

      // Tras el ORIGINAL, el DUPLICADO nº 1 con el QR guardado, aunque el QR
      // esté ahora desactivado.
      b.ajustes = ajustesTickets(qr: ModoQrVerifactu.desactivado);
      final conOriginal = b.store.snapshot;
      final duplicado = decodeEscPos(
        await b.servicio.vistaPreviaTicket(idTicket),
      );
      expect(tieneBanda(duplicado, 'DUPLICADO'), isTrue);
      expect(
        duplicado.texts.where((t) => t.startsWith('Duplicado nº 1 ')),
        hasLength(1),
      );
      expect(
        duplicado.rasters.single.bits,
        decodeEscPos(b.trabajos.single.bytes).rasters.single.bits,
      );
      expect(identical(b.store.snapshot, conOriginal), isTrue);
      expect(b.trabajos, hasLength(1));
    });

    test('vistaPreviaTicket de una factura no imprimible: el provisional con '
        'COPIA y sin cajón', () async {
      final b = Banco(tickets: [ticketMaqueta()]);
      final d = decodeEscPos(await b.servicio.vistaPreviaTicket(idTicket));
      final texto = d.texts.join('|');
      expect(texto, contains('DOCUMENTO PROVISIONAL'));
      expect(d.texts, contains('COPIA'));
      expect(d.named('drawer'), isEmpty);
      expect(b.trabajos, isEmpty);
      expect(b.impresion(), ImpresionTicket.vacia);
    });

    test('vistaPreviaTicket: sin impresora de tickets usa el papel heredado; '
        'fuera del turno, ValidationException; QR no válido, '
        'ValidationException', () async {
      final b = Banco(
        tickets: [ticketMaqueta()],
        ajustes: ajustesTickets(conImpresora: false, papel: PaperWidth.mm58),
      );
      final d = decodeEscPos(await b.servicio.vistaPreviaTicket(idTicket));
      expectWidthsWithin(d, PaperWidth.mm58);
      expect(d.texts, contains('-' * PaperWidth.mm58.columns));
      await expectLater(
        b.servicio.vistaPreviaTicket('t-cerrado'),
        validacion('El ticket t-cerrado no está en el turno'),
      );

      final sinQr = Banco(
        tickets: [ticketMaqueta(factura: facturaFs())],
        cabecera: const EmpresaTicket(nombre: 'Bar', cifnif: 'B1234567'),
      );
      await expectLater(
        sinQr.servicio.vistaPreviaTicket(idTicket),
        throwsA(isA<ValidationException>()),
      );
    });
  });

  group('precuenta', () {
    test(
      'se imprime desde el registro: nº N con importe por comensal',
      () async {
        final b = Banco();
        await b.servicio.imprimirPrecuenta(precuentaMaqueta(), zona: 'Terraza');
        final trabajo = b.trabajos.single;
        expect(trabajo.description, 'Precuenta nº 2 · Mesa 7');
        expect(trabajo.endpoint, impresoraTickets);
        expect(trabajo.reintento, PrintRetryPolicy.always);
        final d = decodeEscPos(trabajo.bytes);
        final texto = d.texts.join('|');
        expect(texto, contains('PRECUENTA Nº 2'));
        expect(texto, contains('Mesa 7 · Terraza'));
        expect(texto, contains('4 x Caña'));
        expect(
          d.texts.singleWhere((t) => t.startsWith('Por comensal (4)')),
          contains('16,75'),
        );
        expect(d.named('drawer'), isEmpty);
        expect(d.rasters, isEmpty);
      },
    );

    test('sin impresora de tickets: PrinterException', () async {
      final b = Banco(ajustes: ajustesTickets(conImpresora: false));
      await expectLater(
        b.servicio.imprimirPrecuenta(precuentaMaqueta()),
        throwsA(isA<PrinterException>()),
      );
    });

    test('un fallo al encolar llega a quien la pide', () async {
      final b = Banco();
      b.impresora.errorAlEncolar = const PrinterException('Cola llena');
      await expectLater(
        b.servicio.imprimirPrecuenta(precuentaMaqueta()),
        throwsA(isA<PrinterException>()),
      );
    });
  });

  group('abrirCajon', () {
    test('encola el pulso del cajón en la impresora de tickets', () async {
      final b = Banco();
      await b.servicio.abrirCajon();
      final trabajo = b.trabajos.single;
      expect(trabajo.description, 'Cajón · apertura manual');
      expect(trabajo.endpoint, impresoraTickets);
      expect(trabajo.bytes, bytesAbrirCajon());
      expect(trabajo.reintento, PrintRetryPolicy.always);
    });

    test('sin impresora de tickets: PrinterException', () async {
      final b = Banco(ajustes: ajustesTickets(conImpresora: false));
      await expectLater(
        b.servicio.abrirCajon(),
        throwsA(isA<PrinterException>()),
      );
    });

    test('si no se puede encolar, llega el error', () async {
      final b = Banco();
      b.impresora.errorAlEncolar = const PrinterException('Cola llena');
      await expectLater(
        b.servicio.abrirCajon(),
        throwsA(
          isA<PrinterException>().having(
            (e) => e.message,
            'message',
            'Cola llena',
          ),
        ),
      );
      expect(b.trabajos, isEmpty);
    });
  });

  group('perfil y formato de la impresora de tickets', () {
    test('el perfil (58 mm, 3 copias y zumbador) llega a la factura, al '
        'provisional, a la precuenta y a la vista previa, no el papel '
        'heredado; cada documento de cliente sale una vez y sin aviso '
        'sonoro', () async {
      final b = Banco(
        tickets: [ticketMaqueta(factura: facturaFs())],
        ajustes: ImpresionSettings(
          tickets: impresoraTickets,
          abrirCajonEfectivo: true,
          paper: PaperWidth.mm80,
          formato: const FormatoImpresion(
            verifactu: QrVerifactuConfig(modo: ModoQrVerifactu.verifactu),
            perfiles: {
              RolImpresora.tickets: PerfilImpresora(
                papel: PaperWidth.mm58,
                copias: 3,
                zumbador: ZumbadorModo.generico,
              ),
            },
          ),
        ),
      );
      await b.servicio.imprimirFactura(idTicket);
      await b.servicio.alCobrar(b.ticket());
      await b.servicio.imprimirPrecuenta(precuentaMaqueta());
      final vista = await b.servicio.vistaPreviaTicket(idTicket);

      expect(b.descripciones, [
        'Factura F2026S12 (original)',
        'Ticket 15 · provisional',
        'Precuenta nº 2 · Mesa 7',
      ]);
      final documentos = {
        for (final trabajo in b.trabajos) trabajo.description: trabajo.bytes,
        'vista previa': vista,
      };
      for (final MapEntry(key: nombre, value: bytes) in documentos.entries) {
        final d = decodeEscPos(bytes);
        expectWidthsWithin(d, PaperWidth.mm58);
        expect(
          d.texts,
          contains('-' * PaperWidth.mm58.columns),
          reason: nombre,
        );
        expect(d.named('cut'), hasLength(1), reason: nombre);
        expect(d.named('beep'), isEmpty, reason: nombre);
      }
    });

    for (final mostrarCamarero in [true, false]) {
      test('el formato del ticket de los ajustes (mostrarCamarero: '
          '$mostrarCamarero) llega al provisional, a la factura, a la '
          'precuenta y a la vista previa', () async {
        final b = Banco(
          tickets: [ticketMaqueta(factura: facturaFs())],
          ajustes: ImpresionSettings(
            tickets: impresoraTickets,
            formato: FormatoImpresion(
              ticket: FormatoTicket(mostrarCamarero: mostrarCamarero),
              verifactu: const QrVerifactuConfig(
                modo: ModoQrVerifactu.verifactu,
              ),
            ),
          ),
        );
        await b.servicio.alCobrar(b.ticket());
        await b.servicio.imprimirFactura(idTicket);
        await b.servicio.imprimirPrecuenta(precuentaMaqueta());
        final vista = await b.servicio.vistaPreviaTicket(idTicket);

        expect(b.trabajos, hasLength(3));
        for (final bytes in [for (final t in b.trabajos) t.bytes, vista]) {
          expect(
            decodeEscPos(bytes).texts.join('|'),
            mostrarCamarero
                ? contains('Camarero: Ana')
                : isNot(contains('Camarero')),
          );
        }
      });
    }
  });

  group('emisiones pendientes fuera del modo factura', () {
    test('el modo por defecto nunca deja emisiones pendientes', () async {
      final b = Banco(tickets: [ticketMaqueta()]);
      final emitidos = <Set<String>>[];
      final suscripcion = b.servicio.emisionesPendientes.listen(emitidos.add);
      final cobrar = b.servicio.alCobrar(b.ticket());
      expect(b.servicio.emisionPendiente(idTicket), isFalse);
      await cobrar;
      await suscripcion.cancel();
      expect(emitidos, [<String>{}]);
    });
  });
}
