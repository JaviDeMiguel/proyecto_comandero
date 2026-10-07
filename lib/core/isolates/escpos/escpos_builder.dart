/// Generador de comandos ESC/POS para impresoras térmicas Epson-compatibles.
///
/// Produce un `Uint8List` listo para enviarse en crudo al puerto 9100 de la
/// impresora. No hace E/S ni depende de Flutter, por lo que puede ejecutarse
/// dentro de un isolate.
///
/// Referencia de comandos: "ESC/POS Application Programming Guide" (Epson).
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:equatable/equatable.dart';

import '../../errors/app_exception.dart';
import 'cp858.dart';
import 'raster.dart';

const int _esc = 0x1B;
const int _gs = 0x1D;
const int _lf = 0x0A;

/// Anchura del rollo de papel. Determina las columnas de texto en fuente
/// normal (fuente A, 12 puntos por carácter) y los puntos de imagen por línea.
enum PaperWidth {
  /// Rollo de 58 mm: 32 columnas, 384 puntos (48 mm imprimibles a 8 puntos/mm).
  mm58(columns: 32, dots: 384),

  /// Rollo de 80 mm: 48 columnas, 576 puntos (72 mm imprimibles).
  mm80(columns: 48, dots: 576);

  const PaperWidth({required this.columns, required this.dots});

  /// Caracteres por línea en fuente normal.
  final int columns;

  /// Puntos (píxeles) por línea para imágenes raster.
  final int dots;
}

/// Alineación horizontal (`ESC a n`).
enum EscPosAlign {
  left(0),
  center(1),
  right(2);

  const EscPosAlign(this.code);

  /// Valor `n` del comando `ESC a`.
  final int code;
}

/// Nivel de corrección de errores de un QR (`GS ( k` función 169).
enum QrErrorCorrection {
  /// ~7 % de recuperación. Códigos más pequeños.
  low(48),

  /// ~15 %. Valor habitual para URLs de verificación.
  medium(49),

  /// ~25 %.
  quartile(50),

  /// ~30 %. Recomendado si el ticket puede mancharse.
  high(51);

  const QrErrorCorrection(this.code);

  final int code;
}

/// Celda de una fila tabulada ([EscPosBuilder.row]).
final class Column extends Equatable {
  const Column(
    this.text, {
    required this.width,
    this.align = EscPosAlign.left,
    this.wrap = false,
  });

  final String text;

  /// Anchura en caracteres (incluye cualquier espacio de separación que se
  /// quiera reservar: el builder no añade separadores entre celdas).
  final int width;

  final EscPosAlign align;

  /// Si es `true`, el texto que no cabe continúa en filas adicionales; si es
  /// `false`, se recorta a [width].
  final bool wrap;

  @override
  List<Object?> get props => [text, width, align, wrap];
}

/// Constructor incremental de un documento ESC/POS.
///
/// El orden de las llamadas es el orden de impresión. Todos los textos pasan
/// por [encodeCp858], de modo que un carácter de control jamás llega a la
/// impresora como comando (ver [cp858ByteFor]).
final class EscPosBuilder {
  EscPosBuilder({required this.paper});

  final PaperWidth paper;

  final BytesBuilder _bytes = BytesBuilder(copy: false);

  /// `ESC @` (reinicia modos) seguido de `ESC t 19` (página de códigos CP858).
  ///
  /// Se selecciona la página en el init porque `ESC @` la devuelve a la de
  /// fábrica (normalmente CP437, sin acentos ni euro).
  void init() {
    _bytes.add(const [_esc, 0x40, _esc, 0x74, 19]);
  }

  /// Escribe texto con los atributos indicados, sin salto de línea final.
  ///
  /// Los atributos se activan antes del texto y se desactivan después, para
  /// que cada llamada sea independiente del estado que dejó la anterior.
  void text(
    String value, {
    EscPosAlign align = EscPosAlign.left,
    bool bold = false,
    bool doubleHeight = false,
    bool doubleWidth = false,
    bool underline = false,
  }) {
    _setAlign(align);
    if (bold) _bytes.add(const [_esc, 0x45, 1]);
    if (underline) _bytes.add(const [_esc, 0x2D, 1]);
    final sizeByte = _sizeByte(doubleHeight, doubleWidth);
    if (sizeByte != 0) _bytes.add([_gs, 0x21, sizeByte]);

    _bytes.add(encodeCp858(value));

    if (sizeByte != 0) _bytes.add(const [_gs, 0x21, 0]);
    if (underline) _bytes.add(const [_esc, 0x2D, 0]);
    if (bold) _bytes.add(const [_esc, 0x45, 0]);
  }

  /// Texto seguido de LF (imprime la línea y avanza).
  void line(
    String value, {
    EscPosAlign align = EscPosAlign.left,
    bool bold = false,
    bool doubleHeight = false,
    bool doubleWidth = false,
    bool underline = false,
  }) {
    text(
      value,
      align: align,
      bold: bold,
      doubleHeight: doubleHeight,
      doubleWidth: doubleWidth,
      underline: underline,
    );
    _bytes.addByte(_lf);
  }

  /// Texto largo partido en líneas de la anchura del papel (por palabras).
  void paragraph(
    String value, {
    EscPosAlign align = EscPosAlign.left,
    bool bold = false,
    bool doubleHeight = false,
    bool doubleWidth = false,
  }) {
    final width = _columnsFor(doubleWidth);
    for (final row in wrapWords(value, width)) {
      line(
        row,
        align: align,
        bold: bold,
        doubleHeight: doubleHeight,
        doubleWidth: doubleWidth,
      );
    }
  }

  /// Fila tabulada: cada celda ocupa exactamente su anchura (rellena con
  /// espacios o recorta; con `wrap` continúa en filas siguientes dejando las
  /// demás celdas en blanco). Siempre se alinea a la izquierda del papel,
  /// porque la tabla ya ocupa su anchura completa.
  ///
  /// Lanza [ValidationException] si las anchuras no caben en el papel.
  void row(
    List<Column> cells, {
    bool bold = false,
    bool doubleHeight = false,
    bool doubleWidth = false,
  }) {
    if (cells.isEmpty) {
      throw const ValidationException(
        'La fila tabulada no tiene celdas: se necesita al menos una columna',
      );
    }
    final available = _columnsFor(doubleWidth);
    var total = 0;
    for (final cell in cells) {
      if (cell.width <= 0) {
        throw ValidationException(
          'La columna "${cell.text}" tiene anchura ${cell.width}: '
          'debe ser mayor que cero',
        );
      }
      total += cell.width;
    }
    if (total > available) {
      throw ValidationException(
        'Las columnas suman $total caracteres y el papel ${paper.name} '
        'solo tiene $available'
        '${doubleWidth ? ' en doble anchura' : ''}',
      );
    }

    final cellLines = [
      for (final cell in cells)
        cell.wrap ? wrapWords(cell.text, cell.width) : [cell.text],
    ];
    final rows = cellLines.fold<int>(
      1,
      (max, lines) => lines.length > max ? lines.length : max,
    );

    for (var r = 0; r < rows; r++) {
      final buffer = StringBuffer();
      for (var c = 0; c < cells.length; c++) {
        final lines = cellLines[c];
        final content = r < lines.length ? lines[r] : '';
        buffer.write(fitRunes(content, cells[c].width, cells[c].align));
      }
      line(
        buffer.toString(),
        bold: bold,
        doubleHeight: doubleHeight,
        doubleWidth: doubleWidth,
      );
    }
  }

  /// Dos columnas: [left] a la izquierda y [right] pegado al margen derecho.
  ///
  /// Si [left] no cabe en el espacio que deja [right] (más un espacio de
  /// separación), se parte por palabras en varias filas y [right] se imprime
  /// en la última, que es como se leen las descripciones largas de un ticket.
  /// Si [right] por sí solo supera la anchura, se recorta.
  void columns2(
    String left,
    String right, {
    bool bold = false,
    bool doubleHeight = false,
    bool doubleWidth = false,
  }) {
    final width = _columnsFor(doubleWidth);
    final rightText = truncateRunes(right, width);
    final rightLen = runeLength(rightText);
    final leftWidth = width - rightLen - 1;

    if (leftWidth <= 0) {
      // No queda sitio: la izquierda va en su propia fila.
      paragraph(
        left,
        bold: bold,
        doubleHeight: doubleHeight,
        doubleWidth: doubleWidth,
      );
      line(
        fitRunes(rightText, width, EscPosAlign.right),
        bold: bold,
        doubleHeight: doubleHeight,
        doubleWidth: doubleWidth,
      );
      return;
    }

    final leftLines = wrapWords(left, leftWidth);
    for (var i = 0; i < leftLines.length; i++) {
      final isLast = i == leftLines.length - 1;
      final content = isLast
          ? '${fitRunes(leftLines[i], leftWidth, EscPosAlign.left)} $rightText'
          : leftLines[i];
      line(
        content,
        bold: bold,
        doubleHeight: doubleHeight,
        doubleWidth: doubleWidth,
      );
    }
  }

  /// Línea de separación de anchura completa.
  void separator([String char = '-']) {
    if (runeLength(char) != 1) {
      throw ValidationException(
        'El separador "$char" debe ser un único carácter',
      );
    }
    line(char * paper.columns);
  }

  /// Avanza [n] líneas (`ESC d n`).
  void feed([int n = 1]) {
    if (n < 0 || n > 255) {
      throw ValidationException(
        'El avance de papel es de $n líneas: debe estar entre 0 y 255',
      );
    }
    if (n == 0) return;
    _bytes.add([_esc, 0x64, n]);
  }

  /// Corte de papel (`GS V 66 n` parcial / `GS V 65 n` completo) con avance de
  /// 3 líneas antes del corte, para que la última línea impresa salga de la
  /// cuchilla. Las impresoras sin cuchilla ignoran el comando.
  void cut({bool partial = true}) {
    _bytes.add([_gs, 0x56, partial ? 0x42 : 0x41, 3]);
  }

  /// Pulso al cajón portamonedas por el conector RJ11 (`ESC p 0 25 250`):
  /// pin 2, 50 ms activo (25 × 2 ms), 500 ms de reposo.
  void openDrawer() {
    _bytes.add(const [_esc, 0x70, 0x00, 0x19, 0xFA]);
  }

  /// Imagen de 1 bit con `GS v 0` (raster bit image) en bandas de hasta 255
  /// filas.
  ///
  /// Por qué bandas: el comando admite hasta 65 535 filas, pero muchas
  /// impresoras económicas tienen un búfer de recepción de pocos KB y, si el
  /// comando no cabe entero, descartan el resto y lo interpretan como texto
  /// (basura impresa). Con 255 filas cada banda ocupa como mucho
  /// 255 × 72 = 18 KB en 80 mm, dentro de lo que tolera cualquier modelo, y
  /// la impresora empieza a imprimir la primera banda mientras recibe las
  /// siguientes. Las bandas son contiguas, así que el resultado es una única
  /// imagen sin costuras.
  void raster(RasterImage image, {EscPosAlign align = EscPosAlign.center}) {
    if (image.width > paper.dots) {
      throw ValidationException(
        'La imagen mide ${image.width} puntos de ancho y el papel '
        '${paper.name} solo tiene ${paper.dots}',
      );
    }
    _setAlign(align);
    final bytesPerRow = image.width ~/ 8;
    var row = 0;
    while (row < image.height) {
      final remaining = image.height - row;
      final rows = remaining > 255 ? 255 : remaining;
      _bytes.add([
        _gs,
        0x76,
        0x30,
        0x00,
        bytesPerRow & 0xFF,
        (bytesPerRow >> 8) & 0xFF,
        rows & 0xFF,
        (rows >> 8) & 0xFF,
      ]);
      final start = row * bytesPerRow;
      _bytes.add(
        Uint8List.sublistView(image.bits, start, start + rows * bytesPerRow),
      );
      row += rows;
    }
  }

  /// Código QR nativo (`GS ( k`, modelo 2). [size] es la anchura del módulo en
  /// puntos (1–16; 4 ≈ 25 mm para una URL corta). Los datos se codifican en
  /// UTF-8, que es lo que esperan los lectores de móvil.
  ///
  /// Secuencia: modelo (fn 65), tamaño (fn 67), corrección (fn 69),
  /// almacenar datos (fn 80) e imprimir (fn 81).
  void qr(
    String data, {
    int size = 4,
    QrErrorCorrection errorCorrection = QrErrorCorrection.medium,
    EscPosAlign align = EscPosAlign.center,
  }) {
    if (size < 1 || size > 16) {
      throw ValidationException(
        'El tamaño de módulo del QR es $size: debe estar entre 1 y 16',
      );
    }
    final payload = utf8.encode(data);
    if (payload.isEmpty) {
      throw const ValidationException('El contenido del QR está vacío');
    }
    // Modelo 2 admite hasta 7 089 dígitos / 2 953 bytes binarios.
    if (payload.length > 2953) {
      throw ValidationException(
        'El contenido del QR ocupa ${payload.length} bytes: el máximo es 2953',
      );
    }
    _setAlign(align);
    _bytes.add(const [_gs, 0x28, 0x6B, 4, 0, 0x31, 0x41, 0x32, 0]);
    _bytes.add([_gs, 0x28, 0x6B, 3, 0, 0x31, 0x43, size]);
    _bytes.add([_gs, 0x28, 0x6B, 3, 0, 0x31, 0x45, errorCorrection.code]);
    final storeLen = payload.length + 3;
    _bytes.add([
      _gs,
      0x28,
      0x6B,
      storeLen & 0xFF,
      (storeLen >> 8) & 0xFF,
      0x31,
      0x50,
      0x30,
    ]);
    _bytes.add(payload);
    _bytes.add(const [_gs, 0x28, 0x6B, 3, 0, 0x31, 0x51, 0x30]);
  }

  /// Bytes acumulados. Se puede seguir añadiendo después; cada llamada
  /// devuelve una copia independiente.
  Uint8List build() => Uint8List.fromList(_bytes.toBytes());

  /// Columnas disponibles para el tamaño indicado.
  int columnsFor({bool doubleWidth = false}) => _columnsFor(doubleWidth);

  int _columnsFor(bool doubleWidth) =>
      doubleWidth ? paper.columns ~/ 2 : paper.columns;

  void _setAlign(EscPosAlign align) {
    _bytes.add([_esc, 0x61, align.code]);
  }

  /// `GS ! n`: bits 4-7 multiplicador de anchura − 1, bits 0-3 de altura − 1.
  static int _sizeByte(bool doubleHeight, bool doubleWidth) =>
      (doubleWidth ? 0x10 : 0) | (doubleHeight ? 0x01 : 0);
}

// ---------------------------------------------------------------------------
// Utilidades de maquetación. Trabajan con runas (puntos de código) porque cada
// runa se convierte en exactamente un byte CP858 y, por tanto, en una columna.
// ---------------------------------------------------------------------------

/// Número de columnas que ocupará [text] al imprimirse.
int runeLength(String text) => text.runes.length;

/// Recorta [text] a [width] columnas.
String truncateRunes(String text, int width) {
  final runes = text.runes;
  if (runes.length <= width) return text;
  return String.fromCharCodes(runes.take(width));
}

/// Recorta o rellena [text] con espacios hasta ocupar exactamente [width]
/// columnas, según [align].
String fitRunes(String text, int width, EscPosAlign align) {
  final clipped = truncateRunes(text, width);
  final padding = width - runeLength(clipped);
  if (padding <= 0) return clipped;
  switch (align) {
    case EscPosAlign.left:
      return clipped + ' ' * padding;
    case EscPosAlign.right:
      return ' ' * padding + clipped;
    case EscPosAlign.center:
      final before = padding ~/ 2;
      return ' ' * before + clipped + ' ' * (padding - before);
  }
}

/// Parte [text] en líneas de como máximo [width] columnas, por palabras. Las
/// palabras más largas que [width] se cortan. Los saltos de línea explícitos
/// se respetan. Siempre devuelve al menos una línea (vacía si no hay texto).
List<String> wrapWords(String text, int width) {
  if (width <= 0) {
    throw ValidationException(
      'La anchura de ajuste es $width: debe ser mayor que cero',
    );
  }
  final result = <String>[];
  for (final paragraph in text.split('\n')) {
    final words = paragraph
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList(growable: false);
    if (words.isEmpty) {
      result.add('');
      continue;
    }
    var current = StringBuffer();
    var currentLen = 0;
    for (final word in words) {
      var remaining = word;
      while (runeLength(remaining) > width) {
        // Palabra más larga que la línea: vuelca lo que hay y corta.
        if (currentLen > 0) {
          result.add(current.toString());
          current = StringBuffer();
          currentLen = 0;
        }
        result.add(truncateRunes(remaining, width));
        remaining = String.fromCharCodes(remaining.runes.skip(width));
      }
      final wordLen = runeLength(remaining);
      if (wordLen == 0) continue;
      if (currentLen == 0) {
        current.write(remaining);
        currentLen = wordLen;
      } else if (currentLen + 1 + wordLen <= width) {
        current
          ..write(' ')
          ..write(remaining);
        currentLen += 1 + wordLen;
      } else {
        result.add(current.toString());
        current = StringBuffer(remaining);
        currentLen = wordLen;
      }
    }
    if (currentLen > 0) result.add(current.toString());
  }
  return result;
}
