/// Descubrimiento del host en la red local por UDP broadcast (puerto 4041).
///
/// * Host (tablet): [UdpDiscoveryResponder].
/// * Comandero (móvil): [UdpDiscoveryScanner].
library;

import 'udp_discovery_responder.dart';
import 'udp_discovery_scanner.dart';

export 'discovery_protocol.dart';
export 'udp_discovery_responder.dart';
export 'udp_discovery_scanner.dart';
