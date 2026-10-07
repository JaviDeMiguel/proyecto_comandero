import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:proyecto_comandero/core/database/mysql_database.dart';
import 'package:proyecto_comandero/core/errors/app_exception.dart';
import 'package:proyecto_comandero/core/facturascripts/fs_http_api.dart';
import 'package:proyecto_comandero/core/facturascripts/fs_resources.dart';
import 'package:proyecto_comandero/core/isolates/isolate_runner.dart';
import 'package:proyecto_comandero/core/network/printing/raw_printer_transport.dart'
    show RawPrinterTransport;
import 'package:proyecto_comandero/features/settings/domain/app_settings.dart';
import 'package:proyecto_comandero/features/settings/presentation/pagina_prueba_impresora.dart';
import 'package:proyecto_comandero/features/settings/presentation/settings_diagnostics.dart';

import '../../core/database/fakes/fake_sql_connection.dart';

const _fiscal = DiagnosticoConfig(
  codserie: 'S',
  codpagoEfectivo: 'CONT',
  codpagoTarjeta: 'TARJETA',
  codalmacen: 'ALG',
  codcliente: 'TPV',
);

final class _FakePrinter implements RawPrinterTransport {
  final List<(PrinterEndpoint, Uint8List)> enviados = [];

  @override
  Future<void> send(PrinterEndpoint endpoint, Uint8List bytes) async =>
      enviados.add((endpoint, bytes));
}

void main() {
  group('ERP', () {
    late List<http.Request> peticiones;
    late int status;

    DefaultSettingsDiagnostics crear() {
      peticiones = [];
      final client = MockClient((request) async {
        peticiones.add(request);
        if (status != 200) {
          return http.Response(
            jsonEncode({'status': 'error', 'message': 'Token no válido'}),
            status,
          );
        }
        if (request.url.path.endsWith('/api/3')) {
          return http.Response(
            jsonEncode({'resources': FsResources.requeridosPorElTpv.toList()}),
            200,
          );
        }
        return http.Response('[]', 200);
      });
      return DefaultSettingsDiagnostics(
        runner: const InlineIsolateRunner(),
        apiFactory: (config) => FsHttpApi(config, client: client),
      );
    }

    test('con la API accesible devuelve el diagnóstico completo', () async {
      status = 200;
      final diagnostics = crear();
      addTearDown(diagnostics.dispose);

      final prueba = await diagnostics.probarErp(
        FsApiConfig(baseUrl: 'http://erp.local', token: 'bueno'),
        _fiscal,
      );

      expect(prueba.accesible, isTrue);
      expect(prueba.items.first.codigo, 'api');
      expect(prueba.items.first.nivel, DiagnosticoNivel.ok);
      expect(prueba.items.length, greaterThan(1));
      expect(peticiones.first.headers['Token'], 'bueno');
    });

    test(
      'tras un token rechazado no vuelve a llamar con la misma clave',
      () async {
        status = 401;
        final diagnostics = crear();
        addTearDown(diagnostics.dispose);
        final config = FsApiConfig(baseUrl: 'http://erp.local', token: 'malo');

        final primera = await diagnostics.probarErp(config, _fiscal);
        expect(primera.accesible, isFalse);
        expect(primera.items.single.nivel, DiagnosticoNivel.error);
        expect(peticiones, hasLength(1));

        final segunda = await diagnostics.probarErp(config, _fiscal);
        expect(segunda.accesible, isFalse);
        expect(peticiones, hasLength(1), reason: 'el cortafuegos la bloquea');

        // Una clave nueva sí se prueba.
        await diagnostics.probarErp(config.copyWith(token: 'otro'), _fiscal);
        expect(peticiones, hasLength(2));
      },
    );

    test('u1: tras un 403 la clave queda bloqueada y solo se reintenta con '
        'desbloquearClave', () async {
      status = 403;
      final diagnostics = crear();
      addTearDown(diagnostics.dispose);
      final config = FsApiConfig(baseUrl: 'http://erp.local', token: 'k');

      expect(diagnostics.estadoErp(config), isA<FsGuardOk>());
      await diagnostics.probarErp(config, _fiscal);
      expect(peticiones, hasLength(1));
      expect(diagnostics.estadoErp(config), isA<FsGuardAuthLocked>());

      // El usuario corrige los permisos en FacturaScripts.
      status = 200;
      final bloqueada = await diagnostics.probarErp(config, _fiscal);
      expect(bloqueada.accesible, isFalse);
      expect(peticiones, hasLength(1), reason: 'sin reintento explícito');

      diagnostics.desbloquearClave(config);
      expect(diagnostics.estadoErp(config), isA<FsGuardOk>());
      final reintento = await diagnostics.probarErp(config, _fiscal);
      expect(reintento.accesible, isTrue);
      expect(peticiones.length, greaterThan(1));
    });

    test(
      'u2: alternar claves (A, B, A) no vuelve a enviar la clave A rechazada',
      () async {
        status = 401;
        final diagnostics = crear();
        addTearDown(diagnostics.dispose);
        final a = FsApiConfig(baseUrl: 'http://erp.local', token: 'A');
        final b = a.copyWith(token: 'B');

        await diagnostics.probarErp(a, _fiscal);
        await diagnostics.probarErp(b, _fiscal);
        expect(peticiones, hasLength(2));

        final otraVez = await diagnostics.probarErp(a, _fiscal);
        expect(otraVez.accesible, isFalse);
        expect(peticiones, hasLength(2), reason: 'A ya se sabe rechazada');
        expect(diagnostics.estadoErp(a), isA<FsGuardAuthLocked>());
        expect(diagnostics.estadoErp(b), isA<FsGuardAuthLocked>());
      },
    );

    test(
      'u2: tras un 401 en Probar, Crear cliente y Resolver subcuentas fallan '
      'en local con la misma clave',
      () async {
        status = 401;
        final diagnostics = crear();
        addTearDown(diagnostics.dispose);
        final config = FsApiConfig(baseUrl: 'http://erp.local', token: 'm');

        await diagnostics.probarErp(config, _fiscal);
        expect(peticiones, hasLength(1));

        await expectLater(
          diagnostics.crearClienteGenerico(config, codcliente: 'TPV'),
          throwsA(isA<ErpApiException>()),
        );
        await expectLater(
          diagnostics.resolverSubcuentas(
            config,
            idempresa: 1,
            fecha: DateTime(2026, 10, 7),
          ),
          throwsA(isA<ErpApiException>()),
        );
        expect(peticiones, hasLength(1));
      },
    );

    test('u2: un 429 suspende todas las claves sin tocar la red', () async {
      status = 429;
      final diagnostics = crear();
      addTearDown(diagnostics.dispose);
      final a = FsApiConfig(baseUrl: 'http://erp.local', token: 'A');

      await diagnostics.probarErp(a, _fiscal);
      expect(peticiones, hasLength(1));
      status = 200;
      final b = a.copyWith(token: 'B');
      expect(diagnostics.estadoErp(b), isA<FsGuardCooldown>());
      final prueba = await diagnostics.probarErp(b, _fiscal);
      expect(prueba.accesible, isFalse);
      await expectLater(
        diagnostics.crearClienteGenerico(b, codcliente: 'TPV'),
        throwsA(isA<ErpApiException>()),
      );
      expect(peticiones, hasLength(1));
    });

    test('tras dispose lanza StateError', () async {
      status = 200;
      final diagnostics = crear();
      await diagnostics.dispose();
      expect(
        () => diagnostics.probarErp(
          FsApiConfig(baseUrl: 'http://erp.local', token: 't'),
          _fiscal,
        ),
        throwsStateError,
      );
    });
  });

  group('MySQL', () {
    test('probarMysql hace ping y cierra la conexión', () async {
      final factory = FakeConnectionFactory();
      final diagnostics = DefaultSettingsDiagnostics(
        mysqlFactory: (config) =>
            MysqlDatabase(config, connectionFactory: factory.call),
      );
      addTearDown(diagnostics.dispose);

      await diagnostics.probarMysql(testConfig);

      expect(factory.current.statements, contains('SELECT 1 AS ok'));
      expect(factory.current.closeCalls, 1);
    });

    test('un fallo de conexión se propaga como AppException', () async {
      final factory = FakeConnectionFactory()
        ..nextConnectError = const NetworkException('MySQL no responde');
      final diagnostics = DefaultSettingsDiagnostics(
        mysqlFactory: (config) =>
            MysqlDatabase(config, connectionFactory: factory.call),
      );
      addTearDown(diagnostics.dispose);

      await expectLater(
        diagnostics.probarMysql(testConfig),
        throwsA(isA<NetworkException>()),
      );
    });

    test('crear tablas sin variantes lanza ConfigException y cierra', () async {
      final factory = FakeConnectionFactory();
      final diagnostics = DefaultSettingsDiagnostics(
        mysqlFactory: (config) =>
            MysqlDatabase(config, connectionFactory: factory.call),
      );
      addTearDown(diagnostics.dispose);

      final informe = await diagnostics.verificarTablas(testConfig);
      expect(informe.variantesExists, isFalse);
      expect(factory.current.closeCalls, 1);

      await expectLater(
        diagnostics.verificarTablas(testConfig, crear: true),
        throwsA(isA<ConfigException>()),
      );
      expect(factory.current.closeCalls, 1);
    });
  });

  test('imprimirPrueba genera ESC/POS y lo envía a la impresora', () async {
    final printer = _FakePrinter();
    final diagnostics = DefaultSettingsDiagnostics(
      runner: const InlineIsolateRunner(),
      printer: printer,
    );
    addTearDown(diagnostics.dispose);
    final endpoint = PrinterEndpoint('10.0.0.5');

    await diagnostics.imprimirPrueba(
      endpoint,
      const PaginaPruebaData(
        paper: PaperWidth.mm58,
        destino: 'Cocina',
        impresora: '10.0.0.5:9100',
        dispositivo: 'TPV 1',
        fechaHora: '07/10/2026 12:00:00',
      ),
    );

    final (destino, bytes) = printer.enviados.single;
    expect(destino, endpoint);
    expect(bytes.take(2), [0x1B, 0x40]);
    expect(latin1.decode(bytes, allowInvalid: true), contains('Cocina'));
  });
}
