import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Almacén clave → valor para secretos. Abstrae `flutter_secure_storage`
/// para poder probar el repositorio (y su respaldo) sin plataforma.
///
/// Las implementaciones dejan pasar los errores de plataforma
/// (`PlatformException`, `MissingPluginException`...): es el repositorio quien
/// decide si recurre al respaldo.
abstract interface class SecretStore {
  Future<String?> read(String key);

  /// `null` borra la clave.
  Future<void> write(String key, String? value);

  Future<void> delete(String key);
}

/// [SecretStore] sobre `flutter_secure_storage` (Keystore en Android,
/// Keychain en iOS/macOS, DPAPI en Windows, libsecret en Linux).
final class FlutterSecureSecretStore implements SecretStore {
  FlutterSecureSecretStore([FlutterSecureStorage? storage])
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String? value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// [SecretStore] en memoria para tests; puede simular fallos de plataforma.
final class InMemorySecretStore implements SecretStore {
  InMemorySecretStore([Map<String, String>? initial]) : values = {...?initial};

  final Map<String, String> values;

  /// Si no es `null`, toda operación lanza esta excepción (simula un
  /// dispositivo sin almacenamiento seguro utilizable).
  Exception? failure;

  /// Si no es `null`, solo las lecturas lanzan esta excepción.
  Exception? readFailure;

  /// Si no es `null`, solo las escrituras y borrados lanzan esta excepción.
  Exception? writeFailure;

  @override
  Future<String?> read(String key) async {
    _maybeFail();
    final error = readFailure;
    if (error != null) throw error;
    return values[key];
  }

  @override
  Future<void> write(String key, String? value) async {
    _maybeFail();
    _maybeFailWrite();
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }

  @override
  Future<void> delete(String key) async {
    _maybeFail();
    _maybeFailWrite();
    values.remove(key);
  }

  void _maybeFail() {
    final error = failure;
    if (error != null) throw error;
  }

  void _maybeFailWrite() {
    final error = writeFailure;
    if (error != null) throw error;
  }
}
