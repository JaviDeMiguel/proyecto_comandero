/// Acceso al sandbox de FacturaScripts para los tests de integración.
///
/// Se leen `TPV_FS_BASE_URL` y `TPV_FS_TOKEN`; sin ellas los tests se saltan.
/// Nunca se envía una petición sin token válido: cinco incidencias en diez
/// minutos banean la IP para todos los agentes.
library;

import 'dart:io';

import 'package:proyecto_comandero/core/facturascripts/fs_api_config.dart';
import 'package:proyecto_comandero/core/facturascripts/fs_http_api.dart';

final class SandboxEnv {
  SandboxEnv._(this.baseUrl, this.token);

  final String baseUrl;
  final String token;

  static SandboxEnv? load() {
    final env = Platform.environment;
    final baseUrl = env['TPV_FS_BASE_URL']?.trim();
    final token = env['TPV_FS_TOKEN']?.trim();
    if (baseUrl == null || baseUrl.isEmpty || token == null || token.isEmpty) {
      return null;
    }
    return SandboxEnv._(baseUrl, token);
  }

  /// Motivo de salto para `skip:` cuando no hay sandbox configurado.
  static String get skipReason =>
      'Define TPV_FS_BASE_URL y TPV_FS_TOKEN para ejecutar contra el sandbox';

  FsHttpApi connect() => FsHttpApi(
    FsApiConfig(baseUrl: baseUrl, token: token),
    // El sandbox corre en PHP de desarrollo: una petición puede tardar.
  );
}

/// Sufijo único y corto para claves de idempotencia de esta ejecución.
String runSuffix() {
  final micros = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
  return '${pid.toRadixString(36)}$micros'.toUpperCase();
}
