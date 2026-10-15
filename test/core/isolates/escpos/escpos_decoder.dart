/// Adaptador del decodificador ESC/POS para los tests: reexporta el de `lib`
/// y expone un `decodeEscPos` **estricto**, de modo que una secuencia mal
/// formada haga fallar el test en vez de pasar desapercibida.
library;

import 'dart:typed_data';

import 'package:proyecto_comandero/core/isolates/escpos/escpos_builder.dart'
    show PaperWidth;
import 'package:proyecto_comandero/core/isolates/escpos/escpos_decoder.dart'
    as lib;
import 'package:test/test.dart';

export 'package:proyecto_comandero/core/isolates/escpos/escpos_decoder.dart'
    hide decodeEscPos;

/// En los tests, estricto: una secuencia mal formada hace fallar el test.
lib.DecodedStream decodeEscPos(Uint8List bytes) =>
    lib.decodeEscPos(bytes, strict: true);

/// Ninguna línea supera el ancho del papel, contando por tramos (el doble
/// ancho cuenta doble). Compartida por las suites de documentos.
void expectWidthsWithin(lib.DecodedStream decoded, PaperWidth paper) {
  for (final line in decoded.lines) {
    expect(
      line.printedWidth,
      lessThanOrEqualTo(paper.columns),
      reason: 'línea demasiado larga: ${line.text}',
    );
  }
}
