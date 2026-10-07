/// Formato de los datagramas de descubrimiento del host en la red local.
///
/// El descubrimiento no usa el sobre `ProtocolMessage` de la sesión TCP: aquí
/// no hay conexión ni handshake, cualquier equipo de la LAN puede escribir en
/// el puerto y cada datagrama debe poder validarse por sí solo. Por eso el
/// formato es mínimo y autodescriptivo (`magic` + `v` + `kind`) y el análisis
/// nunca lanza: lo que no encaja se descarta.
///
/// ```json
/// {"magic":"tpv-comandero","v":1,"kind":"probe","nonce":"9f2c4e6a8b0d1f35"}
/// {"magic":"tpv-comandero","v":1,"kind":"response","nonce":"9f2c4e6a8b0d1f35",
///  "hostId":"…","hostName":"Barra","tcpPort":4040,"requiresPairing":false}
/// ```
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../../errors/app_exception.dart';

/// Puerto UDP en el que escuchan los hosts.
const int kDiscoveryPort = 4041;

/// Marca que distingue estos datagramas de cualquier otro tráfico de
/// broadcast de la LAN (SSDP, mDNS, juegos, otras apps).
const String kDiscoveryMagic = 'tpv-comandero';

/// Versión del formato de datagrama. Un host solo responde a su misma versión.
const int kDiscoveryVersion = 1;

/// Tamaño máximo de un datagrama válido.
///
/// Muy por debajo de la MTU típica (1500) para que nunca se fragmente: un
/// datagrama fragmentado se pierde entero si se pierde un solo fragmento, y
/// muchos puntos de acceso descartan los broadcast fragmentados.
const int kMaxDiscoveryDatagramBytes = 1024;

/// Longitud del nonce que genera [DiscoveryProbe.random].
const int kDiscoveryNonceLength = 16;

/// Longitud máxima de nonce que se acepta de la red.
///
/// El host devuelve el nonce tal cual, así que acotarlo (junto con
/// [kMaxDiscoveryHostIdLength] y [kMaxDiscoveryHostNameLength]) garantiza que
/// la respuesta siempre cabe en [kMaxDiscoveryDatagramBytes].
const int kMaxDiscoveryNonceLength = 64;

/// Longitud máxima de `hostId` (unidades UTF-16).
const int kMaxDiscoveryHostIdLength = 64;

/// Longitud máxima de `hostName` (unidades UTF-16).
const int kMaxDiscoveryHostNameLength = 64;

const String _kindProbe = 'probe';
const String _kindResponse = 'response';
const String _hexDigits = '0123456789abcdef';

/// Sonda que el comandero emite por broadcast para preguntar «¿hay algún host?».
@immutable
final class DiscoveryProbe {
  /// No valida [nonce]: [toBytes] lanza si no es un nonce admisible.
  const DiscoveryProbe({required this.nonce});

  /// Sonda con un nonce aleatorio de [kDiscoveryNonceLength] dígitos hex.
  ///
  /// Por defecto usa `Random.secure()`: el nonce es lo único que liga una
  /// respuesta con este escaneo, y si fuera predecible un equipo ajeno podría
  /// inyectar respuestas falsas sin haber visto la sonda.
  factory DiscoveryProbe.random([Random? random]) {
    final source = random ?? _secureRandom();
    final buffer = StringBuffer();
    for (var i = 0; i < kDiscoveryNonceLength; i++) {
      buffer.write(_hexDigits[source.nextInt(16)]);
    }
    return DiscoveryProbe(nonce: buffer.toString());
  }

  /// Identificador del escaneo: el host lo devuelve en su respuesta.
  final String nonce;

  /// Analiza un datagrama recibido. Devuelve `null` (nunca lanza) si no es
  /// una sonda válida de esta versión del protocolo.
  static DiscoveryProbe? tryParse(List<int> bytes) {
    final json = _decodeEnvelope(bytes, _kindProbe);
    if (json == null) return null;
    final nonce = json['nonce'];
    if (nonce is! String || !_isValidNonce(nonce)) return null;
    return DiscoveryProbe(nonce: nonce);
  }

  /// Serializa la sonda. Lanza [ProtocolException] si el nonce no es válido
  /// (hexadecimal, de 1 a [kMaxDiscoveryNonceLength] caracteres).
  Uint8List toBytes() {
    if (!_isValidNonce(nonce)) {
      throw const ProtocolException('Sonda de descubrimiento: nonce inválido');
    }
    return _encodeDatagram({
      'magic': kDiscoveryMagic,
      'v': kDiscoveryVersion,
      'kind': _kindProbe,
      'nonce': nonce,
    });
  }

  @override
  bool operator ==(Object other) =>
      other is DiscoveryProbe && other.nonce == nonce;

  @override
  int get hashCode => nonce.hashCode;

  @override
  String toString() => 'DiscoveryProbe($nonce)';
}

/// Respuesta de un host a una [DiscoveryProbe].
///
/// No incluye la dirección IP del host: el comandero usa la de origen del
/// datagrama, que es la única que se sabe alcanzable desde su red (el host
/// puede tener varias interfaces y no sabe por cuál le ve cada comandero).
@immutable
final class DiscoveryResponse {
  /// No valida los campos: [toBytes] lanza si alguno no es admisible.
  const DiscoveryResponse({
    required this.nonce,
    required this.hostId,
    required this.hostName,
    required this.tcpPort,
    this.requiresPairing = false,
  });

  /// Eco del nonce de la sonda a la que se responde.
  final String nonce;

  /// Identificador estable de la instalación del host.
  final String hostId;

  /// Nombre visible del host (p. ej. «Barra principal»).
  final String hostName;

  /// Puerto TCP en el que el host acepta comanderos.
  final int tcpPort;

  /// El host exige código de emparejamiento en el `hello`. Viaja aquí para que
  /// el comandero lo pida antes de conectar en lugar de recibir un `reject`.
  final bool requiresPairing;

  /// Analiza un datagrama recibido. Devuelve `null` (nunca lanza) si no es
  /// una respuesta válida de esta versión del protocolo.
  static DiscoveryResponse? tryParse(List<int> bytes) {
    final json = _decodeEnvelope(bytes, _kindResponse);
    if (json == null) return null;
    final nonce = json['nonce'];
    final hostId = json['hostId'];
    final hostName = json['hostName'];
    final tcpPort = json['tcpPort'];
    final requiresPairing = json['requiresPairing'];
    if (nonce is! String ||
        hostId is! String ||
        hostName is! String ||
        tcpPort is! int ||
        requiresPairing is! bool) {
      return null;
    }
    final response = DiscoveryResponse(
      nonce: nonce,
      hostId: hostId,
      hostName: hostName,
      tcpPort: tcpPort,
      requiresPairing: requiresPairing,
    );
    return response._problem == null ? response : null;
  }

  /// Serializa la respuesta. Lanza [ProtocolException] si algún campo no es
  /// válido (los mismos criterios con los que [tryParse] rechaza), de modo que
  /// todo lo que sale por el cable es aceptado por el otro extremo.
  Uint8List toBytes() {
    final problem = _problem;
    if (problem != null) {
      throw ProtocolException('Respuesta de descubrimiento: $problem');
    }
    return _encodeDatagram({
      'magic': kDiscoveryMagic,
      'v': kDiscoveryVersion,
      'kind': _kindResponse,
      'nonce': nonce,
      'hostId': hostId,
      'hostName': hostName,
      'tcpPort': tcpPort,
      'requiresPairing': requiresPairing,
    });
  }

  String? get _problem {
    if (!_isValidNonce(nonce)) return 'nonce inválido';
    if (hostId.trim().isEmpty) return 'hostId vacío';
    if (hostId.length > kMaxDiscoveryHostIdLength) {
      return 'hostId de más de $kMaxDiscoveryHostIdLength caracteres';
    }
    if (hostName.trim().isEmpty) return 'hostName vacío';
    if (hostName.length > kMaxDiscoveryHostNameLength) {
      return 'hostName de más de $kMaxDiscoveryHostNameLength caracteres';
    }
    if (tcpPort < 1 || tcpPort > 65535) {
      return 'tcpPort $tcpPort fuera de rango';
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      other is DiscoveryResponse &&
      other.nonce == nonce &&
      other.hostId == hostId &&
      other.hostName == hostName &&
      other.tcpPort == tcpPort &&
      other.requiresPairing == requiresPairing;

  @override
  int get hashCode =>
      Object.hash(nonce, hostId, hostName, tcpPort, requiresPairing);

  @override
  String toString() =>
      'DiscoveryResponse($hostName [$hostId] tcp:$tcpPort'
      '${requiresPairing ? ', emparejamiento' : ''}, nonce: $nonce)';
}

Random _secureRandom() {
  try {
    return Random.secure();
  } on UnsupportedError {
    // Plataforma sin fuente criptográfica: un nonce menos impredecible sigue
    // sirviendo para casar respuestas con su escaneo.
    return Random();
  }
}

bool _isValidNonce(String nonce) {
  if (nonce.isEmpty || nonce.length > kMaxDiscoveryNonceLength) return false;
  for (final unit in nonce.codeUnits) {
    final isDigit = unit >= 0x30 && unit <= 0x39;
    final isLowerHex = unit >= 0x61 && unit <= 0x66;
    final isUpperHex = unit >= 0x41 && unit <= 0x46;
    if (!isDigit && !isLowerHex && !isUpperHex) return false;
  }
  return true;
}

Uint8List _encodeDatagram(Map<String, Object?> json) =>
    utf8.encode(jsonEncode(json));

/// Decodifica el datagrama y comprueba la cabecera común (`magic`, `v`,
/// `kind`). Los campos desconocidos se toleran para poder ampliar el formato
/// sin romper a los equipos que aún no se han actualizado.
Map<String, Object?>? _decodeEnvelope(List<int> bytes, String expectedKind) {
  if (bytes.isEmpty || bytes.length > kMaxDiscoveryDatagramBytes) return null;
  final Object? decoded;
  try {
    decoded = jsonDecode(utf8.decode(bytes));
  } on FormatException {
    return null;
  }
  if (decoded is! Map<String, Object?>) return null;
  if (decoded['magic'] != kDiscoveryMagic) return null;
  final version = decoded['v'];
  if (version is! int || version != kDiscoveryVersion) return null;
  if (decoded['kind'] != expectedKind) return null;
  return decoded;
}
