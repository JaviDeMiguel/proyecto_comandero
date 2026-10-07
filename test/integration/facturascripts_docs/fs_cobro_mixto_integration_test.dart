import 'dart:io';

import 'package:proyecto_comandero/core/errors/app_exception.dart';
import 'package:proyecto_comandero/core/facturascripts/documents/fs_invoice_service.dart';
import 'package:proyecto_comandero/core/facturascripts/documents/invoice_models.dart';
import 'package:proyecto_comandero/core/facturascripts/fs_api.dart';
import 'package:proyecto_comandero/core/facturascripts/fs_http_api.dart';
import 'package:proyecto_comandero/core/facturascripts/fs_values.dart';
import 'package:proyecto_comandero/core/money/money.dart';
import 'package:test/test.dart';

import 'sandbox.dart';

/// Cuentas bancarias del sandbox: 9001 → 5700000000 (caja), 9002 →
/// 5720000000 (banco/datáfono).
const String cuentaCaja = '9001';
const String cuentaBanco = '9002';

void main() {
  final env = SandboxEnv.load();
  if (env == null) {
    test('sandbox no configurado', () {}, skip: SandboxEnv.skipReason);
    return;
  }

  late FsHttpApi api;
  final suffix = runSuffix();
  final corto = suffix.substring(suffix.length - 5);
  final ahora = DateTime.now();
  late int idEmitida;
  final facturas = <int>[];
  final pagos = <int>{};
  final contadoresIniciales = <String, int>{};

  // Formas de pago creadas para el test: abiertas (pagado=0) y que nacen
  // pagadas (pagado=1), en caja (570) y en banco (572).
  final efe0 = 'Z0E$corto';
  final tar0 = 'Z0T$corto';
  final efe1 = 'Z1E$corto';
  final tar1 = 'Z1T$corto';
  final subcuentaDe = {
    efe0: '5700000000',
    tar0: '5720000000',
    efe1: '5700000000',
    tar1: '5720000000',
  };

  void nota(String text) => stdout.writeln('[sandbox] $text');

  Future<int> contar(String resource) async =>
      (await api.list(resource, limit: 1)).totalCount ?? -1;

  setUpAll(() async {
    api = env.connect();
    final resources = await api.resources();
    expect(
      resources,
      containsAll(['reciboclientes', 'pagoclientes', 'crearFacturaCliente']),
    );
    for (final r in ['reciboclientes', 'pagoclientes', 'asientos']) {
      contadoresIniciales[r] = await contar(r);
    }
    final estados = await api.list(
      'estadodocumentos',
      filters: {'tipodoc': 'FacturaCliente', 'editable': 0},
      limit: 1,
    );
    idEmitida = estados.items.first.fsRequireInt('idestado');
    for (final (codpago, pagado, cuenta) in [
      (efe0, 0, cuentaCaja),
      (tar0, 0, cuentaBanco),
      (efe1, 1, cuentaCaja),
      (tar1, 1, cuentaBanco),
    ]) {
      await api.create('formapagos', {
        'codpago': codpago,
        'descripcion': 'Test cobro mixto $codpago',
        'pagado': pagado,
        'codcuentabanco': cuenta,
        'plazovencimiento': 0,
        'tipovencimiento': 'days',
        'activa': 1,
      });
    }
    nota('formas de pago creadas: $efe0 $tar0 $efe1 $tar1');
  });

  tearDownAll(() async {
    final estados = await api.list(
      'estadodocumentos',
      filters: {'tipodoc': 'FacturaCliente', 'editable': 1},
      limit: 1,
    );
    for (final id in facturas) {
      if (estados.items.isNotEmpty) {
        await api.update('facturaclientes', id, {
          'idestado': estados.items.first.fsRequireInt('idestado'),
        });
      }
      // Los recibos se borran antes (con sus pagos y los asientos de los
      // pagos); después la factura y su asiento de venta.
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
    for (final codpago in [efe0, tar0, efe1, tar1]) {
      nota(
        'forma $codpago borrada: ${await api.delete('formapagos', codpago)}',
      );
    }
    // Comprobación exacta de lo propio (los contadores globales solo se
    // anotan: otra suite del sandbox puede estar escribiendo a la vez).
    for (final id in facturas) {
      expect(await api.get('facturaclientes', id), isNull);
      final restos = await api.list(
        'reciboclientes',
        filters: {'idfactura': id},
        limit: 1,
      );
      expect(restos.items, isEmpty, reason: 'recibos de la factura $id');
    }
    for (final codpago in [efe0, tar0, efe1, tar1]) {
      expect(await api.get('formapagos', codpago), isNull);
    }
    for (final idpago in pagos) {
      expect(await api.get('pagoclientes', idpago), isNull);
    }
    for (final MapEntry(key: r, value: antes) in contadoresIniciales.entries) {
      nota('$r: $antes → ${await contar(r)}');
    }
    await api.close();
  });

  TicketFactura ticket(
    String clave,
    String cabecera,
    List<(String, int)> pagos,
  ) => TicketFactura(
    claveIdempotente: clave,
    codcliente: 'TPVVARIOS',
    codserie: 'S',
    codpago: cabecera,
    codalmacen: 'ALG',
    fechaHora: ahora,
    observaciones: 'Test cobro mixto $suffix',
    lineas: [
      // 18,13636 neto al 10 % → 18,14 + 1,81 = 19,95.
      LineaFactura(
        descripcion: 'Menú cobro mixto',
        cantidad: 1,
        pvpunitarioNeto: 18.13636,
        codimpuesto: 'IVA10',
      ),
    ],
    totalEsperadoCents: 1995,
    modoPago: ModoPago.pagarTrasCrear,
    pagos: [
      for (final (codpago, cents) in pagos)
        PagoFactura(codpago: codpago, importeCents: cents),
    ],
    emitir: true,
    idEstadoEmitida: idEmitida,
  );

  /// Verifica en el ERP: recibos = plan y pagados, un pago por recibo con su
  /// codpago e importe, asiento del pago con 57x al Debe y 430 al Haber,
  /// factura pagada y emitida.
  Future<void> verificar(int idfactura, List<(int, String, int)> plan) async {
    final factura = (await api.get('facturaclientes', idfactura))!;
    expect(factura.fsBool('pagada'), isTrue);
    expect(factura.fsInt('idestado'), idEmitida);
    final recibos = await api.listAll(
      'reciboclientes',
      filters: {'idfactura': idfactura},
      sortBy: 'numero',
    );
    expect([
      for (final r in recibos)
        (
          r.fsInt('numero'),
          r.fsString('codpago'),
          centsFromDecimal(r.fsRequireDouble('importe')),
        ),
    ], plan);
    for (final recibo in recibos) {
      expect(recibo.fsBool('pagado'), isTrue);
      final pagos = await api.listAll(
        'pagoclientes',
        filters: {'idrecibo': recibo.fsRequireInt('idrecibo')},
        sortBy: 'idpago',
      );
      expect(pagos, hasLength(1));
      final pago = pagos.single;
      final codpago = recibo.fsRequireString('codpago');
      final cents = centsFromDecimal(recibo.fsRequireDouble('importe'));
      expect(pago.fsString('codpago'), codpago);
      expect(centsFromDecimal(pago.fsRequireDouble('importe')), cents);
      final partidas = await api.listAll(
        'partidas',
        filters: {'idasiento': pago.fsRequireInt('idasiento')},
        sortBy: 'idpartida',
      );
      final debe = partidas.singleWhere((p) => (p.fsDouble('debe') ?? 0) > 0);
      final haber = partidas.singleWhere((p) => (p.fsDouble('haber') ?? 0) > 0);
      expect(debe.fsString('codsubcuenta'), subcuentaDe[codpago]);
      expect(centsFromDecimal(debe.fsRequireDouble('debe')), cents);
      expect(haber.fsString('codsubcuenta'), startsWith('430'));
      expect(centsFromDecimal(haber.fsRequireDouble('haber')), cents);
    }
  }

  Future<void> segundaPasadaSinEscrituras(TicketFactura t) async {
    final contador = _CortaEscrituras(api);
    final again = await FsInvoiceService(contador).crearOReanudar(t);
    expect(again.yaExistia, isTrue);
    expect(again.avisos, isEmpty);
    expect(contador.escrituras, 0);
  }

  test(
    'formas pagado=0: PUT importe + POST cobrado + pagar, y emitir',
    () async {
      final t = ticket('TPV-MIX0-$suffix', tar0, [(efe0, 1235), (tar0, 760)]);
      final result = await FsInvoiceService(api).crearOReanudar(t);
      facturas.add(result.idfactura);
      pagos.addAll([for (final r in result.recibos) ...r.idpagos]);
      nota('pagado=0: $result');

      expect(result.pagada, isTrue);
      expect(result.emitida, isTrue);
      expect(result.totalCents, 1995);
      expect(result.avisos, isEmpty);
      expect(
        [for (final r in result.recibos) (r.numero, r.codpago, r.importeCents)],
        [(1, tar0, 760), (2, efe0, 1235)],
      );
      await verificar(result.idfactura, [(1, tar0, 760), (2, efe0, 1235)]);
      await segundaPasadaSinEscrituras(t);
    },
  );

  test('formas pagado=1: DELETE del recibo nacido pagado + 2 POST', () async {
    final t = ticket('TPV-MIX1-$suffix', efe1, [(efe1, 1235), (tar1, 760)]);
    final result = await FsInvoiceService(api).crearOReanudar(t);
    facturas.add(result.idfactura);
    pagos.addAll([for (final r in result.recibos) ...r.idpagos]);
    nota('pagado=1: $result');

    expect(result.pagada, isTrue);
    expect(result.emitida, isTrue);
    expect(result.avisos, isEmpty);
    await verificar(result.idfactura, [(1, efe1, 1235), (2, tar1, 760)]);
    await segundaPasadaSinEscrituras(t);
  });

  for (final (nombre, cabecera, otra, corte, perder) in [
    ('pagado=0, respuesta perdida en el PUT del importe', 0, 0, 2, true),
    ('pagado=0, fallo antes del POST del recibo 2', 0, 0, 3, false),
    ('pagado=1, respuesta perdida en el primer POST', 1, 1, 3, true),
  ]) {
    test('reanudación tras cortar a mitad: $nombre', () async {
      final efe = cabecera == 0 ? efe0 : efe1;
      final tar = otra == 0 ? tar0 : tar1;
      final t = ticket('TPV-MIXR$corte${perder ? 'P' : 'F'}-$suffix', efe, [
        (efe, 1235),
        (tar, 760),
      ]);
      final cortada = _CortaEscrituras(api, corte: corte, perder: perder);
      await expectLater(
        FsInvoiceService(cortada).crearOReanudar(t),
        throwsA(isA<ErpApiException>()),
      );
      final page = await api.list(
        'facturaclientes',
        filters: {'numero2': t.claveIdempotente},
        limit: 2,
      );
      expect(page.items, hasLength(1));
      final id = page.items.single.fsRequireInt('idfactura');
      facturas.add(id);

      final result = await FsInvoiceService(api).crearOReanudar(t);
      nota('reanudada ($nombre): $result');
      pagos.addAll([for (final r in result.recibos) ...r.idpagos]);
      expect(result.yaExistia, isTrue);
      expect(result.pagada, isTrue);
      expect(result.avisos, isEmpty);
      await verificar(id, [(1, efe, 1235), (2, tar, 760)]);
      await segundaPasadaSinEscrituras(t);
    });
  }
}

/// Cuenta las escrituras y, si se pide, corta la número [corte]: sin
/// enviarla o enviándola y perdiendo la respuesta ([perder]).
final class _CortaEscrituras implements FsApi {
  _CortaEscrituras(this._inner, {this.corte, this.perder = false});

  final FsApi _inner;
  final int? corte;
  final bool perder;
  int escrituras = 0;

  Future<T> _escritura<T>(Future<T> Function() efecto) async {
    escrituras++;
    if (escrituras != corte) return efecto();
    if (perder) await efecto();
    throw const ErpApiException('Conexión cortada (simulada en el test)');
  }

  @override
  Future<List<String>> resources() => _inner.resources();

  @override
  Future<FsPage> list(
    String resource, {
    Map<String, Object?> filters = const {},
    Map<String, FsSortOrder> sort = const {},
    int limit = 50,
    int offset = 0,
  }) => _inner.list(
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
  }) => _inner.listAll(
    resource,
    filters: filters,
    sortBy: sortBy,
    pageSize: pageSize,
  );

  @override
  Future<FsRecord?> get(String resource, Object id) => _inner.get(resource, id);

  @override
  Future<FsRecord> create(String resource, Map<String, Object?> fields) =>
      _escritura(() => _inner.create(resource, fields));

  @override
  Future<FsRecord> update(
    String resource,
    Object id,
    Map<String, Object?> fields,
  ) => _escritura(() => _inner.update(resource, id, fields));

  @override
  Future<bool> delete(String resource, Object id) =>
      _escritura(() => _inner.delete(resource, id));

  @override
  Future<FsRecord> call(
    String endpoint, {
    List<Object> path = const [],
    Map<String, Object?> fields = const {},
  }) => _escritura(() => _inner.call(endpoint, path: path, fields: fields));
}
