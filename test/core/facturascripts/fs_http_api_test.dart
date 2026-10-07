import 'dart:async';
import 'dart:io';

import 'package:proyecto_comandero/core/errors/app_exception.dart';
import 'package:proyecto_comandero/core/facturascripts/fs_api.dart';
import 'package:proyecto_comandero/core/facturascripts/fs_api_config.dart';
import 'package:proyecto_comandero/core/facturascripts/fs_http_api.dart';
import 'package:proyecto_comandero/core/facturascripts/fs_values.dart';
import 'package:test/test.dart';

import 'fs_fake_server.dart';

const _token = 'clave-de-prueba-1234567890';

void main() {
  late FsFakeServer server;
  late FsHttpApi api;
  late DateTime clock;

  FsHttpApi buildApi({Duration? requestTimeout}) => FsHttpApi(
    FsApiConfig(
      baseUrl: '${server.baseUrl}/',
      token: _token,
      requestTimeout: requestTimeout ?? const Duration(seconds: 5),
    ),
    now: () => clock,
  );

  setUp(() async {
    server = await FsFakeServer.start();
    clock = DateTime(2026, 10, 7, 12, 0, 0);
    api = buildApi();
  });

  tearDown(() async {
    await api.close();
    await server.close();
  });

  group('cabeceras y rutas', () {
    test('GET /api/3 lleva Token y Accept y devuelve los recursos', () async {
      server.enqueueJson(200, {
        'resources': ['almacenes', 'clientes', 'crearFacturaCliente'],
      });

      final resources = await api.resources();

      expect(resources, ['almacenes', 'clientes', 'crearFacturaCliente']);
      final request = server.requests.single;
      expect(request.method, 'GET');
      expect(request.path, '/api/3');
      expect(request.headers['token'], _token);
      expect(request.headers['accept'], 'application/json');
    });

    test('la URL base se normaliza sin barra final', () {
      expect(api.config.baseUrl, server.baseUrl);
      expect(api.config.apiRoot, '${server.baseUrl}/api/3');
    });
  });

  group('list', () {
    test(
      'construye filter[], sort[], limit y offset y lee X-Total-Count',
      () async {
        server.enqueueJson(
          200,
          [
            {'idfactura': 7, 'numero2': 'TPV-1', 'total': 6.65},
          ],
          headers: {'X-Total-Count': '123'},
        );

        final page = await api.list(
          'facturaclientes',
          filters: {
            'numero2': 'TPV-1',
            'fecha_gte': '2026-10-01',
            'pagada': true,
            'idasiento_notnull': 1,
            'total_gt': 12.5,
          },
          sort: {'idfactura': FsSortOrder.asc, 'fecha': FsSortOrder.desc},
          limit: 2,
          offset: 4,
        );

        expect(page.totalCount, 123);
        expect(page.items.single['idfactura'], 7);
        final request = server.requests.single;
        expect(request.path, '/api/3/facturaclientes');
        expect(request.query, {
          'filter[numero2]': 'TPV-1',
          'filter[fecha_gte]': '2026-10-01',
          'filter[pagada]': '1',
          'filter[idasiento_notnull]': '1',
          'filter[total_gt]': '12.5',
          'sort[idfactura]': 'ASC',
          'sort[fecha]': 'DESC',
          'limit': '2',
          'offset': '4',
        });
        expect(
          request.rawQuery,
          'filter%5Bnumero2%5D=TPV-1&filter%5Bfecha_gte%5D=2026-10-01'
          '&filter%5Bpagada%5D=1&filter%5Bidasiento_notnull%5D=1'
          '&filter%5Btotal_gt%5D=12.5&sort%5Bidfactura%5D=ASC'
          '&sort%5Bfecha%5D=DESC&limit=2&offset=4',
        );
      },
    );

    test('codifica espacios y caracteres especiales del filtro', () async {
      server.enqueueJson(200, <Object?>[]);
      await api.list('clientes', filters: {'nombre': 'CLIENTES VARIOS (TPV)&'});
      expect(
        server.requests.single.query['filter[nombre]'],
        'CLIENTES VARIOS (TPV)&',
      );
    });

    test('sin cabecera X-Total-Count el total es nulo', () async {
      server.enqueueJson(200, <Object?>[]);
      final page = await api.list('series');
      expect(page.totalCount, isNull);
      expect(page.items, isEmpty);
      expect(server.requests.single.query['limit'], '50');
      expect(server.requests.single.query['offset'], '0');
    });

    test('limit 0 se rechaza en local (devolvería la tabla entera)', () {
      expect(() => api.list('series', limit: 0), throwsArgumentError);
      expect(() => api.list('series', offset: -1), throwsArgumentError);
      expect(server.requests, isEmpty);
    });

    test(
      'los tipos llegan tal cual (texto o número) y los lee FsRecordReader',
      () async {
        server.enqueueJson(200, [
          {'idasiento': '57', 'importe': '12.50', 'editable': '1'},
          {'idasiento': 58, 'importe': 12.5, 'editable': true},
        ]);
        final page = await api.list('asientos');
        for (final item in page.items) {
          expect(item.fsInt('idasiento'), anyOf(57, 58));
          expect(item.fsDouble('importe'), 12.5);
          expect(item.fsBool('editable'), isTrue);
        }
      },
    );

    test('una respuesta que no es lista lanza ErpApiException', () async {
      server.enqueueJson(200, {'error': 'raro'});
      await expectLater(
        api.list('series'),
        throwsA(
          isA<ErpApiException>()
              .having((e) => e.statusCode, 'statusCode', 200)
              .having((e) => e.kind, 'kind', ErpApiErrorKind.unexpected),
        ),
      );
    });
  });

  group('listAll', () {
    test('recorre 3 páginas sin cabecera hasta la página incompleta', () async {
      server.enqueueJson(200, [
        {'id': 1},
        {'id': 2},
      ]);
      server.enqueueJson(200, [
        {'id': 3},
        {'id': 4},
      ]);
      server.enqueueJson(200, [
        {'id': 5},
      ]);

      final all = await api.listAll('productos', sortBy: 'id', pageSize: 2);

      expect(all.map((r) => r['id']), [1, 2, 3, 4, 5]);
      expect(server.requests, hasLength(3));
      expect(server.requests.map((r) => r.query['offset']), ['0', '2', '4']);
      for (final request in server.requests) {
        expect(request.query['sort[id]'], 'ASC');
        expect(request.query['limit'], '2');
      }
    });

    test(
      'con X-Total-Count se detiene al cubrir el total sin pedir más',
      () async {
        server.enqueueJson(
          200,
          [
            {'id': 1},
            {'id': 2},
          ],
          headers: {'X-Total-Count': '4'},
        );
        server.enqueueJson(
          200,
          [
            {'id': 3},
            {'id': 4},
          ],
          headers: {'X-Total-Count': '4'},
        );

        final all = await api.listAll(
          'productos',
          filters: {'sevende': true},
          sortBy: 'id',
          pageSize: 2,
        );

        expect(all, hasLength(4));
        expect(server.requests, hasLength(2));
        expect(server.requests.first.query['filter[sevende]'], '1');
      },
    );

    test('limita el tamaño de página a 500', () async {
      server.enqueueJson(200, <Object?>[]);
      await api.listAll('productos', sortBy: 'id', pageSize: 5000);
      expect(server.requests.single.query['limit'], '500');
    });
  });

  group('get', () {
    test('devuelve el registro', () async {
      server.enqueueJson(200, {'codcliente': 'TPV', 'nombre': 'VARIOS'});
      final record = await api.get('clientes', 'TPV');
      expect(record, {'codcliente': 'TPV', 'nombre': 'VARIOS'});
      expect(server.requests.single.path, '/api/3/clientes/TPV');
    });

    test('404 de registro ({"error":...}) devuelve null', () async {
      server.enqueueJson(404, {'error': 'Registro no encontrado'});
      expect(await api.get('clientes', 'NADIE'), isNull);
    });

    test('404 de recurso ({"status":"error"}) lanza notFound', () async {
      server.enqueueJson(404, {
        'status': 'error',
        'message': 'Recurso de API no válido',
      });
      await expectLater(
        api.get('facturascliente', 1),
        throwsA(
          isA<ErpApiException>()
              .having((e) => e.kind, 'kind', ErpApiErrorKind.notFound)
              .having(
                (e) => e.message,
                'message',
                'FacturaScripts respondió 404 al leer facturascliente/1: '
                    'Recurso de API no válido',
              ),
        ),
      );
    });
  });

  group('create / update / delete / call', () {
    test('POST codifica el cuerpo como formulario y devuelve data', () async {
      server.enqueueJson(200, {
        'ok': 'Registro actualizado correctamente.',
        'data': {'idfactura': '57', 'total': '6.65'},
      });

      final data = await api.create('facturaclientes', {
        'codcliente': 'TPV',
        'pagada': true,
        'editable': false,
        'riesgomax': null,
        'total': 6.65,
        'cantidad': 2,
        'fecha': fsFormatDate(DateTime(2026, 10, 7)),
        'lineas': [
          {'referencia': 'CANA', 'cantidad': 7, 'pvpunitario': 0.86364},
        ],
      });

      expect(data, {'idfactura': '57', 'total': '6.65'});
      final request = server.requests.single;
      expect(request.method, 'POST');
      expect(request.path, '/api/3/facturaclientes');
      expect(
        request.headers['content-type'],
        startsWith('application/x-www-form-urlencoded'),
      );
      expect(request.headers['token'], _token);
      expect(request.formFields, {
        'codcliente': 'TPV',
        'pagada': '1',
        'editable': '0',
        'riesgomax': 'null',
        'total': '6.65',
        'cantidad': '2',
        'fecha': '07-10-2026',
        'lineas': '[{"referencia":"CANA","cantidad":7,"pvpunitario":0.86364}]',
      });
    });

    test('422 al crear: mensaje con el texto del ERP y kind validation', () async {
      server.enqueueJson(422, {
        'status': 'error',
        'message': 'fecha no válida',
      });
      await expectLater(
        api.call('crearFacturaCliente', fields: {'codcliente': 'TPV'}),
        throwsA(
          isA<ErpApiException>()
              .having((e) => e.kind, 'kind', ErpApiErrorKind.validation)
              .having(
                (e) => e.message,
                'message',
                'FacturaScripts respondió 422 al llamar a crearFacturaCliente: '
                    'fecha no válida',
              )
              .having((e) => e.isTransient, 'isTransient', isFalse),
        ),
      );
      expect(api.guardState, const FsGuardOk());
    });

    test('400 con la forma {"error":...} usa ese texto', () async {
      server.enqueueJson(400, {
        'error': 'Registro duplicado',
        'data': {'codcliente': 'TPV'},
      });
      await expectLater(
        api.create('clientes', {'codcliente': 'TPV'}),
        throwsA(
          isA<ErpApiException>()
              .having(
                (e) => e.message,
                'message',
                'FacturaScripts respondió 400 al crear clientes: '
                    'Registro duplicado',
              )
              .having((e) => e.responseBody, 'responseBody', contains('TPV')),
        ),
      );
    });

    test('PUT envía SOLO los campos indicados', () async {
      server.enqueueJson(200, {
        'ok': 'ok',
        'data': {'idfactura': 57, 'idestado': '11'},
      });
      final data = await api.update('facturaclientes', 57, {'idestado': 11});
      expect(data['idestado'], '11');
      final request = server.requests.single;
      expect(request.method, 'PUT');
      expect(request.path, '/api/3/facturaclientes/57');
      expect(request.formFields, {'idestado': '11'});
      expect(
        request.headers['content-type'],
        startsWith('application/x-www-form-urlencoded'),
      );
    });

    test('respuesta sin data lanza unexpected', () async {
      server.enqueueJson(200, {'ok': 'ok'});
      await expectLater(
        api.update('facturaclientes', 57, {'idestado': 11}),
        throwsA(
          isA<ErpApiException>().having(
            (e) => e.kind,
            'kind',
            ErpApiErrorKind.unexpected,
          ),
        ),
      );
    });

    test('DELETE devuelve true si borra y false en 404', () async {
      server.enqueueJson(200, {'ok': 'borrado', 'data': <String, Object?>{}});
      server.enqueueJson(404, {'error': 'Registro no encontrado'});
      expect(await api.delete('asientos', 9), isTrue);
      expect(await api.delete('asientos', 9), isFalse);
      expect(server.requests.first.method, 'DELETE');
      expect(server.requests.first.path, '/api/3/asientos/9');
      expect(server.requests.first.body, isEmpty);
    });

    test('DELETE con error 400 lanza', () async {
      server.enqueueJson(400, {'error': 'Error al eliminar el registro'});
      await expectLater(
        api.delete('asientos', 9),
        throwsA(
          isA<ErpApiException>().having(
            (e) => e.kind,
            'kind',
            ErpApiErrorKind.validation,
          ),
        ),
      );
    });

    test('call compone la ruta y devuelve el JSON completo', () async {
      server.enqueueJson(200, {
        'ok': 'pagada',
        'data': {'idfactura': 57, 'pagada': true},
      });
      final json = await api.call(
        'pagarFacturaCliente',
        path: [57],
        fields: {'pagada': true, 'fechapago': '07-10-2026'},
      );
      expect(json['ok'], 'pagada');
      final request = server.requests.single;
      expect(request.method, 'POST');
      expect(request.path, '/api/3/pagarFacturaCliente/57');
      expect(request.formFields, {'pagada': '1', 'fechapago': '07-10-2026'});
    });
  });

  group('cuerpos no JSON', () {
    test('un 500 en HTML se recorta a 2 KB y es kind server', () async {
      final html =
          '<html><body><h1>Error</h1><p>${'x' * 5000}</p></body></html>';
      server.enqueue(FakeResponse(500, body: html, contentType: 'text/html'));

      await expectLater(
        api.get('productos', 1),
        throwsA(
          isA<ErpApiException>()
              .having((e) => e.statusCode, 'statusCode', 500)
              .having((e) => e.kind, 'kind', ErpApiErrorKind.server)
              .having((e) => e.outcomeUnknown, 'outcomeUnknown', isTrue)
              .having((e) => e.responseBody!.length, 'responseBody', 2048)
              .having((e) => e.message, 'message', isNot(contains('<html>')))
              .having((e) => e.message, 'message', contains('Error')),
        ),
      );
    });

    test('un 200 que no es JSON lanza unexpected con el cuerpo', () async {
      server.enqueue(
        const FakeResponse(200, body: 'no soy json', contentType: 'text/plain'),
      );
      await expectLater(
        api.get('productos', 1),
        throwsA(
          isA<ErpApiException>()
              .having((e) => e.statusCode, 'statusCode', 200)
              .having((e) => e.kind, 'kind', ErpApiErrorKind.unexpected)
              .having((e) => e.responseBody, 'responseBody', 'no soy json')
              .having((e) => e.cause, 'cause', isA<FormatException>()),
        ),
      );
    });

    test('decodifica UTF-8 aunque el servidor no declare charset', () async {
      server.enqueue(
        const FakeResponse(
          200,
          body: '{"descripcion":"Café con leche","otro":"\\u00f1"}',
        ),
      );
      final record = await api.get('productos', 1);
      expect(record!['descripcion'], 'Café con leche');
      expect(record['otro'], 'ñ');
    });
  });

  group('cortafuegos', () {
    test(
      'tras un 401 ninguna llamada llega al servidor hasta resetGuard',
      () async {
        final states = <FsGuardState>[];
        final subscription = api.guardStates.listen(states.add);
        server.enqueueJson(401, {
          'status': 'error',
          'message': 'Clave de API no válida',
        });

        await expectLater(
          api.resources(),
          throwsA(
            isA<ErpApiException>()
                .having((e) => e.kind, 'kind', ErpApiErrorKind.unauthorized)
                .having((e) => e.isAuthFailure, 'isAuthFailure', isTrue),
          ),
        );
        expect(server.requests, hasLength(1));
        expect(
          api.guardState,
          isA<FsGuardAuthLocked>()
              .having((s) => s.since, 'since', clock)
              .having((s) => s.error.statusCode, 'error.statusCode', 401),
        );

        // Segunda llamada: falla en local, sin tocar la red.
        await expectLater(
          api.list('productos'),
          throwsA(
            isA<ErpApiException>()
                .having((e) => e.kind, 'kind', ErpApiErrorKind.unauthorized)
                .having(
                  (e) => e.message,
                  'message',
                  'Clave de API rechazada el 07-10-2026 12:00:00; '
                      'no se reintenta automáticamente',
                )
                .having((e) => e.cause, 'cause', isA<ErpApiException>()),
          ),
        );
        expect(server.requests, hasLength(1));

        api.resetGuard();
        expect(api.guardState, const FsGuardOk());
        server.enqueueJson(200, {'resources': <Object?>[]});
        expect(await api.resources(), isEmpty);
        expect(server.requests, hasLength(2));

        await pumpEventQueue();
        expect(states, [isA<FsGuardAuthLocked>(), const FsGuardOk()]);
        await subscription.cancel();
      },
    );

    test('un 403 bloquea con kind forbidden', () async {
      server.enqueueJson(403, {'status': 'error', 'message': 'Prohibido'});
      await expectLater(
        api.create('clientes', {'codcliente': 'X'}),
        throwsA(
          isA<ErpApiException>().having(
            (e) => e.kind,
            'kind',
            ErpApiErrorKind.forbidden,
          ),
        ),
      );
      await expectLater(
        api.create('clientes', {'codcliente': 'X'}),
        throwsA(
          isA<ErpApiException>().having(
            (e) => e.kind,
            'kind',
            ErpApiErrorKind.forbidden,
          ),
        ),
      );
      expect(server.requests, hasLength(1));
    });

    test('un 429 abre un cooldown de 10 minutos que vence solo', () async {
      final states = <FsGuardState>[];
      final subscription = api.guardStates.listen(states.add);
      server.enqueueJson(429, {
        'status': 'error',
        'message': 'Por motivos de seguridad se ha bloqueado...',
      });

      await expectLater(
        api.resources(),
        throwsA(
          isA<ErpApiException>()
              .having((e) => e.kind, 'kind', ErpApiErrorKind.banned)
              .having((e) => e.isTransient, 'isTransient', isTrue),
        ),
      );
      expect(
        api.guardState,
        FsGuardCooldown(until: DateTime(2026, 10, 7, 12, 10, 0)),
      );

      clock = DateTime(2026, 10, 7, 12, 9, 59);
      await expectLater(
        api.resources(),
        throwsA(
          isA<ErpApiException>()
              .having((e) => e.kind, 'kind', ErpApiErrorKind.banned)
              .having(
                (e) => e.message,
                'message',
                contains('suspendido hasta 07-10-2026 12:10:00'),
              ),
        ),
      );
      expect(server.requests, hasLength(1));

      clock = DateTime(2026, 10, 7, 12, 10, 0);
      server.enqueueJson(200, {
        'resources': ['clientes'],
      });
      expect(await api.resources(), ['clientes']);
      expect(server.requests, hasLength(2));
      expect(api.guardState, const FsGuardOk());

      await pumpEventQueue();
      expect(states, [isA<FsGuardCooldown>(), const FsGuardOk()]);
      await subscription.cancel();
    });

    test('un 404, 409 o 500 NO activa el cortafuegos', () async {
      server.enqueueJson(409, {
        'status': 'error',
        'message': 'API desactivada',
      });
      server.enqueueJson(500, {'error': 'API-ERROR: boom'});
      server.enqueueJson(404, {'status': 'error', 'message': 'no'});
      for (final kind in [
        ErpApiErrorKind.disabled,
        ErpApiErrorKind.server,
        ErpApiErrorKind.notFound,
      ]) {
        await expectLater(
          api.resources(),
          throwsA(isA<ErpApiException>().having((e) => e.kind, 'kind', kind)),
        );
      }
      expect(api.guardState, const FsGuardOk());
      expect(server.requests, hasLength(3));
    });
  });

  group('red', () {
    test(
      'servidor que no responde: kind network con TimeoutException',
      () async {
        await api.close();
        api = buildApi(requestTimeout: const Duration(milliseconds: 300));
        server.enqueue(
          const FakeResponse(
            200,
            body: '{"resources":[]}',
            delay: Duration(seconds: 3),
          ),
        );

        await expectLater(
          api.resources(),
          throwsA(
            isA<ErpApiException>()
                .having((e) => e.kind, 'kind', ErpApiErrorKind.network)
                .having((e) => e.statusCode, 'statusCode', isNull)
                .having((e) => e.outcomeUnknown, 'outcomeUnknown', isTrue)
                .having((e) => e.cause, 'cause', isA<TimeoutException>()),
          ),
        );
        expect(api.guardState, const FsGuardOk());
      },
    );

    test('conexión rechazada: kind network con SocketException', () async {
      final port = server.baseUrl.split(':').last;
      await server.close();
      // Puerto recién liberado: nadie escucha.
      final closedApi = FsHttpApi(
        FsApiConfig(baseUrl: 'http://127.0.0.1:$port', token: _token),
      );
      addTearDown(closedApi.close);

      await expectLater(
        closedApi.resources(),
        throwsA(
          isA<ErpApiException>()
              .having((e) => e.kind, 'kind', ErpApiErrorKind.network)
              .having((e) => e.cause, 'cause', isA<SocketException>()),
        ),
      );
      // El tearDown general cierra el servidor otra vez: debe tolerarlo.
      server = await FsFakeServer.start();
    });
  });

  group('close', () {
    test(
      'tras close las llamadas lanzan StateError y el flujo termina',
      () async {
        final done = api.guardStates.toList();
        await api.close();
        await api.close(); // idempotente
        expect(await done, isEmpty);
        expect(() => api.resources(), throwsStateError);
        expect(server.requests, isEmpty);
      },
    );
  });
}
