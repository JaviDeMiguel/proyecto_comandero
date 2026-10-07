import 'package:proyecto_comandero/core/errors/app_exception.dart';
import 'package:proyecto_comandero/core/facturascripts/accounting/accounting_models.dart';
import 'package:proyecto_comandero/core/facturascripts/accounting/fs_accounting_service.dart';
import 'package:test/test.dart';

import '../fake_fs_api.dart';

/// Descuadre de caja (faltante de 3,20 €): Debe 659 / Haber 570.
AsientoZ descuadre({String clave = 'Z-20261006-T1', int cents = 320}) =>
    AsientoZ(
      clave: clave,
      fecha: DateTime(2026, 10, 6, 23, 30),
      concepto: 'Cierre Z 06-10-2026 TPV1',
      lineas: [
        PartidaZ(
          codsubcuenta: '6590000000',
          concepto: 'Faltante de caja Z 06-10-2026',
          debeCents: cents,
        ),
        PartidaZ(
          codsubcuenta: '5700000000',
          concepto: 'Faltante de caja Z 06-10-2026',
          haberCents: cents,
        ),
      ],
    );

void main() {
  late FakeFsApi api;
  late FsAccountingService service;

  setUp(() {
    api = FakeFsApi.conDatosBasicos();
    service = FsAccountingService(api);
  });

  group('modelos', () {
    test('AsientoZ calcula sumas y cuadre', () {
      final z = descuadre();
      expect(z.debeTotalCents, 320);
      expect(z.haberTotalCents, 320);
      expect(z.cuadrado, isTrue);
      expect(z.clave, 'Z-20261006-T1');
    });

    test('validaciones de clave, concepto y partidas', () {
      expect(
        () => descuadre(clave: '06-10-2026'),
        throwsA(isA<ValidationException>()),
      );
      expect(
        () => AsientoZ(
          clave: 'Z-X',
          fecha: DateTime(2026),
          concepto: 'c',
          lineas: const [],
        ),
        throwsA(isA<ValidationException>()),
      );
      expect(
        () => PartidaZ(codsubcuenta: '5700000000', concepto: 'c'),
        throwsA(isA<ValidationException>()),
      );
      expect(
        () =>
            PartidaZ(codsubcuenta: '5700000000', concepto: 'c', debeCents: -1),
        throwsA(isA<ValidationException>()),
      );
      expect(
        () => PartidaZ(codsubcuenta: '5700000000', concepto: '', debeCents: 1),
        throwsA(isA<ValidationException>()),
      );
    });

    test('SubcuentasCierre.subcuentaIva cae a la 477 genérica', () {
      const s = SubcuentasCierre(
        codejercicio: '2026',
        porCuenta: {CuentaZ.ivaRepercutido477: '4770000000'},
        ivaPorCodimpuesto: {'IVA10': '4770000010'},
      );
      expect(s.subcuentaIva('IVA10'), '4770000010');
      expect(s.subcuentaIva('IVA0'), '4770000000');
      expect(s.subcuentaIva(null), '4770000000');
      expect(s[CuentaZ.ivaRepercutido477], '4770000000');
    });
  });

  group('contabilizarOReanudar', () {
    test('exige cuadre antes de tocar la API', () async {
      final z = AsientoZ(
        clave: 'Z-20261006-T1',
        fecha: DateTime(2026, 10, 6),
        concepto: 'c',
        lineas: [
          PartidaZ(codsubcuenta: '6590000000', concepto: 'c', debeCents: 320),
          PartidaZ(codsubcuenta: '5700000000', concepto: 'c', haberCents: 300),
        ],
      );
      expect(z.cuadrado, isFalse);
      await expectLater(
        service.contabilizarOReanudar(z),
        throwsA(
          isA<ValidationException>().having(
            (e) => e.message,
            'message',
            contains('descuadrado'),
          ),
        ),
      );
      expect(api.calls, isEmpty);
    });

    test('protocolo exacto: buscar, cabecera, partidas, verificar', () async {
      final result = await service.contabilizarOReanudar(descuadre());

      expect(result.idasiento, 1);
      expect(result.numero, 1);
      expect(result.yaExistia, isFalse);
      expect(result.partidasCreadas, 2);
      expect(result.verificado, isTrue);

      expect(api.calls.map((c) => '${c.method} ${c.resource}'), [
        'LIST asientos',
        'POST asientos',
        'POST partidas',
        'POST partidas',
        'LIST partidas',
      ]);
      expect(api.calls[0].filters, {'documento': 'Z-20261006-T1'});
      expect(api.calls[1].fields, {
        'fecha': '06-10-2026',
        'concepto': 'Cierre Z 06-10-2026 TPV1',
        'documento': 'Z-20261006-T1',
        'importe': '3.20',
      });
      expect(api.calls[2].fields, {
        'idasiento': 1,
        'codsubcuenta': '6590000000',
        'concepto': 'Faltante de caja Z 06-10-2026',
        'documento': 'Z-20261006-T1',
        'debe': '3.20',
        'haber': '0.00',
      });
      expect(api.calls[3].fields['codsubcuenta'], '5700000000');
      expect(api.calls[3].fields['debe'], '0.00');
      expect(api.calls[3].fields['haber'], '3.20');
      expect(api.calls[4].filters, {'idasiento': 1});
      expect(api.table('partidas'), hasLength(2));
      expect(api.table('partidas').first['idsubcuenta'], isNotNull);
    });

    test('partida de IVA lleva baseimponible e iva', () async {
      final z = AsientoZ(
        clave: 'Z-20261006-T2',
        fecha: DateTime(2026, 10, 6),
        concepto: 'Resumen',
        lineas: [
          PartidaZ(codsubcuenta: '5700000000', concepto: 'c', debeCents: 665),
          PartidaZ(codsubcuenta: '7000000000', concepto: 'c', haberCents: 605),
          PartidaZ(
            codsubcuenta: '4770000010',
            concepto: 'IVA 10%',
            haberCents: 60,
            baseCents: 605,
            ivaPct: 10,
          ),
        ],
      );
      await service.contabilizarOReanudar(z);
      final iva = api.callsTo('partidas', method: 'POST').last.fields;
      expect(iva['baseimponible'], '6.05');
      expect(iva['iva'], 10.0);
      final caja = api.callsTo('partidas', method: 'POST').first.fields;
      expect(caja, isNot(contains('baseimponible')));
      expect(caja, isNot(contains('iva')));
    });

    test('reanudación con partidas completas: no toca nada', () async {
      final first = await service.contabilizarOReanudar(descuadre());
      api.calls.clear();

      final second = await service.contabilizarOReanudar(descuadre());

      expect(second.yaExistia, isTrue);
      expect(second.idasiento, first.idasiento);
      expect(second.numero, 1);
      expect(second.partidasCreadas, 0);
      expect(second.verificado, isTrue);
      expect(api.calls.map((c) => '${c.method} ${c.resource}'), [
        'LIST asientos',
        'LIST partidas',
      ]);
      expect(api.table('asientos'), hasLength(1));
      expect(api.table('partidas'), hasLength(2));
    });

    test('reanudación con partidas incompletas: borra y recrea', () async {
      // Se perdió la respuesta de la segunda partida: el ERP la guardó pero
      // el TPV no lo sabe. El asiento queda con 1 partida de 2.
      api.failOn(
        'partidas',
        nth: 2,
        method: 'POST',
        error: const ErpApiException('timeout'),
      );
      await expectLater(
        service.contabilizarOReanudar(descuadre()),
        throwsA(isA<ErpApiException>()),
      );
      // La compensación borró el asiento; simulamos que NO pudo (p. ej. el
      // corte siguió): dejamos a mano un asiento a medias con la clave.
      final huerfano = api.seed('asientos', {
        'fecha': '06-10-2026',
        'concepto': 'Cierre Z 06-10-2026 TPV1',
        'documento': 'Z-20261006-T1',
        'codejercicio': '2026',
        'importe': 3.2,
        'editable': true,
        'numero': 7,
      });
      api.seed('partidas', {
        'idasiento': huerfano['idasiento'],
        'codsubcuenta': '6590000000',
        'concepto': 'x',
        'debe': 3.2,
        'haber': 0.0,
      });
      api.calls.clear();

      final result = await service.contabilizarOReanudar(descuadre());

      expect(result.yaExistia, isFalse);
      expect(result.idasiento, isNot(huerfano['idasiento']));
      expect(result.partidasCreadas, 2);
      expect(result.verificado, isTrue);
      expect(api.calls.map((c) => '${c.method} ${c.resource}'), [
        'LIST asientos',
        'LIST partidas',
        'DELETE asientos',
        'POST asientos',
        'POST partidas',
        'POST partidas',
        'LIST partidas',
      ]);
      expect(
        api.callsTo('asientos', method: 'DELETE').single.id,
        huerfano['idasiento'],
      );
      expect(api.table('asientos'), hasLength(1));
      expect(api.table('partidas'), hasLength(2));
      expect(
        api.table('partidas').every((p) => p['idasiento'] == result.idasiento),
        isTrue,
      );
    });

    test('partidas con sumas distintas también se recrean', () async {
      final viejo = api.seed('asientos', {
        'fecha': '06-10-2026',
        'concepto': 'c',
        'documento': 'Z-20261006-T1',
        'codejercicio': '2026',
        'importe': 1.0,
        'editable': true,
      });
      for (final (sub, debe, haber) in [
        ('6590000000', 1.0, 0.0),
        ('5700000000', 0.0, 1.0),
      ]) {
        api.seed('partidas', {
          'idasiento': viejo['idasiento'],
          'codsubcuenta': sub,
          'concepto': 'c',
          'debe': debe,
          'haber': haber,
        });
      }

      final result = await service.contabilizarOReanudar(descuadre());
      expect(result.yaExistia, isFalse);
      expect(api.callsTo('asientos', method: 'DELETE'), hasLength(1));
      final partidas = api.table('partidas');
      expect(partidas, hasLength(2));
      expect(partidas.map((p) => p['debe']), ['3.20', '0.00']);
    });

    test(
      'fallo en una partida: compensación y error con el idasiento',
      () async {
        api.failOn(
          'partidas',
          nth: 2,
          method: 'POST',
          error: const ErpApiException(
            'record-save-error',
            statusCode: 400,
            responseBody: '{"error":"record-save-error - idsubcuenta nulo"}',
          ),
        );

        await expectLater(
          service.contabilizarOReanudar(descuadre()),
          throwsA(
            isA<ErpApiException>()
                .having((e) => e.statusCode, 'statusCode', 400)
                .having((e) => e.message, 'message', contains('idasiento 1'))
                .having((e) => e.message, 'message', contains('1/2 creadas'))
                .having(
                  (e) => e.message,
                  'message',
                  contains('asiento 1 borrado'),
                )
                .having((e) => e.responseBody, 'responseBody', contains('nulo'))
                .having((e) => e.cause, 'cause', isA<ErpApiException>()),
          ),
        );
        expect(api.calls.map((c) => '${c.method} ${c.resource}'), [
          'LIST asientos',
          'POST asientos',
          'POST partidas',
          'POST partidas',
          'DELETE asientos',
        ]);
        expect(api.table('asientos'), isEmpty);
        expect(api.table('partidas'), isEmpty, reason: 'borrado en cascada');
      },
    );

    test('fallo en una partida y en la compensación: lo dice', () async {
      api.failOn(
        'partidas',
        nth: 1,
        method: 'POST',
        error: const ErpApiException('500', statusCode: 500),
      );
      api.failOn(
        'asientos',
        nth: 1,
        method: 'DELETE',
        error: const ErpApiException('timeout'),
      );
      await expectLater(
        service.contabilizarOReanudar(descuadre()),
        throwsA(
          isA<ErpApiException>()
              .having((e) => e.statusCode, 'statusCode', 500)
              .having(
                (e) => e.message,
                'message',
                contains('NO se pudo borrar'),
              ),
        ),
      );
      expect(api.table('asientos'), hasLength(1), reason: 'quedó huérfano');

      // La siguiente reanudación lo encuentra incompleto y lo recrea.
      final result = await service.contabilizarOReanudar(descuadre());
      expect(result.verificado, isTrue);
      expect(api.table('asientos'), hasLength(1));
      expect(api.table('partidas'), hasLength(2));
    });

    test(
      'subcuenta inexistente en el ejercicio: error 400 y compensación',
      () async {
        final z = AsientoZ(
          clave: 'Z-20261006-T9',
          fecha: DateTime(2026, 10, 6),
          concepto: 'c',
          lineas: [
            PartidaZ(codsubcuenta: '6780000000', concepto: 'c', debeCents: 100),
            PartidaZ(
              codsubcuenta: '5700000000',
              concepto: 'c',
              haberCents: 100,
            ),
          ],
        );
        await expectLater(
          service.contabilizarOReanudar(z),
          throwsA(
            isA<ErpApiException>().having(
              (e) => e.kind,
              'kind',
              ErpApiErrorKind.validation,
            ),
          ),
        );
        expect(api.table('asientos'), isEmpty);
      },
    );

    test(
      'fallo de red en la verificación: creado pero no verificado',
      () async {
        api.failOn(
          'partidas',
          nth: 1,
          method: 'LIST',
          error: const ErpApiException('timeout'),
        );
        final result = await service.contabilizarOReanudar(descuadre());
        expect(result.verificado, isFalse);
        expect(result.partidasCreadas, 2);
        expect(api.table('partidas'), hasLength(2));

        final again = await service.contabilizarOReanudar(descuadre());
        expect(again.yaExistia, isTrue);
        expect(again.verificado, isTrue);
      },
    );

    test('dos asientos con la misma clave: ValidationException', () async {
      await service.contabilizarOReanudar(descuadre());
      api.seed('asientos', {
        'documento': 'Z-20261006-T1',
        'concepto': 'otro',
        'codejercicio': '2026',
      });
      await expectLater(
        service.contabilizarOReanudar(descuadre()),
        throwsA(isA<ValidationException>()),
      );
    });
  });

  group('resolverSubcuentas', () {
    test('resuelve las seis cuentas y el IVA por impuesto', () async {
      final s = await service.resolverSubcuentas(
        DateTime(2026, 10, 6),
        idempresa: 1,
      );

      expect(s.codejercicio, '2026');
      expect(s.porCuenta, {
        CuentaZ.caja570: '5700000000',
        CuentaZ.banco572: '5720000000',
        CuentaZ.ventas700: '7000000000',
        CuentaZ.ivaRepercutido477: '4770000000',
        CuentaZ.perdidas659: '6590000000',
        CuentaZ.ingresos759: '7590000000',
      });
      expect(s.ivaPorCodimpuesto, {
        'IVA4': '4770000004',
        'IVA10': '4770000010',
        'IVA21': '4770000021',
      });
      expect(s.subcuentaIva('IVA0'), '4770000000');

      final ejercicio = api.callsTo('ejercicios').single;
      expect(ejercicio.filters, {
        'idempresa': 1,
        'estado': 'ABIERTO',
        'fechainicio_lte': '2026-10-06',
        'fechafin_gte': '2026-10-06',
      });
      final sub570 = api.callsTo('subcuentas').first;
      expect(sub570.filters, {'codejercicio': '2026', 'codcuenta': '570'});
      expect(sub570.limit, 1);
      expect(api.callsTo('subcuentas'), hasLength(6));
    });

    test('la 477 genérica es la primera por codsubcuenta', () async {
      final s = await service.resolverSubcuentas(
        DateTime(2026, 3, 1),
        idempresa: 1,
      );
      expect(s[CuentaZ.ivaRepercutido477], '4770000000');
    });

    test('cache por ejercicio: la segunda llamada no consulta', () async {
      await service.resolverSubcuentas(DateTime(2026, 1, 1), idempresa: 1);
      api.calls.clear();

      final s = await service.resolverSubcuentas(
        DateTime(2026, 12, 31),
        idempresa: 1,
      );

      expect(s.codejercicio, '2026');
      expect(api.calls, isEmpty);
    });

    test('la caché caduca con el reloj inyectado', () async {
      var now = DateTime(2026, 10, 6, 8);
      service = FsAccountingService(api, now: () => now);
      await service.resolverSubcuentas(DateTime(2026, 10, 6), idempresa: 1);
      api.calls.clear();

      now = now.add(FsAccountingService.cacheTtl + const Duration(minutes: 1));
      await service.resolverSubcuentas(DateTime(2026, 10, 6), idempresa: 1);
      expect(api.callsTo('subcuentas'), hasLength(6));
      expect(api.callsTo('ejercicios'), isEmpty, reason: 'ejercicio conocido');

      api.calls.clear();
      service.invalidarCache();
      await service.resolverSubcuentas(DateTime(2026, 10, 6), idempresa: 1);
      expect(api.callsTo('ejercicios'), hasLength(1));
    });

    test('overrides: sustituyen y se comprueba que existen', () async {
      api.seed('subcuentas', {
        'codejercicio': '2026',
        'codcuenta': '678',
        'codsubcuenta': '6780000000',
        'descripcion': 'Gastos excepcionales',
      });
      final s = await service.resolverSubcuentas(
        DateTime(2026, 10, 6),
        idempresa: 1,
        overrides: const {CuentaZ.perdidas659: '6780000000'},
      );
      expect(s[CuentaZ.perdidas659], '6780000000');
      expect(s[CuentaZ.caja570], '5700000000');
      final check = api.callsTo('subcuentas').last;
      expect(check.filters, {
        'codejercicio': '2026',
        'codsubcuenta': '6780000000',
      });

      api.calls.clear();
      await service.resolverSubcuentas(
        DateTime(2026, 10, 6),
        idempresa: 1,
        overrides: const {CuentaZ.perdidas659: '6780000000'},
      );
      expect(api.calls, isEmpty, reason: 'override verificado en caché');

      await expectLater(
        service.resolverSubcuentas(
          DateTime(2026, 10, 6),
          idempresa: 1,
          overrides: const {CuentaZ.caja570: '5709999999'},
        ),
        throwsA(
          isA<ConfigException>()
              .having((e) => e.message, 'message', contains('5709999999'))
              .having((e) => e.message, 'message', contains('570')),
        ),
      );
    });

    test('faltan subcuentas: ConfigException dice cuáles', () async {
      api
          .table('subcuentas')
          .removeWhere(
            (s) => s['codcuenta'] == '659' || s['codcuenta'] == '759',
          );
      await expectLater(
        service.resolverSubcuentas(DateTime(2026, 10, 6), idempresa: 1),
        throwsA(
          isA<ConfigException>()
              .having((e) => e.message, 'message', contains('2026'))
              .having((e) => e.message, 'message', contains('659'))
              .having((e) => e.message, 'message', contains('759'))
              .having((e) => e.message, 'message', isNot(contains('570 ('))),
        ),
      );
    });

    test('sin ejercicio abierto para la fecha: ConfigException', () async {
      await expectLater(
        service.resolverSubcuentas(DateTime(2027, 1, 1), idempresa: 1),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains('2027-01-01'),
          ),
        ),
      );
      await expectLater(
        service.resolverSubcuentas(DateTime(2026, 6, 1), idempresa: 2),
        throwsA(isA<ConfigException>()),
      );
    });

    test('ejercicio cerrado no vale', () async {
      api.find('ejercicios', '2026')!['estado'] = 'CERRADO';
      await expectLater(
        service.resolverSubcuentas(DateTime(2026, 6, 1), idempresa: 1),
        throwsA(isA<ConfigException>()),
      );
    });
  });

  group('hayFacturasConAsiento', () {
    test('filtra por fecha ISO, serie e idasiento no nulo', () async {
      api.seed('facturaclientes', {
        'fecha': '06-10-2026',
        'codserie': 'S',
        'idasiento': 5,
      });
      api.seed('facturaclientes', {
        'fecha': '06-10-2026',
        'codserie': 'A',
        'idasiento': 6,
      });
      api.seed('facturaclientes', {
        'fecha': '06-10-2026',
        'codserie': 'S',
        'idasiento': null,
      });

      expect(
        await service.hayFacturasConAsiento(
          fecha: DateTime(2026, 10, 6, 14),
          codserie: 'S',
        ),
        isTrue,
      );
      expect(api.calls.single.filters, {
        'fecha': '2026-10-06',
        'codserie': 'S',
        'idasiento_notnull': 1,
      });
      expect(api.calls.single.limit, 1);

      expect(
        await service.hayFacturasConAsiento(
          fecha: DateTime(2026, 10, 7),
          codserie: 'S',
        ),
        isFalse,
      );
      expect(
        await service.hayFacturasConAsiento(
          fecha: DateTime(2026, 10, 6),
          codserie: 'R',
        ),
        isFalse,
      );
    });
  });
}
