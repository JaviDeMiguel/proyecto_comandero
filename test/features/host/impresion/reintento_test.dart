/// Reintento de trabajos de impresión fallidos (P2, §5.17 del diseño de
/// impresión): el aviso «Fallo de impresión» lleva el id del trabajo, el
/// reintento vuelve a seguirlo y, en las facturas, nunca repite un documento
/// que pudo salir: imprime el siguiente DUPLICADO (art. 14 del RD 1619/2012).
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:proyecto_comandero/core/errors/app_exception.dart';
import 'package:proyecto_comandero/core/isolates/isolate_runner.dart';
import 'package:proyecto_comandero/core/network/printing/print_queue.dart';
import 'package:proyecto_comandero/core/network/printing/raw_printer_transport.dart';
import 'package:proyecto_comandero/features/host/application/alert_bus.dart';
import 'package:proyecto_comandero/features/host/application/host_state_store.dart';
import 'package:proyecto_comandero/features/host/application/impresion/canal_impresion.dart';
import 'package:proyecto_comandero/features/host/application/impresion/tickets_impresion.dart';
import 'package:proyecto_comandero/features/host/application/ports.dart';
import 'package:proyecto_comandero/features/host/application/printing_service.dart';
import 'package:proyecto_comandero/features/host/data/in_memory_host_state_repository.dart';
import 'package:proyecto_comandero/features/host/data/print_queue_adapter.dart';
import 'package:proyecto_comandero/features/host/domain/host_settings.dart';
import 'package:proyecto_comandero/features/host/domain/host_snapshot.dart';
import 'package:proyecto_comandero/features/host/domain/operational_alert.dart';
import 'package:proyecto_comandero/features/sala/domain/ticket.dart';
import 'package:test/test.dart';

import '../../../core/network/printing/fake_transport.dart';
import '../fakes/fake_ports.dart';
import 'tickets_impresion_test.dart'
    show
        ajustesTickets,
        cabeceraConNif,
        facturaFs,
        idTicket,
        impresoraTickets,
        mesa7,
        ticketMaqueta;

const Duration _timeout = Duration(seconds: 5);

const PrinterException _fallaAlEscribir = PrinterException(
  'La impresora dejó de aceptar datos (12 de 900 bytes enviados)',
);
const PrinterConnectException _fallaAlConectar = PrinterConnectException(
  'No se pudo conectar con la impresora',
);

/// La fachada sobre un diario con el ticket facturado de la maqueta
/// (F2026S12, 67,00 €) y la cola [puerto].
final class _Banco {
  _Banco(this.puerto, {ImpresionSettings? ajustes})
    : store = HostStateStore(
        InMemoryHostStateRepository(),
        HostSnapshot(
          mesas: const [mesa7],
          ticketsTurno: [ticketMaqueta(factura: facturaFs())],
        ),
      ) {
    printing = PrintingService(
      alerts: alerts,
      runner: const InlineIsolateRunner(),
      settings: ajustes ?? ajustesTickets(),
      nombreTpv: 'Barra',
      store: store,
      printer: puerto,
      empresa: cabeceraConNif,
      now: FakeClock(DateTime(2026, 10, 9, 14, 40)).call,
    );
  }

  final PrinterPort puerto;
  final AlertBus alerts = AlertBus();
  final HostStateStore store;
  late final PrintingService printing;

  ImpresionTicket get impresion =>
      store.snapshot.ticketPorId(idTicket)!.impresion;

  List<OperationalAlert> get fallos => [
    for (final a in alerts.recientes)
      if (a.titulo.startsWith('Fallo de impresión')) a,
  ];
}

/// Cola que solo imprime: no admite reintentos.
final class _ColaSinReintentos implements PrinterPort {
  @override
  String imprimir(
    PrinterEndpoint endpoint,
    Uint8List bytes, {
    required String description,
    PrintRetryPolicy reintento = PrintRetryPolicy.always,
  }) => 'job-1';

  @override
  Future<String?> terminado(String jobId) async => 'sin papel';
}

/// Cola cuyos trabajos no terminan hasta que el test lo decide ([fin]).
final class _ColaDiferida implements RetryablePrinterPort {
  final List<String> ids = [];
  final Map<String, Completer<String?>> fin = {};
  final List<String> reintentados = [];

  /// Trabajos que fallaron sin enviar nada.
  final Set<String> sinEnviar = {};

  @override
  String imprimir(
    PrinterEndpoint endpoint,
    Uint8List bytes, {
    required String description,
    PrintRetryPolicy reintento = PrintRetryPolicy.always,
  }) {
    final id = 'job-${ids.length}';
    ids.add(id);
    fin[id] = Completer<String?>();
    return id;
  }

  @override
  Future<String?> terminado(String jobId) => fin[jobId]!.future;

  @override
  String reintentar(String jobId) {
    reintentados.add(jobId);
    fin[jobId] = Completer<String?>();
    return jobId;
  }

  @override
  bool nadaEnviado(String jobId) => sinEnviar.contains(jobId);
}

/// Canal y servicio de tickets sin la fachada, para mirar su registro de
/// trabajos de factura.
final class _Directo {
  _Directo(PrinterPort puerto)
    : store = HostStateStore(
        InMemoryHostStateRepository(),
        HostSnapshot(
          mesas: const [mesa7],
          ticketsTurno: [ticketMaqueta(factura: facturaFs())],
        ),
      ) {
    canal = CanalImpresion(
      alerts: alerts,
      runner: const InlineIsolateRunner(),
      settings: ajustesTickets,
      printer: () => puerto,
    );
    tickets = TicketsImpresion(
      store: store,
      canal: canal,
      alerts: alerts,
      settings: ajustesTickets,
      cabecera: () => cabeceraConNif,
      now: FakeClock(DateTime(2026, 10, 9, 14, 40)).call,
    );
  }

  final AlertBus alerts = AlertBus();
  final HostStateStore store;
  late final CanalImpresion canal;
  late final TicketsImpresion tickets;
}

bool _esDuplicado(Uint8List bytes) =>
    String.fromCharCodes(bytes).contains('DUPLICADO');

void main() {
  group('aviso de fallo y reintento de un trabajo cualquiera', () {
    late FakePrinterPort cola;
    late _Banco banco;

    setUp(() {
      cola = FakePrinterPort()..error = 'sin papel';
      banco = _Banco(cola);
    });

    test('el aviso de fallo lleva trabajoImpresion', () async {
      await banco.printing.reimprimirProvisional(idTicket);
      await banco.printing.idle();

      final aviso = banco.fallos.single;
      expect(aviso.nivel, AlertaNivel.error);
      expect(aviso.trabajoImpresion, cola.jobs.single.id);
      expect(aviso.detalle, '$impresoraTickets: sin papel');
    });

    test('tras reintentar se vuelve a seguir el trabajo, y un nuevo fallo da '
        'otro aviso', () async {
      await banco.printing.reimprimirProvisional(idTicket);
      await banco.printing.idle();
      final id = cola.jobs.single.id;

      await banco.printing.reintentar(id);
      await banco.printing.idle();

      expect(cola.reintentados, [id]);
      expect(cola.jobs, hasLength(1), reason: 'los mismos bytes');
      expect(banco.fallos, hasLength(2));
      expect(banco.fallos.last.trabajoImpresion, id);

      // Esta vez sale: ni aviso nuevo ni otro reintento posible.
      cola.error = null;
      await banco.printing.reintentar(id);
      await banco.printing.idle();
      expect(cola.reintentados, [id, id]);
      expect(banco.fallos, hasLength(2));
      await expectLater(
        banco.printing.reintentar(id),
        throwsA(isA<PrinterException>()),
      );
    });

    test('un trabajo que no falló o desconocido no se reintenta', () async {
      cola.error = null;
      await banco.printing.reimprimirProvisional(idTicket);
      await banco.printing.idle();

      await expectLater(
        banco.printing.reintentar(cola.jobs.single.id),
        throwsA(isA<PrinterException>()),
      );
      await expectLater(
        banco.printing.reintentar('no-existe'),
        throwsA(isA<PrinterException>()),
      );
      expect(cola.reintentados, isEmpty);
    });

    test('si la cola rechaza el reintento, el trabajo sigue fallido', () async {
      await banco.printing.reimprimirProvisional(idTicket);
      await banco.printing.idle();
      final id = cola.jobs.single.id;
      cola.errorAlReintentar = const PrinterException('cola llena');

      await expectLater(
        banco.printing.reintentar(id),
        throwsA(isA<PrinterException>()),
      );

      cola
        ..errorAlReintentar = null
        ..error = null;
      await banco.printing.reintentar(id);
      expect(cola.reintentados, [id]);
    });

    test('con una cola sin reintentos el aviso no lleva trabajo', () async {
      final sinReintentos = _Banco(_ColaSinReintentos());

      await sinReintentos.printing.reimprimirProvisional(idTicket);
      await sinReintentos.printing.idle();

      expect(sinReintentos.fallos.single.trabajoImpresion, isNull);
      await expectLater(
        sinReintentos.printing.reintentar('job-1'),
        throwsA(isA<PrinterException>()),
      );
    });
  });

  group('reintento de una factura (FakePrinterPort)', () {
    late FakePrinterPort cola;
    late _Banco banco;

    setUp(() async {
      cola = FakePrinterPort()..error = 'la impresora cortó la conexión';
      banco = _Banco(cola);
      await banco.printing.imprimirFactura(idTicket);
      await banco.printing.idle();
    });

    test('si llegó a enviar bytes imprime el siguiente DUPLICADO y no '
        'reenvía el ORIGINAL', () async {
      final original = cola.jobs.single;
      expect(original.description, 'Factura F2026S12 (original)');
      expect(banco.fallos.single.trabajoImpresion, original.id);
      cola.error = null;

      await banco.printing.reintentar(original.id);
      await banco.printing.idle();

      expect(cola.reintentados, isEmpty);
      expect(cola.jobs, hasLength(2));
      final duplicado = cola.jobs.last;
      expect(duplicado.description, 'Factura F2026S12 (duplicado 1)');
      expect(duplicado.reintento, PrintRetryPolicy.connectOnly);
      expect(_esDuplicado(duplicado.bytes), isTrue);
      expect(banco.impresion.originalImpreso, isTrue);
      expect(banco.impresion.duplicados, 1);
    });

    test('el mismo aviso no imprime un segundo DUPLICADO', () async {
      final original = cola.jobs.single;
      cola.error = null;
      await banco.printing.reintentar(original.id);

      await expectLater(
        banco.printing.reintentar(original.id),
        throwsA(isA<PrinterException>()),
      );
      expect(cola.jobs, hasLength(2));
      expect(cola.reintentados, isEmpty);
      expect(banco.impresion.duplicados, 1);
    });

    test('dos pulsaciones seguidas dan un solo DUPLICADO', () async {
      final original = cola.jobs.single;
      cola.error = null;

      final primera = banco.printing.reintentar(original.id);
      final segunda = expectLater(
        banco.printing.reintentar(original.id),
        throwsA(
          isA<PrinterException>().having(
            (e) => e.message,
            'message',
            contains('Ya se está reintentando'),
          ),
        ),
      );

      await primera;
      await segunda;
      expect(cola.jobs, hasLength(2));
      expect(banco.impresion.duplicados, 1);
    });

    test('si no llegó a conectar reencola los mismos bytes del '
        'ORIGINAL', () async {
      final original = cola.jobs.single;
      cola
        ..sinEnviar.add(original.id)
        ..error = null;

      await banco.printing.reintentar(original.id);
      await banco.printing.idle();

      expect(cola.reintentados, [original.id]);
      expect(cola.jobs, hasLength(1), reason: 'ningún DUPLICADO');
      expect(banco.impresion.duplicados, 0);
    });

    test(
      'un DUPLICADO que también falla se reintenta con el siguiente',
      () async {
        final original = cola.jobs.single;
        await banco.printing.reintentar(original.id);
        await banco.printing.idle();
        final duplicado1 = cola.jobs.last;
        expect(banco.fallos.last.trabajoImpresion, duplicado1.id);

        cola.error = null;
        await banco.printing.reintentar(duplicado1.id);
        await banco.printing.idle();

        expect(cola.jobs.map((j) => j.description), [
          'Factura F2026S12 (original)',
          'Factura F2026S12 (duplicado 1)',
          'Factura F2026S12 (duplicado 2)',
        ]);
        expect(banco.impresion.duplicados, 2);
      },
    );

    test('si el DUPLICADO no se puede imprimir, el trabajo sigue fallido y '
        'se puede reintentar después', () async {
      final original = cola.jobs.single;
      cola
        ..error = null
        ..errorAlEncolar = const PrinterException('cola llena');

      await expectLater(
        banco.printing.reintentar(original.id),
        throwsA(isA<PrinterException>()),
      );
      expect(banco.impresion.duplicados, 0, reason: 'marca deshecha');

      cola.errorAlEncolar = null;
      await banco.printing.reintentar(original.id);

      expect(cola.jobs.last.description, 'Factura F2026S12 (duplicado 1)');
      expect(banco.impresion.duplicados, 1);
    });
  });

  group('reintento de una factura sobre la cola real', () {
    late FakeTransport transporte;
    late PrintQueueAdapter cola;
    late _Banco banco;

    setUp(() {
      transporte = FakeTransport();
      cola = PrintQueueAdapter.forTransport(
        transporte,
        options: const PrintQueueOptions(retryDelay: Duration(milliseconds: 5)),
      );
      banco = _Banco(cola);
    });

    tearDown(() => cola.dispose());

    Future<String> facturaFallida() async {
      await banco.printing.imprimirFactura(idTicket);
      await banco.printing.idle();
      return banco.fallos.single.trabajoImpresion!;
    }

    test('un ORIGINAL que falló al escribir no se repite: sale el '
        'DUPLICADO 1', () async {
      transporte.failNext(_fallaAlEscribir);
      final id = await facturaFallida();
      expect(cola.queue.find(id)!.nothingSent, isFalse);

      await banco.printing.reintentar(id).timeout(_timeout);
      await banco.printing.idle().timeout(_timeout);

      expect(transporte.attempts, hasLength(2));
      expect(_esDuplicado(transporte.sent.single.bytes), isTrue);
      expect(cola.queue.find(id)!.status, PrintJobStatus.failed);
      expect(banco.impresion.duplicados, 1);
      expect(banco.fallos, hasLength(1));
    });

    test('un ORIGINAL que no llegó a conectar sale con sus mismos bytes y el '
        'mismo id', () async {
      transporte.failNext(_fallaAlConectar, times: 3);
      final id = await facturaFallida();
      expect(cola.queue.find(id)!.nothingSent, isTrue);

      await banco.printing.reintentar(id).timeout(_timeout);
      await banco.printing.idle().timeout(_timeout);

      final job = cola.queue.find(id)!;
      expect(job.status, PrintJobStatus.done);
      expect(job.attempts, 4);
      expect(transporte.sent, hasLength(1));
      expect(_esDuplicado(transporte.sent.single.bytes), isFalse);
      expect(banco.impresion.duplicados, 0);
    });

    test('una comanda fallida se reencola tal cual y un nuevo fallo da otro '
        'aviso', () async {
      transporte.failNext(_fallaAlEscribir, times: 3);
      await banco.printing.reimprimirProvisional(idTicket);
      await banco.printing.idle().timeout(_timeout);
      final id = banco.fallos.single.trabajoImpresion!;

      transporte.failNext(_fallaAlEscribir, times: 3);
      await banco.printing.reintentar(id);
      await banco.printing.idle().timeout(_timeout);

      expect(banco.fallos, hasLength(2));
      expect(banco.fallos.last.trabajoImpresion, id);
      expect(cola.queue.find(id)!.attempts, 6);

      await banco.printing.reintentar(id);
      await banco.printing.idle().timeout(_timeout);
      expect(cola.queue.find(id)!.status, PrintJobStatus.done);
      expect(transporte.sent, hasLength(1));
    });
  });

  group('CanalImpresion', () {
    test('recuerda como mucho maxFallidos trabajos fallidos', () async {
      final cola = FakePrinterPort()..error = 'sin papel';
      final canal = CanalImpresion(
        alerts: AlertBus(),
        runner: const InlineIsolateRunner(),
        settings: ajustesTickets,
        printer: () => cola,
      );
      for (var i = 0; i <= CanalImpresion.maxFallidos; i++) {
        await canal.enviarCrudo(impresoraTickets, 'Cajón $i', Uint8List(1));
      }
      await canal.idle();

      expect(canal.fallido(cola.jobs.first.id), isFalse);
      expect(canal.fallido(cola.jobs[1].id), isTrue);
      expect(canal.fallido(cola.jobs.last.id), isTrue);
      expect(
        () => canal.reintentar(cola.jobs.first.id),
        throwsA(isA<PrinterException>()),
      );
      expect(
        () => canal.nadaEnviado(cola.jobs.first.id),
        throwsA(isA<PrinterException>()),
      );

      canal.descartar(cola.jobs.last.id);
      expect(canal.fallido(cola.jobs.last.id), isFalse);
    });
  });

  group('las facturas nunca se reenvían si pudieron salir', () {
    test('una factura aún en la cola no se olvida aunque haya más de 100 y, '
        'si falla después, sale el DUPLICADO (revisión de WP-16)', () async {
      final cola = _ColaDiferida();
      final banco = _Banco(cola);
      for (var i = 0; i <= 100; i++) {
        await banco.printing.imprimirFactura(idTicket);
      }

      cola.fin['job-0']!.complete('la impresora cortó la conexión');
      await Future<void>.delayed(Duration.zero);
      final aviso = banco.fallos.single;
      expect(aviso.trabajoImpresion, 'job-0');
      expect(banco.printing.puedeReintentar('job-0'), isTrue);
      await banco.printing.reintentar('job-0');

      expect(cola.reintentados, isEmpty, reason: 'ORIGINAL no reenviado');
      expect(cola.ids, hasLength(102));
      expect(banco.impresion.duplicados, 101);
      expect(banco.printing.puedeReintentar('job-0'), isFalse);
    });

    test('se olvidan las facturas ya impresas de más de 100', () async {
      final cola = FakePrinterPort();
      final directo = _Directo(cola);
      for (var i = 0; i <= 100; i++) {
        await directo.tickets.imprimirFactura(idTicket);
      }
      await directo.canal.idle();
      // La siguiente ya encuentra terminadas a las anteriores.
      await directo.tickets.imprimirFactura(idTicket);

      expect(directo.tickets.esTrabajoDeFactura(cola.jobs.first.id), isFalse);
      expect(directo.tickets.esTrabajoDeFactura(cola.jobs[1].id), isFalse);
      expect(directo.tickets.esTrabajoDeFactura(cola.jobs[2].id), isTrue);
      expect(directo.tickets.esTrabajoDeFactura(cola.jobs.last.id), isTrue);
    });

    test('el canal no reenvía una factura que pudo enviar bytes, aunque nadie '
        'la recuerde como factura', () async {
      final cola = _ColaDiferida();
      final directo = _Directo(cola);
      final id = await directo.canal.enviarCrudo(
        impresoraTickets,
        'Cajón',
        Uint8List(1),
      );
      final factura = await directo.canal.enviar(
        impresoraTickets,
        'Factura F2026S12 (original)',
        (_) async => Uint8List(1),
        reintento: PrintRetryPolicy.connectOnly,
      );
      expect(directo.canal.pendiente(factura!), isTrue);
      expect(directo.canal.fallido(factura), isFalse);
      cola.fin[factura]!.complete('cortó la conexión');
      cola.fin[id!]!.complete('sin papel');
      await directo.canal.idle();

      expect(directo.canal.pendiente(factura), isTrue);
      expect(directo.canal.puedeReintentar(factura), isFalse);
      expect(
        () => directo.canal.reintentar(factura),
        throwsA(
          isA<PrinterException>().having(
            (e) => e.message,
            'message',
            contains('DUPLICADO'),
          ),
        ),
      );
      expect(cola.reintentados, isEmpty);
      expect(directo.canal.fallido(factura), isTrue, reason: 'sigue fallida');

      // Un trabajo cualquiera sí se reencola tal cual.
      expect(directo.canal.puedeReintentar(id), isTrue);
      directo.canal.reintentar(id);
      expect(cola.reintentados, [id]);
      expect(directo.canal.puedeReintentar(id), isFalse);
      expect(directo.canal.pendiente(id), isTrue, reason: 'en la cola');
      cola.fin[id]!.complete(null);
      await directo.canal.idle();
      expect(directo.canal.pendiente(id), isFalse);

      // Una factura que no llegó a conectar sí, con sus mismos bytes.
      cola.sinEnviar.add(factura);
      expect(directo.canal.puedeReintentar(factura), isTrue);
      directo.canal.reintentar(factura);
      expect(cola.reintentados, [id, factura]);
      cola.fin[factura]!.complete(null);
      await directo.canal.idle();
    });

    test(
      'puedeReintentar es falso si la cola ya no conoce la factura',
      () async {
        final cola = FakePrinterPort()..error = 'cortó la conexión';
        final directo = _Directo(cola);
        await directo.canal.enviar(
          impresoraTickets,
          'Factura F2026S12 (original)',
          (_) async => Uint8List(1),
          reintento: PrintRetryPolicy.connectOnly,
        );
        await directo.canal.idle();
        final id = cola.jobs.single.id;
        cola.sinEnviar.add(id);
        expect(directo.canal.puedeReintentar(id), isTrue);

        cola.jobs.clear();

        expect(directo.canal.puedeReintentar(id), isFalse);
      },
    );
  });

  group('puedeReintentar y trabajos cancelados', () {
    test(
      'un trabajo cancelado se avisa pero no se ofrece reintentarlo',
      () async {
        final cola = FakePrinterPort()..error = trabajoCancelado;
        final banco = _Banco(cola);

        await banco.printing.reimprimirProvisional(idTicket);
        await banco.printing.idle();

        final aviso = banco.fallos.single;
        expect(aviso.detalle, '$impresoraTickets: cancelado');
        expect(aviso.trabajoImpresion, isNull);
        final id = cola.jobs.single.id;
        expect(banco.printing.puedeReintentar(id), isFalse);
        await expectLater(
          banco.printing.reintentar(id),
          throwsA(isA<PrinterException>()),
        );
        expect(cola.reintentados, isEmpty);
      },
    );

    test('un trabajo cancelado en la cola real tampoco', () async {
      final transporte = FakeTransport()..holdSends = true;
      final cola = PrintQueueAdapter.forTransport(transporte);
      final banco = _Banco(cola);
      await banco.printing.abrirCajon();
      await banco.printing.reimprimirProvisional(idTicket);
      await transporte.whenHeld(1);

      final enCola = cola.queue.jobs.last.id;
      expect(cola.queue.cancel(enCola), isTrue);
      transporte.releaseAll();
      await banco.printing.idle().timeout(_timeout);

      expect(banco.fallos.single.trabajoImpresion, isNull);
      expect(banco.printing.puedeReintentar(enCola), isFalse);
      await cola.dispose();
    });

    test('la fachada lo sigue en comandas y facturas', () async {
      final cola = FakePrinterPort()..error = 'sin papel';
      final banco = _Banco(cola);
      await banco.printing.reimprimirProvisional(idTicket);
      await banco.printing.imprimirFactura(idTicket);
      await banco.printing.idle();
      final copia = cola.jobs[0].id;
      final original = cola.jobs[1].id;

      expect(banco.printing.puedeReintentar(copia), isTrue);
      expect(banco.printing.puedeReintentar(original), isTrue);
      expect(banco.printing.puedeReintentar('no-existe'), isFalse);

      cola.error = null;
      final enCurso = banco.printing.reintentar(original);
      expect(banco.printing.puedeReintentar(original), isFalse);
      await enCurso;
      await banco.printing.reintentar(copia);
      await banco.printing.idle();

      expect(banco.printing.puedeReintentar(original), isFalse);
      expect(banco.printing.puedeReintentar(copia), isFalse);
      expect(banco.printing.puedeReintentar(cola.jobs.last.id), isFalse);
    });
  });

  group('OperationalAlert y AlertBus', () {
    test('trabajoImpresion forma parte de la igualdad', () {
      final cuando = DateTime(2026, 10, 9);
      OperationalAlert aviso(String? trabajo) => OperationalAlert(
        nivel: AlertaNivel.error,
        titulo: 'Fallo de impresión: Comanda',
        cuando: cuando,
        trabajoImpresion: trabajo,
      );

      expect(aviso('a'), aviso('a'));
      expect(aviso('a') == aviso('b'), isFalse);
      expect(aviso(null).trabajoImpresion, isNull);
    });

    test('toString muestra el nivel, el título y el detalle', () {
      final cuando = DateTime(2026, 10, 9);
      final conDetalle = OperationalAlert(
        nivel: AlertaNivel.error,
        titulo: 'Fallo de impresión: Comanda',
        detalle: 'sin papel',
        cuando: cuando,
        trabajoImpresion: 'job-1',
      );
      final sinDetalle = OperationalAlert(
        nivel: AlertaNivel.info,
        titulo: 'Catálogo actualizado',
        cuando: cuando,
      );

      expect(
        conDetalle.toString(),
        'OperationalAlert(error, Fallo de impresión: Comanda: sin papel)',
      );
      expect(
        sinDetalle.toString(),
        'OperationalAlert(info, Catálogo actualizado)',
      );
    });

    test('error y emit lo llevan al aviso; info y aviso no', () {
      final bus = AlertBus()
        ..error('Fallo', trabajoImpresion: 'job-7')
        ..emit(AlertaNivel.aviso, 'Otro', trabajoImpresion: 'job-8')
        ..info('Info')
        ..aviso('Aviso');

      expect(bus.recientes.map((a) => a.trabajoImpresion), [
        'job-7',
        'job-8',
        null,
        null,
      ]);
    });
  });
}
