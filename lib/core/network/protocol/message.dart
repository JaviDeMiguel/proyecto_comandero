import 'package:meta/meta.dart';
import 'package:uuid/uuid.dart';

import '../../errors/app_exception.dart';

/// Versión del protocolo de mensajes host ⇄ comandero. Se valida en el `hello`.
const int kProtocolVersion = 1;

const int _maxIdLength = 64;
const int _maxTypeLength = 64;
const Uuid _uuid = Uuid();

/// Sobre común de todos los mensajes TCP entre el host y los comanderos.
///
/// En el cable (una línea terminada en `\n`):
/// `{"v":1,"id":"…","type":"comanda.submit","ts":1730000000000,"replyTo":"…","payload":{…}}`
///
/// * [id] identifica el mensaje de forma única; el host lo usa para
///   deduplicar retransmisiones tras una reconexión.
/// * [replyTo] enlaza una respuesta (`ack`, `error`, `pong`, `welcome`...) con
///   el mensaje que la originó.
@immutable
final class ProtocolMessage {
  const ProtocolMessage({
    required this.id,
    required this.type,
    required this.timestampMs,
    this.replyTo,
    this.payload = const {},
    this.version = kProtocolVersion,
  });

  /// Crea un mensaje nuevo con identificador único y la hora actual.
  factory ProtocolMessage.create(
    String type, {
    Map<String, Object?> payload = const {},
    String? replyTo,
    String? id,
    DateTime? now,
  }) {
    return ProtocolMessage(
      id: id ?? _uuid.v4(),
      type: type,
      timestampMs: (now ?? DateTime.now()).millisecondsSinceEpoch,
      replyTo: replyTo,
      payload: payload,
    );
  }

  /// Valida y convierte una trama decodificada.
  ///
  /// Lanza [ProtocolException] si falta un campo o su tipo no es el esperado.
  factory ProtocolMessage.fromJson(Map<String, Object?> json) {
    final version = json['v'];
    if (version is! int || version < 1) {
      throw const ProtocolException("Mensaje sin versión de protocolo ('v')");
    }
    final id = json['id'];
    if (id is! String || id.isEmpty || id.length > _maxIdLength) {
      throw const ProtocolException("Mensaje con 'id' ausente o inválido");
    }
    final type = json['type'];
    if (type is! String || type.isEmpty || type.length > _maxTypeLength) {
      throw const ProtocolException("Mensaje con 'type' ausente o inválido");
    }
    final timestamp = json['ts'];
    if (timestamp is! int) {
      throw const ProtocolException("Mensaje con 'ts' ausente o inválido");
    }
    final replyTo = json['replyTo'];
    if (replyTo != null &&
        (replyTo is! String ||
            replyTo.isEmpty ||
            replyTo.length > _maxIdLength)) {
      throw const ProtocolException("Mensaje con 'replyTo' inválido");
    }
    final payload = json['payload'];
    if (payload != null && payload is! Map<String, Object?>) {
      throw const ProtocolException(
        "Mensaje con 'payload' que no es un objeto",
      );
    }
    return ProtocolMessage(
      id: id,
      type: type,
      timestampMs: timestamp,
      replyTo: replyTo as String?,
      payload: (payload as Map<String, Object?>?) ?? const {},
      version: version,
    );
  }

  final String id;
  final String type;

  /// Hora del emisor (epoch en milisegundos). Solo informativa: los relojes
  /// de tablet y móviles no están sincronizados.
  final int timestampMs;
  final String? replyTo;
  final Map<String, Object?> payload;
  final int version;

  /// Construye la respuesta a este mensaje (`replyTo` = [id]).
  ProtocolMessage reply(
    String type, {
    Map<String, Object?> payload = const {},
    DateTime? now,
  }) => ProtocolMessage.create(type, payload: payload, replyTo: id, now: now);

  Map<String, Object?> toJson() => {
    'v': version,
    'id': id,
    'type': type,
    'ts': timestampMs,
    if (replyTo != null) 'replyTo': replyTo,
    'payload': payload,
  };

  @override
  String toString() =>
      'ProtocolMessage($type, id: $id${replyTo == null ? '' : ', replyTo: $replyTo'})';
}
