import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/logging/app_logger.dart';
import '../../core/logging/rotating_file_log.dart';

final _log = appLogger('app');

/// Nivel del registro: INFO tanto en depuración como en release (avisos,
/// errores y los hitos de sincronización, sin el detalle FINE de cada
/// petición).
const Level nivelRegistro = Level.INFO;

/// Tiempo máximo para localizar la carpeta del registro: el arranque no debe
/// quedarse esperando a un plugin que no responde.
const Duration _plazoCarpeta = Duration(seconds: 3);

/// Configura el registro de la app y los manejadores globales de errores.
///
/// Los registros van a `dart:developer` y, si se puede abrir, a un fichero
/// rotativo [RotatingFileLog] en [carpetaDeRegistro]. Un fallo al localizar
/// o abrir el fichero no impide arrancar: la app sigue sin registro en disco.
/// Devuelve el registro en fichero abierto, o `null`.
Future<RotatingFileLog?> iniciarRegistro() async {
  configureLogging(level: nivelRegistro);
  instalarManejadoresDeErrores();

  RotatingFileLog? fichero;
  try {
    final carpeta = await carpetaDeRegistro().timeout(_plazoCarpeta);
    fichero = RotatingFileLog.open(directory: carpeta);
  } on Exception catch (error, stackTrace) {
    _log.warning(
      'No se pudo abrir el registro en fichero; se sigue sin él',
      error,
      stackTrace,
    );
    return null;
  }

  final abierto = fichero;
  configureLogging(
    level: nivelRegistro,
    onRecord: (record) {
      developerLogSink(record);
      abierto.write(record);
    },
  );
  _log.info(
    'Inicio de TPV Comandero (${Platform.operatingSystem} '
    '${Platform.operatingSystemVersion}); registro en ${abierto.path}',
  );
  return abierto;
}

/// Carpeta del fichero de registro:
/// - Android: almacenamiento externo propio de la app
///   (`Android/data/es.tpvcomandero.app/files/logs`), accesible por USB para
///   soporte; si no hay, la carpeta de soporte interna.
/// - Windows y resto: `<carpeta de soporte>/logs` (en Windows,
///   `%APPDATA%\TPV Comandero\TPV Comandero\logs`).
Future<String> carpetaDeRegistro() async {
  if (Platform.isAndroid) {
    final externa = await getExternalStorageDirectory();
    if (externa != null) return _subcarpeta(externa.path);
  }
  final soporte = await getApplicationSupportDirectory();
  return _subcarpeta(soporte.path);
}

String _subcarpeta(String base) => '$base${Platform.pathSeparator}logs';

/// Registra con su traza los errores que nadie captura, sin quitar el
/// tratamiento por defecto de Flutter (volcado en consola en depuración).
void instalarManejadoresDeErrores() {
  final anteriorFlutter = FlutterError.onError;
  FlutterError.onError = (details) {
    _log.severe(
      'Error de Flutter: ${details.exceptionAsString()}',
      details.exception,
      details.stack,
    );
    anteriorFlutter?.call(details);
  };

  final dispatcher = PlatformDispatcher.instance;
  final anteriorPlataforma = dispatcher.onError;
  dispatcher.onError = (error, stackTrace) {
    _log.severe('Error no capturado', error, stackTrace);
    if (anteriorPlataforma != null) {
      return anteriorPlataforma(error, stackTrace);
    }
    // En depuración se deja el tratamiento por defecto del motor (lo vuelca
    // en consola); en release basta con haberlo registrado.
    return !kDebugMode;
  };
}
