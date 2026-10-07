/// Codificación de texto a la página de códigos CP858 de las impresoras
/// térmicas Epson-compatibles (`ESC t 19`).
///
/// CP858 es CP850 (Latín occidental de MS-DOS) con el símbolo del euro en el
/// byte `0xD5` (en CP850 ese byte es la `ı` sin punto). Es la única página de
/// códigos con `€` que entienden prácticamente todas las impresoras de ticket
/// baratas, por eso se usa en lugar de CP1252 o UTF-8.
///
/// Cada carácter de entrada produce **exactamente un byte**, lo que permite al
/// [EscPosBuilder] calcular anchuras de columna contando caracteres (runas).
/// Todo carácter sin equivalente se sustituye por `?` para que el texto siga
/// ocupando lo previsto y nunca descoloque el ticket.
library;

import 'dart:typed_data';

/// Byte CP858 que ocupa el símbolo del euro.
const int cp858Euro = 0xD5;

/// Byte con el que se sustituye cualquier carácter sin representación.
const int cp858Unknown = 0x3F; // '?'

/// Código de punto Unicode → byte CP858 para la parte alta (0x80–0xFF).
///
/// Solo se incluyen los caracteres que puede necesitar un ticket español (y
/// portugués/francés/catalán por proximidad); los símbolos de dibujo de cajas
/// de CP850 se omiten a propósito.
const Map<int, int> _highTable = {
  0x00C7: 0x80, // Ç
  0x00FC: 0x81, // ü
  0x00E9: 0x82, // é
  0x00E2: 0x83, // â
  0x00E4: 0x84, // ä
  0x00E0: 0x85, // à
  0x00E5: 0x86, // å
  0x00E7: 0x87, // ç
  0x00EA: 0x88, // ê
  0x00EB: 0x89, // ë
  0x00E8: 0x8A, // è
  0x00EF: 0x8B, // ï
  0x00EE: 0x8C, // î
  0x00EC: 0x8D, // ì
  0x00C4: 0x8E, // Ä
  0x00C5: 0x8F, // Å
  0x00C9: 0x90, // É
  0x00E6: 0x91, // æ
  0x00C6: 0x92, // Æ
  0x00F4: 0x93, // ô
  0x00F6: 0x94, // ö
  0x00F2: 0x95, // ò
  0x00FB: 0x96, // û
  0x00F9: 0x97, // ù
  0x00FF: 0x98, // ÿ
  0x00D6: 0x99, // Ö
  0x00DC: 0x9A, // Ü
  0x00F8: 0x9B, // ø
  0x00A3: 0x9C, // £
  0x00D8: 0x9D, // Ø
  0x00D7: 0x9E, // ×
  0x0192: 0x9F, // ƒ
  0x00E1: 0xA0, // á
  0x00ED: 0xA1, // í
  0x00F3: 0xA2, // ó
  0x00FA: 0xA3, // ú
  0x00F1: 0xA4, // ñ
  0x00D1: 0xA5, // Ñ
  0x00AA: 0xA6, // ª
  0x00BA: 0xA7, // º
  0x00BF: 0xA8, // ¿
  0x00AE: 0xA9, // ®
  0x00AC: 0xAA, // ¬
  0x00BD: 0xAB, // ½
  0x00BC: 0xAC, // ¼
  0x00A1: 0xAD, // ¡
  0x00AB: 0xAE, // «
  0x00BB: 0xAF, // »
  0x00C1: 0xB5, // Á
  0x00C2: 0xB6, // Â
  0x00C0: 0xB7, // À
  0x00A9: 0xB8, // ©
  0x00A2: 0xBD, // ¢
  0x00A5: 0xBE, // ¥
  0x00E3: 0xC6, // ã
  0x00C3: 0xC7, // Ã
  0x00A4: 0xCF, // ¤
  0x00F0: 0xD0, // ð
  0x00D0: 0xD1, // Ð
  0x00CA: 0xD2, // Ê
  0x00CB: 0xD3, // Ë
  0x00C8: 0xD4, // È
  0x20AC: cp858Euro, // €
  0x00CD: 0xD6, // Í
  0x00CE: 0xD7, // Î
  0x00CF: 0xD8, // Ï
  0x00A6: 0xDD, // ¦
  0x00CC: 0xDE, // Ì
  0x00D3: 0xE0, // Ó
  0x00DF: 0xE1, // ß
  0x00D4: 0xE2, // Ô
  0x00D2: 0xE3, // Ò
  0x00F5: 0xE4, // õ
  0x00D5: 0xE5, // Õ
  0x00B5: 0xE6, // µ
  0x00FE: 0xE7, // þ
  0x00DE: 0xE8, // Þ
  0x00DA: 0xE9, // Ú
  0x00DB: 0xEA, // Û
  0x00D9: 0xEB, // Ù
  0x00FD: 0xEC, // ý
  0x00DD: 0xED, // Ý
  0x00AF: 0xEE, // ¯
  0x00B4: 0xEF, // ´
  0x00AD: 0xF0, // guion suave
  0x00B1: 0xF1, // ±
  0x2017: 0xF2, // ‗
  0x00BE: 0xF3, // ¾
  0x00B6: 0xF4, // ¶
  0x00A7: 0xF5, // §
  0x00F7: 0xF6, // ÷
  0x00B8: 0xF7, // ¸
  0x00B0: 0xF8, // °
  0x00A8: 0xF9, // ¨
  0x00B7: 0xFA, // ·
  0x00B9: 0xFB, // ¹
  0x00B3: 0xFC, // ³
  0x00B2: 0xFD, // ²
  0x25A0: 0xFE, // ■
  0x00A0: 0x20, // espacio duro → espacio normal (CP850 lo tiene en 0xFF, que
  // algunas impresoras pintan como bloque)
};

/// Caracteres tipográficos frecuentes en descripciones copiadas del ERP que
/// no existen en CP858 pero tienen un equivalente ASCII razonable.
const Map<int, int> _asciiFallback = {
  0x2018: 0x27, // ‘
  0x2019: 0x27, // ’
  0x201A: 0x27, // ‚
  0x201C: 0x22, // “
  0x201D: 0x22, // ”
  0x201E: 0x22, // „
  0x2013: 0x2D, // –
  0x2014: 0x2D, // —
  0x2010: 0x2D, // ‐
  0x2022: 0xFA, // • → · (punto medio de CP858)
  0x2032: 0x27, // ′
  0x2033: 0x22, // ″
  0x2122: 0x54, // ™ → 'T' (mejor que '?')
  0x2026: 0x2E, // … → '.' (se emite como un único byte)
};

/// Codifica [text] a bytes CP858, un byte por carácter.
///
/// - ASCII imprimible (0x20–0x7E) se copia tal cual.
/// - `\n` se emite como LF (`0x0A`, imprime y avanza) y `\t` como HT (`0x09`).
/// - Cualquier otro carácter de control (incluidos `0x1B` ESC y `0x1D` GS) se
///   sustituye por `?`: así un texto procedente de la red o del ERP no puede
///   inyectar comandos en la impresora.
/// - Caracteres fuera de la tabla (emoji, cirílico...) → `?`.
Uint8List encodeCp858(String text) {
  final runes = text.runes.toList(growable: false);
  final out = Uint8List(runes.length);
  for (var i = 0; i < runes.length; i++) {
    out[i] = cp858ByteFor(runes[i]);
  }
  return out;
}

/// Byte CP858 correspondiente a un código de punto Unicode.
int cp858ByteFor(int rune) {
  if (rune == 0x0A || rune == 0x09) return rune;
  if (rune >= 0x20 && rune <= 0x7E) return rune;
  return _highTable[rune] ?? _asciiFallback[rune] ?? cp858Unknown;
}

/// Tabla inversa byte → carácter, para decodificar lo que se envió a la
/// impresora (vista previa en pantalla, tests). Los bytes sin entrada en la
/// tabla directa (dibujo de cajas) se devuelven como `?`.
final Map<int, int> _reverseTable = {
  for (final entry in _highTable.entries)
    if (entry.key != 0x00A0) entry.value: entry.key,
};

/// Decodifica bytes CP858 a texto. Es la inversa de [encodeCp858] para todo
/// carácter representable; los bytes de control se conservan tal cual.
String decodeCp858(List<int> bytes) {
  final buffer = StringBuffer();
  for (final byte in bytes) {
    if (byte < 0x80) {
      buffer.writeCharCode(byte);
    } else {
      buffer.writeCharCode(_reverseTable[byte] ?? cp858Unknown);
    }
  }
  return buffer.toString();
}
