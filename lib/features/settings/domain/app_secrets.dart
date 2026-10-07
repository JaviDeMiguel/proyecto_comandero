import 'package:equatable/equatable.dart';

import '../../../core/utils/json_map.dart';

/// Secretos de los ajustes, separados del JSON principal para guardarlos en
/// el almacenamiento seguro del dispositivo.
///
/// `null` significa "no guardado": al reinyectarlos en los ajustes
/// (`AppSettings.conSecretos`) un secreto nulo deja el valor que ya tuvieran.
final class AppSecrets extends Equatable {
  const AppSecrets({this.fsApiToken, this.mysqlPassword, this.pairingCode});

  /// Lee los secretos guardados; campos ausentes → `null`. Lanza
  /// [FormatException] si un campo presente no es texto.
  factory AppSecrets.fromJson(Map<String, Object?> json) => AppSecrets(
    fsApiToken: json.optionalString(keyFsApiToken),
    mysqlPassword: json.optionalString(keyMysqlPassword),
    pairingCode: json.optionalString(keyPairingCode),
  );

  /// Claves fijas, tanto en el JSON como en el almacenamiento seguro.
  static const String keyFsApiToken = 'fsApiToken';
  static const String keyMysqlPassword = 'mysqlPassword';
  static const String keyPairingCode = 'pairingCode';
  static const List<String> keys = [
    keyFsApiToken,
    keyMysqlPassword,
    keyPairingCode,
  ];

  /// Clave de la API de FacturaScripts (cabecera `Token`).
  final String? fsApiToken;

  /// Contraseña del usuario MySQL.
  final String? mysqlPassword;

  /// Código de emparejamiento host ↔ comandero.
  final String? pairingCode;

  bool get isEmpty =>
      fsApiToken == null && mysqlPassword == null && pairingCode == null;

  /// Mapa clave → valor (solo los secretos presentes).
  Map<String, Object?> toJson() => {
    if (fsApiToken != null) keyFsApiToken: fsApiToken,
    if (mysqlPassword != null) keyMysqlPassword: mysqlPassword,
    if (pairingCode != null) keyPairingCode: pairingCode,
  };

  /// Valor de un secreto por su clave fija.
  String? operator [](String key) => switch (key) {
    keyFsApiToken => fsApiToken,
    keyMysqlPassword => mysqlPassword,
    keyPairingCode => pairingCode,
    _ => throw ArgumentError.value(key, 'key', 'Secreto desconocido'),
  };

  @override
  List<Object?> get props => [fsApiToken, mysqlPassword, pairingCode];

  /// Nunca muestra los valores: este texto puede acabar en logs.
  @override
  String toString() =>
      'AppSecrets(fsApiToken: ${fsApiToken == null ? 'no' : '***'}, '
      'mysqlPassword: ${mysqlPassword == null ? 'no' : '***'}, '
      'pairingCode: ${pairingCode == null ? 'no' : '***'})';
}
