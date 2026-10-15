/// Modo «Emitir factura al cobrar» (§5.4 y §5.6 del diseño de impresión),
/// con fake_async: el cajón al instante, la espera de la factura en el diario
/// con su plazo, el ORIGINAL si llega a tiempo y, si no, el provisional sin
/// cajón con un aviso; las emisiones pendientes y la cancelación de esperas.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:proyecto_comandero/core/errors/app_exception.dart';
import 'package:proyecto_comandero/core/fiscal/verifactu_qr.dart';
import 'package:proyecto_comandero/core/isolates/escpos/escpos.dart';
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
import 'package:proyecto_comandero/features/sala/domain/ticket.dart';
import 'package:test/test.dart';

import '../../../core/isolates/escpos/escpos_decoder.dart';
import '../fakes/fake_ports.dart';

final impresoraTickets = PrinterEndpoint('192.168.1.50');
final cobro = DateTime(2026, 10, 9, 14, 32);
const idTicket = 't-15';
const mesa7 = Mesa(id: 'm7', nombre: 'Mesa 7', zona: 'Terraza');
const plazo = Duration(seconds: 10);

const cabeceraConNif = EmpresaTicket(
  nombre: 'BAR MANOLO, S.L.',
  cifnif: 'B12345678',
);

ImpresionSettings ajustesFactura({
  ModoEmision modo = ModoEmision.facturaAlCobrar,
  bool imprimirAlCobrar = true,
  bool conImpresora = true,
  Duration espera = plazo,
}) => ImpresionSettings(
  tickets: conImpresora ? impresoraTickets : null,
  abrirCajonEfectivo: true,
  imprimirTicketAlCobrar: imprimirAlCobrar,
  formato: FormatoImpresion(
    emision: EmisionTicket(modo: modo, esperaSegundos: espera.inSeconds),
    verifactu: const QrVerifactuConfig(modo: ModoQrVerifactu.verifactu),
  ),
);

/// Ticket recién cobrado: 2 cañas, 6,70 €, con la factura `pendiente` en la
/// cola de sincronización (como lo deja `SalaService` al cobrar).
Ticket ticketCobrado({
  String id = idTicket,
  int numeroLocal = 15,
  MetodoPago metodo = MetodoPago.efectivo,
  FacturaSincronizada? factura,
}) => Ticket(
  id: id,
  numeroLocal: numeroLocal,
  mesaId: mesa7.id,
  nombreMesa: mesa7.nombre,
  comandaId: 'c1',
  fechaHora: cobro,
  lineas: [
    LineaComanda(
      id: 'l1',
      referencia: 'CANA',
      descripcion: 'Caña',
      cantidad: 2,
      pvpUnitarioCents: 335,
      pvpUnitarioNeto: 3.35 / 1.1,
      ivaBp: 1000,
      codimpuesto: 'IVA10',
      creadaEn: cobro,
    ),
  ],
  totales: TotalesTicket(
    netoCents: 609,
    ivaCents: 61,
    totalCents: 670,
    desglose: const [
      DesgloseIva(
        codimpuesto: 'IVA10',
        ivaBp: 1000,
        baseCents: 609,
        cuotaCents: 61,
      ),
    ],
  ),
  metodoPago: metodo,
  entregadoCents: metodo == MetodoPago.efectivo ? 1000 : null,
  factura:
      factura ?? FacturaSincronizada(estado: EstadoSincronizacion.pendiente),
);

FacturaSincronizada facturaFs({int totalFsCents = 670}) => FacturaSincronizada(
  estado: EstadoSincronizacion.sincronizado,
  codigo: 'F2026S12',
  fecha: DateTime(2026, 10, 9, 14, 33),
  totalFsCents: totalFsCents,
);

final facturaRechazada = FacturaSincronizada(
  estado: EstadoSincronizacion.error,
  error: 'HTTP 422: cliente inexistente',
);

/// Diario, canal y servicio dentro de la zona de fake_async, con el reloj
/// del host atado al tiempo simulado.
final class Banco {
  Banco(
    this.async, {
    List<Ticket>? tickets,
    ImpresionSettings? ajustes,
    this.cabecera = cabeceraConNif,
    PrinterPort Function(FakePrinterPort impresora)? puerto,
  }) : ajustes = ajustes ?? ajustesFactura(),
       store = HostStateStore(
         InMemoryHostStateRepository(),
         HostSnapshot(
           mesas: const [mesa7],
           ticketsTurno: tickets ?? [ticketCobrado()],
         ),
       ) {
    final cola = puerto == null ? impresora : puerto(impresora);
    canal = CanalImpresion(
      alerts: alerts,
      runner: const InlineIsolateRunner(),
      settings: () => this.ajustes,
      printer: () => cola,
    );
    servicio = TicketsImpresion(
      store: store,
      canal: canal,
      alerts: alerts,
      settings: () => this.ajustes,
      cabecera: () => cabecera,
      now: () => inicio.add(async.elapsed),
    );
  }

  static final inicio = DateTime(2026, 10, 9, 14, 32, 5);

  final FakeAsync async;
  final alerts = AlertBus();
  final impresora = FakePrinterPort();
  final HostStateStore store;
  ImpresionSettings ajustes;
  EmpresaTicket cabecera;
  late final CanalImpresion canal;
  late final TicketsImpresion servicio;

  ImpresionTicket impresion([String id = idTicket]) =>
      store.snapshot.ticketPorId(id)!.impresion;

  List<String> get descripciones => [
    for (final trabajo in impresora.jobs) trabajo.description,
  ];

  /// Comandos `drawer` de cada trabajo encolado, en orden.
  List<int> get cajonesPorTrabajo => [
    for (final trabajo in impresora.jobs)
      decodeEscPos(trabajo.bytes).named('drawer').length,
  ];

  List<String> get titulos => [
    for (final alerta in alerts.recientes) alerta.titulo,
  ];

  /// Despacha el efecto del cobro como lo hace la sala (sin esperarlo) y
  /// devuelve si ya terminó. Un error del efecto hace fallar el test.
  bool Function() cobrar([String id = idTicket]) {
    var hecho = false;
    unawaited(
      servicio
          .alCobrar(store.snapshot.ticketPorId(id)!)
          .then((_) => hecho = true),
    );
    return () => hecho;
  }

  /// FacturaScripts contesta: el diario pasa la factura del ticket a
  /// [factura] (como `BillingService._actualizarTicket`).
  void responderFs(FacturaSincronizada factura, [String id = idTicket]) {
    unawaited(
      store.update((s) => s.conTicket(s.ticketPorId(id)!.conFactura(factura))),
    );
    async.flushMicrotasks();
  }
}

/// Cola que rechaza las facturas como si estuviera llena y encola lo demás
/// en la [FakePrinterPort].
final class _ColaSinSitioParaFacturas implements PrinterPort {
  _ColaSinSitioParaFacturas(this._interna);

  final FakePrinterPort _interna;

  @override
  String imprimir(
    PrinterEndpoint endpoint,
    Uint8List bytes, {
    required String description,
    PrintRetryPolicy reintento = PrintRetryPolicy.always,
  }) {
    if (description.startsWith('Factura')) {
      throw const PrinterException('Cola de impresión llena');
    }
    return _interna.imprimir(
      endpoint,
      bytes,
      description: description,
      reintento: reintento,
    );
  }

  @override
  Future<String?> terminado(String jobId) => _interna.terminado(jobId);
}

void main() {
  group('modo «Emitir factura al cobrar»', () {
    test('el cajón sale al instante, antes de esperar a la factura', () {
      fakeAsync((async) {
        final b = Banco(async);
        final terminado = b.cobrar();
        // Sin ceder el control: el trabajo propio del cajón ya está en cola.
        expect(b.descripciones, ['Cajón · ticket 15']);
        expect(b.impresora.jobs.single.bytes, bytesAbrirCajon());
        expect(b.impresora.jobs.single.endpoint, impresoraTickets);

        async.elapse(const Duration(seconds: 9));
        expect(terminado(), isFalse);
        expect(b.descripciones, ['Cajón · ticket 15']);
        async.elapse(const Duration(seconds: 1));
        expect(terminado(), isTrue);
      });
    });

    test('si la factura llega a tiempo: el ORIGINAL, facturaOriginalEn y un '
        'solo comando drawer entre todos los trabajos del cobro', () {
      fakeAsync((async) {
        final b = Banco(async);
        final terminado = b.cobrar();
        async.elapse(const Duration(seconds: 3));
        expect(terminado(), isFalse);

        b.responderFs(facturaFs());
        expect(terminado(), isTrue);
        expect(b.descripciones, [
          'Cajón · ticket 15',
          'Factura F2026S12 (original)',
        ]);
        expect(b.cajonesPorTrabajo, [1, 0]);
        expect(b.impresora.jobs.last.reintento, PrintRetryPolicy.connectOnly);
        final impresion = b.impresion();
        expect(
          impresion.facturaOriginalEn,
          Banco.inicio.add(const Duration(seconds: 3)),
        );
        expect(impresion.qr?.leyenda, 'VERI*FACTU');
        expect(impresion.provisionalEn, isNull);
        expect(b.alerts.recientes, isEmpty);
        expect(async.pendingTimers, isEmpty);
      });
    });

    test('con tarjeta no hay cajón: solo la factura', () {
      fakeAsync((async) {
        final b = Banco(
          async,
          tickets: [ticketCobrado(metodo: MetodoPago.tarjeta)],
        );
        final terminado = b.cobrar();
        expect(b.impresora.jobs, isEmpty);
        b.responderFs(facturaFs());
        expect(terminado(), isTrue);
        expect(b.descripciones, ['Factura F2026S12 (original)']);
        expect(b.cajonesPorTrabajo, [0]);
      });
    });

    test('si vence el plazo: el provisional sin segundo pulso y un aviso '
        'info', () {
      fakeAsync((async) {
        final b = Banco(async);
        final terminado = b.cobrar();
        async.elapse(plazo - const Duration(milliseconds: 1));
        expect(terminado(), isFalse);
        async.elapse(const Duration(milliseconds: 1));

        expect(terminado(), isTrue);
        expect(b.descripciones, [
          'Cajón · ticket 15',
          'Ticket 15 · provisional',
        ]);
        expect(b.cajonesPorTrabajo, [1, 0]);
        final aviso = b.alerts.recientes.single;
        expect(aviso.nivel, AlertaNivel.info);
        expect(
          aviso.titulo,
          'Factura no disponible a tiempo: se imprimió el documento '
          'provisional del ticket 15',
        );
        expect(aviso.origen, 'impresion');
        expect(b.impresion().provisionalEn, Banco.inicio.add(plazo));
        expect(b.impresion().originalImpreso, isFalse);

        // La factura que llega tarde no imprime nada más.
        b.responderFs(facturaFs());
        expect(b.impresora.jobs, hasLength(2));
        expect(async.pendingTimers, isEmpty);
      });
    });

    test('el plazo es el de los ajustes (3 s)', () {
      fakeAsync((async) {
        const espera = Duration(seconds: 3);
        final b = Banco(async, ajustes: ajustesFactura(espera: espera));
        final terminado = b.cobrar();
        async.elapse(espera - const Duration(milliseconds: 1));
        expect(terminado(), isFalse);
        async.elapse(const Duration(milliseconds: 1));

        expect(terminado(), isTrue);
        expect(b.descripciones, [
          'Cajón · ticket 15',
          'Ticket 15 · provisional',
        ]);
        expect(b.impresion().provisionalEn, Banco.inicio.add(espera));
        expect(async.pendingTimers, isEmpty);
      });
    });

    test('con la factura en error: el provisional en el acto', () {
      fakeAsync((async) {
        final b = Banco(async);
        final terminado = b.cobrar();
        async.elapse(const Duration(seconds: 1));
        b.responderFs(facturaRechazada);

        expect(terminado(), isTrue);
        expect(b.descripciones, [
          'Cajón · ticket 15',
          'Ticket 15 · provisional',
        ]);
        expect(b.cajonesPorTrabajo, [1, 0]);
        final aviso = b.alerts.recientes.single;
        expect(aviso.nivel, AlertaNivel.info);
        expect(
          aviso.titulo,
          'Factura no disponible: se imprimió el documento provisional del '
          'ticket 15',
        );
        expect(
          aviso.detalle,
          'FacturaScripts rechazó la factura del ticket nº 15: HTTP 422: '
          'cliente inexistente',
        );
        expect(async.pendingTimers, isEmpty);
      });
    });

    test('una factura que ya estaba en error al cobrar no se espera', () {
      fakeAsync((async) {
        final b = Banco(
          async,
          tickets: [
            ticketCobrado(
              factura: FacturaSincronizada(estado: EstadoSincronizacion.error),
            ),
          ],
        );
        final terminado = b.cobrar();
        async.flushMicrotasks();
        expect(terminado(), isTrue);
        expect(b.descripciones, [
          'Cajón · ticket 15',
          'Ticket 15 · provisional',
        ]);
        expect(
          b.alerts.recientes.single.detalle,
          'FacturaScripts rechazó la factura del ticket nº 15',
        );
      });
    });

    for (final caso in [
      (
        nombre: 'sin NIF',
        cabecera: const EmpresaTicket(nombre: 'BAR MANOLO, S.L.'),
        totalFs: 670,
        causa: 'Falta el NIF del emisor',
      ),
      (
        nombre: 'con el total de FS distinto',
        cabecera: cabeceraConNif,
        totalFs: 671,
        causa:
            'El total de la factura F2026S12 en FacturaScripts (6,71 €) no '
            'coincide con el del ticket (6,70 €)',
      ),
    ]) {
      test('${caso.nombre}: el provisional y un aviso que nombra la causa', () {
        fakeAsync((async) {
          final b = Banco(async, cabecera: caso.cabecera);
          final terminado = b.cobrar();
          async.elapse(const Duration(seconds: 2));
          b.responderFs(facturaFs(totalFsCents: caso.totalFs));

          expect(terminado(), isTrue);
          expect(b.descripciones, [
            'Cajón · ticket 15',
            'Ticket 15 · provisional',
          ]);
          expect(b.cajonesPorTrabajo, [1, 0]);
          final aviso = b.alerts.recientes.single;
          expect(aviso.nivel, AlertaNivel.info);
          expect(aviso.detalle, contains(caso.causa));
          expect(b.impresion().originalImpreso, isFalse);
          expect(b.impresion().provisionalEn, isNotNull);
        });
      });
    }

    test('si _imprimirFactura falla (cola llena): el provisional sin cajón y '
        'un aviso; la marca del ORIGINAL se revierte', () {
      fakeAsync((async) {
        final b = Banco(async, puerto: _ColaSinSitioParaFacturas.new);
        final terminado = b.cobrar();
        async.elapse(const Duration(seconds: 2));
        b.responderFs(facturaFs());

        expect(terminado(), isTrue);
        expect(b.descripciones, [
          'Cajón · ticket 15',
          'Ticket 15 · provisional',
        ]);
        expect(b.cajonesPorTrabajo, [1, 0]);
        final aviso = b.alerts.recientes.single;
        expect(aviso.nivel, AlertaNivel.aviso);
        expect(
          aviso.titulo,
          'No se pudo imprimir la factura del ticket 15: Cola de impresión '
          'llena. Se imprimió el documento provisional',
        );
        final impresion = b.impresion();
        expect(impresion.originalImpreso, isFalse);
        expect(impresion.qr, isNull);
        expect(impresion.provisionalEn, isNotNull);
        expect(b.servicio.emisionPendiente(idTicket), isFalse);
      });
    });

    test('con un NIF que no sirve para el QR: el provisional y un aviso con '
        'el motivo', () {
      fakeAsync((async) {
        final b = Banco(
          async,
          cabecera: const EmpresaTicket(nombre: 'Bar', cifnif: 'B1234567'),
        );
        final terminado = b.cobrar();
        b.responderFs(facturaFs());

        expect(terminado(), isTrue);
        expect(b.descripciones, [
          'Cajón · ticket 15',
          'Ticket 15 · provisional',
        ]);
        final aviso = b.alerts.recientes.single;
        expect(aviso.nivel, AlertaNivel.aviso);
        expect(aviso.titulo, contains('no sirve para el QR tributario'));
        expect(
          aviso.titulo,
          endsWith('. Se imprimió el documento provisional'),
        );
        expect(b.impresion().originalImpreso, isFalse);
      });
    });

    test('si tampoco sale el provisional, los avisos no lo prometen', () {
      fakeAsync((async) {
        for (final (id, numero, desenlace, ultimo) in [
          (
            't-15',
            15,
            null,
            'Factura no disponible a tiempo para el ticket 15',
          ),
          (
            't-16',
            16,
            facturaRechazada,
            'Factura no disponible para el ticket 16',
          ),
          (
            't-17',
            17,
            facturaFs(),
            'No se pudo imprimir la factura del ticket 17: Cola de impresión '
                'llena',
          ),
        ]) {
          final b = Banco(
            async,
            tickets: [ticketCobrado(id: id, numeroLocal: numero)],
          );
          b.impresora.errorAlEncolar = const PrinterException(
            'Cola de impresión llena',
          );
          final terminado = b.cobrar(id);
          if (desenlace == null) {
            async.elapse(plazo);
          } else {
            b.responderFs(desenlace, id);
          }
          expect(terminado(), isTrue, reason: ultimo);
          expect(b.impresora.jobs, isEmpty);
          expect(b.titulos, [
            'No se pudo encolar "Cajón · ticket $numero"',
            'No se pudo encolar "Ticket $numero · provisional"',
            ultimo,
          ]);
          expect(b.impresion(id), ImpresionTicket.vacia);
        }
      });
    });

    test('emisionPendiente es verdadero desde que empieza el cobro, antes de '
        'su primer await, hasta que termina', () {
      fakeAsync((async) {
        final b = Banco(async);
        final emitidos = <Set<String>>[];
        b.servicio.emisionesPendientes.listen(emitidos.add);
        async.flushMicrotasks();
        expect(emitidos, [<String>{}]);
        expect(b.servicio.emisionPendiente(idTicket), isFalse);

        final terminado = b.cobrar();
        // Sin ceder el control: ya está pendiente.
        expect(b.servicio.emisionPendiente(idTicket), isTrue);
        async.elapse(const Duration(seconds: 5));
        expect(b.servicio.emisionPendiente(idTicket), isTrue);

        // Quien se suscribe a mitad recibe primero el estado actual.
        final tardio = <Set<String>>[];
        b.servicio.emisionesPendientes.listen(tardio.add);
        async.flushMicrotasks();
        expect(tardio, [
          {idTicket},
        ]);

        b.responderFs(facturaFs());
        expect(terminado(), isTrue);
        expect(b.servicio.emisionPendiente(idTicket), isFalse);
        expect(emitidos, [
          <String>{},
          {idTicket},
          <String>{},
        ]);
        expect(tardio, [
          {idTicket},
          <String>{},
        ]);
      });
    });

    test('cancelarEsperas libera la espera, y las que empiezan después no '
        'esperan', () {
      fakeAsync((async) {
        final b = Banco(
          async,
          tickets: [
            ticketCobrado(),
            ticketCobrado(id: 't-16', numeroLocal: 16),
          ],
        );
        final primero = b.cobrar();
        async.elapse(const Duration(seconds: 1));
        b.servicio.cancelarEsperas();
        async.flushMicrotasks();

        expect(primero(), isTrue);
        expect(b.descripciones, [
          'Cajón · ticket 15',
          'Ticket 15 · provisional',
        ]);
        expect(b.servicio.emisionPendiente(idTicket), isFalse);
        expect(async.pendingTimers, isEmpty);

        final segundo = b.cobrar('t-16');
        async.flushMicrotasks();
        expect(segundo(), isTrue);
        expect(b.descripciones.skip(2), [
          'Cajón · ticket 16',
          'Ticket 16 · provisional',
        ]);
        expect(async.elapsed, const Duration(seconds: 1));
      });
    });

    test('tras cancelarEsperas, una factura que ya está lista se imprime '
        'como ORIGINAL', () {
      fakeAsync((async) {
        final b = Banco(async, tickets: [ticketCobrado(factura: facturaFs())]);
        b.servicio.cancelarEsperas();
        final terminado = b.cobrar();
        async.flushMicrotasks();

        expect(terminado(), isTrue);
        expect(b.descripciones, [
          'Cajón · ticket 15',
          'Factura F2026S12 (original)',
        ]);
        expect(b.cajonesPorTrabajo, [1, 0]);
        expect(b.impresion().originalImpreso, isTrue);
        expect(b.alerts.recientes, isEmpty);
        expect(async.elapsed, Duration.zero);
      });
    });

    test('si el ticket sale del turno durante la espera (Cierre Z), el '
        'provisional sin esperar al plazo', () {
      fakeAsync((async) {
        final b = Banco(async);
        final terminado = b.cobrar();
        async.elapse(const Duration(seconds: 1));
        unawaited(b.store.update((s) => s.copyWith(ticketsTurno: const [])));
        async.flushMicrotasks();

        expect(terminado(), isTrue);
        expect(b.descripciones, [
          'Cajón · ticket 15',
          'Ticket 15 · provisional',
        ]);
        expect(async.pendingTimers, isEmpty);
      });
    });

    test('si el diario se cierra durante la espera, termina sin esperar al '
        'plazo', () {
      fakeAsync((async) {
        final b = Banco(async);
        final terminado = b.cobrar();
        async.elapse(const Duration(seconds: 1));
        unawaited(b.store.dispose());
        async.flushMicrotasks();

        expect(terminado(), isTrue);
        expect(b.descripciones, [
          'Cajón · ticket 15',
          'Ticket 15 · provisional',
        ]);
        // El provisional ya estaba en la cola: el diario cerrado no lo anota.
        expect(b.impresion().provisionalEn, isNull);
        expect(async.pendingTimers, isEmpty);
      });
    });

    test('sin «Imprimir el ticket al cobrar»: solo el cajón, sin espera ni '
        'emisión pendiente', () {
      fakeAsync((async) {
        final b = Banco(
          async,
          ajustes: ajustesFactura(imprimirAlCobrar: false),
        );
        final terminado = b.cobrar();
        expect(b.servicio.emisionPendiente(idTicket), isFalse);
        async.flushMicrotasks();
        expect(terminado(), isTrue);
        expect(b.descripciones, ['Cajón · ticket 15']);
        expect(async.pendingTimers, isEmpty);
      });
    });

    test('sin impresora de tickets: nada que imprimir ni esperar', () {
      fakeAsync((async) {
        final b = Banco(async, ajustes: ajustesFactura(conImpresora: false));
        final terminado = b.cobrar();
        expect(b.servicio.emisionPendiente(idTicket), isFalse);
        async.flushMicrotasks();
        expect(terminado(), isTrue);
        expect(b.impresora.jobs, isEmpty);
        expect(async.pendingTimers, isEmpty);
      });
    });
  });

  test('en el modo por defecto nunca se espera', () {
    fakeAsync((async) {
      final b = Banco(
        async,
        ajustes: ajustesFactura(modo: ModoEmision.alInstante),
      );
      final terminado = b.cobrar();
      expect(b.servicio.emisionPendiente(idTicket), isFalse);
      async.flushMicrotasks();

      expect(terminado(), isTrue);
      expect(async.elapsed, Duration.zero);
      expect(async.pendingTimers, isEmpty);
      expect(b.descripciones, ['Ticket 15 · provisional']);
      expect(b.cajonesPorTrabajo, [1]);
      expect(b.impresion().originalImpreso, isFalse);
      expect(b.alerts.recientes, isEmpty);
    });
  });
}
