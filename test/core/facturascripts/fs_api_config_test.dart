import 'package:proyecto_comandero/core/errors/app_exception.dart';
import 'package:proyecto_comandero/core/facturascripts/fs_api_config.dart';
import 'package:test/test.dart';

void main() {
  group('FsApiConfig', () {
    test('normaliza la URL base: espacios, barras finales y sufijo /api/3', () {
      expect(
        FsApiConfig(
          baseUrl: ' http://host/facturascripts/ ',
          token: 't',
        ).baseUrl,
        'http://host/facturascripts',
      );
      expect(
        FsApiConfig(
          baseUrl: 'http://host/facturascripts///',
          token: 't',
        ).baseUrl,
        'http://host/facturascripts',
      );
      expect(
        FsApiConfig(
          baseUrl: 'http://host/facturascripts/api/3',
          token: 't',
        ).baseUrl,
        'http://host/facturascripts',
      );
      expect(
        FsApiConfig(baseUrl: 'https://erp.local/api/', token: 't').baseUrl,
        'https://erp.local',
      );
      expect(
        FsApiConfig(baseUrl: 'http://127.0.0.1:8765', token: 't').apiRoot,
        'http://127.0.0.1:8765/api/3',
      );
    });

    test('rechaza URLs que no son http(s) absolutas', () {
      for (final bad in [
        '',
        'host/facturascripts',
        'ftp://x',
        'http://',
        'http://h/?a=1',
      ]) {
        expect(
          () => FsApiConfig(baseUrl: bad, token: 't'),
          throwsA(isA<ConfigException>()),
          reason: bad,
        );
      }
    });

    test('tiempos por defecto: 5 s conexión y 20 s respuesta', () {
      final config = FsApiConfig(baseUrl: 'http://h', token: 't');
      expect(config.connectTimeout, const Duration(seconds: 5));
      expect(config.requestTimeout, const Duration(seconds: 20));
    });

    test('toJson / fromJson conservan todos los campos', () {
      final config = FsApiConfig(
        baseUrl: 'http://h/fs',
        token: 'secreto',
        connectTimeout: const Duration(seconds: 3),
        requestTimeout: const Duration(seconds: 45),
      );
      final json = config.toJson();
      expect(json, {
        'baseUrl': 'http://h/fs',
        'token': 'secreto',
        'connectTimeoutMs': 3000,
        'requestTimeoutMs': 45000,
      });
      expect(FsApiConfig.fromJson(json), config);
      expect(FsApiConfig.fromJson(json).hashCode, config.hashCode);
    });

    test('fromJson aplica los tiempos por defecto si faltan', () {
      final config = FsApiConfig.fromJson({
        'baseUrl': 'http://h',
        'token': 't',
      });
      expect(config.connectTimeout, FsApiConfig.defaultConnectTimeout);
      expect(config.requestTimeout, FsApiConfig.defaultRequestTimeout);
    });

    test('fromJson traduce FormatException a ConfigException', () {
      expect(
        () => FsApiConfig.fromJson({'baseUrl': 'http://h'}),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.cause,
            'cause',
            isA<FormatException>(),
          ),
        ),
      );
      expect(
        () => FsApiConfig.fromJson({'baseUrl': 'http://h', 'token': 5}),
        throwsA(isA<ConfigException>()),
      );
    });

    test('toString no revela el token', () {
      final text = FsApiConfig(
        baseUrl: 'http://h',
        token: 'SECRETO',
      ).toString();
      expect(text, isNot(contains('SECRETO')));
      expect(text, contains('http://h'));
    });

    test('copyWith cambia solo lo indicado', () {
      final config = FsApiConfig(baseUrl: 'http://h', token: 't');
      final copy = config.copyWith(token: 'u');
      expect(copy.token, 'u');
      expect(copy.baseUrl, config.baseUrl);
      expect(copy, isNot(equals(config)));
    });
  });
}
