import 'package:proyecto_comandero/core/errors/app_exception.dart';
import 'package:proyecto_comandero/core/facturascripts/documents/fs_invoice_service.dart';
import 'package:proyecto_comandero/core/facturascripts/documents/invoice_models.dart';
import 'package:proyecto_comandero/core/facturascripts/fs_api.dart';
import 'package:test/test.dart';

import '../fake_fs_api.dart';

TicketFactura ticket({
  String clave = 'TPV-T1-0001',
  String codpago = 'TPVEFE',
  ModoPago modoPago = ModoPago.nacePagada,
  bool emitir = false,
  int? idEstadoEmitida,
  int totalEsperadoCents = 665,
  List<LineaFactura>? lineas,
  String? observaciones = 'Mesa 12 · Ana',
  List<PagoFactura> pagos = const [],
}) => TicketFactura(
  claveIdempotente: clave,
  codcliente: 'TPVVARIOS',
  codserie: 'S',
  codpago: codpago,
  codalmacen: 'ALG',
  fechaHora: DateTime(2026, 10, 6, 21, 15, 3),
  observaciones: observaciones,
  lineas:
      lineas ??
      [
        LineaFactura(
          referencia: 'CANA',
          descripcion: 'Caña',
          cantidad: 7,
          pvpunitarioNeto: 0.86364,
          codimpuesto: 'IVA10',
        ),
      ],
  totalEsperadoCents: totalEsperadoCents,
  modoPago: modoPago,
  pagos: pagos,
  emitir: emitir,
  idEstadoEmitida: idEstadoEmitida,
);

/// Fecha y hora con las que el doble guarda la factura al simular el relleno
/// de un hueco de numeración (distintas de las del ticket, 06-10-2026
/// 21:15:03).
final DateTime fechaHuecoFs = DateTime(2026, 10, 5, 23, 59, 58);

void main() {
  late FakeFsApi api;
  late FsInvoiceService service;

  setUp(() {
    api = FakeFsApi.conDatosBasicos();
    service = FsInvoiceService(api);
  });

  group('camino feliz', () {
    test(
      'nacePagada: una consulta y un crearFacturaCliente, sin pagar',
      () async {
        final result = await service.crearOReanudar(ticket());

        expect(result.yaExistia, isFalse);
        expect(result.idfactura, 1);
        expect(result.codigo, 'F2026S1');
        expect(result.numero, '1');
        expect(result.totalCents, 665);
        expect(result.pagada, isTrue);
        expect(result.idasiento, isNotNull);
        expect(result.emitida, isFalse);
        expect(result.avisos, isEmpty);

        expect(api.calls.map((c) => '${c.method} ${c.resource}'), [
          'LIST facturaclientes',
          'CALL crearFacturaCliente',
        ]);
        expect(api.calls.first.filters, {'numero2': 'TPV-T1-0001'});
        expect(api.calls.first.limit, 2);
        expect(api.table('facturaclientes'), hasLength(1));
      },
    );

    test('pagarTrasCrear: paga con fechapago del ticket y codpago', () async {
      final result = await service.crearOReanudar(
        ticket(codpago: 'TPVTAR', modoPago: ModoPago.pagarTrasCrear),
      );

      expect(result.pagada, isTrue);
      expect(result.avisos, isEmpty);
      final pago = api.callsTo('pagarFacturaCliente').single;
      expect(pago.id, '1');
      expect(pago.fields, {
        'pagada': 1,
        'fechapago': '06-10-2026',
        'codpago': 'TPVTAR',
      });
      expect(api.table('reciboclientes').single['pagado'], isTrue);
    });

    test(
      'envía exactamente los campos permitidos, con lineas como JSON',
      () async {
        await service.crearOReanudar(
          ticket(
            lineas: [
              LineaFactura(
                referencia: 'CANA',
                descripcion: 'Caña',
                cantidad: 7,
                pvpunitarioNeto: 0.86364,
                codimpuesto: 'IVA10',
              ),
              LineaFactura(
                descripcion: 'Pan',
                cantidad: 1,
                pvpunitarioNeto: 0.909090909,
                codimpuesto: 'IVA10',
              ),
            ],
            totalEsperadoCents: 765,
          ),
        );

        final fields = api.callsTo('crearFacturaCliente').single.fields;
        expect(fields.keys.toSet(), {
          'codcliente',
          'codserie',
          'codpago',
          'codalmacen',
          'fecha',
          'hora',
          'numero2',
          'observaciones',
          'lineas',
        });
        expect(fields['fecha'], '06-10-2026');
        expect(fields['hora'], '21:15:03');
        expect(fields['numero2'], 'TPV-T1-0001');
        expect(fields['observaciones'], 'Mesa 12 · Ana');
        expect(fields['lineas'], [
          {
            'referencia': 'CANA',
            'descripcion': 'Caña',
            'cantidad': 7.0,
            'pvpunitario': 0.86364,
            'codimpuesto': 'IVA10',
          },
          {
            'descripcion': 'Pan',
            'cantidad': 1.0,
            'pvpunitario': 0.90909,
            'codimpuesto': 'IVA10',
          },
        ]);
        for (final prohibido in FakeFsApi.camposProhibidosFactura) {
          expect(fields, isNot(contains(prohibido)));
        }
        expect(fields, isNot(contains('pagada')));
      },
    );

    test('sin observaciones no se envía el campo', () async {
      await service.crearOReanudar(ticket(observaciones: null));
      expect(
        api.callsTo('crearFacturaCliente').single.fields,
        isNot(contains('observaciones')),
      );
    });

    test('pagada nunca viaja como texto true/false', () async {
      await service.crearOReanudar(
        ticket(codpago: 'CONT', modoPago: ModoPago.pagarTrasCrear),
      );
      final pagada = api.callsTo('pagarFacturaCliente').single.fields['pagada'];
      expect(pagada, isA<int>());
      expect(pagada, 1);
    });
  });

  group('avisos', () {
    test('total distinto al del TPV: aviso, nunca segunda factura', () async {
      final result = await service.crearOReanudar(
        ticket(totalEsperadoCents: 700),
      );

      expect(result.totalCents, 665);
      expect(result.avisos, ['Total FacturaScripts 6,65 € ≠ TPV 7,00 €']);
      expect(api.callsTo('crearFacturaCliente'), hasLength(1));
    });

    test('nacePagada con forma de pago que no nace pagada: aviso', () async {
      final result = await service.crearOReanudar(ticket(codpago: 'CONT'));

      expect(result.pagada, isFalse);
      expect(result.avisos, hasLength(1));
      expect(result.avisos.single, contains("'CONT'"));
      expect(api.callsTo('pagarFacturaCliente'), isEmpty);
    });

    test('factura sin asiento: aviso', () async {
      api.generaAsientos = false;
      final result = await service.crearOReanudar(ticket());

      expect(result.idasiento, isNull);
      expect(result.avisos.single, contains('sin asiento'));
    });
  });

  group('idempotencia', () {
    test('respuesta perdida al crear: la reanudación no crea otra', () async {
      api.loseResponseOn('crearFacturaCliente', nth: 1);
      final t = ticket(codpago: 'TPVTAR', modoPago: ModoPago.pagarTrasCrear);

      await expectLater(
        service.crearOReanudar(t),
        throwsA(
          isA<ErpApiException>().having(
            (e) => e.outcomeUnknown,
            'outcomeUnknown',
            isTrue,
          ),
        ),
      );
      expect(api.table('facturaclientes'), hasLength(1));
      expect(api.callsTo('pagarFacturaCliente'), isEmpty);

      final result = await service.crearOReanudar(t);

      expect(result.yaExistia, isTrue);
      expect(result.idfactura, 1);
      expect(result.pagada, isTrue);
      expect(api.table('facturaclientes'), hasLength(1));
      expect(api.callsTo('crearFacturaCliente'), hasLength(1));
      expect(api.callsTo('pagarFacturaCliente'), hasLength(1));
    });

    test('fallo en pagar: la reanudación solo paga', () async {
      api.failOn(
        'pagarFacturaCliente',
        nth: 1,
        error: const ErpApiException('500', statusCode: 500),
      );
      final t = ticket(codpago: 'TPVTAR', modoPago: ModoPago.pagarTrasCrear);

      await expectLater(
        service.crearOReanudar(t),
        throwsA(
          isA<ErpApiException>().having(
            (e) => e.kind,
            'kind',
            ErpApiErrorKind.server,
          ),
        ),
      );

      final result = await service.crearOReanudar(t);
      expect(result.yaExistia, isTrue);
      expect(result.pagada, isTrue);
      expect(api.callsTo('crearFacturaCliente'), hasLength(1));
      expect(api.callsTo('pagarFacturaCliente'), hasLength(2));
    });

    test('segunda llamada completa: no toca nada', () async {
      final first = await service.crearOReanudar(ticket());
      api.calls.clear();
      final second = await service.crearOReanudar(ticket());

      expect(second.yaExistia, isTrue);
      expect(second.idfactura, first.idfactura);
      expect(second.codigo, first.codigo);
      expect(api.calls.map((c) => c.method), ['LIST']);
    });

    test(
      'dos facturas con la misma clave en FS: ValidationException',
      () async {
        await service.crearOReanudar(ticket());
        api.seed('facturaclientes', {
          'numero2': 'TPV-T1-0001',
          'codigo': 'F2026S99',
          'total': 1.0,
        });

        await expectLater(
          service.crearOReanudar(ticket()),
          throwsA(
            isA<ValidationException>().having(
              (e) => e.message,
              'message',
              contains('duplicada'),
            ),
          ),
        );
      },
    );
  });

  group('emisión', () {
    test('emite con PUT de SOLO idestado cuando difiere', () async {
      final result = await service.crearOReanudar(
        ticket(emitir: true, idEstadoEmitida: 11),
      );

      expect(result.emitida, isTrue);
      final put = api.callsTo('facturaclientes', method: 'PUT').single;
      expect(put.id, 1);
      expect(put.fields, {'idestado': 11});
      expect(api.find('facturaclientes', 1)!['idestado'], 11);
    });

    test('ya emitida: no hay PUT', () async {
      await service.crearOReanudar(ticket(emitir: true, idEstadoEmitida: 11));
      api.calls.clear();

      final result = await service.crearOReanudar(
        ticket(emitir: true, idEstadoEmitida: 11),
      );

      expect(result.emitida, isTrue);
      expect(result.yaExistia, isTrue);
      expect(api.callsTo('facturaclientes', method: 'PUT'), isEmpty);
    });

    test('se emite después de cobrar', () async {
      await service.crearOReanudar(
        ticket(
          codpago: 'TPVTAR',
          modoPago: ModoPago.pagarTrasCrear,
          emitir: true,
          idEstadoEmitida: 11,
        ),
      );
      expect(api.calls.map((c) => c.method), ['LIST', 'CALL', 'CALL', 'PUT']);
    });
  });

  group('errores', () {
    test('422 del ERP se propaga tal cual', () async {
      api.failOn(
        'crearFacturaCliente',
        nth: 1,
        error: const ErpApiException('record-save-error', statusCode: 422),
      );
      await expectLater(
        service.crearOReanudar(ticket()),
        throwsA(
          isA<ErpApiException>().having(
            (e) => e.kind,
            'kind',
            ErpApiErrorKind.validation,
          ),
        ),
      );
      expect(api.table('facturaclientes'), isEmpty);
    });

    test('respuesta sin doc: ErpApiException unexpected', () async {
      final rota = _RespuestaRota(api);
      await expectLater(
        FsInvoiceService(rota).crearOReanudar(ticket()),
        throwsA(
          isA<ErpApiException>()
              .having((e) => e.kind, 'kind', ErpApiErrorKind.unexpected)
              .having((e) => e.cause, 'cause', isA<FormatException>()),
        ),
      );
    });
  });

  group('validación del ticket', () {
    test('clave que parece una fecha', () {
      expect(
        () => ticket(clave: '06-10-2026'),
        throwsA(isA<ValidationException>()),
      );
      expect(
        () => ticket(clave: '2026-10-06 21:15:00'),
        throwsA(isA<ValidationException>()),
      );
    });

    test('clave de más de 50 caracteres', () {
      expect(
        () => ticket(clave: 'TPV-${'x' * 50}'),
        throwsA(isA<ValidationException>()),
      );
      expect(ticket(clave: 'TPV-${'x' * 46}').claveIdempotente, hasLength(50));
    });

    test('clave vacía, sin líneas, emitir sin estado', () {
      expect(() => ticket(clave: '  '), throwsA(isA<ValidationException>()));
      expect(() => ticket(lineas: []), throwsA(isA<ValidationException>()));
      expect(() => ticket(emitir: true), throwsA(isA<ValidationException>()));
    });

    test('la línea redondea el neto a 5 decimales en el JSON', () {
      final linea = LineaFactura(
        descripcion: 'x',
        cantidad: 1,
        pvpunitarioNeto: 1.1818181818,
        codimpuesto: 'IVA10',
      );
      expect(linea.toFsJson()['pvpunitario'], 1.18182);
      expect(linea.toFsJson(), isNot(contains('referencia')));
    });
  });

  group('fecha y total de FS', () {
    test('salen del doc de crearFacturaCliente, sin releer', () async {
      final result = await service.crearOReanudar(ticket());

      expect(result.fecha, DateTime(2026, 10, 6, 21, 15, 3));
      expect(result.totalFsCents, 665);
      expect(result.totalCents, 665);
      expect(api.callsTo('facturaclientes', method: 'GET'), isEmpty);
    });

    test('al reanudar una factura existente salen del listado', () async {
      api.fechaHoraRellenoHueco = fechaHuecoFs;
      final first = await service.crearOReanudar(ticket());
      api.calls.clear();

      final second = await service.crearOReanudar(ticket());

      expect(second.yaExistia, isTrue);
      expect(second.fecha, fechaHuecoFs);
      expect(second.fecha, first.fecha);
      expect(second.totalFsCents, 665);
      expect(api.calls.map((c) => c.method), ['LIST']);
    });

    test('sin hora se toma 00:00:00', () async {
      api.seed('facturaclientes', {
        'numero2': 'TPV-T1-0001',
        'codigo': 'F2026S1',
        'numero': '1',
        'fecha': '06-10-2026',
        'total': 6.65,
        'pagada': true,
        'idasiento': 7,
      });

      final result = await service.crearOReanudar(ticket());

      expect(result.yaExistia, isTrue);
      expect(result.fecha, DateTime(2026, 10, 6));
      expect(result.totalFsCents, 665);
      expect(result.avisos, isEmpty);
    });

    test('sin total en la respuesta: relee GET facturaclientes/{id}', () async {
      api.camposSinDevolverAlCrear = const {'total'};

      final result = await service.crearOReanudar(ticket());

      expect(result.totalFsCents, 665);
      expect(result.totalCents, 665);
      expect(result.fecha, DateTime(2026, 10, 6, 21, 15, 3));
      expect(result.avisos, isEmpty);
      expect(api.calls.map((c) => '${c.method} ${c.resource}'), [
        'LIST facturaclientes',
        'CALL crearFacturaCliente',
        'GET facturaclientes',
      ]);
      expect(api.calls.last.id, 1);
    });

    test('sin fecha en la respuesta: una sola relectura', () async {
      api.camposSinDevolverAlCrear = const {'fecha', 'hora'};

      final result = await service.crearOReanudar(ticket());

      expect(result.fecha, DateTime(2026, 10, 6, 21, 15, 3));
      expect(result.totalFsCents, 665);
      expect(result.avisos, isEmpty);
      expect(api.callsTo('facturaclientes', method: 'GET'), hasLength(1));
    });

    test(
      'si tampoco el GET trae el total: null, nunca el del ticket',
      () async {
        final sinTotal = _SinCampos(api, const {'total'});

        final result = await FsInvoiceService(sinTotal)
            .crearOReanudar(ticket(totalEsperadoCents: 700));

        expect(result.totalFsCents, isNull);
        expect(result.totalCents, 700, reason: 'totalCents: el del ticket');
        expect(result.fecha, DateTime(2026, 10, 6, 21, 15, 3));
        expect(result.avisos, [
          'FacturaScripts no devolvió el total de la factura',
        ]);
        expect(api.callsTo('facturaclientes', method: 'GET'), hasLength(1));
        expect(api.callsTo('crearFacturaCliente'), hasLength(1));
      },
    );

    test(
      'si tampoco el GET trae la fecha: null, nunca la del ticket',
      () async {
        final sinFecha = _SinCampos(api, const {'fecha'});

        final result = await FsInvoiceService(sinFecha)
            .crearOReanudar(ticket());

        expect(result.fecha, isNull);
        expect(result.totalFsCents, 665);
        expect(result.avisos, [
          'FacturaScripts no devolvió la fecha de la factura',
        ]);
        expect(api.callsTo('facturaclientes', method: 'GET'), hasLength(1));
      },
    );

    test('relleno de huecos: la fecha es la de FS, no la del ticket', () async {
      api.fechaHoraRellenoHueco = fechaHuecoFs;

      final result = await service.crearOReanudar(ticket());

      final enviados = api.callsTo('crearFacturaCliente').single.fields;
      expect(enviados['fecha'], '06-10-2026');
      expect(enviados['hora'], '21:15:03');
      expect(result.fecha, fechaHuecoFs);
      expect(result.totalFsCents, 665);
      expect(result.avisos, isEmpty);
      expect(api.callsTo('facturaclientes', method: 'GET'), isEmpty);
    });

    test(
      'relleno de huecos con pagarTrasCrear: se conserva la de FS',
      () async {
        api.fechaHoraRellenoHueco = fechaHuecoFs;

        final result = await service.crearOReanudar(
          ticket(codpago: 'TPVTAR', modoPago: ModoPago.pagarTrasCrear),
        );

        expect(result.pagada, isTrue);
        expect(result.fecha, fechaHuecoFs);
        expect(result.totalFsCents, 665);
      },
    );

    test('cobro mixto: conserva la fecha y el total de FS', () async {
      api.fechaHoraRellenoHueco = fechaHuecoFs;

      final result = await service.crearOReanudar(
        ticket(
          codpago: 'TPVTAR',
          modoPago: ModoPago.pagarTrasCrear,
          pagos: [
            PagoFactura(codpago: 'TPVEFE', importeCents: 365, efectivo: true),
            PagoFactura(codpago: 'TPVTAR', importeCents: 300),
          ],
        ),
      );

      expect(result.cobroMixto, isTrue);
      expect(result.pagada, isTrue);
      expect(result.fecha, fechaHuecoFs);
      expect(result.totalFsCents, 665);
      expect(result.totalCents, 665);
      expect(result.avisos, isEmpty);
    });

    test('ResultadoFactura: opcionales (nulos) y parte de la igualdad', () {
      const sinFs = ResultadoFactura(
        idfactura: 1,
        codigo: 'F2026S1',
        numero: '1',
        totalCents: 665,
        pagada: true,
        idasiento: 1,
        emitida: false,
        yaExistia: false,
        avisos: [],
      );
      final conFs = ResultadoFactura(
        idfactura: 1,
        codigo: 'F2026S1',
        numero: '1',
        fecha: DateTime(2026, 10, 6, 21, 15, 3),
        totalCents: 665,
        totalFsCents: 665,
        pagada: true,
        idasiento: 1,
        emitida: false,
        yaExistia: false,
        avisos: const [],
      );

      expect(sinFs.fecha, isNull);
      expect(sinFs.totalFsCents, isNull);
      expect(conFs, isNot(equals(sinFs)));
      expect(conFs.props, containsAll([conFs.fecha, conFs.totalFsCents]));
    });
  });

  group('doble: totales classic', () {
    test('tres líneas con dos tipos de IVA (ejemplo 2 del informe)', () async {
      final result = await service.crearOReanudar(
        ticket(
          lineas: [
            LineaFactura(
              descripcion: 'A',
              cantidad: 2,
              pvpunitarioNeto: 4.54545,
              codimpuesto: 'IVA10',
            ),
            LineaFactura(
              descripcion: 'B',
              cantidad: 1,
              pvpunitarioNeto: 11.157021,
              codimpuesto: 'IVA21',
            ),
            LineaFactura(
              descripcion: 'C',
              cantidad: 3,
              pvpunitarioNeto: 1.36364,
              codimpuesto: 'IVA10',
            ),
          ],
          totalEsperadoCents: 2800,
        ),
      );
      expect(result.totalCents, 2800);
      expect(result.avisos, isEmpty);
      final doc = api.find('facturaclientes', 1)!;
      expect(doc['neto'], 24.34);
      expect(doc['totaliva'], 3.66);
    });
  });
}

/// Quita [campos] de la factura tanto en el `doc` de `crearFacturaCliente`
/// como en los GET: FacturaScripts no los devuelve ni al releer.
final class _SinCampos extends FakeFsApiDelegate {
  _SinCampos(super.inner, this.campos);

  final Set<String> campos;

  @override
  Future<FsRecord?> get(String resource, Object id) async {
    final record = await inner.get(resource, id);
    return record == null ? null : _filtrar(record);
  }

  @override
  Future<FsRecord> call(
    String endpoint, {
    List<Object> path = const [],
    Map<String, Object?> fields = const {},
  }) async {
    final response = await inner.call(endpoint, path: path, fields: fields);
    final doc = response['doc'];
    return doc is FsRecord ? {...response, 'doc': _filtrar(doc)} : response;
  }

  FsRecord _filtrar(FsRecord record) => {
    for (final MapEntry(:key, :value) in record.entries)
      if (!campos.contains(key)) key: value,
  };
}

/// Devuelve una respuesta de `crearFacturaCliente` sin `doc`.
final class _RespuestaRota extends FakeFsApiDelegate {
  _RespuestaRota(super.inner);

  @override
  Future<Map<String, Object?>> call(
    String endpoint, {
    List<Object> path = const [],
    Map<String, Object?> fields = const {},
  }) async {
    await inner.call(endpoint, path: path, fields: fields);
    return {'lines': <Object?>[]};
  }
}
