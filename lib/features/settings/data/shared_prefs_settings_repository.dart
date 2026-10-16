import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart'
    show MissingPluginException, PlatformException;
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/errors/app_exception.dart';
import '../../../core/logging/app_logger.dart';
import '../../../core/utils/streams.dart';
import '../application/settings_service.dart';
import '../domain/app_settings.dart';
import 'secret_store.dart';

/// Repositorio real: el JSON de ajustes (sin secretos) en `shared_preferences`
/// y los secretos en el almacenamiento seguro del sistema.
///
/// Si el almacenamiento seguro falla ([PlatformException],
/// [MissingPluginException]: plugin ausente, Keystore corrupto, escritorio sin
/// libsecret...), el repositorio registra el error, guarda los secretos en
/// `shared_preferences` como respaldo y deja un aviso en [avisoAlmacenamiento]
/// para que la UI lo muestre. Cuando el almacenamiento seguro vuelve a
/// funcionar, los secretos migran de vuelta y el respaldo se borra.
///
/// Integridad de los secretos:
/// - Un secreto que no se pudo leer es *desconocido*, no borrado: mientras lo
///   sea, guardar unos ajustes sin él no lo elimina del almacenamiento seguro.
///   Solo se borra tras una lectura correcta, después de haberlo escrito en
///   esta sesión o con [saveBorrandoSecretos] (acción explícita del usuario).
/// - El respaldo sin cifrar, si existe, es siempre la versión más reciente:
///   al volver a funcionar el almacenamiento seguro se migra y se borra.
final class SharedPrefsSettingsRepository
    implements
        SettingsRepository,
        BorradoExplicitoDeSecretos,
        IdentidadRescatable {
  /// [prefs] es la instancia de `SharedPreferences.getInstance()`; [secrets]
  /// por defecto es [FlutterSecureSecretStore].
  SharedPrefsSettingsRepository({
    required SharedPreferences prefs,
    SecretStore? secrets,
  }) : this._(prefs, secrets ?? FlutterSecureSecretStore());

  SharedPrefsSettingsRepository._(this._prefs, this._secrets);

  /// Abre `shared_preferences` y el almacenamiento seguro por defecto.
  static Future<SharedPrefsSettingsRepository> open({
    SecretStore? secrets,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return SharedPrefsSettingsRepository(prefs: prefs, secrets: secrets);
    } on PlatformException catch (error) {
      throw ConfigException(
        'No se pudo abrir el almacenamiento de ajustes: ${error.message}',
        cause: error,
      );
    } on MissingPluginException catch (error) {
      throw ConfigException(
        'Almacenamiento de ajustes no disponible en esta plataforma',
        cause: error,
      );
    }
  }

  /// Clave del JSON principal (sin secretos).
  static const String prefsKeySettings = 'tpv.settings';

  /// Clave del respaldo de secretos en `shared_preferences` (solo si el
  /// almacenamiento seguro falla).
  static const String prefsKeySecretsFallback = 'tpv.settings.secrets';

  /// Prefijo de las claves fijas en el almacenamiento seguro.
  static const String secureKeyPrefix = 'tpv.secret.';

  /// Clave en el almacenamiento seguro de cada secreto de [AppSecrets.keys].
  static String secureKey(String secret) => '$secureKeyPrefix$secret';

  final SharedPreferences _prefs;
  final SecretStore _secrets;
  final Logger _log = appLogger('settings.storage');
  final StreamController<String?> _avisos =
      StreamController<String?>.broadcast();

  String? _aviso;

  /// Secretos cuyo valor en el almacenamiento seguro se desconoce porque la
  /// última lectura falló. Un `null` en ellos no significa "borrado".
  final Set<String> _noLeidos = <String>{};

  /// Clave, dentro del respaldo, con los secretos que no se pudieron leer
  /// cuando se escribió.
  static const String _fallbackKeyNoLeidos = '_noLeidos';

  /// Texto del aviso vigente sobre el almacenamiento (p. ej. "los secretos
  /// se guardan sin cifrar") o `null` si todo funciona.
  String? get avisoAlmacenamiento => _aviso;

  /// Emite cada cambio de [avisoAlmacenamiento] (`null` = aviso retirado).
  Stream<String?> get avisos => _avisos.stream;

  /// `true` mientras los secretos dependan del respaldo sin cifrar.
  bool get almacenamientoSeguroDegradado => _aviso != null;

  @override
  Future<AppSettings?> load() async {
    final raw = _readPrefsString(prefsKeySettings);
    if (raw == null) return null;

    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException catch (error) {
      throw ConfigException(
        'Los ajustes guardados no son JSON válido: ${error.message}',
        cause: error,
      );
    }
    if (decoded is! Map<String, Object?>) {
      throw const ConfigException(
        'Los ajustes guardados no tienen el formato esperado (objeto JSON)',
      );
    }
    final settings = AppSettings.fromJson(decoded);
    return settings.conSecretos(await _loadSecrets());
  }

  @override
  Future<void> save(AppSettings settings) async {
    await _writePrefsString(
      prefsKeySettings,
      jsonEncode(settings.toJson(incluirSecretos: false)),
    );
    await _saveSecrets(settings.secrets);
  }

  @override
  Future<void> clear() async {
    await _removePrefs(prefsKeySettings);
    await _removePrefs(prefsKeySecretsFallback);
    _noLeidos.clear();
    try {
      for (final key in AppSecrets.keys) {
        await _secrets.delete(secureKey(key));
      }
    } on Exception catch (error, stackTrace) {
      if (!_esFalloDePlataforma(error)) rethrow;
      _degradar('No se pudieron borrar los secretos', error, stackTrace);
    }
  }

  /// Lee solo `deviceId` y `deviceName` del JSON guardado, aunque el resto
  /// esté corrupto (para "Restablecer ajustes" sin perder la identidad).
  @override
  Future<IdentidadDispositivo?> leerIdentidad() async {
    try {
      final raw = _prefs.getString(prefsKeySettings);
      if (raw == null) return null;
      return IdentidadDispositivo.desdeJson(jsonDecode(raw));
    } on Object catch (error, stackTrace) {
      _log.warning('Identidad del dispositivo ilegible', error, stackTrace);
      return null;
    }
  }

  /// Libera el flujo de avisos.
  Future<void> dispose() async {
    cerrarSinEsperar(_avisos);
  }

  // ---------------------------------------------------------------- secretos

  /// Guarda [settings] tratando cada secreto nulo como borrado de forma
  /// explícita, aunque no se haya podido leer antes (lo usa
  /// `SettingsService.reset`). Como [save], escribe primero el JSON: si eso
  /// falla no se borra ningún secreto.
  @override
  Future<void> saveBorrandoSecretos(AppSettings settings) async {
    await _writePrefsString(
      prefsKeySettings,
      jsonEncode(settings.toJson(incluirSecretos: false)),
    );
    _noLeidos.clear();
    await _saveSecrets(settings.secrets);
  }

  Future<AppSecrets> _loadSecrets() async {
    final respaldo = _loadFallbackSecrets();
    final values = <String, Object?>{};
    try {
      for (final key in AppSecrets.keys) {
        final value = await _secrets.read(secureKey(key));
        if (value != null) values[key] = value;
      }
    } on Exception catch (error, stackTrace) {
      if (!_esFalloDePlataforma(error)) rethrow;
      _degradar('No se pudieron leer los secretos', error, stackTrace);
      // Lo que no esté en el respaldo es desconocido, no borrado: mientras
      // siga así, [_saveSecrets] no lo elimina del almacenamiento seguro.
      _noLeidos
        ..clear()
        ..addAll(respaldo?.noLeidos ?? AppSecrets.keys);
      return respaldo?.secrets ?? const AppSecrets();
    }
    final secure = AppSecrets.fromJson(values);
    if (respaldo == null) {
      _noLeidos.clear();
      _restaurar();
      return secure;
    }
    // El respaldo solo se escribe cuando falla el guardado seguro, así que es
    // siempre la versión más reciente: se migra (completando con lo seguro
    // los secretos que no se habían podido leer al escribirlo) y
    // [_saveSecrets] lo borra al terminar bien.
    final reciente = _combinar(respaldo, secure);
    _noLeidos.clear();
    await _saveSecrets(reciente);
    return reciente;
  }

  /// Secretos del [respaldo], con los que este no conocía tomados de
  /// [secure].
  static AppSecrets _combinar(_Respaldo respaldo, AppSecrets secure) {
    String? valor(String key) =>
        respaldo.noLeidos.contains(key) ? secure[key] : respaldo.secrets[key];
    return AppSecrets(
      fsApiToken: valor(AppSecrets.keyFsApiToken),
      mysqlPassword: valor(AppSecrets.keyMysqlPassword),
      pairingCode: valor(AppSecrets.keyPairingCode),
    );
  }

  Future<void> _saveSecrets(AppSecrets secrets) async {
    try {
      for (final key in AppSecrets.keys) {
        final value = secrets[key];
        if (value == null) {
          // Un secreto que no se pudo leer no está "borrado": se conserva.
          if (_noLeidos.contains(key)) continue;
          await _secrets.delete(secureKey(key));
        } else {
          await _secrets.write(secureKey(key), value);
          _noLeidos.remove(key);
        }
      }
      await _removePrefs(prefsKeySecretsFallback);
      _restaurar();
    } on Exception catch (error, stackTrace) {
      if (!_esFalloDePlataforma(error)) rethrow;
      _degradar('No se pudieron guardar los secretos', error, stackTrace);
      // El respaldo se escribe siempre (aunque no lleve ningún secreto): su
      // presencia indica que es la versión más reciente y que lo que haya en
      // el almacenamiento seguro está caducado.
      final noLeidos = [
        for (final key in AppSecrets.keys)
          if (_noLeidos.contains(key) && secrets[key] == null) key,
      ];
      await _writePrefsString(
        prefsKeySecretsFallback,
        jsonEncode({
          ...secrets.toJson(),
          if (noLeidos.isNotEmpty) _fallbackKeyNoLeidos: noLeidos,
        }),
      );
    }
  }

  /// Respaldo guardado o `null` si no hay (o es ilegible).
  _Respaldo? _loadFallbackSecrets() {
    final raw = _readPrefsString(prefsKeySecretsFallback);
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, Object?>) {
        final noLeidos = decoded[_fallbackKeyNoLeidos];
        return _Respaldo(
          AppSecrets.fromJson(decoded),
          noLeidos is List<Object?>
              ? {
                  for (final key in noLeidos)
                    if (key is String && AppSecrets.keys.contains(key)) key,
                }
              : const <String>{},
        );
      }
      _log.warning('Respaldo de secretos con formato inesperado');
    } on FormatException catch (error, stackTrace) {
      _log.warning('Respaldo de secretos ilegible', error, stackTrace);
    }
    return null;
  }

  // -------------------------------------------------------- shared_preferences

  String? _readPrefsString(String key) {
    try {
      return _prefs.getString(key);
    } on TypeError catch (error) {
      throw ConfigException(
        "La clave '$key' de los ajustes no contiene texto",
        cause: error,
      );
    }
  }

  Future<void> _writePrefsString(String key, String value) async {
    final ok = await _guardPrefs(() => _prefs.setString(key, value));
    if (!ok) {
      throw ConfigException("No se pudo guardar la clave '$key' de ajustes");
    }
  }

  Future<void> _removePrefs(String key) async {
    if (!_prefs.containsKey(key)) return;
    await _guardPrefs(() => _prefs.remove(key));
  }

  Future<bool> _guardPrefs(Future<bool> Function() action) async {
    try {
      return await action();
    } on PlatformException catch (error) {
      throw ConfigException(
        'Error al escribir los ajustes: ${error.message}',
        cause: error,
      );
    } on MissingPluginException catch (error) {
      throw ConfigException(
        'Almacenamiento de ajustes no disponible en esta plataforma',
        cause: error,
      );
    }
  }

  // ------------------------------------------------------------------- avisos

  static bool _esFalloDePlataforma(Exception error) =>
      error is PlatformException || error is MissingPluginException;

  void _degradar(String contexto, Exception error, StackTrace stackTrace) {
    _log.warning(
      '$contexto en el almacenamiento seguro; se usa shared_preferences '
      'como respaldo',
      error,
      stackTrace,
    );
    final aviso =
        'El almacenamiento seguro del dispositivo no está disponible: '
        'el token de la API y las contraseñas se guardan sin cifrar '
        '($contexto).';
    if (_aviso == aviso) return;
    _aviso = aviso;
    if (!_avisos.isClosed) _avisos.add(aviso);
  }

  void _restaurar() {
    if (_aviso == null) return;
    _log.info('El almacenamiento seguro vuelve a funcionar');
    _aviso = null;
    if (!_avisos.isClosed) _avisos.add(null);
  }
}

/// Respaldo de secretos leído de `shared_preferences`.
final class _Respaldo {
  const _Respaldo(this.secrets, this.noLeidos);

  final AppSecrets secrets;

  /// Secretos que no se habían podido leer cuando se escribió el respaldo
  /// (su valor vigente es el del almacenamiento seguro).
  final Set<String> noLeidos;
}
