/// Cobro mixto de punta a punta en el host contra el sandbox de
/// FacturaScripts: `SalaService.cobrarMixto` → trabajo `factura` en la cola →
/// `BillingService` (modo de cada parte según `formapagos.pagado`) →
/// `FsInvoiceService`/`FsCobroMixto` reales.
///
/// Se ejecuta solo con `TPV_FS_BASE_URL` y `TPV_FS_TOKEN` (ver
/// `facturascripts_docs/sandbox.dart`) y borra todo lo que crea.
library;

import 'dart:io';

import 'package:proyecto_comandero/core/facturascripts/fs_api.dart';
import 'package:proyecto_comandero/core/facturascripts/fs_http_api.dart';
import 'package:proyecto_comandero/core/facturascripts/fs_values.dart';
import 'package:proyecto_comandero/core/isolates/isolate_runner.dart';
import 'package:proyecto_comandero/core/money/money.dart';
import 'package:proyecto_comandero/features/host/application/billing_service.dart';
import 'package:proyecto_comandero/features/host/application/printing_service.dart';
import 'package:proyecto_comandero/features/host/application/sync_outbox.dart';
import 'package:proyecto_comandero/features/host/data/fs_port_adapters.dart';
import 'package:proyecto_comandero/features/host/domain/host_settings.dart';
import 'package:proyecto_comandero/features/host/domain/sync_job.dart';
import 'package:proyecto_comandero/features/sala/domain/ticket.dart';
import 'package:test/test.dart';

import '../../features/host/fakes/fake_ports.dart' show FakeClock;
import '../../features/host/support/host_test_support.dart';
import '../facturascripts_docs/sandbox.dart';

void main() {
  final env = SandboxEnv.load();
  if (env == null) {
    test('sandbox no configurado', () {}, skip: SandboxEnv.skipReason);
    return;
  }

  late FsHttpApi api;
  final suffix = runSuffix();
  final corto = suffix.substring(suffix.length - 5);
  // Efectivo que nace pagado (caja 570) y tarjeta que no (banco 572).
  final efectivo = 'H1E$corto';
  final tarjeta = 'H0T$corto';
  final facturas = <int>[];
  // Compartido por todos los tests: los ids (y la clave de factura) no se
  // repiten entre hosts montados en la misma ejecución.
  var ids = 0;

  void nota(String text) => stdout.writeln('[sandbox] $text');

  setUpAll(() async {
    api = env.connect();
    for (final (codpago, pagado, cuenta) in [
      (efectivo, 1, '9001'),
      (tarjeta, 0, '9002'),
    ]) {
      await api.create('formapagos', {
        'codpago': codpago,
        'descripcion': 'Test host cobro mixto $codpago',
        'pagado': pagado,
        'codcuentabanco': cuenta,
        'plazovencimiento': 0,
        'tipovencimiento': 'days',
        'activa': 1,
      });
    }
    nota('formas de pago creadas: $efectivo $tarjeta');
  });

  tearDownAll(() async {
    final editables = await api.list(
      'estadodocumentos',
      filters: {'tipodoc': 'FacturaCliente', 'editable': 1},
      limit: 1,
    );
    for (final id in facturas) {
      if (editables.items.isNotEmpty) {
        await api.update('facturaclientes', id, {
          'idestado': editables.items.first.fsRequireInt('idestado'),
        });
      }
      final recibos = await api.listAll(
        'reciboclientes',
        filters: {'idfactura': id},
        sortBy: 'idrecibo',
      );
      for (final r in recibos) {
        await api.delete('reciboclientes', r.fsRequireInt('idrecibo'));
      }
      nota('factura $id borrada: ${await api.delete('facturaclientes', id)}');
    }
    for (final codpago in [efectivo, tarjeta]) {
      nota(
        'forma $codpago borrada: ${await api.delete('formapagos', codpago)}',
      );
    }
    for (final id in facturas) {
      expect(await api.get('facturaclientes', id), isNull);
      final restos = await api.list(
        'reciboclientes',
        filters: {'idfactura': id},
        limit: 1,
      );
      expect(restos.items, isEmpty, reason: 'recibos de la factura $id');
    }
    for (final codpago in [efectivo, tarjeta]) {
      expect(await api.get('formapagos', codpago), isNull);
    }
    await api.close();
  });

  /// Monta sala + cola + facturación reales sobre [fsApi]. Devuelve la sala
  /// y la cola; el desmontaje queda registrado con `addTearDown`.
  Future<(SalaFixture, SyncOutbox)> montarHost(FsApi fsApi) async {
    final f = await SalaFixture.create(
      clock: FakeClock(DateTime.now()),
      newId: () => 'H$suffix-${++ids}',
    );
    final outbox = SyncOutbox(store: f.store, alerts: f.alerts);
    final printing = PrintingService(
      alerts: f.alerts,
      runner: const InlineIsolateRunner(),
      settings: const ImpresionSettings(imprimirTicketAlCobrar: false),
      nombreTpv: 'Sandbox',
      store: f.store,
    );
    final ports = FsPorts(fsApi);
    final billing = BillingService(
      store: f.store,
      alerts: f.alerts,
      outbox: outbox,
      printing: printing,
      fiscal: FiscalSettings(
        codcliente: 'TPVVARIOS',
        codserie: 'S',
        codpagoEfectivo: efectivo,
        codpagoTarjeta: tarjeta,
        codalmacen: 'ALG',
        emitirFacturas: true,
      ),
      invoice: ports.invoice,
      masterData: ports.masterData,
    );
    f.sala.addEffects(billing);
    addTearDown(() async {
      await billing.dispose();
      await outbox.dispose();
      await f.dispose();
    });
    await outbox.start();
    return (f, outbox);
  }

  Future<List<(int, String, int, bool)>> recibosDe(int idfactura) async => [
    for (final r in await api.listAll(
      'reciboclientes',
      filters: {'idfactura': idfactura},
      sortBy: 'numero',
    ))
      (
        r.fsRequireInt('numero'),
        r.fsRequireString('codpago'),
        centsFromDecimal(r.fsRequireDouble('importe')),
        r.fsBool('pagado'),
      ),
  ];

  test('cobro mixto en el host: una factura emitida con un recibo pagado por '
      'forma de pago; reintentar no duplica nada', () async {
    final (f, outbox) = await montarHost(api);

    // 7 cañas = 6,65 €: 2,65 en efectivo (entrega 5,00) y 4,00 con tarjeta.
    await f.sala.aceptarLineas(submit('m1', [linea('l1', 'CANA', 7)]));
    final ticket = await f.sala.cobrarMixto(
      'm1',
      efectivoCents: 265,
      entregadoCents: 500,
    );
    expect(ticket.metodoPago, MetodoPago.tarjeta);
    await f.sala.idle();
    await outbox.idle();

    final job = f.store.snapshot.jobPorId(BillingService.jobIdDe(ticket.id))!;
    expect(job.estado, SyncJobEstado.hecho, reason: job.ultimoError);
    final factura = f.store.snapshot.ticketPorId(ticket.id)!.factura!;
    nota('factura ${factura.codigo} avisos: ${factura.avisos}');
    facturas.add(factura.idfactura!);
    expect(factura.estado, EstadoSincronizacion.sincronizado);
    expect(factura.pagada, isTrue);
    expect(factura.emitida, isTrue);
    expect(factura.avisos, isEmpty);

    final fs = (await api.get('facturaclientes', factura.idfactura!))!;
    expect(fs.fsRequireString('numero2'), ticket.claveFactura);
    expect(fs.fsRequireString('codpago'), tarjeta, reason: 'principal');
    expect(centsFromDecimal(fs.fsRequireDouble('total')), 665);
    expect(fs.fsBool('pagada'), isTrue);

    Future<List<(int, String, int, bool)>> recibos() =>
        recibosDe(factura.idfactura!);
    expect(await recibos(), [
      (1, tarjeta, 400, true),
      (2, efectivo, 265, true),
    ]);

    // Reintentar el trabajo (p. ej. tras un corte) no crea nada más.
    await outbox.reintentar(job.id);
    await outbox.idle();
    final otra = await api.list(
      'facturaclientes',
      filters: {'numero2': ticket.claveFactura},
    );
    expect(otra.items, hasLength(1));
    expect(await recibos(), hasLength(2));
  });

  test('r3: efectivo principal con pagado=1 y tarjeta con pagado=0: la '
      'cabecera es la tarjeta y no se borra ningún cobro', () async {
    final registro = _ApiQueAnota(api);
    final (f, outbox) = await montarHost(registro);

    // 7 cañas = 6,65 €: 4,00 en efectivo (principal) y 2,65 con tarjeta.
    await f.sala.aceptarLineas(submit('m1', [linea('l1', 'CANA', 7)]));
    final ticket = await f.sala.cobrarMixto('m1', efectivoCents: 400);
    expect(ticket.metodoPago, MetodoPago.efectivo);
    await f.sala.idle();
    await outbox.idle();

    final job = f.store.snapshot.jobPorId(BillingService.jobIdDe(ticket.id))!;
    expect(job.estado, SyncJobEstado.hecho, reason: job.ultimoError);
    final factura = f.store.snapshot.ticketPorId(ticket.id)!.factura!;
    nota('r3: factura ${factura.codigo} avisos: ${factura.avisos}');
    facturas.add(factura.idfactura!);
    expect(factura.pagada, isTrue);
    expect(factura.avisos, isEmpty);
    nota('r3: escrituras ${registro.escrituras}');

    final fs = (await api.get('facturaclientes', factura.idfactura!))!;
    expect(fs.fsRequireString('codpago'), tarjeta, reason: 'nace abierta');
    expect(await recibosDe(factura.idfactura!), [
      (1, tarjeta, 265, true),
      (2, efectivo, 400, true),
    ]);
    expect(
      registro.escrituras.where((e) => e.startsWith('DELETE')),
      isEmpty,
      reason: 'ningún cobro ni asiento creado para borrarlo',
    );
    // Un único pago (con su asiento) por recibo.
    for (final r in await api.listAll(
      'reciboclientes',
      filters: {'idfactura': factura.idfactura},
      sortBy: 'numero',
    )) {
      final pagos = await api.list(
        'pagoclientes',
        filters: {'idrecibo': r.fsRequireInt('idrecibo')},
      );
      expect(pagos.items, hasLength(1));
      expect(pagos.items.single.fsInt('idasiento'), isNotNull);
    }
  });
}

/// [FsApi] que delega en otra y anota las escrituras (`MÉTODO recurso`).
final class _ApiQueAnota implements FsApi {
  _ApiQueAnota(this._api);

  final FsApi _api;
  final List<String> escrituras = [];

  @override
  Future<List<String>> resources() => _api.resources();

  @override
  Future<FsPage> list(
    String resource, {
    Map<String, Object?> filters = const {},
    Map<String, FsSortOrder> sort = const {},
    int limit = 50,
    int offset = 0,
  }) => _api.list(
    resource,
    filters: filters,
    sort: sort,
    limit: limit,
    offset: offset,
  );

  @override
  Future<List<FsRecord>> listAll(
    String resource, {
    Map<String, Object?> filters = const {},
    required String sortBy,
    int pageSize = 200,
  }) => _api.listAll(
    resource,
    filters: filters,
    sortBy: sortBy,
    pageSize: pageSize,
  );

  @override
  Future<FsRecord?> get(String resource, Object id) => _api.get(resource, id);

  @override
  Future<FsRecord> create(String resource, Map<String, Object?> fields) {
    escrituras.add('POST $resource');
    return _api.create(resource, fields);
  }

  @override
  Future<FsRecord> update(
    String resource,
    Object id,
    Map<String, Object?> fields,
  ) {
    escrituras.add('PUT $resource');
    return _api.update(resource, id, fields);
  }

  @override
  Future<bool> delete(String resource, Object id) {
    escrituras.add('DELETE $resource');
    return _api.delete(resource, id);
  }

  @override
  Future<FsRecord> call(
    String endpoint, {
    List<Object> path = const [],
    Map<String, Object?> fields = const {},
  }) {
    escrituras.add('CALL $endpoint');
    return _api.call(endpoint, path: path, fields: fields);
  }
}
