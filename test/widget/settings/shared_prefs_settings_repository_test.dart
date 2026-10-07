import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proyecto_comandero/core/errors/app_exception.dart';
import 'package:proyecto_comandero/features/settings/application/settings_service.dart';
import 'package:proyecto_comandero/features/settings/data/secret_store.dart';
import 'package:proyecto_comandero/features/settings/data/shared_prefs_settings_repository.dart';
import 'package:proyecto_comandero/features/settings/domain/app_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

AppSettings ajustesConSecretos() => AppSettings(
  deviceId: 'dev-1',
  deviceName: 'Tablet caja',
  rol: DeviceRole.host,
  red: const NetworkSettings(pairingCode: '1234'),
  mysql: const MysqlConfig(
    host: 'db',
    user: 'tpv',
    password: 'muy-secreta',
    database: 'facturascripts',
  ),
  fsApi: FsApiConfig(baseUrl: 'http://erp', token: 'token-secreto'),
  mesas: const [Mesa(id: 'b', nombre: 'Barra', zona: 'Barra')],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<SharedPreferences> prefsVacias() async {
    SharedPreferences.setMockInitialValues({});
    return SharedPreferences.getInstance();
  }

  group('con almacenamiento seguro simulado (flutter_secure_storage)', () {
    late SharedPreferences prefs;
    late SharedPrefsSettingsRepository repo;

    setUp(() async {
      FlutterSecureStorage.setMockInitialValues({});
      prefs = await prefsVacias();
      repo = SharedPrefsSettingsRepository(
        prefs: prefs,
        secrets: FlutterSecureSecretStore(const FlutterSecureStorage()),
      );
    });

    tearDown(() => repo.dispose());

    test('load sin datos devuelve null', () async {
      expect(await repo.load(), isNull);
      expect(repo.avisoAlmacenamiento, isNull);
    });

    test('save separa secretos y load los reúne', () async {
      final original = ajustesConSecretos();
      await repo.save(original);

      final raw = prefs.getString(
        SharedPrefsSettingsRepository.prefsKeySettings,
      )!;
      expect(raw, isNot(contains('token-secreto')));
      expect(raw, isNot(contains('muy-secreta')));
      expect(raw, isNot(contains('1234')));
      expect(
        prefs.containsKey(
          SharedPrefsSettingsRepository.prefsKeySecretsFallback,
        ),
        isFalse,
      );

      const storage = FlutterSecureStorage();
      expect(
        await storage.read(
          key: SharedPrefsSettingsRepository.secureKey(
            AppSecrets.keyFsApiToken,
          ),
        ),
        'token-secreto',
      );
      expect(
        await storage.read(
          key: SharedPrefsSettingsRepository.secureKey(
            AppSecrets.keyPairingCode,
          ),
        ),
        '1234',
      );

      expect(await repo.load(), original);
      expect(repo.almacenamientoSeguroDegradado, isFalse);
    });

    test('quitar un secreto lo borra del almacenamiento seguro', () async {
      await repo.save(ajustesConSecretos());
      await repo.save(
        ajustesConSecretos().copyWith(
          red: const NetworkSettings(),
          borrarFsApi: true,
        ),
      );
      const storage = FlutterSecureStorage();
      expect(
        await storage.read(
          key: SharedPrefsSettingsRepository.secureKey(
            AppSecrets.keyPairingCode,
          ),
        ),
        isNull,
      );
      expect(
        await storage.read(
          key: SharedPrefsSettingsRepository.secureKey(
            AppSecrets.keyFsApiToken,
          ),
        ),
        isNull,
      );
      final loaded = (await repo.load())!;
      expect(loaded.fsApi, isNull);
      expect(loaded.red.pairingCode, isNull);
      expect(loaded.mysql!.password, 'muy-secreta');
    });

    test('clear borra ajustes y secretos', () async {
      await repo.save(ajustesConSecretos());
      await repo.clear();
      expect(await repo.load(), isNull);
      expect(prefs.getKeys(), isEmpty);
      const storage = FlutterSecureStorage();
      for (final key in AppSecrets.keys) {
        expect(
          await storage.read(key: SharedPrefsSettingsRepository.secureKey(key)),
          isNull,
        );
      }
    });

    test('JSON corrupto en prefs lanza ConfigException', () async {
      await prefs.setString(
        SharedPrefsSettingsRepository.prefsKeySettings,
        '{no',
      );
      await expectLater(repo.load(), throwsA(isA<ConfigException>()));
      await prefs.setString(
        SharedPrefsSettingsRepository.prefsKeySettings,
        '[1]',
      );
      await expectLater(repo.load(), throwsA(isA<ConfigException>()));
      await prefs.setString(
        SharedPrefsSettingsRepository.prefsKeySettings,
        jsonEncode({'deviceId': 'x', 'rol': 'cocina'}),
      );
      await expectLater(repo.load(), throwsA(isA<ConfigException>()));
    });

    test('u5: leerIdentidad rescata deviceId y deviceName de un JSON con '
        'otra sección corrupta', () async {
      expect(await repo.leerIdentidad(), isNull);
      await prefs.setString(
        SharedPrefsSettingsRepository.prefsKeySettings,
        jsonEncode({
          'deviceId': 'movil-42',
          'deviceName': 'Camarero 2',
          'red': {'tcpPort': 99999},
        }),
      );
      await expectLater(repo.load(), throwsA(isA<ConfigException>()));
      expect(
        await repo.leerIdentidad(),
        const IdentidadDispositivo(
          deviceId: 'movil-42',
          deviceName: 'Camarero 2',
        ),
      );

      for (final ilegible in [
        '{no',
        '[1]',
        jsonEncode({'deviceId': ' '}),
      ]) {
        await prefs.setString(
          SharedPrefsSettingsRepository.prefsKeySettings,
          ilegible,
        );
        expect(await repo.leerIdentidad(), isNull, reason: ilegible);
      }
      await prefs.setString(
        SharedPrefsSettingsRepository.prefsKeySettings,
        jsonEncode({'deviceId': 'x', 'deviceName': 7}),
      );
      expect((await repo.leerIdentidad())!.deviceName, 'Dispositivo');
    });

    test('u5: restablecerAjustesIlegibles conserva la identidad y borra los '
        'secretos', () async {
      await repo.save(ajustesConSecretos());
      final raw = jsonDecode(
        prefs.getString(SharedPrefsSettingsRepository.prefsKeySettings)!,
      ) as Map<String, Object?>;
      raw['red'] = {'tcpPort': 99999};
      await prefs.setString(
        SharedPrefsSettingsRepository.prefsKeySettings,
        jsonEncode(raw),
      );
      await expectLater(repo.load(), throwsA(isA<ConfigException>()));

      final identidad = await restablecerAjustesIlegibles(repo);

      expect(identidad?.deviceId, 'dev-1');
      final loaded = (await repo.load())!;
      expect(loaded.deviceId, 'dev-1');
      expect(loaded.deviceName, 'Tablet caja');
      expect(loaded.rol, isNull);
      expect(loaded.fsApi, isNull);
      expect(loaded.mysql, isNull);
      const storage = FlutterSecureStorage();
      for (final key in AppSecrets.keys) {
        expect(
          await storage.read(key: SharedPrefsSettingsRepository.secureKey(key)),
          isNull,
        );
      }
    });

    test('u5: restablecerAjustesIlegibles sin identidad legible lo borra '
        'todo', () async {
      await prefs.setString(
        SharedPrefsSettingsRepository.prefsKeySettings,
        '{no',
      );
      expect(await restablecerAjustesIlegibles(repo), isNull);
      expect(await repo.load(), isNull);
    });

    test('un JSON de versión anterior carga con valores por defecto', () async {
      await prefs.setString(
        SharedPrefsSettingsRepository.prefsKeySettings,
        jsonEncode({'deviceId': 'viejo', 'deviceName': 'Antiguo'}),
      );
      final loaded = (await repo.load())!;
      expect(loaded.deviceId, 'viejo');
      expect(loaded.rol, isNull);
      expect(loaded.mesas, hasLength(13));
    });
  });

  group('respaldo cuando el almacenamiento seguro falla', () {
    late SharedPreferences prefs;
    late InMemorySecretStore secrets;
    late SharedPrefsSettingsRepository repo;

    setUp(() async {
      prefs = await prefsVacias();
      secrets = InMemorySecretStore();
      repo = SharedPrefsSettingsRepository(prefs: prefs, secrets: secrets);
    });

    tearDown(() => repo.dispose());

    test('PlatformException al guardar: respaldo en prefs y aviso', () async {
      final avisos = <String?>[];
      final sub = repo.avisos.listen(avisos.add);
      addTearDown(sub.cancel);

      secrets.failure = PlatformException(code: 'keystore', message: 'roto');
      await repo.save(ajustesConSecretos());
      await Future<void>.delayed(Duration.zero);

      expect(repo.almacenamientoSeguroDegradado, isTrue);
      expect(repo.avisoAlmacenamiento, contains('sin cifrar'));
      expect(avisos, hasLength(1));
      expect(secrets.values, isEmpty);
      final fallback = prefs.getString(
        SharedPrefsSettingsRepository.prefsKeySecretsFallback,
      )!;
      expect(jsonDecode(fallback), {
        'fsApiToken': 'token-secreto',
        'mysqlPassword': 'muy-secreta',
        'pairingCode': '1234',
      });

      // Con el almacenamiento seguro todavía roto, load usa el respaldo.
      expect(await repo.load(), ajustesConSecretos());
    });

    test('MissingPluginException también activa el respaldo', () async {
      secrets.failure = MissingPluginException('sin plugin');
      await repo.save(ajustesConSecretos());
      expect(repo.almacenamientoSeguroDegradado, isTrue);
      expect(await repo.load(), ajustesConSecretos());
    });

    test('otros errores no se tragan', () async {
      secrets.failure = const FormatException('inesperado');
      await expectLater(
        repo.save(ajustesConSecretos()),
        throwsA(isA<FormatException>()),
      );
    });

    test('al recuperarse migra los secretos y retira el aviso', () async {
      final avisos = <String?>[];
      final sub = repo.avisos.listen(avisos.add);
      addTearDown(sub.cancel);

      secrets.failure = PlatformException(code: 'keystore');
      await repo.save(ajustesConSecretos());
      expect(repo.almacenamientoSeguroDegradado, isTrue);

      secrets.failure = null;
      final loaded = await repo.load();
      await Future<void>.delayed(Duration.zero);

      expect(loaded, ajustesConSecretos());
      expect(repo.almacenamientoSeguroDegradado, isFalse);
      expect(avisos, [isNotNull, isNull]);
      expect(
        secrets.values[SharedPrefsSettingsRepository.secureKey(
          AppSecrets.keyMysqlPassword,
        )],
        'muy-secreta',
      );
      expect(
        prefs.containsKey(
          SharedPrefsSettingsRepository.prefsKeySecretsFallback,
        ),
        isFalse,
      );
    });

    test('sin secretos el respaldo no lleva ningún valor en claro', () async {
      secrets.failure = PlatformException(code: 'keystore');
      await repo.save(AppSettings.defaults(deviceId: 'x', deviceName: 'X'));
      // El respaldo vacío marca que lo más reciente es "sin secretos".
      expect(
        jsonDecode(
          prefs.getString(
            SharedPrefsSettingsRepository.prefsKeySecretsFallback,
          )!,
        ),
        isEmpty,
      );
      expect(repo.almacenamientoSeguroDegradado, isTrue);
    });

    test('fallo al leer secretos: usa el respaldo si existe', () async {
      await repo.save(ajustesConSecretos());
      expect(repo.almacenamientoSeguroDegradado, isFalse);

      secrets.failure = PlatformException(code: 'keystore');
      final loaded = (await repo.load())!;
      expect(repo.almacenamientoSeguroDegradado, isTrue);
      // No hay respaldo (se guardó bien), así que los secretos quedan vacíos
      // pero el resto de ajustes carga.
      expect(loaded.deviceId, 'dev-1');
      expect(loaded.fsApi!.token, '');
      expect(loaded.red.pairingCode, isNull);
    });
  });

  group('integridad de los secretos', () {
    late SharedPreferences prefs;
    late InMemorySecretStore secrets;

    setUp(() async {
      prefs = await prefsVacias();
      secrets = InMemorySecretStore();
    });

    SharedPrefsSettingsRepository nuevoRepo() {
      final repo = SharedPrefsSettingsRepository(
        prefs: prefs,
        secrets: secrets,
      );
      addTearDown(repo.dispose);
      return repo;
    }

    String? seguro(String key) =>
        secrets.values[SharedPrefsSettingsRepository.secureKey(key)];

    bool hayRespaldo() => prefs.containsKey(
      SharedPrefsSettingsRepository.prefsKeySecretsFallback,
    );

    test('h1: un fallo al leer no hace que el siguiente guardado borre los '
        'secretos', () async {
      await nuevoRepo().save(ajustesConSecretos());

      final repo = nuevoRepo();
      secrets.readFailure = PlatformException(code: 'keystore');
      final cargados = (await repo.load())!;
      expect(cargados.fsApi!.token, '');
      expect(repo.almacenamientoSeguroDegradado, isTrue);

      // El almacenamiento vuelve a funcionar y el usuario cambia otro ajuste.
      secrets.readFailure = null;
      await repo.save(cargados.copyWith(fondoCajaCents: 5000));

      expect(seguro(AppSecrets.keyFsApiToken), 'token-secreto');
      expect(seguro(AppSecrets.keyMysqlPassword), 'muy-secreta');
      expect(seguro(AppSecrets.keyPairingCode), '1234');
      final recargados = (await nuevoRepo().load())!;
      expect(recargados.fsApi!.token, 'token-secreto');
      expect(recargados.mysql!.password, 'muy-secreta');
      expect(recargados.red.pairingCode, '1234');
      expect(recargados.fondoCajaCents, 5000);
    });

    test(
      'h1: un secreto no leído pero reescrito sí se puede borrar después',
      () async {
        await nuevoRepo().save(ajustesConSecretos());

        final repo = nuevoRepo();
        secrets.readFailure = PlatformException(code: 'keystore');
        final cargados = (await repo.load())!;
        secrets.readFailure = null;

        // El usuario escribe un código nuevo y después lo quita.
        final conCodigo = cargados.copyWith(
          red: cargados.red.copyWith(pairingCode: '9999'),
        );
        await repo.save(conCodigo);
        expect(seguro(AppSecrets.keyPairingCode), '9999');
        await repo.save(
          conCodigo.copyWith(
            red: conCodigo.red.copyWith(borrarPairingCode: true),
          ),
        );
        expect(seguro(AppSecrets.keyPairingCode), isNull);
        // Los que siguen sin leerse se conservan.
        expect(seguro(AppSecrets.keyFsApiToken), 'token-secreto');
      },
    );

    test('h1: tras un fallo de lectura y de escritura, el respaldo no borra '
        'lo que no se leyó', () async {
      await nuevoRepo().save(ajustesConSecretos());

      final repo = nuevoRepo();
      secrets.failure = PlatformException(code: 'keystore');
      final cargados = (await repo.load())!;
      await repo.save(
        cargados.copyWith(red: cargados.red.copyWith(pairingCode: '5555')),
      );
      expect(hayRespaldo(), isTrue);

      secrets.failure = null;
      final recargados = (await nuevoRepo().load())!;
      expect(recargados.fsApi!.token, 'token-secreto');
      expect(recargados.mysql!.password, 'muy-secreta');
      expect(recargados.red.pairingCode, '5555');
      expect(seguro(AppSecrets.keyPairingCode), '5555');
      expect(hayRespaldo(), isFalse);
    });

    test('h2: el respaldo más reciente prevalece sobre secretos antiguos y se '
        'borra al migrar', () async {
      final viejos = ajustesConSecretos().copyWith(
        fsApi: FsApiConfig(baseUrl: 'http://erp', token: 'viejo'),
      );
      await nuevoRepo().save(viejos);

      // El usuario cambia el token y la escritura segura falla.
      secrets.writeFailure = PlatformException(code: 'keystore');
      final nuevos = viejos.copyWith(
        fsApi: FsApiConfig(baseUrl: 'http://erp', token: 'nuevo'),
        red: const NetworkSettings(),
      );
      await nuevoRepo().save(nuevos);
      expect(hayRespaldo(), isTrue);
      expect(seguro(AppSecrets.keyFsApiToken), 'viejo');

      // Siguiente arranque con el almacenamiento seguro ya sano.
      secrets.writeFailure = null;
      final repo = nuevoRepo();
      final avisos = <String?>[];
      final sub = repo.avisos.listen(avisos.add);
      addTearDown(sub.cancel);
      final cargados = (await repo.load())!;

      expect(cargados.fsApi!.token, 'nuevo');
      expect(cargados.red.pairingCode, isNull, reason: 'el usuario lo quitó');
      expect(seguro(AppSecrets.keyFsApiToken), 'nuevo');
      expect(seguro(AppSecrets.keyPairingCode), isNull);
      expect(hayRespaldo(), isFalse);
      expect(repo.almacenamientoSeguroDegradado, isFalse);
    });

    test('h2: si al migrar vuelve a fallar, el respaldo se conserva', () async {
      await nuevoRepo().save(ajustesConSecretos());
      secrets.writeFailure = PlatformException(code: 'keystore');
      final nuevos = ajustesConSecretos().copyWith(
        fsApi: FsApiConfig(baseUrl: 'http://erp', token: 'nuevo'),
      );
      await nuevoRepo().save(nuevos);

      final repo = nuevoRepo();
      final cargados = (await repo.load())!;
      expect(cargados.fsApi!.token, 'nuevo');
      expect(hayRespaldo(), isTrue);
      expect(repo.almacenamientoSeguroDegradado, isTrue);
    });

    test(
      'h8: saveBorrandoSecretos elimina también los secretos no leídos',
      () async {
        await nuevoRepo().save(ajustesConSecretos());
        final repo = nuevoRepo();
        secrets.readFailure = PlatformException(code: 'keystore');
        await repo.load();
        secrets.readFailure = null;

        await repo.saveBorrandoSecretos(
          AppSettings.defaults(deviceId: 'dev-1', deviceName: 'Tablet caja'),
        );
        expect(secrets.values, isEmpty);
        final recargados = (await nuevoRepo().load())!;
        expect(recargados.deviceId, 'dev-1');
        expect(recargados.red.pairingCode, isNull);
      },
    );
  });
}
