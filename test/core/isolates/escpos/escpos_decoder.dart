/// Decodificador mínimo de flujos ESC/POS para los tests: separa comandos de
/// texto y reconstruye las líneas impresas con sus atributos, de modo que los
/// tests puedan afirmar sobre el *resultado visible* (anchura, alineación)
/// además de sobre los bytes.
library;

import 'dart:typed_data';

import 'package:proyecto_comandero/core/isolates/escpos/cp858.dart';

/// Línea de texto tal como la imprimiría la impresora.
final class DecodedLine {
  const DecodedLine({
    required this.text,
    required this.align,
    required this.bold,
    required this.doubleHeight,
    required this.doubleWidth,
  });

  final String text;

  /// 0 izquierda, 1 centro, 2 derecha (valor de `ESC a`).
  final int align;
  final bool bold;
  final bool doubleHeight;
  final bool doubleWidth;

  @override
  String toString() =>
      '[${align == 0
          ? 'L'
          : align == 1
          ? 'C'
          : 'R'}'
      '${bold ? 'B' : ''}${doubleHeight ? 'H' : ''}${doubleWidth ? 'W' : ''}] '
      '"$text"';
}

/// Comando no textual encontrado en el flujo.
final class DecodedCommand {
  const DecodedCommand(this.name, [this.args = const []]);

  final String name;
  final List<int> args;

  @override
  String toString() => '$name$args';
}

/// Resultado de [decodeEscPos].
final class DecodedStream {
  DecodedStream({required this.lines, required this.commands});

  final List<DecodedLine> lines;
  final List<DecodedCommand> commands;

  List<String> get texts => lines.map((l) => l.text).toList(growable: false);

  Iterable<DecodedCommand> named(String name) =>
      commands.where((c) => c.name == name);
}

/// Recorre [bytes] interpretando los comandos que emite `EscPosBuilder`.
/// Lanza [StateError] ante un byte ESC/GS seguido de un comando desconocido,
/// para que un test detecte secuencias mal formadas.
DecodedStream decodeEscPos(Uint8List bytes) {
  final lines = <DecodedLine>[];
  final commands = <DecodedCommand>[];
  final current = <int>[];
  var align = 0;
  var bold = false;
  var doubleHeight = false;
  var doubleWidth = false;
  // Atributos con los que empezó la línea en curso (para líneas vacías se
  // usan los actuales).
  int? lineAlign;
  bool? lineBold;
  bool? lineH;
  bool? lineW;

  void flushLine() {
    lines.add(
      DecodedLine(
        text: decodeCp858(current),
        align: lineAlign ?? align,
        bold: lineBold ?? bold,
        doubleHeight: lineH ?? doubleHeight,
        doubleWidth: lineW ?? doubleWidth,
      ),
    );
    current.clear();
    lineAlign = null;
    lineBold = null;
    lineH = null;
    lineW = null;
  }

  var i = 0;
  while (i < bytes.length) {
    final b = bytes[i];
    if (b == 0x1B) {
      final cmd = bytes[i + 1];
      switch (cmd) {
        case 0x40: // ESC @
          commands.add(const DecodedCommand('init'));
          align = 0;
          bold = false;
          doubleHeight = false;
          doubleWidth = false;
          i += 2;
        case 0x74: // ESC t n
          commands.add(DecodedCommand('codepage', [bytes[i + 2]]));
          i += 3;
        case 0x61: // ESC a n
          align = bytes[i + 2];
          i += 3;
        case 0x45: // ESC E n
          bold = bytes[i + 2] != 0;
          i += 3;
        case 0x2D: // ESC - n
          commands.add(DecodedCommand('underline', [bytes[i + 2]]));
          i += 3;
        case 0x64: // ESC d n
          commands.add(DecodedCommand('feed', [bytes[i + 2]]));
          i += 3;
        case 0x70: // ESC p m t1 t2
          commands.add(
            DecodedCommand('drawer', [
              bytes[i + 2],
              bytes[i + 3],
              bytes[i + 4],
            ]),
          );
          i += 5;
        default:
          throw StateError(
            'Comando ESC desconocido: 0x${cmd.toRadixString(16)}',
          );
      }
      continue;
    }
    if (b == 0x1D) {
      final cmd = bytes[i + 1];
      switch (cmd) {
        case 0x21: // GS ! n
          final n = bytes[i + 2];
          doubleWidth = (n & 0xF0) != 0;
          doubleHeight = (n & 0x0F) != 0;
          i += 3;
        case 0x56: // GS V m n
          commands.add(DecodedCommand('cut', [bytes[i + 2], bytes[i + 3]]));
          i += 4;
        case 0x76: // GS v 0 m xL xH yL yH data
          final xL = bytes[i + 4];
          final xH = bytes[i + 5];
          final yL = bytes[i + 6];
          final yH = bytes[i + 7];
          final bytesPerRow = xL + xH * 256;
          final rows = yL + yH * 256;
          commands.add(
            DecodedCommand('raster', [bytes[i + 3], bytesPerRow, rows]),
          );
          i += 8 + bytesPerRow * rows;
        case 0x28: // GS ( k pL pH cn fn ...
          // GS ( k pL pH cn fn ... : los datos ocupan pL + pH*256 bytes a
          // partir de cn.
          final pL = bytes[i + 3];
          final pH = bytes[i + 4];
          final len = pL + pH * 256;
          final fn = bytes[i + 6];
          commands.add(DecodedCommand('qr', [fn, len]));
          i += 5 + len;
        default:
          throw StateError(
            'Comando GS desconocido: 0x${cmd.toRadixString(16)}',
          );
      }
      continue;
    }
    if (b == 0x0A) {
      flushLine();
      i++;
      continue;
    }
    if (current.isEmpty) {
      lineAlign = align;
      lineBold = bold;
      lineH = doubleHeight;
      lineW = doubleWidth;
    }
    current.add(b);
    i++;
  }
  if (current.isNotEmpty) flushLine();
  return DecodedStream(lines: lines, commands: commands);
}
