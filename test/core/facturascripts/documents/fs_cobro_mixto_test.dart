import 'package:proyecto_comandero/core/errors/app_exception.dart';
import 'package:proyecto_comandero/core/facturascripts/documents/fs_invoice_service.dart';
import 'package:proyecto_comandero/core/facturascripts/documents/invoice_models.dart';
import 'package:proyecto_comandero/core/facturascripts/fs_api.dart';
import 'package:proyecto_comandero/core/facturascripts/fs_values.dart';
import 'package:proyecto_comandero/core/money/money.dart';
import 'package:test/test.dart';

import '../fake_fs_api.dart';

/// Menú de 19,95 €: 18,13636 neto al 10 % → 18,14 + 1,81.
LineaFactura menu() => LineaFactura(
  descripcion: 'Menú cobro mixto',
  cantidad: 1,
  pvpunitarioNeto: 18.13636,
  codimpuesto: 'IVA10',
);

/// En el doble `TPVEFE` nace pagada (pagado=1) y `TPVTAR`/`CONT` no.
TicketFactura ticket({
  String clave = 'TPV-MIX-0001',
  String codpago = 'TPVEFE',
  ModoPago modoPago = ModoPago.nacePagada,
  List<PagoFactura>? pagos,
  int totalEsperadoCents = 1995,
  bool emitir = false,
}) => TicketFactura(
  claveIdempotente: clave,
  codcliente: 'TPVVARIOS',
  codserie: 'S',
  codpago: codpago,
  codalmacen: 'ALG',
  fechaHora: DateTime(2026, 10, 7, 21, 48),
  lineas: [menu()],
  totalEsperadoCents: totalEsperadoCents,
  modoPago: modoPago,
  pagos:
      pagos ??
      [
        PagoFactura(
          codpago: 'TPVEFE',
          importeCents: 1235,
          modoPago: ModoPago.nacePagada,
        ),
        PagoFactura(codpago: 'TPVTAR', importeCents: 760),
      ],
  emitir: emitir,
  idEstadoEmitida: emitir ? 11 : null,
);

/// Efectivo con forma que nace pagada (caso B del informe).
TicketFactura ticketNacePagado() => ticket();

/// Tarjeta como cabecera, forma que no nace pagada (caso A).
TicketFactura ticketAbierto() => ticket(
  codpago: 'TPVTAR',
  modoPago: ModoPago.pagarTrasCrear,
  pagos: [
    PagoFactura(codpago: 'TPVEFE', importeCents: 1235),
    PagoFactura(codpago: 'TPVTAR', importeCents: 760),
  ],
);

List<String> escrituras(FakeFsApi api) => [
  for (final call in api.calls)
    if (const {'POST', 'PUT', 'DELETE', 'CALL'}.contains(call.method))
      '${call.method} ${call.resource}',
];

int cents(Object? value) =>
    centsFromDecimal(value is num ? value : double.parse(value.toString()));

/// Comprueba en el doble el estado final de un cobro mixto correcto: recibos
/// iguales al plan y pagados, un pago por recibo con su codpago e importe, un
/// asiento por pago con la subcuenta de su forma de pago y ningún asiento
/// huérfano.
void expectCobroCompleto(
  FakeFsApi api,
  int idfactura,
  List<(int, String, int)> plan,
) {
  final factura = api.find('facturaclientes', idfactura)!;
  expect(factura.fsBool('pagada'), isTrue, reason: 'factura pagada');
  final recibos = [
    for (final r in api.table('reciboclientes'))
      if (r.fsInt('idfactura') == idfactura) r,
  ]..sort((a, b) => a.fsInt('numero')!.compareTo(b.fsInt('numero')!));
  expect(
    [
      for (final r in recibos)
        (r.fsInt('numero'), r.fsString('codpago'), cents(r['importe'])),
    ],
    [for (final p in plan) (p.$1, p.$2, p.$3)],
  );
  expect(recibos.every((r) => r.fsBool('pagado')), isTrue);
  var sumaCents = 0;
  for (final recibo in recibos) {
    final pagos = [
      for (final p in api.table('pagoclientes'))
        if (p.fsInt('idrecibo') == recibo.fsInt('idrecibo')) p,
    ];
    expect(pagos, hasLength(1), reason: 'un pago por recibo');
    final pago = pagos.single;
    expect(pago.fsString('codpago'), recibo.fsString('codpago'));
    expect(cents(pago['importe']), cents(recibo['importe']));
    final partidas = [
      for (final p in api.table('partidas'))
        if (p.fsInt('idasiento') == pago.fsInt('idasiento')) p,
    ];
    final debe = partidas.singleWhere((p) => cents(p['debe']) > 0);
    expect(
      debe.fsString('codsubcuenta'),
      api.subcuentaCobro[recibo.fsString('codpago')] ?? '5720000000',
    );
    expect(cents(debe['debe']), cents(recibo['importe']));
    sumaCents += cents(recibo['importe']);
  }
  expect(sumaCents, cents(factura['total']));
  // Sin huérfanos: todo pago apunta a un recibo vivo y todo asiento es el de
  // la venta o el de un pago.
  final idrecibos = {
    for (final r in api.table('reciboclientes')) r.fsInt('idrecibo'),
  };
  for (final pago in api.table('pagoclientes')) {
    expect(idrecibos, contains(pago.fsInt('idrecibo')));
  }
  final asientosValidos = {
    for (final f in api.table('facturaclientes')) f.fsInt('idasiento'),
    for (final p in api.table('pagoclientes')) p.fsInt('idasiento'),
  };
  for (final asiento in api.table('asientos')) {
    expect(asientosValidos, contains(asiento.fsInt('idasiento')));
  }
}

const planNacePagado = [(1, 'TPVEFE', 1235), (2, 'TPVTAR', 760)];
const planAbierto = [(1, 'TPVTAR', 760), (2, 'TPVEFE', 1235)];

void main() {
  late FakeFsApi api;
  late FsInvoiceService service;

  setUp(() {
    api = FakeFsApi.conDatosBasicos();
    service = FsInvoiceService(api);
  });

  group('plan de cobro', () {
    test('número 1 = codpago de la cabecera; el resto en su orden', () {
      expect(ticketAbierto().planCobro, const [
        ParteCobro(numero: 1, codpago: 'TPVTAR', importeCents: 760),
        ParteCobro(numero: 2, codpago: 'TPVEFE', importeCents: 1235),
      ]);
      expect(ticketAbierto().esCobroMixto, isTrue);
      expect(ticketAbierto().codpagoCabecera, 'TPVTAR');
    });

    test('r2: el plan conserva qué parte es efectivo al normalizar', () {
      final t = ticket(
        codpago: 'TPVTAR',
        modoPago: ModoPago.pagarTrasCrear,
        pagos: [
          PagoFactura(codpago: 'TPVEFE', importeCents: 1000, efectivo: true),
          PagoFactura(codpago: 'TPVTAR', importeCents: 760),
          PagoFactura(codpago: 'TPVEFE', importeCents: 235, efectivo: true),
        ],
      );
      expect(t.planCobro, const [
        ParteCobro(numero: 1, codpago: 'TPVTAR', importeCents: 760),
        ParteCobro(
          numero: 2,
          codpago: 'TPVEFE',
          importeCents: 1235,
          efectivo: true,
        ),
      ]);
      expect(t.planCobro.last.conImporte(1).efectivo, isTrue);
    });

    test('sin pagos: una parte con codpago, total y modoPago', () {
      final t = ticket(pagos: const []);
      expect(t.planCobro, const [
        ParteCobro(
          numero: 1,
          codpago: 'TPVEFE',
          importeCents: 1995,
          modoPago: ModoPago.nacePagada,
        ),
      ]);
      expect(t.esCobroMixto, isFalse);
    });

    test('quita las partes de 0 y fusiona las de igual codpago', () {
      final sinCero = ticket(
        codpago: 'TPVEFE',
        pagos: [
          PagoFactura(codpago: 'TPVEFE', importeCents: 0),
          PagoFactura(
            codpago: 'TPVTAR',
            importeCents: 1995,
            modoPago: ModoPago.pagarTrasCrear,
          ),
        ],
      );
      expect(sinCero.esCobroMixto, isFalse);
      expect(sinCero.codpagoCabecera, 'TPVTAR');
      expect(sinCero.modoPagoCabecera, ModoPago.pagarTrasCrear);

      final fusionado = ticket(
        pagos: [
          PagoFactura(codpago: 'TPVEFE', importeCents: 1000),
          PagoFactura(codpago: 'TPVEFE', importeCents: 995),
        ],
      );
      expect(fusionado.planCobro, [
        const ParteCobro(numero: 1, codpago: 'TPVEFE', importeCents: 1995),
      ]);
    });

    test('cabecera ausente del reparto: manda la parte de mayor importe', () {
      final t = ticket(
        codpago: 'CONT',
        pagos: [
          PagoFactura(codpago: 'TPVTAR', importeCents: 760),
          PagoFactura(codpago: 'TPVEFE', importeCents: 1235),
        ],
      );
      expect(t.planCobro.map((p) => p.codpago), ['TPVEFE', 'TPVTAR']);
    });

    test('validaciones del reparto', () {
      expect(
        () => ticket(
          pagos: [
            PagoFactura(codpago: 'TPVEFE', importeCents: 1235),
            PagoFactura(codpago: 'TPVTAR', importeCents: 700),
          ],
        ),
        throwsA(isA<ValidationException>()),
      );
      expect(
        () => PagoFactura(codpago: ' ', importeCents: 1),
        throwsA(isA<ValidationException>()),
      );
      expect(
        () => PagoFactura(codpago: 'TPVEFE', importeCents: -1),
        throwsA(isA<ValidationException>()),
      );
    });
  });

  group('cobro mixto: camino feliz', () {
    test(
      'forma que no nace pagada: PUT importe, POST cobrado y pagar SIN codpago',
      () async {
        final result = await service.crearOReanudar(ticketAbierto());

        expect(escrituras(api), [
          'CALL crearFacturaCliente',
          'PUT reciboclientes',
          'POST reciboclientes',
          'CALL pagarFacturaCliente',
        ]);
        final crear = api.callsTo('crearFacturaCliente').single.fields;
        expect(crear['codpago'], 'TPVTAR');
        expect(crear, isNot(contains('pagada')));
        expect(api.callsTo('reciboclientes', method: 'PUT').single.fields, {
          'importe': '7.60',
        });
        final alta = api.callsTo('reciboclientes', method: 'POST').single;
        expect(alta.fields, {
          'idfactura': 1,
          'codcliente': 'TPVVARIOS',
          'coddivisa': 'EUR',
          'idempresa': 1,
          'numero': 2,
          'codpago': 'TPVEFE',
          'importe': '12.35',
          'fecha': '07-10-2026',
          'pagado': 1,
          'fechapago': '07-10-2026',
        });
        expect(api.callsTo('pagarFacturaCliente').single.fields, {
          'pagada': 1,
          'fechapago': '07-10-2026',
        });

        expect(result.pagada, isTrue);
        expect(result.totalCents, 1995);
        expect(result.avisos, isEmpty);
        expect(result.cobroMixto, isTrue);
        expect(
          [
            for (final r in result.recibos)
              (r.numero, r.codpago, r.importeCents, r.pagado, r.pagosCents),
          ],
          [(1, 'TPVTAR', 760, true, 760), (2, 'TPVEFE', 1235, true, 1235)],
        );
        expect(result.recibos.every((r) => r.idpagos.length == 1), isTrue);
        expectCobroCompleto(api, 1, planAbierto);
      },
    );

    test('forma que nace pagada: DELETE del recibo y 2 POST cobrados, sin '
        'pagar', () async {
      final result = await service.crearOReanudar(ticketNacePagado());

      expect(escrituras(api), [
        'CALL crearFacturaCliente',
        'DELETE reciboclientes',
        'POST reciboclientes',
        'POST reciboclientes',
      ]);
      expect(api.callsTo('reciboclientes', method: 'PUT'), isEmpty);
      expect(result.pagada, isTrue);
      expect(result.avisos, isEmpty);
      expectCobroCompleto(api, 1, planNacePagado);
    });

    test('las dos formas abiertas (CONT + TPVTAR)', () async {
      final result = await service.crearOReanudar(
        ticket(
          codpago: 'CONT',
          modoPago: ModoPago.pagarTrasCrear,
          pagos: [
            PagoFactura(codpago: 'CONT', importeCents: 1000),
            PagoFactura(codpago: 'TPVTAR', importeCents: 995),
          ],
        ),
      );
      expect(result.pagada, isTrue);
      expectCobroCompleto(api, 1, const [
        (1, 'CONT', 1000),
        (2, 'TPVTAR', 995),
      ]);
    });

    test('segunda pasada: 0 escrituras y el mismo resultado', () async {
      for (final t in [ticketAbierto(), ticket(clave: 'TPV-MIX-0002')]) {
        final first = await service.crearOReanudar(t);
        api.calls.clear();
        final second = await service.crearOReanudar(t);

        expect(escrituras(api), isEmpty, reason: t.claveIdempotente);
        expect(second.yaExistia, isTrue);
        expect(second.recibos, first.recibos);
        expect(second.avisos, isEmpty);
      }
    });

    test('emite después de cobrar con PUT de solo idestado', () async {
      final result = await service.crearOReanudar(
        ticket(
          codpago: 'TPVTAR',
          emitir: true,
          modoPago: ModoPago.pagarTrasCrear,
        ),
      );
      expect(result.emitida, isTrue);
      expect(escrituras(api).last, 'PUT facturaclientes');
      expect(api.callsTo('facturaclientes', method: 'PUT').single.fields, {
        'idestado': 11,
      });
    });

    test(
      'nunca envía codpago a pagarFacturaCliente en el cobro mixto',
      () async {
        await service.crearOReanudar(ticketAbierto());
        for (final call in api.callsTo('pagarFacturaCliente')) {
          expect(call.fields, isNot(contains('codpago')));
        }
      },
    );

    test('el pago único no lee recibos (flujo de siempre)', () async {
      await service.crearOReanudar(ticket(pagos: const []));
      expect(api.callsTo('reciboclientes'), isEmpty);
      expect(api.callsTo('pagoclientes'), isEmpty);
      expect(api.calls.map((c) => '${c.method} ${c.resource}'), [
        'LIST facturaclientes',
        'CALL crearFacturaCliente',
      ]);
    });

    test('reparto normalizado a un pago: flujo único con su codpago', () async {
      final result = await service.crearOReanudar(
        ticket(
          pagos: [
            PagoFactura(codpago: 'TPVEFE', importeCents: 0),
            PagoFactura(codpago: 'TPVTAR', importeCents: 1995),
          ],
        ),
      );
      expect(result.cobroMixto, isFalse);
      expect(
        api.callsTo('crearFacturaCliente').single.fields['codpago'],
        'TPVTAR',
      );
      expect(
        api.callsTo('pagarFacturaCliente').single.fields['codpago'],
        'TPVTAR',
      );
      expect(result.pagada, isTrue);
    });
  });

  group('total de FacturaScripts distinto del TPV', () {
    test('la diferencia se ajusta en la última parte, con aviso', () async {
      final result = await service.crearOReanudar(
        ticket(
          codpago: 'TPVTAR',
          modoPago: ModoPago.pagarTrasCrear,
          totalEsperadoCents: 2000,
          pagos: [
            PagoFactura(codpago: 'TPVTAR', importeCents: 1240),
            PagoFactura(codpago: 'TPVEFE', importeCents: 760),
          ],
        ),
      );
      expect(result.totalCents, 1995);
      expect(result.avisos, hasLength(2));
      expect(result.avisos.first, contains('ajustado'));
      expect(result.avisos.last, contains('Total FacturaScripts'));
      expectCobroCompleto(api, 1, const [
        (1, 'TPVTAR', 1240),
        (2, 'TPVEFE', 755),
      ]);
    });

    test('r2: la diferencia va a la parte en efectivo aunque sea el recibo '
        'n.º 1, nunca a la tarjeta', () async {
      final result = await service.crearOReanudar(
        ticket(
          totalEsperadoCents: 1996,
          pagos: [
            PagoFactura(
              codpago: 'TPVEFE',
              importeCents: 1236,
              modoPago: ModoPago.nacePagada,
              efectivo: true,
            ),
            PagoFactura(codpago: 'TPVTAR', importeCents: 760),
          ],
        ),
      );
      expect(result.totalCents, 1995);
      expect(result.avisos.first, contains('TPVEFE 12,36 € → 12,35 €'));
      expectCobroCompleto(api, 1, const [
        (1, 'TPVEFE', 1235),
        (2, 'TPVTAR', 760),
      ]);
    });

    test('r2: si el efectivo no admite la diferencia la absorbe la otra '
        'parte', () async {
      final result = await service.crearOReanudar(
        ticket(
          codpago: 'TPVTAR',
          modoPago: ModoPago.pagarTrasCrear,
          totalEsperadoCents: 2000,
          pagos: [
            PagoFactura(codpago: 'TPVTAR', importeCents: 1995),
            PagoFactura(codpago: 'TPVEFE', importeCents: 5, efectivo: true),
          ],
        ),
      );
      expect(result.avisos.first, contains('TPVTAR 19,95 € → 19,90 €'));
      expectCobroCompleto(api, 1, const [
        (1, 'TPVTAR', 1990),
        (2, 'TPVEFE', 5),
      ]);
    });

    test('r2: si ninguna parte admite la diferencia: ValidationException, '
        'sin tocar los recibos', () async {
      final t = ticket(
        codpago: 'TPVTAR',
        modoPago: ModoPago.pagarTrasCrear,
        totalEsperadoCents: 4000,
        pagos: [
          PagoFactura(codpago: 'TPVTAR', importeCents: 2000),
          PagoFactura(codpago: 'TPVEFE', importeCents: 2000, efectivo: true),
        ],
      );
      await expectLater(
        service.crearOReanudar(t),
        throwsA(isA<ValidationException>()),
      );
      expect(escrituras(api), ['CALL crearFacturaCliente']);
    });
  });

  group('reanudación de estados intermedios', () {
    /// Factura creada (como si la app hubiera muerto justo después) con el
    /// recibo automático n.º 1 por el total.
    Future<int> crearSoloFactura(TicketFactura t) async {
      final response = await api.call(
        'crearFacturaCliente',
        fields: {
          'codcliente': 'TPVVARIOS',
          'codserie': 'S',
          'codpago': t.codpagoCabecera,
          'codalmacen': 'ALG',
          'fecha': '07-10-2026',
          'hora': '21:48:00',
          'numero2': t.claveIdempotente,
          'lineas': [menu().toFsJson()],
        },
      );
      return (response['doc']! as FsRecord).fsRequireInt('idfactura');
    }

    FsRecord recibo(int idfactura, int numero) => api
        .table('reciboclientes')
        .singleWhere(
          (r) =>
              r.fsInt('idfactura') == idfactura && r.fsInt('numero') == numero,
        );

    Map<String, Object?> altaRecibo(
      int idfactura,
      int numero,
      String codpago,
      String importe, {
      bool pagado = false,
    }) => {
      'idfactura': idfactura,
      'codcliente': 'TPVVARIOS',
      'idempresa': 1,
      'numero': numero,
      'codpago': codpago,
      'importe': importe,
      'fecha': '07-10-2026',
      if (pagado) 'pagado': 1,
      if (pagado) 'fechapago': '07-10-2026',
    };

    Future<void> reanudarYComprobar(
      TicketFactura t,
      int id,
      List<(int, String, int)> plan,
      List<String> esperadas,
    ) async {
      api.calls.clear();
      final result = await service.crearOReanudar(t);
      expect(result.yaExistia, isTrue);
      expect(escrituras(api), esperadas);
      expect(result.avisos, isEmpty);
      expectCobroCompleto(api, id, plan);
      api.calls.clear();
      await service.crearOReanudar(t);
      expect(escrituras(api), isEmpty, reason: 'segunda pasada');
    }

    test('C1: recibo 1 ajustado, falta el 2', () async {
      final t = ticketAbierto();
      final id = await crearSoloFactura(t);
      await api.update('reciboclientes', recibo(id, 1)['idrecibo']!, {
        'importe': '7.60',
      });
      await reanudarYComprobar(t, id, planAbierto, [
        'POST reciboclientes',
        'CALL pagarFacturaCliente',
      ]);
    });

    test(
      'C2: recibo 2 abierto y recibo 1 sin ajustar (suma > total)',
      () async {
        final t = ticketAbierto();
        final id = await crearSoloFactura(t);
        await api.create(
          'reciboclientes',
          altaRecibo(id, 2, 'TPVEFE', '12.35'),
        );
        await reanudarYComprobar(t, id, planAbierto, [
          'PUT reciboclientes',
          'CALL pagarFacturaCliente',
        ]);
      },
    );

    test('C3: recibo 1 ajustado y pagado, falta el 2', () async {
      final t = ticketAbierto();
      final id = await crearSoloFactura(t);
      final idrecibo = recibo(id, 1)['idrecibo']!;
      await api.update('reciboclientes', idrecibo, {'importe': '7.60'});
      await api.update('reciboclientes', idrecibo, {
        'pagado': 1,
        'fechapago': '07-10-2026',
      });
      await reanudarYComprobar(t, id, planAbierto, ['POST reciboclientes']);
    });

    test('C4: recibos correctos, el 1 pagado y el 2 abierto', () async {
      final t = ticketAbierto();
      final id = await crearSoloFactura(t);
      final idrecibo = recibo(id, 1)['idrecibo']!;
      await api.update('reciboclientes', idrecibo, {'importe': '7.60'});
      await api.update('reciboclientes', idrecibo, {
        'pagado': 1,
        'fechapago': '07-10-2026',
      });
      await api.create('reciboclientes', altaRecibo(id, 2, 'TPVEFE', '12.35'));
      await reanudarYComprobar(t, id, planAbierto, [
        'CALL pagarFacturaCliente',
      ]);
    });

    test('C5: recibo automático borrado y ninguno creado', () async {
      final t = ticketAbierto();
      final id = await crearSoloFactura(t);
      await api.delete('reciboclientes', recibo(id, 1)['idrecibo']!);
      await reanudarYComprobar(t, id, planAbierto, [
        'POST reciboclientes',
        'POST reciboclientes',
      ]);
    });

    test('C6: factura emitida antes de dividir', () async {
      final t = ticketAbierto();
      final id = await crearSoloFactura(t);
      await api.update('facturaclientes', id, {'idestado': 11});
      await reanudarYComprobar(t, id, planAbierto, [
        'PUT reciboclientes',
        'POST reciboclientes',
        'CALL pagarFacturaCliente',
      ]);
    });

    test('B/E: recibo nacido pagado por el total', () async {
      final t = ticketNacePagado();
      final id = await crearSoloFactura(t);
      expect(recibo(id, 1).fsBool('pagado'), isTrue);
      await reanudarYComprobar(t, id, planNacePagado, [
        'DELETE reciboclientes',
        'POST reciboclientes',
        'POST reciboclientes',
      ]);
    });

    test(
      'D.2: codpago reescrito por un pagar con codpago → DELETE y POST',
      () async {
        final t = ticketAbierto();
        await service.crearOReanudar(t);
        // Alguien cobra la factura "a la antigua": desmarca y paga con codpago.
        await api.call('pagarFacturaCliente', path: [1], fields: {'pagada': 0});
        await api.call(
          'pagarFacturaCliente',
          path: [1],
          fields: {'pagada': 1, 'codpago': 'TPVEFE'},
        );
        api.calls.clear();
        final result = await service.crearOReanudar(t);
        expect(escrituras(api), [
          'DELETE reciboclientes',
          'POST reciboclientes',
        ]);
        final recibos = result.recibos;
        expect(recibos.map((r) => r.codpago), ['TPVTAR', 'TPVEFE']);
        expect(result.pagada, isTrue);
      },
    );

    test(
      'recibo duplicado del mismo número: se borra el sobrante con aviso',
      () async {
        final t = ticketAbierto();
        await service.crearOReanudar(t);
        await api.create(
          'reciboclientes',
          altaRecibo(1, 2, 'TPVEFE', '12.35', pagado: true),
        );
        api.calls.clear();
        final result = await service.crearOReanudar(t);
        expect(escrituras(api), ['DELETE reciboclientes']);
        expect(result.avisos.single, contains('duplicado'));
        expectCobroCompleto(api, 1, planAbierto);
      },
    );

    test('recibo con dos pagos (pagado reenviado): solo avisa', () async {
      final t = ticketAbierto();
      await service.crearOReanudar(t);
      await api.update('reciboclientes', recibo(1, 2)['idrecibo']!, {
        'pagado': 1,
      });
      api.calls.clear();
      final result = await service.crearOReanudar(t);
      expect(escrituras(api), isEmpty);
      expect(result.avisos.single, contains('2 pagos'));
      expect(
        result.recibos.singleWhere((r) => r.numero == 2).idpagos,
        hasLength(2),
      );
    });

    test('recibo con número fuera del plan: se borra', () async {
      final t = ticketAbierto();
      await service.crearOReanudar(t);
      await api.create('reciboclientes', altaRecibo(1, 3, 'CONT', '1.00'));
      api.calls.clear();
      await service.crearOReanudar(t);
      expect(escrituras(api), ['DELETE reciboclientes']);
      expectCobroCompleto(api, 1, planAbierto);
    });
  });

  group('corte en cualquier escritura (la app muere a mitad)', () {
    for (final (nombre, crear, plan) in [
      ('forma abierta', ticketAbierto, planAbierto),
      ('forma que nace pagada', ticketNacePagado, planNacePagado),
    ]) {
      for (final perderRespuesta in [false, true]) {
        test('$nombre, ${perderRespuesta ? 'respuesta perdida' : 'fallo antes'}'
            ' en cada escritura', () async {
          // Escrituras de una ejecución limpia.
          final limpio = FakeFsApi.conDatosBasicos();
          await FsInvoiceService(limpio).crearOReanudar(crear());
          final total = escrituras(limpio).length;
          expect(total, greaterThanOrEqualTo(4));

          for (var corte = 1; corte <= total; corte++) {
            final fake = FakeFsApi.conDatosBasicos();
            final cortada = _CorteEnEscritura(
              fake,
              corte,
              perderRespuesta: perderRespuesta,
            );
            await expectLater(
              FsInvoiceService(cortada).crearOReanudar(crear()),
              throwsA(isA<ErpApiException>()),
              reason: 'corte $corte',
            );
            final result = await FsInvoiceService(fake).crearOReanudar(crear());
            expect(result.pagada, isTrue, reason: 'corte $corte');
            expect(result.avisos, isEmpty, reason: 'corte $corte');
            expect(fake.table('facturaclientes'), hasLength(1));
            expectCobroCompleto(fake, 1, plan);

            fake.calls.clear();
            await FsInvoiceService(fake).crearOReanudar(crear());
            expect(escrituras(fake), isEmpty, reason: 'corte $corte');
          }
        });
      }
    }
  });

  group('errores', () {
    test('400 al ajustar un recibo se propaga (definitivo)', () async {
      api.failOn(
        'reciboclientes',
        nth: 1,
        method: 'PUT',
        error: const ErpApiException('save error', statusCode: 400),
      );
      await expectLater(
        service.crearOReanudar(ticketAbierto()),
        throwsA(
          isA<ErpApiException>().having(
            (e) => e.kind,
            'kind',
            ErpApiErrorKind.validation,
          ),
        ),
      );
    });

    test('factura desaparecida entre la búsqueda y el cobro: 404', () async {
      final borrada = _BorraAntesDeLeer(api);
      await expectLater(
        FsInvoiceService(borrada).crearOReanudar(ticketAbierto()),
        throwsA(
          isA<ErpApiException>().having(
            (e) => e.kind,
            'kind',
            ErpApiErrorKind.notFound,
          ),
        ),
      );
    });
  });

  group('doble: reglas de FacturaScripts para recibos', () {
    test('PUT importe sobre un recibo pagado: 400 sin cambios', () async {
      await api.call(
        'crearFacturaCliente',
        fields: {
          'codcliente': 'TPVVARIOS',
          'codpago': 'TPVEFE',
          'lineas': [menu().toFsJson()],
        },
      );
      final recibo = api.table('reciboclientes').single;
      await expectLater(
        api.update('reciboclientes', recibo['idrecibo']!, {'importe': '1.00'}),
        throwsA(isA<ErpApiException>()),
      );
      expect(cents(recibo['importe']), 1995);
    });

    test('pagar con codpago reescribe todos los recibos', () async {
      await service.crearOReanudar(ticketAbierto());
      await api.call('pagarFacturaCliente', path: [1], fields: {'pagada': 0});
      await api.call(
        'pagarFacturaCliente',
        path: [1],
        fields: {'pagada': 1, 'codpago': 'TPVEFE'},
      );
      expect(api.table('reciboclientes').map((r) => r['codpago']).toSet(), {
        'TPVEFE',
      });
    });
  });
}

/// Simula que la app muere en la escritura número [corte]: sin aplicarla o
/// aplicándola sin recibir la respuesta.
final class _CorteEnEscritura extends FakeFsApiDelegate {
  _CorteEnEscritura(super.inner, this.corte, {required this.perderRespuesta});

  final int corte;
  final bool perderRespuesta;
  int _escrituras = 0;

  Future<T> _escritura<T>(Future<T> Function() efecto) async {
    _escrituras++;
    if (_escrituras != corte) return efecto();
    if (perderRespuesta) await efecto();
    throw const ErpApiException('Conexión cortada (simulada)');
  }

  @override
  Future<FsRecord> create(String resource, Map<String, Object?> fields) =>
      _escritura(() => inner.create(resource, fields));

  @override
  Future<FsRecord> update(
    String resource,
    Object id,
    Map<String, Object?> fields,
  ) => _escritura(() => inner.update(resource, id, fields));

  @override
  Future<bool> delete(String resource, Object id) =>
      _escritura(() => inner.delete(resource, id));

  @override
  Future<FsRecord> call(
    String endpoint, {
    List<Object> path = const [],
    Map<String, Object?> fields = const {},
  }) => _escritura(() => inner.call(endpoint, path: path, fields: fields));
}

/// Borra la factura justo después de crearla (antes del cobro mixto).
final class _BorraAntesDeLeer extends FakeFsApiDelegate {
  _BorraAntesDeLeer(super.inner);

  @override
  Future<FsRecord?> get(String resource, Object id) async {
    if (resource == 'facturaclientes') {
      inner.table(resource).clear();
    }
    return inner.get(resource, id);
  }
}
