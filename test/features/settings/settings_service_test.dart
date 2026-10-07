import 'dart:async';

import 'package:proyecto_comandero/core/errors/app_exception.dart';
import 'package:proyecto_comandero/features/settings/application/settings_service.dart';
import 'package:proyecto_comandero/features/settings/data/in_memory_settings_repository.dart';
import 'package:proyecto_comandero/features/settings/domain/app_settings.dart';
import 'package:test/test.dart';

/// Repositorio que falla en la operación indicada (para probar la
/// traducción de errores).
final class _FailingRepository implements SettingsRepository {
  _FailingRepository(
    this.inner, {
    this.failSave = false,
    this.failLoad = false,
  });

  final InMemorySettingsRepository inner;
  bool failSave;
  bool failLoad;

  @override
  Future<AppSettings?> load() {
    if (failLoad) throw const ConfigException('ajustes corruptos');
    return inner.load();
  }

  @override
  Future<void> save(AppSettings settings) {
    if (failSave) throw StateError('disco lleno');
    return inner.save(settings);
  }

  @override
  Future<void> clear() => inner.clear();
}

/// Repositorio con borrado explícito de secretos que cuenta las llamadas.
final class _RepoConBorrado
    implements SettingsRepository, BorradoExplicitoDeSecretos {
  final InMemorySettingsRepository inner = InMemorySettingsRepository();
  int borrados = 0;
  int clears = 0;

  @override
  Future<AppSettings?> load() => inner.load();

  @override
  Future<void> save(AppSettings settings) => inner.save(settings);

  @override
  Future<void> saveBorrandoSecretos(AppSettings settings) {
    borrados++;
    return inner.save(settings);
  }

  @override
  Future<void> clear() {
    clears++;
    return inner.clear();
  }
}

void main() {
  const fixedId = '0d9c2f6e-1b2c-4d3e-9f8a-7b6c5d4e3f21';

  group('load', () {
    test(
      'sin ajustes crea defaults con deviceId y nombre, y los guarda',
      () async {
        final repo = InMemorySettingsRepository();
        final service = SettingsService(repo, newDeviceId: () => fixedId);
        addTearDown(service.dispose);

        expect(service.isLoaded, isFalse);
        expect(() => service.current, throwsStateError);

        final settings = await service.load();
        expect(settings.deviceId, fixedId);
        expect(settings.deviceName, 'Dispositivo-3F21');
        expect(settings.rol, isNull);
        expect(settings.mesas, hasLength(13));
        expect(service.isLoaded, isTrue);
        expect(service.current, settings);
        expect(repo.saveCount, 1);
        expect(await repo.load(), settings);
      },
    );

    test('el deviceId es estable entre arranques', () async {
      final repo = InMemorySettingsRepository();
      var counter = 0;
      String nextId() => 'id-${++counter}';

      final first = SettingsService(repo, newDeviceId: nextId);
      final a = await first.load();
      await first.dispose();

      final second = SettingsService(repo, newDeviceId: nextId);
      final b = await second.load();
      await second.dispose();

      expect(a.deviceId, 'id-1');
      expect(b.deviceId, 'id-1');
      expect(counter, 1, reason: 'el generador solo se usa la primera vez');
      expect(repo.saveCount, 1, reason: 'el segundo load no reescribe');
    });

    test('genera UUID v4 por defecto', () async {
      final service = SettingsService(InMemorySettingsRepository());
      addTearDown(service.dispose);
      final settings = await service.load();
      expect(
        settings.deviceId,
        matches(
          RegExp(
            r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
          ),
        ),
      );
      expect(
        settings.deviceName,
        matches(RegExp(r'^Dispositivo-[0-9A-F]{4}$')),
      );
    });

    test(
      'propaga ConfigException de un repositorio corrupto sin sobrescribir',
      () async {
        final inner = InMemorySettingsRepository(
          initial: AppSettings.defaults(deviceId: 'x', deviceName: 'X'),
        );
        final service = SettingsService(
          _FailingRepository(inner, failLoad: true),
        );
        addTearDown(service.dispose);
        await expectLater(service.load(), throwsA(isA<ConfigException>()));
        expect(service.isLoaded, isFalse);
        expect(inner.saveCount, 0);
      },
    );
  });

  group('update', () {
    late InMemorySettingsRepository repo;
    late SettingsService service;

    setUp(() async {
      repo = InMemorySettingsRepository();
      service = SettingsService(repo, newDeviceId: () => fixedId);
      await service.load();
    });

    tearDown(() => service.dispose());

    test('guarda, actualiza current y emite el cambio', () async {
      final emitted = <AppSettings>[];
      final sub = service.changes.listen(emitted.add);
      addTearDown(sub.cancel);

      final result = await service.update(
        (s) => s.copyWith(rol: DeviceRole.host, fondoCajaCents: 10000),
      );
      await Future<void>.delayed(Duration.zero);

      expect(result.rol, DeviceRole.host);
      expect(result.fondoCajaCents, 10000);
      expect(service.current, result);
      expect(await repo.load(), result);
      expect(emitted, [result]);
      expect(repo.saveCount, 2);
    });

    test('sin cambios no guarda ni emite', () async {
      final emitted = <AppSettings>[];
      final sub = service.changes.listen(emitted.add);
      addTearDown(sub.cancel);

      final before = service.current;
      final result = await service.update((s) => s.copyWith());
      await Future<void>.delayed(Duration.zero);

      expect(result, before);
      expect(emitted, isEmpty);
      expect(repo.saveCount, 1);
    });

    test('las actualizaciones concurrentes se aplican en orden', () async {
      final futures = [
        for (var i = 1; i <= 5; i++)
          service.update(
            (s) => s.copyWith(fondoCajaCents: s.fondoCajaCents + i),
          ),
      ];
      await Future.wait(futures);
      expect(service.current.fondoCajaCents, 15);
      expect((await repo.load())!.fondoCajaCents, 15);
    });

    test('no permite cambiar el deviceId', () async {
      await expectLater(
        service.update((s) => s.copyWith(deviceId: 'otro')),
        throwsA(isA<ConfigException>()),
      );
      expect(service.current.deviceId, fixedId);
    });

    test('un fallo del repositorio se traduce y no altera current', () async {
      final failing = _FailingRepository(repo, failSave: true);
      final other = SettingsService(failing, newDeviceId: () => fixedId);
      addTearDown(other.dispose);
      await other.load();
      final before = other.current;

      await expectLater(
        other.update((s) => s.copyWith(deviceName: 'Nuevo')),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains('disco lleno'),
          ),
        ),
      );
      expect(other.current, before);

      // Un fallo no bloquea la cola: la siguiente operación funciona.
      failing.failSave = false;
      final after = await other.update((s) => s.copyWith(deviceName: 'Nuevo'));
      expect(after.deviceName, 'Nuevo');
    });

    test(
      'secretos sobreviven al ciclo guardar/cargar del repositorio',
      () async {
        await service.update(
          (s) => s.copyWith(
            fsApi: FsApiConfig(baseUrl: 'http://erp', token: 'tok'),
            red: s.red.copyWith(pairingCode: '4321'),
          ),
        );
        final reloaded = await repo.load();
        expect(reloaded!.fsApi!.token, 'tok');
        expect(reloaded.red.pairingCode, '4321');
      },
    );
  });

  group('reset', () {
    test('vuelve a los defaults conservando la identidad y emite', () async {
      final repo = InMemorySettingsRepository();
      final service = SettingsService(repo, newDeviceId: () => fixedId);
      addTearDown(service.dispose);
      await service.load();
      await service.update(
        (s) => s.copyWith(
          rol: DeviceRole.comandero,
          deviceName: 'Camarero 2',
          mesas: const [],
          red: s.red.copyWith(pairingCode: '1111'),
        ),
      );

      final emitted = <AppSettings>[];
      final sub = service.changes.listen(emitted.add);
      addTearDown(sub.cancel);

      await service.reset();
      await Future<void>.delayed(Duration.zero);

      final after = service.current;
      expect(after.deviceId, fixedId);
      expect(after.deviceName, 'Camarero 2');
      expect(after.rol, isNull);
      expect(after.red.pairingCode, isNull);
      expect(after.mesas, hasLength(13));
      expect(
        after,
        AppSettings.defaults(deviceId: fixedId, deviceName: 'Camarero 2'),
      );
      expect(emitted, [after]);
      expect(await repo.load(), after);
    });

    test(
      'h8: si el guardado falla no se pierde nada (ni la identidad)',
      () async {
        final inner = InMemorySettingsRepository();
        final repo = _FailingRepository(inner);
        final service = SettingsService(
          repo,
          newDeviceId: () => 'dev-original',
        );
        addTearDown(service.dispose);
        await service.load();
        await service.update((s) => s.copyWith(rol: DeviceRole.comandero));

        repo.failSave = true;
        await expectLater(service.reset(), throwsA(isA<ConfigException>()));
        repo.failSave = false;

        final otro = SettingsService(inner, newDeviceId: () => 'dev-NUEVO');
        addTearDown(otro.dispose);
        final cargados = await otro.load();
        expect(cargados.deviceId, 'dev-original');
        expect(cargados.rol, DeviceRole.comandero);
      },
    );

    test('h8: reset usa el borrado explícito de secretos si existe', () async {
      final repo = _RepoConBorrado();
      final service = SettingsService(repo, newDeviceId: () => fixedId);
      addTearDown(service.dispose);
      await service.load();
      await service.reset();
      expect(repo.borrados, 1);
      expect(repo.clears, 0);
    });

    test('sin load previo crea unos defaults nuevos', () async {
      final repo = InMemorySettingsRepository();
      final service = SettingsService(repo, newDeviceId: () => fixedId);
      addTearDown(service.dispose);
      await service.reset();
      expect(service.current.deviceId, fixedId);
      expect(await repo.load(), service.current);
    });
  });

  group('dispose', () {
    test('cierra el flujo y rechaza operaciones posteriores', () async {
      final service = SettingsService(InMemorySettingsRepository());
      await service.load();
      final done = service.changes.toList();
      await service.dispose();
      expect(await done, isEmpty);
      expect(() => service.update((s) => s), throwsStateError);
      expect(() => service.load(), throwsStateError);
      await service.dispose(); // idempotente
    });
  });

  test('nombrePorDefecto usa los 4 últimos alfanuméricos en mayúsculas', () {
    expect(SettingsService.nombrePorDefecto('abc'), 'Dispositivo-ABC');
    expect(SettingsService.nombrePorDefecto('11-22-ff-9z'), 'Dispositivo-FF9Z');
    expect(SettingsService.nombrePorDefecto(fixedId), 'Dispositivo-3F21');
  });
}
