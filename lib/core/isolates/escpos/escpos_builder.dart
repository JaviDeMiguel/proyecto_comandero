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
/// normal (fuente A, 12 puntos por carácter), los puntos de imagen por línea
/// y la resolución del cabezal, que fija el tamaño físico de un raster.
///
/// El valor JSON es `name`. El valor `mm80Dpi180` solo se guarda en el perfil
/// de cada impresora (`impresion.formato.perfiles.*.papel`), nunca en el papel
/// heredado `impresion.paper`, para que una versión anterior de la aplicación
/// no encuentre un nombre que no conoce.
enum PaperWidth {
  /// Rollo de 58 mm: 32 columnas, 384 puntos (48 mm imprimibles a 8 puntos/mm).
  mm58(columns: 32, dots: 384, dpi: 203, etiqueta: '58 mm'),

  /// Rollo de 80 mm: 48 columnas, 576 puntos (72 mm imprimibles).
  mm80(columns: 48, dots: 576, dpi: 203, etiqueta: '80 mm'),

  /// Rollo de 80 mm a 180 ppp (Epson TM-T88 y compatibles): 42 columnas y 512
  /// puntos con la fuente A de 12 puntos.
  mm80Dpi180(columns: 42, dots: 512, dpi: 180, etiqueta: '80 mm (180 ppp)');

  const PaperWidth({
    required this.columns,
    required this.dots,
    required this.dpi,
    required this.etiqueta,
  });

  /// Caracteres por línea en fuente normal.
  final int columns;

  /// Puntos (píxeles) por línea para imágenes raster.
  final int dots;

  /// Resolución del cabezal en puntos por pulgada.
  final int dpi;

  /// Texto para la interfaz («58 mm», «80 mm»).
  final String etiqueta;

  /// Puntos por milímetro: 7,99 a 203 ppp y 7,09 a 180 ppp.
  double get puntosPorMm => dpi / 25.4;
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

/// Tramo de una línea compuesta ([EscPosBuilder.lineRuns]): texto que
/// comparte los atributos de la línea y solo decide si va en inverso.
final class TextRun extends Equatable {
  const TextRun(this.text, {this.inverse = false});

  final String text;

  /// Blanco sobre negro (`GS B 1`) solo en este tramo.
  final bool inverse;

  @override
  List<Object?> get props => [text, inverse];
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

  /// `ESC @` (reinicia modos), `ESC t 19` (página de códigos CP858) y
  /// `ESC R 0` (juego de caracteres internacional de EE. UU.).
  ///
  /// Se selecciona la página en el init porque `ESC @` la devuelve a la de
  /// fábrica (normalmente CP437, sin acentos ni euro). El juego internacional
  /// va después: una impresora configurada para «Spain I/II» sustituye
  /// `# @ [ \ ] { | }` por otros signos, y con el juego de EE. UU. esos bytes
  /// imprimen lo que dice la tabla CP858.
  void init() {
    _bytes.add(const [_esc, 0x40, _esc, 0x74, 19, _esc, 0x52, 0]);
  }

  /// Escribe texto con los atributos indicados, sin salto de línea final.
  ///
  /// Los atributos se activan antes del texto (alineación, negrita, subrayado,
  /// tamaño e inverso, en ese orden) y se desactivan después en orden inverso,
  /// para que cada llamada sea independiente del estado que dejó la anterior.
  void text(
    String value, {
    EscPosAlign align = EscPosAlign.left,
    bool bold = false,
    bool doubleHeight = false,
    bool doubleWidth = false,
    bool underline = false,
    bool inverse = false,
  }) {
    _setAlign(align);
    _writeRun(
      value,
      bold: bold,
      underline: underline,
      doubleHeight: doubleHeight,
      doubleWidth: doubleWidth,
      inverse: inverse,
    );
  }

  /// Texto seguido de LF (imprime la línea y avanza).
  void line(
    String value, {
    EscPosAlign align = EscPosAlign.left,
    bool bold = false,
    bool doubleHeight = false,
    bool doubleWidth = false,
    bool underline = false,
    bool inverse = false,
  }) {
    text(
      value,
      align: align,
      bold: bold,
      doubleHeight: doubleHeight,
      doubleWidth: doubleWidth,
      underline: underline,
      inverse: inverse,
    );
    _bytes.addByte(_lf);
  }

  /// Línea compuesta por tramos que comparten alineación, negrita y tamaño y
  /// que solo se distinguen por el inverso: la nota destacada de una comanda
  /// («   > » normal y el texto de la nota en inverso).
  ///
  /// Quien la llama parte antes el texto en filas que quepan en el papel. Por
  /// cada tramo se emiten los atributos de la línea, `GS B 1` si el tramo va
  /// en inverso, el texto y la desactivación; al final, LF.
  void lineRuns(
    List<TextRun> runs, {
    EscPosAlign align = EscPosAlign.left,
    bool bold = false,
    bool doubleHeight = false,
    bool doubleWidth = false,
  }) {
    _setAlign(align);
    for (final run in runs) {
      _writeRun(
        run.text,
        bold: bold,
        underline: false,
        doubleHeight: doubleHeight,
        doubleWidth: doubleWidth,
        inverse: run.inverse,
      );
    }
    _bytes.addByte(_lf);
  }

  /// Barra negra a todo el ancho del papel con [texto] centrado en blanco
  /// (ESPERAR, DOCUMENTO PROVISIONAL, DUPLICADO, MARCHAR, ANULACIÓN,
  /// REIMPRESIÓN, MUESTRA).
  ///
  /// Cada fila de `wrapWords(texto, columnas)` se imprime alineada a la
  /// izquierda, en negrita e inverso, y **rellenada con espacios** hasta las
  /// columnas disponibles (la mitad en doble ancho), de modo que el fondo
  /// negro sea continuo. Su texto decodificado empieza, por tanto, por los
  /// espacios del relleno.
  void banda(
    String texto, {
    bool doubleHeight = false,
    bool doubleWidth = false,
  }) {
    final columns = _columnsFor(doubleWidth);
    for (final row in wrapWords(texto, columns)) {
      line(
        fitRunes(row, columns, EscPosAlign.center),
        bold: true,
        doubleHeight: doubleHeight,
        doubleWidth: doubleWidth,
        inverse: true,
      );
    }
  }

  /// Texto largo partido en líneas de la anchura del papel (por palabras).
  void paragraph(
    String value, {
    EscPosAlign align = EscPosAlign.left,
    bool bold = false,
    bool doubleHeight = false,
    bool doubleWidth = false,
    bool inverse = false,
  }) {
    final width = _columnsFor(doubleWidth);
    for (final row in wrapWords(value, width)) {
      line(
        row,
        align: align,
        bold: bold,
        doubleHeight: doubleHeight,
        doubleWidth: doubleWidth,
        inverse: inverse,
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
    bool inverse = false,
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
        inverse: inverse,
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
    bool inverse = false,
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
        inverse: inverse,
      );
      line(
        fitRunes(rightText, width, EscPosAlign.right),
        bold: bold,
        doubleHeight: doubleHeight,
        doubleWidth: doubleWidth,
        inverse: inverse,
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
        inverse: inverse,
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

  /// Pitido del zumbador interno (`ESC B n t`): [veces] pitidos de
  /// [duracion] × 50 ms.
  ///
  /// Es el comando de facto de los clones (Xprinter, GPrinter…); Epson y Star
  /// no lo definen, y una impresora sin `ESC B` trata `n` y `t` como datos.
  /// Por eso ambos se limitan a 1..8: un 9 (`0x09`) sería un tabulador que la
  /// impresora ejecutaría. Lanza [ValidationException] fuera de ese rango.
  void pitido({int veces = 2, int duracion = 2}) {
    _requireRange(veces, 1, 8, 'El número de pitidos');
    _requireRange(duracion, 1, 8, 'La duración del pitido');
    _bytes.add([_esc, 0x42, veces, duracion]);
  }

  /// Zumbador externo conectado al puerto del cajón: [veces] pulsos
  /// `ESC p m 50 100` (100 ms encendido, 200 ms apagado) por el [pin] 5
  /// (m = 1) o el pin 2 (m = 0).
  ///
  /// Por defecto va por el pin 5, que no dispara un cajón conectado al pin 2.
  /// Lanza [ValidationException] si [veces] no está en 1..3 o [pin] no es
  /// 2 ni 5.
  void pulsoZumbadorCajon({int veces = 1, int pin = 5}) {
    _requireRange(veces, 1, 3, 'El número de pulsos del zumbador');
    if (pin != 2 && pin != 5) {
      throw ValidationException('El pin del zumbador es $pin: debe ser 2 o 5');
    }
    final m = pin == 5 ? 1 : 0;
    for (var i = 0; i < veces; i++) {
      _bytes.add([_esc, 0x70, m, 0x32, 0x64]);
    }
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

  /// Un tramo de texto con sus atributos activados antes y desactivados
  /// después (sin alineación, que es de la línea).
  void _writeRun(
    String value, {
    required bool bold,
    required bool underline,
    required bool doubleHeight,
    required bool doubleWidth,
    required bool inverse,
  }) {
    if (bold) _bytes.add(const [_esc, 0x45, 1]);
    if (underline) _bytes.add(const [_esc, 0x2D, 1]);
    final sizeByte = _sizeByte(doubleHeight, doubleWidth);
    if (sizeByte != 0) _bytes.add([_gs, 0x21, sizeByte]);
    if (inverse) _bytes.add(const [_gs, 0x42, 1]);

    _bytes.add(encodeCp858(value));

    if (inverse) _bytes.add(const [_gs, 0x42, 0]);
    if (sizeByte != 0) _bytes.add(const [_gs, 0x21, 0]);
    if (underline) _bytes.add(const [_esc, 0x2D, 0]);
    if (bold) _bytes.add(const [_esc, 0x45, 0]);
  }

  static void _requireRange(int value, int min, int max, String what) {
    if (value < min || value > max) {
      throw ValidationException(
        '$what es $value: debe estar entre $min y $max',
      );
    }
  }

  /// `GS ! n`: bits 4-7 multiplicador de anchura − 1, bits 0-3 de altura − 1.
  static int _sizeByte(bool doubleHeight, bool doubleWidth) =>
      (doubleWidth ? 0x10 : 0) | (doubleHeight ? 0x01 : 0);
}

/// Aviso sonoro de un documento de preparación (comanda, MARCHAR, anulación,
/// reimpresión), según el perfil de la impresora.
enum ZumbadorModo {
  /// Sin aviso.
  ninguno,

  /// Zumbador interno con `ESC B` ([EscPosBuilder.pitido]).
  generico,

  /// Zumbador externo en el puerto del cajón
  /// ([EscPosBuilder.pulsoZumbadorCajon]).
  puertoCajon,
}

/// Bytes del aviso sonoro (vacío si [modo] es `ninguno`). Es pura: el canal
/// de impresión los añade al final de un trabajo sin pasar por un generador.
///
/// [pitidos] se acota al rango de cada comando (1..8 con `generico`, 1..3 con
/// `puertoCajon`); [pin] solo cuenta con `puertoCajon` y debe ser 2 o 5
/// ([ValidationException] si no).
Uint8List bytesAviso(ZumbadorModo modo, {int pitidos = 2, int pin = 5}) {
  final b = EscPosBuilder(paper: PaperWidth.mm80);
  switch (modo) {
    case ZumbadorModo.ninguno:
      break;
    case ZumbadorModo.generico:
      b.pitido(veces: pitidos.clamp(1, 8), duracion: 2);
    case ZumbadorModo.puertoCajon:
      b.pulsoZumbadorCajon(veces: pitidos.clamp(1, 3), pin: pin);
  }
  return b.build();
}

/// `ESC p 0 25 250` suelto, los mismos bytes que [EscPosBuilder.openDrawer]:
/// el trabajo propio de abrir el cajón cuando no acompaña a un documento.
Uint8List bytesAbrirCajon() =>
    (EscPosBuilder(paper: PaperWidth.mm80)..openDrawer()).build();

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
