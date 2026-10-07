import 'dart:convert';

import '../application/settings_service.dart';
import '../domain/app_settings.dart';

/// Repositorio en memoria: tests y arranque sin plugins de plataforma.
///
/// Guarda el JSON serializado (no la instancia) para que el comportamiento
/// de ida y vuelta sea el mismo que con la persistencia real.
final class InMemorySettingsRepository
    implements SettingsRepository, IdentidadRescatable {
  InMemorySettingsRepository({AppSettings? initial})
    : _json = initial == null ? null : jsonEncode(initial.toJson());

  String? _json;

  /// Número de escrituras realizadas (útil en tests).
  int saveCount = 0;

  /// Último JSON guardado, tal cual (`null` si no hay ajustes).
  String? get storedJson => _json;

  @override
  Future<AppSettings?> load() async {
    final json = _json;
    if (json == null) return null;
    return AppSettings.fromJson(jsonDecode(json) as Map<String, Object?>);
  }

  @override
  Future<void> save(AppSettings settings) async {
    _json = jsonEncode(settings.toJson());
    saveCount++;
  }

  @override
  Future<IdentidadDispositivo?> leerIdentidad() async {
    final json = _json;
    if (json == null) return null;
    try {
      return IdentidadDispositivo.desdeJson(jsonDecode(json));
    } on FormatException {
      return null;
    }
  }

  @override
  Future<void> clear() async {
    _json = null;
  }
}
