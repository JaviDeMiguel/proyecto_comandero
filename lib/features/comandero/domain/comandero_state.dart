import 'package:equatable/equatable.dart';

import '../../../core/facturascripts/catalog/catalog_models.dart';
import '../../../core/network/discovery/udp_discovery_scanner.dart';
import '../../../core/network/tcp/tcp_comandero_client.dart';
import '../../sala/protocol/sala_messages.dart';

/// Host con el que el comandero quiere (o consigue) hablar.
///
/// [hostId] y [hostName] se conocen si vino del descubrimiento UDP o tras el
/// `welcome`; con un host introducido a mano empiezan vacíos.
final class HostObjetivo extends Equatable {
  const HostObjetivo({required this.endpoint, this.hostId, this.hostName});

  factory HostObjetivo.desdeDescubierto(DiscoveredHost host) => HostObjetivo(
    endpoint: HostEndpoint(host: host.address.address, port: host.tcpPort),
    hostId: host.hostId,
    hostName: host.hostName,
  );

  final HostEndpoint endpoint;
  final String? hostId;
  final String? hostName;

  /// Texto para la interfaz: nombre si se conoce, si no la dirección.
  String get etiqueta => hostName ?? endpoint.toString();

  HostObjetivo copyWith({String? hostId, String? hostName}) => HostObjetivo(
    endpoint: endpoint,
    hostId: hostId ?? this.hostId,
    hostName: hostName ?? this.hostName,
  );

  @override
  List<Object?> get props => [endpoint, hostId, hostName];
}

/// Estado del comandero tal como lo ve la interfaz.
sealed class ComanderoState extends Equatable {
  const ComanderoState();

  /// Host al que se refiere el estado, si lo hay.
  HostObjetivo? get host => null;
}

/// Sin host configurado ni descubierto. [hostsEncontrados] conserva el
/// resultado de la última búsqueda para que el usuario elija; [error] es el
/// fallo de la última búsqueda o conexión, si lo hubo.
final class SinHost extends ComanderoState {
  const SinHost({this.hostsEncontrados = const [], this.error});

  final List<DiscoveredHost> hostsEncontrados;
  final Object? error;

  @override
  List<Object?> get props => [hostsEncontrados, error];
}

/// Búsqueda UDP en curso; [hosts] crece a medida que responden.
final class Buscando extends ComanderoState {
  const Buscando({this.hosts = const []});

  final List<DiscoveredHost> hosts;

  @override
  List<Object?> get props => [hosts];
}

/// Conexión TCP y carga inicial (snapshot de sala y catálogo) en curso.
final class Conectando extends ComanderoState {
  const Conectando({required this.host});

  @override
  final HostObjetivo host;

  @override
  List<Object?> get props => [host];
}

/// Sesión establecida y sala cargada. [catalogo] puede ser `null` si el host
/// aún no pudo servirlo (se reintenta con espera creciente mientras dure la
/// sesión); [pendientes] son las peticiones fiables (comandas, anulaciones)
/// que esperan respuesta del host.
///
/// [catalogoDesactualizado] es `true` si no hay catálogo o el que se usa (el
/// de la caché, o uno anterior) no es la versión que anuncia el host: los
/// precios e IVA pueden no ser los vigentes y la interfaz debería avisar.
final class Conectado extends ComanderoState {
  const Conectado({
    required this.host,
    required this.sala,
    this.catalogo,
    this.pendientes = 0,
    this.catalogoDesactualizado = false,
  });

  @override
  final HostObjetivo host;
  final SalaSnapshot sala;
  final CatalogSnapshot? catalogo;
  final int pendientes;
  final bool catalogoDesactualizado;

  @override
  List<Object?> get props => [
    host,
    sala,
    catalogo,
    pendientes,
    catalogoDesactualizado,
  ];
}

/// Conexión perdida; el cliente TCP reintenta solo. [intento] es el número
/// de fallos seguidos y [pendientes] lo que saldrá al reconectar.
final class Reconectando extends ComanderoState {
  const Reconectando({
    required this.host,
    required this.intento,
    required this.reintentoEn,
    this.error,
    this.pendientes = 0,
  });

  @override
  final HostObjetivo host;
  final int intento;
  final Duration reintentoEn;
  final Object? error;
  final int pendientes;

  @override
  List<Object?> get props => [host, intento, reintentoEn, error, pendientes];
}

/// El host no admite a este comandero (código de emparejamiento, versión,
/// dispositivo reemplazado): hace falta acción del usuario.
final class Rechazado extends ComanderoState {
  const Rechazado({
    required this.codigo,
    required this.mensaje,
    this.host,
    this.pendientes = 0,
  });

  @override
  final HostObjetivo? host;

  /// Uno de `RejectCodes` o `ByeReasons.replaced`.
  final String codigo;
  final String mensaje;

  /// Peticiones fiables que siguen en cola para cuando se vuelva a conectar.
  final int pendientes;

  @override
  List<Object?> get props => [host, codigo, mensaje, pendientes];
}

/// Aviso puntual para la interfaz sobre un envío de comanda (no es un estado:
/// llega por `ComanderoController.avisos`).
final class AvisoComandero extends Equatable {
  const AvisoComandero({
    required this.mesaId,
    required this.mensaje,
    this.lineaIds = const [],
  });

  final String mesaId;

  /// Texto listo para mostrar al camarero.
  final String mensaje;

  /// Líneas afectadas (ids de línea de comanda).
  final List<String> lineaIds;

  @override
  List<Object?> get props => [mesaId, mensaje, lineaIds];
}
