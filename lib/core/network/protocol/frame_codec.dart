import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../../errors/app_exception.dart';

/// Tamaño máximo por defecto de una trama (sin contar el delimitador).
const int kDefaultMaxFrameBytes = 1024 * 1024;

const int _lf = 0x0A;
const int _cr = 0x0D;
const int _space = 0x20;
const int _tab = 0x09;

/// Serializa [json] como una trama JSON-line: `jsonEncode` en UTF-8 + `\n`.
///
/// `jsonEncode` escapa los saltos de línea que haya dentro de las cadenas, así
/// que el byte `0x0A` solo aparece como delimitador de trama.
Uint8List encodeFrame(
  Map<String, Object?> json, {
  int maxFrameBytes = kDefaultMaxFrameBytes,
}) {
  final String text;
  try {
    text = jsonEncode(json);
  } on JsonUnsupportedObjectError catch (error) {
    throw ProtocolException(
      'El mensaje no es serializable a JSON',
      cause: error,
    );
  }
  final body = utf8.encode(text);
  if (body.length > maxFrameBytes) {
    throw ProtocolException(
      'Trama de ${body.length} bytes: supera el máximo de $maxFrameBytes',
    );
  }
  return Uint8List(body.length + 1)
    ..setRange(0, body.length, body)
    ..[body.length] = _lf;
}

/// Resultado de decodificar una trama recibida.
sealed class FrameEvent {
  const FrameEvent();
}

/// Trama válida: un objeto JSON.
final class FrameData extends FrameEvent {
  const FrameData(this.json);

  final Map<String, Object?> json;
}

/// Trama rechazada.
///
/// Si [fatal] es `false` solo se descarta esa trama (el delimitador permite
/// resincronizar). Si es `true` el flujo deja de ser fiable y la conexión
/// debe cerrarse.
final class FrameFailure extends FrameEvent {
  const FrameFailure(this.error, {required this.fatal});

  final ProtocolException error;
  final bool fatal;
}

/// Decodificador incremental de tramas JSON-line.
///
/// TCP entrega un flujo de bytes sin fronteras de mensaje: una lectura puede
/// traer media trama, una trama y media o varias seguidas. El framer acumula
/// bytes hasta encontrar `\n` y solo entonces decodifica UTF-8, de modo que un
/// carácter multibyte partido entre dos segmentos nunca se interpreta a medias.
final class JsonLineFramer {
  JsonLineFramer({this.maxFrameBytes = kDefaultMaxFrameBytes})
    : assert(maxFrameBytes > 0, 'maxFrameBytes debe ser positivo');

  final int maxFrameBytes;
  final BytesBuilder _pending = BytesBuilder(copy: false);
  bool _broken = false;

  /// Bytes recibidos que todavía no completan una trama.
  int get pendingBytes => _pending.length;

  /// `true` tras un fallo fatal: todo lo que llegue después se ignora.
  bool get isBroken => _broken;

  /// Procesa un segmento recibido y devuelve las tramas que completa, en orden.
  List<FrameEvent> add(List<int> chunk) {
    if (_broken || chunk.isEmpty) return const [];

    final events = <FrameEvent>[];
    var start = 0;
    for (var i = 0; i < chunk.length; i++) {
      if (chunk[i] != _lf) continue;

      if (_pending.length + (i - start) > maxFrameBytes) {
        events.add(_breakWithOversize());
        return events;
      }
      _pending.add(chunk.sublist(start, i));
      start = i + 1;

      final event = _decodeLine(_pending.takeBytes());
      if (event != null) events.add(event);
    }

    if (start < chunk.length) {
      if (_pending.length + (chunk.length - start) > maxFrameBytes) {
        events.add(_breakWithOversize());
        return events;
      }
      _pending.add(chunk.sublist(start));
    }
    return events;
  }

  /// Señala el fin del flujo. Devuelve un fallo si quedaba una trama a medias.
  FrameFailure? close() {
    if (_broken || _pending.isEmpty) return null;
    final lost = _pending.length;
    _pending.clear();
    _broken = true;
    return FrameFailure(
      ProtocolException(
        'Conexión cerrada con una trama incompleta ($lost bytes)',
      ),
      fatal: true,
    );
  }

  FrameFailure _breakWithOversize() {
    _pending.clear();
    _broken = true;
    return FrameFailure(
      ProtocolException('Trama sin delimitador de más de $maxFrameBytes bytes'),
      fatal: true,
    );
  }

  FrameEvent? _decodeLine(Uint8List line) {
    var end = line.length;
    if (end > 0 && line[end - 1] == _cr) end--;
    if (_isBlank(line, end)) return null;

    final String text;
    try {
      text = utf8.decode(Uint8List.sublistView(line, 0, end));
    } on FormatException catch (error) {
      return FrameFailure(
        ProtocolException('Trama con UTF-8 inválido', cause: error),
        fatal: false,
      );
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException catch (error) {
      return FrameFailure(
        ProtocolException('Trama con JSON inválido', cause: error),
        fatal: false,
      );
    }

    if (decoded is! Map<String, Object?>) {
      return FrameFailure(
        const ProtocolException('La trama no es un objeto JSON'),
        fatal: false,
      );
    }
    return FrameData(decoded);
  }

  static bool _isBlank(Uint8List line, int end) {
    for (var i = 0; i < end; i++) {
      final byte = line[i];
      if (byte != _space && byte != _tab && byte != _cr) return false;
    }
    return true;
  }
}

/// Adapta [JsonLineFramer] a un `Stream` de segmentos de socket.
///
/// Uso: `const JsonLineDecoder().bind(socket)`.
final class JsonLineDecoder
    extends StreamTransformerBase<List<int>, FrameEvent> {
  const JsonLineDecoder({this.maxFrameBytes = kDefaultMaxFrameBytes});

  final int maxFrameBytes;

  @override
  Stream<FrameEvent> bind(Stream<List<int>> stream) {
    return Stream<FrameEvent>.eventTransformed(
      stream,
      (sink) => _FramerSink(JsonLineFramer(maxFrameBytes: maxFrameBytes), sink),
    );
  }
}

final class _FramerSink implements EventSink<List<int>> {
  _FramerSink(this._framer, this._output);

  final JsonLineFramer _framer;
  final EventSink<FrameEvent> _output;

  @override
  void add(List<int> chunk) => _framer.add(chunk).forEach(_output.add);

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _output.addError(error, stackTrace);

  @override
  void close() {
    final tail = _framer.close();
    if (tail != null) _output.add(tail);
    _output.close();
  }
}
