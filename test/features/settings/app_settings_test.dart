import 'dart:convert';

import 'package:proyecto_comandero/core/errors/app_exception.dart';
import 'package:proyecto_comandero/features/settings/domain/app_settings.dart';
import 'package:test/test.dart';

/// Ajustes con todas las secciones rellenas (sin valores por defecto).
AppSettings ajustesCompletos() => AppSettings(
  deviceId: '6f1c2a3b-0000-4000-8000-00000000abcd',
  deviceName: 'Tablet caja',
  rol: DeviceRole.host,
  red: const NetworkSettings(
    tcpPort: 5050,
    discoveryPort: 5051,
    pairingCode: '1234',
    hostManual: '192.168.1.10:5050',
  ),
  mysql: const MysqlConfig(
    host: '192.168.1.10',
    port: 3307,
    user: 'tpv',
    password: 'muy-secreta',
    database: 'facturascripts',
    secure: true,
  ),
  fsApi: FsApiConfig(
    baseUrl: 'http://192.168.1.10/facturascripts',
    token: 'token-secreto',
    requestTimeout: const Duration(seconds: 30),
  ),
  fiscal: const FiscalSettings(
    codserie: 'T',
    codcliente: 'CLI-TPV',
    codalmacen: 'ALG',
    codpagoEfectivo: 'EFEC',
    codpagoTarjeta: 'TARJ',
    idempresa: 2,
    emitirFacturas: false,
    modoAsientoZ: ModoAsientoZ.resumenCompleto,
    subcuentasOverride: {
      CuentaZ.caja570: '5700000002',
      CuentaZ.ventas700: '7000000001',
    },
    nombreTpv: 'TPV Terraza',
  ),
  impresion: PrintingSettings(
    tickets: PrinterEndpoint('192.168.1.50'),
    cocina: PrinterEndpoint('192.168.1.51', port: 9101),
    paper: PaperWidth.mm58,
    abrirCajon: false,
    imprimirTicketAlCobrar: false,
    imprimirComandaCocina: false,
  ),
  reposicion: const ReposicionSettings(
    automatica: false,
    enCierre: false,
    politica: PoliticaReposicion(
      factorSinMaximo: 1.5,
      multiploPedido: 6,
      incluirSinMinimo: true,
    ),
  ),
  fondoCajaCents: 15000,
  mesas: const [
    Mesa(id: 'b', nombre: 'Barra', zona: 'Barra'),
    Mesa(
      id: 't1',
      nombre: 'Terraza 1',
      zona: 'Terraza',
      orden: 1,
      comensales: 4,
    ),
  ],
);

/// Pasa por texto JSON real para detectar tipos no serializables.
Map<String, Object?> roundTrip(Map<String, Object?> json) =>
    jsonDecode(jsonEncode(json)) as Map<String, Object?>;

void main() {
  group('AppSettings.defaults', () {
    test('valores por defecto del enunciado', () {
      final s = AppSettings.defaults(deviceId: 'id', deviceName: 'Dispositivo');
      expect(s.rol, isNull);
      expect(s.red.tcpPort, 4040);
      expect(s.red.discoveryPort, 4041);
      expect(s.red.pairingCode, isNull);
      expect(s.red.hostManual, isNull);
      expect(s.mysql, isNull);
      expect(s.fsApi, isNull);
      expect(s.fiscal.codserie, 'S');
      expect(s.fiscal.codcliente, 'TPV');
      expect(s.fiscal.codalmacen, isNull);
      expect(s.fiscal.codpagoEfectivo, 'CONT');
      expect(s.fiscal.codpagoTarjeta, 'TARJETA');
      expect(s.fiscal.idempresa, isNull);
      expect(s.fiscal.emitirFacturas, isTrue);
      expect(s.fiscal.modoAsientoZ, ModoAsientoZ.soloDescuadre);
      expect(s.fiscal.subcuentasOverride, isEmpty);
      expect(s.fiscal.nombreTpv, 'TPV 1');
      expect(s.impresion.tickets, isNull);
      expect(s.impresion.paper, PaperWidth.mm80);
      expect(s.impresion.abrirCajon, isTrue);
      expect(s.impresion.imprimirTicketAlCobrar, isTrue);
      expect(s.impresion.imprimirComandaCocina, isTrue);
      expect(s.reposicion.automatica, isTrue);
      expect(s.reposicion.enCierre, isTrue);
      expect(s.reposicion.politica, const PoliticaReposicion());
      expect(s.fondoCajaCents, 0);
      expect(s.mesas, hasLength(13));
      expect(
        s.mesas.first,
        const Mesa(id: 'barra', nombre: 'Barra', zona: 'Barra'),
      );
      expect(s.mesas[1].nombre, 'Mesa 1');
      expect(s.mesas[1].zona, 'Salón');
      expect(s.mesas.last.nombre, 'Mesa 12');
      expect(s.mesas.map((m) => m.id).toSet(), hasLength(13));
    });
  });

  group('JSON ida y vuelta', () {
    test('completa con secretos', () {
      final original = ajustesCompletos();
      final restored = AppSettings.fromJson(roundTrip(original.toJson()));
      expect(restored, original);
      expect(restored.hashCode, original.hashCode);
    });

    test('por defecto (sin rol, sin ERP)', () {
      final original = AppSettings.defaults(deviceId: 'abc', deviceName: 'D');
      expect(AppSettings.fromJson(roundTrip(original.toJson())), original);
    });

    test('campos ausentes toman el valor por defecto', () {
      final s = AppSettings.fromJson({'deviceId': 'x'});
      final defaults = AppSettings.defaults(
        deviceId: 'x',
        deviceName: 'Dispositivo',
      );
      expect(s, defaults);
    });

    test('secciones parciales rellenan solo lo que falta', () {
      final s = AppSettings.fromJson({
        'deviceId': 'x',
        'deviceName': 'Movil 2',
        'rol': 'comandero',
        'red': {'tcpPort': 4100},
        'fiscal': {'codalmacen': 'ALG'},
        'impresion': {
          'tickets': {'host': '10.0.0.5'},
        },
        'reposicion': {
          'politica': {'multiploPedido': 12},
        },
        'caja': {'fondoCajaCents': 5000},
        'mesas': <Object?>[],
      });
      expect(s.rol, DeviceRole.comandero);
      expect(s.red.tcpPort, 4100);
      expect(s.red.discoveryPort, 4041);
      expect(s.fiscal.codalmacen, 'ALG');
      expect(s.fiscal.codserie, 'S');
      expect(s.impresion.tickets, PrinterEndpoint('10.0.0.5', port: 9100));
      expect(s.impresion.cocina, isNull);
      expect(s.reposicion.politica.multiploPedido, 12);
      expect(s.reposicion.politica.factorSinMaximo, 2.0);
      expect(s.fondoCajaCents, 5000);
      expect(s.mesas, isEmpty);
    });

    test('campos desconocidos se ignoran', () {
      final json = ajustesCompletos().toJson()
        ..['futuro'] = true
        ..['red'] = {...ajustesCompletos().red.toJson(), 'ipv6': 'si'}
        ..['fiscal'] = {...ajustesCompletos().fiscal.toJson(), 'x': 1};
      expect(AppSettings.fromJson(roundTrip(json)), ajustesCompletos());
    });

    test('incluye schemaVersion y serializa enums por nombre', () {
      final json = ajustesCompletos().toJson();
      expect(json['schemaVersion'], AppSettings.schemaVersion);
      expect(json['rol'], 'host');
      expect((json['fiscal'] as Map)['modoAsientoZ'], 'resumenCompleto');
      expect((json['fiscal'] as Map)['subcuentasOverride'], {
        'caja570': '5700000002',
        'ventas700': '7000000001',
      });
      expect((json['impresion'] as Map)['paper'], 'mm58');
      expect((json['impresion'] as Map)['cocina'], {
        'host': '192.168.1.51',
        'port': 9101,
      });
    });

    test('tipos o valores inválidos lanzan ConfigException con la sección', () {
      expect(
        () => AppSettings.fromJson({}),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains('dispositivo'),
          ),
        ),
      );
      expect(
        () => AppSettings.fromJson({'deviceId': 'x', 'rol': 'cocina'}),
        throwsA(isA<ConfigException>()),
      );
      expect(
        () => AppSettings.fromJson({
          'deviceId': 'x',
          'red': {'tcpPort': 70000},
        }),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains("'red'"),
          ),
        ),
      );
      expect(
        () => AppSettings.fromJson({
          'deviceId': 'x',
          'red': {'hostManual': 'sin-puerto'},
        }),
        throwsA(isA<ConfigException>()),
      );
      expect(
        () => AppSettings.fromJson({
          'deviceId': 'x',
          'mysql': {'host': 'h'},
        }),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains("'mysql'"),
          ),
        ),
      );
      expect(
        () => AppSettings.fromJson({
          'deviceId': 'x',
          'fsApi': {'baseUrl': 'no-es-url'},
        }),
        throwsA(isA<ConfigException>()),
      );
      expect(
        () => AppSettings.fromJson({
          'deviceId': 'x',
          'fiscal': {
            'subcuentasOverride': {'cuenta999': '1'},
          },
        }),
        throwsA(isA<ConfigException>()),
      );
      expect(
        () => AppSettings.fromJson({
          'deviceId': 'x',
          'impresion': {
            'tickets': {'host': ' '},
          },
        }),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains("'impresion'"),
          ),
        ),
      );
      expect(
        () => AppSettings.fromJson({
          'deviceId': 'x',
          'reposicion': {
            'politica': {'multiploPedido': 0},
          },
        }),
        throwsA(isA<ConfigException>()),
      );
      expect(
        () => AppSettings.fromJson({
          'deviceId': 'x',
          'mesas': [1],
        }),
        throwsA(isA<ConfigException>()),
      );
    });
  });

  group('secretos', () {
    test(
      'toJson(incluirSecretos: false) omite token, contraseña y pairing',
      () {
        final json = ajustesCompletos().toJson(incluirSecretos: false);
        final text = jsonEncode(json);
        expect(text, isNot(contains('token-secreto')));
        expect(text, isNot(contains('muy-secreta')));
        expect(text, isNot(contains('1234')));
        expect((json['fsApi'] as Map).containsKey('token'), isFalse);
        expect((json['mysql'] as Map).containsKey('password'), isFalse);
        expect((json['red'] as Map).containsKey('pairingCode'), isFalse);
        // El resto de la configuración sí viaja.
        expect(
          (json['fsApi'] as Map)['baseUrl'],
          'http://192.168.1.10/facturascripts',
        );
        expect((json['mysql'] as Map)['user'], 'tpv');
        expect((json['red'] as Map)['hostManual'], '192.168.1.10:5050');
      },
    );

    test('secrets + conSecretos reconstruyen los ajustes completos', () {
      final original = ajustesCompletos();
      final secrets = original.secrets;
      expect(
        secrets,
        const AppSecrets(
          fsApiToken: 'token-secreto',
          mysqlPassword: 'muy-secreta',
          pairingCode: '1234',
        ),
      );

      final sinSecretos = AppSettings.fromJson(
        roundTrip(original.toJson(incluirSecretos: false)),
      );
      expect(sinSecretos, isNot(original));
      expect(sinSecretos.fsApi!.token, '');
      expect(sinSecretos.mysql!.password, '');
      expect(sinSecretos.red.pairingCode, isNull);
      expect(sinSecretos.secrets.isEmpty, isTrue);

      expect(sinSecretos.conSecretos(secrets), original);
      expect(original.sinSecretos(), sinSecretos);
    });

    test('conSecretos con secretos nulos conserva los valores actuales', () {
      final original = ajustesCompletos();
      expect(original.conSecretos(const AppSecrets()), original);
      expect(
        original
            .conSecretos(const AppSecrets(pairingCode: '9999'))
            .red
            .pairingCode,
        '9999',
      );
    });

    test('token y contraseña se ignoran si la sección no está configurada', () {
      final s = AppSettings.defaults(
        deviceId: 'x',
        deviceName: 'D',
      ).conSecretos(const AppSecrets(fsApiToken: 't', mysqlPassword: 'p'));
      expect(s.fsApi, isNull);
      expect(s.mysql, isNull);
    });

    test('AppSecrets JSON y toString sin valores', () {
      const secrets = AppSecrets(fsApiToken: 'tok-1', pairingCode: 'pin-7');
      expect(AppSecrets.fromJson(secrets.toJson()), secrets);
      expect(secrets.toJson().keys, ['fsApiToken', 'pairingCode']);
      expect(secrets[AppSecrets.keyFsApiToken], 'tok-1');
      expect(secrets[AppSecrets.keyMysqlPassword], isNull);
      expect(secrets.toString(), isNot(contains('pin-7')));
      expect(secrets.toString(), isNot(contains('tok-1')));
      expect(() => secrets['otra'], throwsArgumentError);
    });

    test('toString de los ajustes no revela secretos', () {
      final text = ajustesCompletos().toString();
      expect(text, isNot(contains('token-secreto')));
      expect(text, isNot(contains('muy-secreta')));
      expect(text, isNot(contains('1234')));
    });
  });

  group('copyWith', () {
    test('borra los campos anulables con los indicadores', () {
      final s = ajustesCompletos().copyWith(
        borrarRol: true,
        borrarMysql: true,
        borrarFsApi: true,
        red: ajustesCompletos().red.copyWith(
          borrarPairingCode: true,
          borrarHostManual: true,
        ),
        fiscal: ajustesCompletos().fiscal.copyWith(
          borrarCodalmacen: true,
          borrarIdempresa: true,
        ),
        impresion: ajustesCompletos().impresion.copyWith(borrarCocina: true),
      );
      expect(s.rol, isNull);
      expect(s.mysql, isNull);
      expect(s.fsApi, isNull);
      expect(s.red.pairingCode, isNull);
      expect(s.red.hostManual, isNull);
      expect(s.fiscal.codalmacen, isNull);
      expect(s.fiscal.idempresa, isNull);
      expect(s.impresion.cocina, isNull);
      expect(s.impresion.tickets, isNotNull);
    });

    test('sin argumentos devuelve un valor igual', () {
      expect(ajustesCompletos().copyWith(), ajustesCompletos());
    });
  });

  group('NetworkSettings.parseHostManual', () {
    test('ipv4, nombre e ipv6 entre corchetes', () {
      expect(NetworkSettings.parseHostManual('192.168.1.10:4040'), (
        host: '192.168.1.10',
        port: 4040,
      ));
      expect(NetworkSettings.parseHostManual(' tablet.local:4040 '), (
        host: 'tablet.local',
        port: 4040,
      ));
      expect(NetworkSettings.parseHostManual('[fe80::1]:4040'), (
        host: 'fe80::1',
        port: 4040,
      ));
    });

    test('rechaza formatos inválidos', () {
      for (final bad in [
        'host',
        'host:',
        ':4040',
        'host:abc',
        'host:0',
        'a b:1',
      ]) {
        expect(
          () => NetworkSettings.parseHostManual(bad),
          throwsFormatException,
          reason: bad,
        );
      }
    });
  });
}
