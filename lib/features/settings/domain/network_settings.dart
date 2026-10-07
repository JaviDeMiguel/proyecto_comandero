import 'package:equatable/equatable.dart';

import '../../../core/utils/json_map.dart';

/// Ajustes de la red local: puertos del protocolo y emparejamiento.
///
/// El [pairingCode] es un secreto: no viaja en el JSON cuando se serializa
/// con `incluirSecretos: false` (ver `AppSettings.toJson`).
final class NetworkSettings extends Equatable {
  const NetworkSettings({
    this.tcpPort = defaultTcpPort,
    this.discoveryPort = defaultDiscoveryPort,
    this.pairingCode,
    this.hostManual,
  });

  /// Lee los ajustes guardados. Campos ausentes → valor por defecto. Lanza
  /// [FormatException] si un campo presente tiene un tipo o valor inválido.
  factory NetworkSettings.fromJson(Map<String, Object?> json) {
    final tcpPort = json.optionalInt('tcpPort') ?? defaultTcpPort;
    final discoveryPort =
        json.optionalInt('discoveryPort') ?? defaultDiscoveryPort;
    _checkPort('tcpPort', tcpPort);
    _checkPort('discoveryPort', discoveryPort);
    final hostManual = json.optionalString('hostManual');
    if (hostManual != null) parseHostManual(hostManual);
    return NetworkSettings(
      tcpPort: tcpPort,
      discoveryPort: discoveryPort,
      pairingCode: json.optionalString('pairingCode'),
      hostManual: hostManual,
    );
  }

  static const int defaultTcpPort = 4040;
  static const int defaultDiscoveryPort = 4041;

  /// Puerto TCP de la sesión host ↔ comandero.
  final int tcpPort;

  /// Puerto UDP del descubrimiento por broadcast.
  final int discoveryPort;

  /// Código que el comandero presenta en el `hello` y que el host exige en
  /// el `welcome`. `null` = sin emparejamiento (solo redes de confianza).
  final String? pairingCode;

  /// Dirección fija del host (`ip:puerto`) para redes donde el broadcast UDP
  /// no funciona. `null` = usar solo el descubrimiento automático.
  final String? hostManual;

  /// Descompone [hostManual] en host y puerto. Lanza [FormatException] si el
  /// formato no es `host:puerto` con puerto entre 1 y 65535.
  static ({String host, int port}) parseHostManual(String value) {
    final text = value.trim();
    final sep = text.lastIndexOf(':');
    if (sep <= 0 || sep == text.length - 1) {
      throw FormatException(
        "Campo 'hostManual': se esperaba 'host:puerto' y llegó '$value'",
      );
    }
    final host = text.substring(0, sep).replaceAll(RegExp(r'^\[|\]$'), '');
    final port = int.tryParse(text.substring(sep + 1));
    if (host.isEmpty || host.contains(RegExp(r'\s'))) {
      throw FormatException("Campo 'hostManual': host no válido en '$value'");
    }
    if (port == null) {
      throw FormatException(
        "Campo 'hostManual': puerto no numérico en '$value'",
      );
    }
    _checkPort('hostManual', port);
    return (host: host, port: port);
  }

  static void _checkPort(String campo, int port) {
    if (port < 1 || port > 65535) {
      throw FormatException("Campo '$campo': puerto fuera de rango: $port");
    }
  }

  Map<String, Object?> toJson({bool incluirSecretos = true}) => {
    'tcpPort': tcpPort,
    'discoveryPort': discoveryPort,
    if (incluirSecretos && pairingCode != null) 'pairingCode': pairingCode,
    if (hostManual != null) 'hostManual': hostManual,
  };

  /// Los parámetros anulables se "borran" con [borrarPairingCode] y
  /// [borrarHostManual] (pasar `null` conserva el valor actual).
  NetworkSettings copyWith({
    int? tcpPort,
    int? discoveryPort,
    String? pairingCode,
    bool borrarPairingCode = false,
    String? hostManual,
    bool borrarHostManual = false,
  }) => NetworkSettings(
    tcpPort: tcpPort ?? this.tcpPort,
    discoveryPort: discoveryPort ?? this.discoveryPort,
    pairingCode: borrarPairingCode ? null : (pairingCode ?? this.pairingCode),
    hostManual: borrarHostManual ? null : (hostManual ?? this.hostManual),
  );

  @override
  List<Object?> get props => [tcpPort, discoveryPort, pairingCode, hostManual];

  /// Sin el código de emparejamiento: apto para logs.
  @override
  String toString() =>
      'NetworkSettings(tcp: $tcpPort, udp: $discoveryPort, '
      'pairing: ${pairingCode == null ? 'no' : '***'}, '
      'hostManual: $hostManual)';
}
