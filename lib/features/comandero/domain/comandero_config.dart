import 'package:equatable/equatable.dart';

import '../../../core/network/discovery/discovery_protocol.dart';
import '../../../core/network/tcp/tcp_comandero_client.dart';
import '../../../core/network/tcp/tcp_host_server.dart';
import '../../sala/domain/enrutamiento_comandas.dart';
import '../../sala/domain/linea_comanda.dart';

/// Configuración del comandero (móvil) que necesita el controlador.
///
/// Es independiente de cómo se persista (preferencias, fichero...): la capa
/// de ajustes construye una instancia y se la pasa al controlador.
final class ComanderoConfig extends Equatable {
  const ComanderoConfig({
    required this.deviceId,
    required this.deviceName,
    this.appVersion,
    this.pairingCode,
    this.hostManual,
    this.discoveryPort = kDiscoveryPort,
    this.destinoPorFamilia = const {},
    this.destinoPorDefecto = DestinoPreparacion.cocina,
  });

  /// Identificador estable de la instalación; el host deduplica por él.
  final String deviceId;

  /// Nombre visible del dispositivo ("Comandero terraza").
  final String deviceName;
  final String? appVersion;

  /// Código de emparejamiento que exige el host, si lo tiene configurado.
  final String? pairingCode;

  /// Host fijado a mano (`ip` o `ip:puerto`); `null` si se descubre por UDP.
  final String? hostManual;

  /// Puerto UDP en el que escuchan los hosts.
  final int discoveryPort;

  /// Destino de preparación por `codfamilia`; las familias que no figuren
  /// heredan el de su familia madre y, si ninguna antecesora figura, usan
  /// [destinoPorDefecto].
  ///
  /// Es el enrutamiento local de reserva: si el host publica el suyo en el
  /// snapshot de sala, el comandero usa el del host (que es quien fija el
  /// destino definitivo de cada línea).
  final Map<String, DestinoPreparacion> destinoPorFamilia;
  final DestinoPreparacion destinoPorDefecto;

  /// [destinoPorFamilia] y [destinoPorDefecto] como enrutamiento.
  EnrutamientoComandas get enrutamiento => EnrutamientoComandas(
    porFamilia: Map.unmodifiable(destinoPorFamilia),
    porDefecto: destinoPorDefecto,
  );

  /// Destino de preparación de un artículo según su familia ([madreDe] es
  /// la jerarquía de familias del catálogo, para heredar).
  DestinoPreparacion destinoDe(
    String? codfamilia, {
    Map<String, String?> madreDe = const {},
  }) => enrutamiento.destinoDe(codfamilia, madreDe: madreDe);

  /// Identidad que viaja en el `hello`.
  ClientIdentity get identity => ClientIdentity(
    deviceId: deviceId,
    deviceName: deviceName,
    appVersion: appVersion,
  );

  ComanderoConfig copyWith({
    String? deviceName,
    String? appVersion,
    String? Function()? pairingCode,
    String? Function()? hostManual,
    int? discoveryPort,
    Map<String, DestinoPreparacion>? destinoPorFamilia,
    DestinoPreparacion? destinoPorDefecto,
  }) => ComanderoConfig(
    deviceId: deviceId,
    deviceName: deviceName ?? this.deviceName,
    appVersion: appVersion ?? this.appVersion,
    pairingCode: pairingCode == null ? this.pairingCode : pairingCode(),
    hostManual: hostManual == null ? this.hostManual : hostManual(),
    discoveryPort: discoveryPort ?? this.discoveryPort,
    destinoPorFamilia: destinoPorFamilia ?? this.destinoPorFamilia,
    destinoPorDefecto: destinoPorDefecto ?? this.destinoPorDefecto,
  );

  @override
  List<Object?> get props => [
    deviceId,
    deviceName,
    appVersion,
    pairingCode,
    hostManual,
    discoveryPort,
    destinoPorFamilia,
    destinoPorDefecto,
  ];
}

/// Analiza `ip`, `ip:puerto` o `[ipv6]:puerto`. Sin puerto se asume
/// [kDefaultHostPort]. Lanza [FormatException] si no tiene sentido.
HostEndpoint parseHostEndpoint(String texto) {
  final valor = texto.trim();
  if (valor.isEmpty) throw const FormatException('Dirección del host vacía');

  final conCorchetes = RegExp(r'^\[(.+)\](?::(\d{1,5}))?$').firstMatch(valor);
  if (conCorchetes != null) {
    return HostEndpoint(
      host: conCorchetes.group(1)!,
      port: _parsePort(conCorchetes.group(2)),
    );
  }
  final separadores = ':'.allMatches(valor).length;
  if (separadores == 0) {
    return HostEndpoint(host: valor, port: kDefaultHostPort);
  }
  if (separadores == 1) {
    final index = valor.indexOf(':');
    final host = valor.substring(0, index);
    if (host.isEmpty) throw FormatException("Falta el host en '$texto'");
    return HostEndpoint(
      host: host,
      port: _parsePort(valor.substring(index + 1)),
    );
  }
  // Varias ':' sin corchetes: IPv6 sin puerto.
  return HostEndpoint(host: valor, port: kDefaultHostPort);
}

int _parsePort(String? texto) {
  if (texto == null || texto.isEmpty) return kDefaultHostPort;
  final port = int.tryParse(texto);
  if (port == null || port < 1 || port > 65535) {
    throw FormatException("Puerto inválido '$texto'");
  }
  return port;
}
