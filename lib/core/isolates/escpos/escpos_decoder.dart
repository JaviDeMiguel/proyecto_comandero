/// Decodificador de flujos ESC/POS, la inversa de [EscPosBuilder]: separa los
/// comandos del texto y reconstruye las líneas impresas con sus atributos, por
/// tramos, de modo que la vista previa pueda dibujarlas y los tests afirmar
/// sobre el *resultado visible* (anchura, alineación, inverso) además de sobre
/// los bytes.
///
/// Es Dart puro y solo depende de `cp858.dart` y `raster.dart`, así que vale
/// tanto para `lib` (vista previa) como para los tests. No es un emulador
/// completo: reconoce los comandos que emite el builder y, en modo tolerante,
/// se salta lo que no entiende sin lanzar nunca.
library;

import 'dart:typed_data';

import 'cp858.dart';
import 'raster.dart';

const int _esc = 0x1B;
const int _gs = 0x1D;
const int _lf = 0x0A;

/// Tramo de una línea con atributos uniformes.
final class DecodedRun {
  const DecodedRun({
    required this.text,
    this.bold = false,
    this.underline = false,
    this.doubleHeight = false,
    this.doubleWidth = false,
    this.inverse = false,
  });

  final String text;
  final bool bold;
  final bool underline;
  final bool doubleHeight;
  final bool doubleWidth;

  /// Blanco sobre negro (`GS B 1`).
  final bool inverse;

  /// Columnas que ocupa al imprimirse: el doble ancho cuenta doble.
  int get printedWidth => text.runes.length * (doubleWidth ? 2 : 1);

  @override
  String toString() {
    final flags = _flags(
      bold: bold,
      doubleHeight: doubleHeight,
      doubleWidth: doubleWidth,
      underline: underline,
      inverse: inverse,
    );
    return '[$flags]"$text"';
  }
}

/// Línea de texto tal como la imprimiría la impresora.
///
/// Los atributos de la línea se derivan de los tramos («alguno lo tiene»), de
/// modo que una línea de un solo tramo, que es lo que imprime casi todo el
/// código, se lee igual que si tuviera los atributos directamente.
final class DecodedLine {
  const DecodedLine({required this.runs, required this.align});

  final List<DecodedRun> runs;

  /// 0 izquierda, 1 centro, 2 derecha (valor de `ESC a`).
  final int align;

  /// Concatenación de los tramos.
  String get text => runs.map((run) => run.text).join();

  bool get bold => runs.any((run) => run.bold);
  bool get underline => runs.any((run) => run.underline);
  bool get doubleHeight => runs.any((run) => run.doubleHeight);
  bool get doubleWidth => runs.any((run) => run.doubleWidth);
  bool get inverse => runs.any((run) => run.inverse);

  /// Suma de las anchuras de los tramos; el doble ancho cuenta doble.
  int get printedWidth =>
      runs.fold(0, (total, run) => total + run.printedWidth);

  @override
  String toString() {
    final alignLetter = switch (align) {
      0 => 'L',
      1 => 'C',
      _ => 'R',
    };
    final flags = _flags(
      bold: bold,
      doubleHeight: doubleHeight,
      doubleWidth: doubleWidth,
      underline: underline,
      inverse: inverse,
    );
    return '[$alignLetter$flags] "$text"';
  }
}

/// Comando no textual encontrado en el flujo.
///
/// [name] es uno de `init`, `codepage`, `charset`, `underline`, `feed`,
/// `drawer`, `beep`, `cut`, `raster`, `qr` o `desconocido`.
final class DecodedCommand {
  const DecodedCommand(this.name, [this.args = const []]);

  final String name;
  final List<int> args;

  @override
  String toString() => '$name$args';
}

/// Imagen raster reconstruida a partir de una o varias bandas `GS v 0`
/// consecutivas, con sus bits.
final class DecodedRaster {
  DecodedRaster({required this.image, required this.align});

  /// Bits tal como se enviaron (MSB primero, 1 = negro).
  final RasterImage image;

  /// 0 izquierda, 1 centro, 2 derecha (valor de `ESC a` al empezar la imagen).
  final int align;

  int get width => image.width;
  int get height => image.height;
  Uint8List get bits => image.bits;

  /// `true` si el punto ([x], [y]) es negro.
  bool isBlack(int x, int y) => image.isBlack(x, y);

  @override
  String toString() => 'raster ${width}x$height align=$align';
}

/// Elemento del documento, en el orden en que sale del papel.
sealed class DecodedElement {
  const DecodedElement();
}

/// Una línea de texto.
final class ElementoTexto extends DecodedElement {
  const ElementoTexto(this.linea);

  final DecodedLine linea;
}

/// Una imagen (logo, QR rasterizado).
final class ElementoImagen extends DecodedElement {
  const ElementoImagen(this.imagen);

  final DecodedRaster imagen;
}

/// Una marca sin texto: corte (`cut`), cajón (`drawer`), pitido (`beep`) o
/// avance de papel (`feed`).
final class ElementoMarca extends DecodedElement {
  const ElementoMarca(this.comando);

  final DecodedCommand comando;
}

/// Resultado de [decodeEscPos].
final class DecodedStream {
  const DecodedStream({
    required this.lines,
    required this.commands,
    required this.elements,
  });

  /// Líneas impresas, en orden.
  final List<DecodedLine> lines;

  /// Comandos no textuales, en orden. Conserva un `raster` por cada banda
  /// `GS v 0` (args `[m, bytesPorFila, filas]`).
  final List<DecodedCommand> commands;

  /// Texto, imágenes y marcas en el orden del papel, para la vista previa.
  final List<DecodedElement> elements;

  List<String> get texts =>
      lines.map((line) => line.text).toList(growable: false);

  Iterable<DecodedCommand> named(String name) =>
      commands.where((command) => command.name == name);

  /// Imágenes con las bandas consecutivas ya unidas.
  Iterable<DecodedRaster> get rasters =>
      elements.whereType<ElementoImagen>().map((element) => element.imagen);
}

/// Recorre [bytes] interpretando los comandos que emite [EscPosBuilder]:
/// `ESC @`, `ESC t n`, `ESC R n`, `ESC a n`, `ESC E n`, `ESC - n`, `ESC d n`,
/// `ESC p m t1 t2`, `ESC B n t`, `GS ! n`, `GS B n`, `GS V m n`, `GS v 0` y
/// `GS ( k`.
///
/// - Un cambio de atributo (negrita, subrayado, tamaño o inverso) dentro de
///   una línea abre un tramo nuevo; la alineación es la vigente al empezar la
///   línea.
/// - Tolerante por defecto: **nunca lanza**. Un comando desconocido se
///   registra como `desconocido` (args `[prefijo, byte]`) y se saltan esos dos
///   bytes; un comando truncado al final del flujo se descarta. Con [strict]
///   lanza [FormatException] en ambos casos (lo usan los tests).
/// - Con [wrapColumns] emula el salto de línea de la impresora: cuando un
///   carácter ya no cabe (el doble ancho cuenta doble, así que en doble ancho
///   caben la mitad) la línea se cierra y el tramo continúa en la siguiente.
/// - Las bandas `GS v 0` consecutivas del mismo ancho se unen en una sola
///   imagen en [DecodedStream.rasters] y [DecodedStream.elements]; en
///   [DecodedStream.commands] sigue habiendo un `raster` por banda.
/// - Avance, corte, cajón y pitido imprimen antes el texto pendiente, como
///   hace la impresora, para que [DecodedStream.elements] conserve el orden.
///
/// Lanza [ArgumentError] si [wrapColumns] no es positivo.
DecodedStream decodeEscPos(
  Uint8List bytes, {
  bool strict = false,
  int? wrapColumns,
}) {
  if (wrapColumns != null && wrapColumns <= 0) {
    throw ArgumentError.value(
      wrapColumns,
      'wrapColumns',
      'debe ser mayor que cero',
    );
  }
  return _Decoder(bytes, strict: strict, wrapColumns: wrapColumns).run();
}

/// Atributos de tramo vigentes en la impresora.
typedef _Attrs = ({
  bool bold,
  bool underline,
  bool doubleHeight,
  bool doubleWidth,
  bool inverse,
});

/// El flujo termina en mitad de un comando.
final class _TruncatedStream implements Exception {
  const _TruncatedStream(this.offset);

  final int offset;
}

/// Bandas `GS v 0` adyacentes que forman una misma imagen.
final class _PendingRaster {
  _PendingRaster({
    required this.mode,
    required this.bytesPerRow,
    required this.align,
  });

  final int mode;
  final int bytesPerRow;
  final int align;
  final BytesBuilder _bits = BytesBuilder();
  int rows = 0;

  /// Posición del primer byte que sigue a la última banda.
  int endOffset = 0;

  void append(Uint8List data, int rowCount, {required int end}) {
    _bits.add(data);
    rows += rowCount;
    endOffset = end;
  }

  /// `null` si la imagen está vacía (0 filas o 0 bytes por fila).
  DecodedRaster? toRaster() {
    if (bytesPerRow == 0 || rows == 0) return null;
    return DecodedRaster(
      image: RasterImage(
        width: bytesPerRow * 8,
        height: rows,
        bits: _bits.toBytes(),
      ),
      align: align,
    );
  }
}

final class _Decoder {
  _Decoder(this._bytes, {required this._strict, required this._wrapColumns});

  final Uint8List _bytes;
  final bool _strict;
  final int? _wrapColumns;

  final List<DecodedLine> _lines = [];
  final List<DecodedCommand> _commands = [];
  final List<DecodedElement> _elements = [];

  // Estado de la impresora.
  int _align = 0;
  bool _bold = false;
  bool _underline = false;
  bool _doubleHeight = false;
  bool _doubleWidth = false;
  bool _inverse = false;

  // Línea en curso: tramos cerrados, tramo abierto y su anchura impresa.
  final List<DecodedRun> _runs = [];
  final List<int> _runBytes = [];
  _Attrs? _openAttrs;
  int? _lineAlign;
  int _lineWidth = 0;

  _PendingRaster? _raster;

  int _i = 0;

  DecodedStream run() {
    try {
      while (_i < _bytes.length) {
        final b = _bytes[_i];
        if (b == _esc) {
          _escCommand();
        } else if (b == _gs) {
          _gsCommand();
        } else if (b == _lf) {
          _finishRaster();
          _flushLine();
          _i++;
        } else {
          _appendChar(b);
          _i++;
        }
      }
    } on _TruncatedStream catch (e) {
      if (_strict) {
        throw FormatException(
          'Flujo ESC/POS truncado: el comando que empieza en el byte '
          '${e.offset} no está completo',
          _bytes,
          e.offset,
        );
      }
    }
    _finishRaster();
    _flushIfPending();
    return DecodedStream(
      lines: List<DecodedLine>.unmodifiable(_lines),
      commands: List<DecodedCommand>.unmodifiable(_commands),
      elements: List<DecodedElement>.unmodifiable(_elements),
    );
  }

  _Attrs get _attrs => (
    bold: _bold,
    underline: _underline,
    doubleHeight: _doubleHeight,
    doubleWidth: _doubleWidth,
    inverse: _inverse,
  );

  // ---------------------------------------------------------------------------
  // Texto y líneas
  // ---------------------------------------------------------------------------

  void _appendChar(int b) {
    _finishRaster();
    final attrs = _attrs;
    final width = attrs.doubleWidth ? 2 : 1;
    final wrap = _wrapColumns;
    if (wrap != null && _lineWidth > 0 && _lineWidth + width > wrap) {
      // La impresora imprime la línea llena y sigue en la siguiente.
      _flushLine();
    }
    if (_openAttrs != attrs) {
      _closeRun();
      _openAttrs = attrs;
    }
    _lineAlign ??= _align;
    _runBytes.add(b);
    _lineWidth += width;
  }

  void _closeRun() {
    final attrs = _openAttrs;
    if (attrs == null) return;
    _runs.add(
      DecodedRun(
        text: decodeCp858(_runBytes),
        bold: attrs.bold,
        underline: attrs.underline,
        doubleHeight: attrs.doubleHeight,
        doubleWidth: attrs.doubleWidth,
        inverse: attrs.inverse,
      ),
    );
    _runBytes.clear();
    _openAttrs = null;
  }

  void _flushLine() {
    _closeRun();
    final line = DecodedLine(
      runs: List<DecodedRun>.unmodifiable(_runs),
      align: _lineAlign ?? _align,
    );
    _lines.add(line);
    _elements.add(ElementoTexto(line));
    _runs.clear();
    _lineAlign = null;
    _lineWidth = 0;
  }

  /// Imprime la línea en curso solo si tiene texto (antes de una marca o de
  /// una imagen, que la impresora saca después del búfer).
  void _flushIfPending() {
    if (_openAttrs != null || _runs.isNotEmpty) _flushLine();
  }

  // ---------------------------------------------------------------------------
  // Comandos
  // ---------------------------------------------------------------------------

  /// Comprueba que quedan [count] bytes desde la posición actual.
  void _need(int count) {
    if (_i + count > _bytes.length) throw _TruncatedStream(_i);
  }

  /// Argumentos de un comando de dos bytes de prefijo (`ESC x` / `GS x`) y
  /// [argCount] bytes de parámetros; avanza la posición tras ellos.
  List<int> _take(int argCount) {
    _need(2 + argCount);
    final args = List<int>.generate(
      argCount,
      (k) => _bytes[_i + 2 + k],
      growable: false,
    );
    _i += 2 + argCount;
    return args;
  }

  void _command(DecodedCommand command) => _commands.add(command);

  void _mark(DecodedCommand command) {
    _flushIfPending();
    _commands.add(command);
    _elements.add(ElementoMarca(command));
  }

  void _unknown(int prefix, int cmd) {
    if (_strict) {
      final name = prefix == _esc ? 'ESC' : 'GS';
      throw FormatException(
        'Comando $name desconocido: 0x${cmd.toRadixString(16)}',
        _bytes,
        _i,
      );
    }
    _commands.add(DecodedCommand('desconocido', [prefix, cmd]));
    _i += 2;
  }

  void _escCommand() {
    _need(2);
    _finishRaster();
    final cmd = _bytes[_i + 1];
    switch (cmd) {
      case 0x40: // ESC @
        _take(0);
        _resetModes();
        _command(const DecodedCommand('init'));
      case 0x74: // ESC t n
        _command(DecodedCommand('codepage', _take(1)));
      case 0x52: // ESC R n
        _command(DecodedCommand('charset', _take(1)));
      case 0x61: // ESC a n
        _align = _take(1).single;
      case 0x45: // ESC E n
        _bold = _take(1).single & 1 == 1;
      case 0x2D: // ESC - n
        final args = _take(1);
        _underline = const [1, 2, 49, 50].contains(args.single);
        _command(DecodedCommand('underline', args));
      case 0x64: // ESC d n
        _mark(DecodedCommand('feed', _take(1)));
      case 0x70: // ESC p m t1 t2
        _mark(DecodedCommand('drawer', _take(3)));
      case 0x42: // ESC B n t
        _mark(DecodedCommand('beep', _take(2)));
      default:
        _unknown(_esc, cmd);
    }
  }

  void _gsCommand() {
    _need(2);
    final cmd = _bytes[_i + 1];
    if (cmd == 0x76) {
      _rasterBand();
      return;
    }
    _finishRaster();
    switch (cmd) {
      case 0x21: // GS ! n
        final n = _take(1).single;
        _doubleWidth = (n & 0xF0) != 0;
        _doubleHeight = (n & 0x0F) != 0;
      case 0x42: // GS B n
        _inverse = _take(1).single & 1 == 1;
      case 0x56: // GS V m n
        _mark(DecodedCommand('cut', _take(2)));
      case 0x28: // GS ( k pL pH cn fn ...
        _symbol();
      default:
        _unknown(_gs, cmd);
    }
  }

  /// `GS ( k pL pH cn fn …`: los datos ocupan `pL + pH × 256` bytes a partir
  /// de `cn`. Se registra como `qr` con `[fn, longitud]`.
  void _symbol() {
    _need(7);
    if (_bytes[_i + 2] != 0x6B) {
      _unknown(_gs, 0x28);
      return;
    }
    final len = _bytes[_i + 3] + _bytes[_i + 4] * 256;
    final fn = _bytes[_i + 6];
    final total = 5 + len;
    _need(total < 7 ? 7 : total);
    _command(DecodedCommand('qr', [fn, len]));
    _i += total;
  }

  void _resetModes() {
    _align = 0;
    _bold = false;
    _underline = false;
    _doubleHeight = false;
    _doubleWidth = false;
    _inverse = false;
  }

  // ---------------------------------------------------------------------------
  // Raster
  // ---------------------------------------------------------------------------

  /// `GS v 0 m xL xH yL yH datos`: una banda. Se une a la anterior si empieza
  /// justo donde terminó y tiene su mismo ancho y modo.
  void _rasterBand() {
    _need(8);
    if (_bytes[_i + 2] != 0x30) {
      _finishRaster();
      _unknown(_gs, 0x76);
      return;
    }
    final mode = _bytes[_i + 3];
    final bytesPerRow = _bytes[_i + 4] + _bytes[_i + 5] * 256;
    final rows = _bytes[_i + 6] + _bytes[_i + 7] * 256;
    final dataLength = bytesPerRow * rows;
    _need(8 + dataLength);
    _commands.add(DecodedCommand('raster', [mode, bytesPerRow, rows]));

    final start = _i + 8;
    final end = start + dataLength;
    final data = Uint8List.sublistView(_bytes, start, end);
    final pending = _raster;
    if (pending != null &&
        pending.endOffset == _i &&
        pending.bytesPerRow == bytesPerRow &&
        pending.mode == mode) {
      pending.append(data, rows, end: end);
    } else {
      _finishRaster();
      _flushIfPending();
      _raster = _PendingRaster(
        mode: mode,
        bytesPerRow: bytesPerRow,
        align: _align,
      )..append(data, rows, end: end);
    }
    _i = end;
  }

  void _finishRaster() {
    final pending = _raster;
    if (pending == null) return;
    _raster = null;
    final raster = pending.toRaster();
    if (raster != null) _elements.add(ElementoImagen(raster));
  }
}

String _flags({
  required bool bold,
  required bool doubleHeight,
  required bool doubleWidth,
  required bool underline,
  required bool inverse,
}) =>
    '${bold ? 'B' : ''}${doubleHeight ? 'H' : ''}${doubleWidth ? 'W' : ''}'
    '${underline ? 'U' : ''}${inverse ? 'I' : ''}';
