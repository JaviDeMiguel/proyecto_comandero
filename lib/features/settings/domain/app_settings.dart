import 'package:equatable/equatable.dart';

import '../../../core/database/mysql_config.dart';
import '../../../core/errors/app_exception.dart';
import '../../../core/facturascripts/fs_api_config.dart';
import '../../../core/utils/json_map.dart';
import '../../sala/domain/mesa.dart';
import 'app_secrets.dart';
import 'fiscal_settings.dart';
import 'network_settings.dart';
import 'printing_settings.dart';
import 'reposicion_settings.dart';
import 'settings_json.dart';

export '../../../core/database/mysql_config.dart' show MysqlConfig;
export '../../../core/facturascripts/accounting/accounting_models.dart'
    show CuentaZ;
export '../../../core/facturascripts/fs_api_config.dart' show FsApiConfig;
export '../../../core/isolates/cierre_z/cierre_z_models.dart' show ModoAsientoZ;
export '../../../core/isolates/escpos/escpos_builder.dart' show PaperWidth;
export '../../../core/isolates/reposicion/reposicion_models.dart'
    show PoliticaReposicion;
export '../../../core/network/printing/raw_printer_transport.dart'
    show PrinterEndpoint, kRawPrintPort;
export '../../sala/domain/mesa.dart' show Mesa;
export 'app_secrets.dart';
export 'fiscal_settings.dart';
export 'network_settings.dart';
export 'printing_settings.dart';
export 'reposicion_settings.dart';

/// Papel de este dispositivo en la red local.
enum DeviceRole {
  /// Tablet: servidor TCP, caja, impresión y sincronización con el ERP.
  host,

  /// Móvil: toma comandas y las envía al host.
  comandero,
}

/// Ajustes completos de la aplicación.
///
/// Valor inmutable; se modifica con [copyWith] y se persiste como JSON. Los
/// secretos (token de la API, contraseña de MySQL, código de emparejamiento)
/// se guardan aparte: [toJson] con `incluirSecretos: false` los omite y
/// [secrets] / [conSecretos] permiten separarlos y reinyectarlos.
final class AppSettings extends Equatable {
  const AppSettings({
    required this.deviceId,
    required this.deviceName,
    this.rol,
    this.red = const NetworkSettings(),
    this.mysql,
    this.fsApi,
    this.fiscal = const FiscalSettings(),
    this.impresion = const PrintingSettings(),
    this.reposicion = const ReposicionSettings(),
    this.fondoCajaCents = 0,
    this.mesas = const [],
  });

  /// Ajustes por defecto de un dispositivo recién instalado (sin rol).
  factory AppSettings.defaults({
    required String deviceId,
    required String deviceName,
  }) => AppSettings(
    deviceId: deviceId,
    deviceName: deviceName,
    mesas: mesasPorDefecto(),
  );

  /// Reconstruye los ajustes guardados.
  ///
  /// Tolerante: cualquier campo ausente toma su valor por defecto (así un
  /// JSON de una versión anterior sigue cargando) y los campos desconocidos
  /// se ignoran. Un campo presente con tipo o valor inválido lanza
  /// [ConfigException]. Si el JSON se guardó sin secretos, `fsApi.token` y
  /// `mysql.password` quedan vacíos hasta que se llame a [conSecretos].
  factory AppSettings.fromJson(Map<String, Object?> json) {
    final deviceId = parseSeccion(
      'dispositivo',
      () => json.requireString('deviceId'),
    );
    if (deviceId.trim().isEmpty) {
      throw const ConfigException("Ajustes 'dispositivo': deviceId vacío");
    }
    final deviceName = parseSeccion(
      'dispositivo',
      () => json.optionalString('deviceName') ?? 'Dispositivo',
    );
    final rol = parseSeccion(
      'dispositivo',
      () => enumPorNombreOpcional(DeviceRole.values, json['rol'], campo: 'rol'),
    );
    final mysqlJson = parseSeccion('mysql', () => json.optionalMap('mysql'));
    final fsApiJson = parseSeccion('fsApi', () => json.optionalMap('fsApi'));
    final mesasJson = parseSeccion(
      'mesas',
      () => optionalMapList(json, 'mesas'),
    );

    return AppSettings(
      deviceId: deviceId,
      deviceName: deviceName,
      rol: rol,
      red: parseSeccion(
        'red',
        () => NetworkSettings.fromJson(json.optionalMap('red') ?? const {}),
      ),
      mysql: mysqlJson == null
          ? null
          : parseSeccion('mysql', () => MysqlConfig.fromJson(mysqlJson)),
      fsApi: fsApiJson == null
          ? null
          : parseSeccion(
              'fsApi',
              () => FsApiConfig.fromJson({'token': '', ...fsApiJson}),
            ),
      fiscal: parseSeccion(
        'fiscal',
        () => FiscalSettings.fromJson(json.optionalMap('fiscal') ?? const {}),
      ),
      impresion: parseSeccion(
        'impresion',
        () => PrintingSettings.fromJson(
          json.optionalMap('impresion') ?? const {},
        ),
      ),
      reposicion: parseSeccion(
        'reposicion',
        () => ReposicionSettings.fromJson(
          json.optionalMap('reposicion') ?? const {},
        ),
      ),
      fondoCajaCents: parseSeccion('caja', () {
        final caja = json.optionalMap('caja');
        return caja?.optionalInt('fondoCajaCents') ?? 0;
      }),
      mesas: mesasJson == null
          ? mesasPorDefecto()
          : parseSeccion(
              'mesas',
              () => [for (final mesa in mesasJson) Mesa.fromJson(mesa)],
            ),
    );
  }

  /// Versión del esquema JSON; permite migraciones explícitas en el futuro.
  static const int schemaVersion = 1;

  /// Salón por defecto: la barra y doce mesas.
  static List<Mesa> mesasPorDefecto() => [
    const Mesa(id: 'barra', nombre: 'Barra', zona: 'Barra'),
    for (var i = 1; i <= 12; i++)
      Mesa(id: 'mesa-$i', nombre: 'Mesa $i', zona: 'Salón', orden: i),
  ];

  /// Identificador estable del dispositivo (UUID v4); se genera una vez.
  final String deviceId;

  /// Nombre visible en la red local ("Tablet caja", "Camarero 2"...).
  final String deviceName;

  /// `null` = rol aún no elegido (primer arranque).
  final DeviceRole? rol;

  final NetworkSettings red;

  /// Conexión MySQL directa (solo host). `null` = sin configurar.
  final MysqlConfig? mysql;

  /// Conexión con la API REST de FacturaScripts (solo host).
  final FsApiConfig? fsApi;

  final FiscalSettings fiscal;
  final PrintingSettings impresion;
  final ReposicionSettings reposicion;

  /// Fondo de caja inicial en céntimos (efectivo esperado del Cierre Z).
  final int fondoCajaCents;

  /// Mesas configuradas (vacío solo si el usuario las borra todas).
  final List<Mesa> mesas;

  bool get esHost => rol == DeviceRole.host;
  bool get esComandero => rol == DeviceRole.comandero;

  /// Secretos contenidos en estos ajustes (los vacíos cuentan como ausentes).
  AppSecrets get secrets => AppSecrets(
    fsApiToken: _nonEmpty(fsApi?.token),
    mysqlPassword: _nonEmpty(mysql?.password),
    pairingCode: _nonEmpty(red.pairingCode),
  );

  /// Copia con los [secrets] reinyectados. Un secreto `null` conserva el
  /// valor actual; el token y la contraseña solo se aplican si la sección
  /// correspondiente está configurada.
  AppSettings conSecretos(AppSecrets secrets) => copyWith(
    fsApi: secrets.fsApiToken == null || fsApi == null
        ? null
        : fsApi!.copyWith(token: secrets.fsApiToken),
    mysql: secrets.mysqlPassword == null || mysql == null
        ? null
        : mysql!.copyWith(password: secrets.mysqlPassword),
    red: secrets.pairingCode == null
        ? null
        : red.copyWith(pairingCode: secrets.pairingCode),
  );

  /// Copia sin ningún secreto (token y contraseña vacíos, sin pairing).
  AppSettings sinSecretos() => copyWith(
    fsApi: fsApi?.copyWith(token: ''),
    mysql: mysql?.copyWith(password: ''),
    red: red.copyWith(borrarPairingCode: true),
  );

  /// Serializa los ajustes. Con `incluirSecretos: false` omite el token de la
  /// API, la contraseña de MySQL y el código de emparejamiento (se guardan en
  /// el almacenamiento seguro).
  Map<String, Object?> toJson({bool incluirSecretos = true}) {
    final mysqlJson = mysql?.toJson();
    final fsApiJson = fsApi?.toJson();
    if (!incluirSecretos) {
      mysqlJson?.remove('password');
      fsApiJson?.remove('token');
    }
    return {
      'schemaVersion': schemaVersion,
      'deviceId': deviceId,
      'deviceName': deviceName,
      if (rol != null) 'rol': rol!.name,
      'red': red.toJson(incluirSecretos: incluirSecretos),
      'mysql': ?mysqlJson,
      'fsApi': ?fsApiJson,
      'fiscal': fiscal.toJson(),
      'impresion': impresion.toJson(),
      'reposicion': reposicion.toJson(),
      'caja': {'fondoCajaCents': fondoCajaCents},
      'mesas': [for (final mesa in mesas) mesa.toJson()],
    };
  }

  /// Los campos anulables se borran con los indicadores `borrar*`.
  AppSettings copyWith({
    String? deviceId,
    String? deviceName,
    DeviceRole? rol,
    bool borrarRol = false,
    NetworkSettings? red,
    MysqlConfig? mysql,
    bool borrarMysql = false,
    FsApiConfig? fsApi,
    bool borrarFsApi = false,
    FiscalSettings? fiscal,
    PrintingSettings? impresion,
    ReposicionSettings? reposicion,
    int? fondoCajaCents,
    List<Mesa>? mesas,
  }) => AppSettings(
    deviceId: deviceId ?? this.deviceId,
    deviceName: deviceName ?? this.deviceName,
    rol: borrarRol ? null : (rol ?? this.rol),
    red: red ?? this.red,
    mysql: borrarMysql ? null : (mysql ?? this.mysql),
    fsApi: borrarFsApi ? null : (fsApi ?? this.fsApi),
    fiscal: fiscal ?? this.fiscal,
    impresion: impresion ?? this.impresion,
    reposicion: reposicion ?? this.reposicion,
    fondoCajaCents: fondoCajaCents ?? this.fondoCajaCents,
    mesas: mesas ?? this.mesas,
  );

  static String? _nonEmpty(String? value) =>
      value == null || value.isEmpty ? null : value;

  @override
  List<Object?> get props => [
    deviceId,
    deviceName,
    rol,
    red,
    mysql,
    fsApi,
    fiscal,
    impresion,
    reposicion,
    fondoCajaCents,
    mesas,
  ];

  /// Sin secretos (delegan en los `toString` de cada sección).
  @override
  String toString() =>
      'AppSettings($deviceName [$deviceId], rol: ${rol?.name ?? 'sin elegir'}, '
      '$red, $mysql, $fsApi, mesas: ${mesas.length})';
}
