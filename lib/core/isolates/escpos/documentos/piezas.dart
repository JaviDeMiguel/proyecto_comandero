/// Piezas comunes de los documentos ESC/POS: cabecera del emisor, bloque del
/// QR tributario, líneas de venta con letra de IVA, total con desglose, banda
/// de muestra, nota destacada por tramos, texto sangrado, etiqueta de la mesa,
/// anchuras de las tablas de tres columnas, cierre del documento, formatos de
/// fecha y validaciones.
///
/// Son internas del paquete `documentos/`: el barril `ticket_documents.dart`
/// no las exporta y solo las importan los generadores de esta carpeta. Por eso
/// son públicas (sin guion bajo) aunque no formen parte de la API del módulo.
library;

import '../../../errors/app_exception.dart';
import '../../../money/money.dart';
import '../escpos_builder.dart';
import '../qr_raster.dart';
import '../raster.dart';
import 'modelos_comunes.dart';

/// Validaciones comunes del ticket y de la precuenta. [documento] encabeza
/// los mensajes ("El ticket", "La precuenta").
void validarLineasYDesglose(
  List<LineaTicket> lineas,
  List<DesgloseIvaTicketPrint> desglose, {
  required String documento,
}) {
  if (lineas.isEmpty) {
    throw ValidationException(
      '$documento no tiene líneas: no se imprime un documento vacío',
    );
  }
  for (final linea in lineas) {
    if (linea.descripcion.trim().isEmpty) {
      throw ValidationException('$documento tiene una línea sin descripción');
    }
    if (linea.cantidad == 0 || !linea.cantidad.isFinite) {
      throw ValidationException(
        'La línea "${linea.descripcion}" tiene cantidad ${linea.cantidad}: '
        'debe ser un número distinto de cero',
      );
    }
  }
  for (final iva in desglose) {
    if (iva.ivaPct < 0 || !iva.ivaPct.isFinite) {
      throw ValidationException(
        'El desglose contiene un tipo de IVA ${iva.ivaPct} %: '
        'debe ser un porcentaje no negativo',
      );
    }
  }
}

/// Líneas de venta: "cantidad x descripción ... importe" con la letra de IVA
/// tras el importe si la línea la lleva («8,00 A»), precio unitario si la
/// cantidad no es 1 y la nota sangrada.
void printLineas(EscPosBuilder b, List<LineaTicket> lineas) {
  for (final linea in lineas) {
    final importe = formatCents(linea.importeCents, symbol: false);
    final letra = linea.letraIva?.trim();
    b.columns2(
      '${formatQuantity(linea.cantidad)} x ${linea.descripcion}',
      letra == null || letra.isEmpty ? importe : '$importe $letra',
    );
    if (linea.cantidad != 1) {
      b.line('   (${formatCents(linea.pvpUnitarioCents)}/ud)');
    }
    final nota = linea.nota;
    if (nota != null && nota.trim().isNotEmpty) {
      printIndented(b, nota, prefix: '   * ');
    }
  }
}

/// Total en el mayor tamaño del documento (negrita, doble alto y doble ancho)
/// o, si «TOTAL», un espacio y el importe no caben en las columnas de doble
/// ancho (desde 10.000,00 € a 58 mm), en doble alto a anchura normal para no
/// partir la palabra. Después «IVA incluido» a la derecha, si [ivaIncluido], y
/// el desglose de IVA en tres columnas, con la letra de cada tipo si la lleva.
void printTotalYDesglose(
  EscPosBuilder b,
  int totalCents,
  List<DesgloseIvaTicketPrint> desglose, {
  bool ivaIncluido = false,
}) {
  final total = formatCents(totalCents);
  final cabeEnDobleAncho =
      runeLength('TOTAL') + 1 + runeLength(total) <=
      b.columnsFor(doubleWidth: true);
  b
    ..separator()
    ..columns2(
      'TOTAL',
      total,
      bold: true,
      doubleHeight: true,
      doubleWidth: cabeEnDobleAncho,
    );
  if (ivaIncluido) {
    b.line('IVA incluido', align: EscPosAlign.right);
  }

  if (desglose.isNotEmpty) {
    b.separator();
    final widths = threeColumnWidths(b.paper);
    b.row([
      Column('IVA', width: widths.$1),
      Column('Base', width: widths.$2, align: EscPosAlign.right),
      Column('Cuota', width: widths.$3, align: EscPosAlign.right),
    ]);
    for (final iva in desglose) {
      final tipo = '${formatQuantity(iva.ivaPct, maxDecimals: 2)} %';
      final letra = iva.letra?.trim();
      b.row([
        Column(
          letra == null || letra.isEmpty ? tipo : '$letra $tipo',
          width: widths.$1,
        ),
        Column(
          formatCents(iva.baseCents, symbol: false),
          width: widths.$2,
          align: EscPosAlign.right,
        ),
        Column(
          formatCents(iva.cuotaCents, symbol: false),
          width: widths.$3,
          align: EscPosAlign.right,
        ),
      ]);
    }
  }
}

void validateEmpresa(EmpresaTicket empresa) {
  if (empresa.nombre.trim().isEmpty) {
    throw const ValidationException(
      'El nombre de la empresa está vacío: es obligatorio en la cabecera',
    );
  }
}

/// Logo (si lo hay) y datos de la empresa centrados: el nombre comercial en
/// negrita y doble alto con la razón social debajo (o solo la razón social,
/// con el mismo realce, si no hay nombre comercial o coincide con ella), el
/// NIF, la dirección, «CP ciudad (provincia)», el teléfono y la web.
void printCabeceraEmpresa(EscPosBuilder b, EmpresaTicket empresa) {
  final logo = empresa.logoPng;
  if (logo != null && logo.isNotEmpty) {
    b
      ..raster(rasterizarLogo(logo, maxWidthDots: b.paper.dots))
      ..feed();
  }
  final nombre = empresa.nombre.trim();
  final comercial = empresa.nombreComercial?.trim();
  final hayComercial =
      comercial != null &&
      comercial.isNotEmpty &&
      comercial.toUpperCase() != nombre.toUpperCase();
  b.paragraph(
    hayComercial ? comercial : nombre,
    align: EscPosAlign.center,
    bold: true,
    doubleHeight: true,
  );
  if (hayComercial) {
    b.paragraph(nombre, align: EscPosAlign.center);
  }
  final cifnif = empresa.cifnif;
  if (cifnif != null && cifnif.trim().isNotEmpty) {
    b.line('NIF: ${cifnif.trim()}', align: EscPosAlign.center);
  }
  final direccion = empresa.direccion;
  if (direccion != null && direccion.trim().isNotEmpty) {
    b.paragraph(direccion, align: EscPosAlign.center);
  }
  final provincia = empresa.provincia?.trim();
  final localidad = [
    empresa.codpostal?.trim(),
    empresa.ciudad?.trim(),
  ].whereType<String>().where((p) => p.isNotEmpty).join(' ');
  final localidadCompleta = provincia == null || provincia.isEmpty
      ? localidad
      : '$localidad ($provincia)'.trim();
  if (localidadCompleta.isNotEmpty) {
    b.paragraph(localidadCompleta, align: EscPosAlign.center);
  }
  final telefono = empresa.telefono;
  if (telefono != null && telefono.trim().isNotEmpty) {
    b.line('Tel.: ${telefono.trim()}', align: EscPosAlign.center);
  }
  final web = empresa.web;
  if (web != null && web.trim().isNotEmpty) {
    b.paragraph(web.trim(), align: EscPosAlign.center);
  }
}

/// Bloque del QR tributario al principio de la factura (§6.3 del diseño):
/// «QR tributario:», la imagen rasterizada dentro del isolate y, si la hay,
/// la [leyenda] («VERI*FACTU»); los dos textos en negrita, doble alto y doble
/// ancho, el mayor tamaño de la factura, como exige la especificación de la
/// AEAT. Termina con un separador.
///
/// Lanza [ValidationException] si [url] está vacía o el QR no cabe entre 30 y
/// 40 mm en el papel.
void printQrTributario(
  EscPosBuilder b, {
  required String url,
  String? leyenda,
}) {
  if (url.trim().isEmpty) {
    throw const ValidationException('La URL del QR tributario está vacía');
  }
  final qr = rasterizarQr(
    url,
    dpi: b.paper.dpi,
    anchoMaximoPuntos: b.paper.dots,
  );
  b
    ..line(
      'QR tributario:',
      align: EscPosAlign.center,
      bold: true,
      doubleHeight: true,
      doubleWidth: true,
    )
    ..raster(qr.imagen);
  if (leyenda != null && leyenda.trim().isNotEmpty) {
    b.line(
      leyenda.trim(),
      align: EscPosAlign.center,
      bold: true,
      doubleHeight: true,
      doubleWidth: true,
    );
  }
  b.separator();
}

/// Banda «MUESTRA · SIN VALIDEZ» de los documentos de muestra de la página
/// «Tickets y comandas»: lo primero que se imprime, en doble alto.
void printBandaMuestra(EscPosBuilder b) {
  b.banda('MUESTRA · SIN VALIDEZ', doubleHeight: true);
}

/// Nombre de la mesa tal como se imprime: tal cual («Mesa 7», «Terraza 3») y,
/// si son solo dígitos, con el prefijo «Mesa» («Mesa 7»).
String etiquetaMesa(String mesa) {
  final texto = mesa.trim();
  return RegExp(r'^\d+$').hasMatch(texto) ? 'Mesa $texto' : texto;
}

/// Nota de una línea de preparación en negrita y doble alto, con el prefijo
/// «   > » sin inverso y el texto de la nota en inverso (una línea de dos
/// tramos, §6.1 del diseño), partida por palabras en filas que quepan; las
/// filas siguientes llevan una sangría de la anchura del prefijo.
void printNotaDestacada(
  EscPosBuilder b,
  String nota, {
  String prefix = '   > ',
}) {
  final indent = ' ' * runeLength(prefix);
  final width = b.paper.columns - runeLength(prefix);
  final rows = wrapWords(nota.trim(), width);
  for (var i = 0; i < rows.length; i++) {
    b.lineRuns(
      [TextRun(i == 0 ? prefix : indent), TextRun(rows[i], inverse: true)],
      bold: true,
      doubleHeight: true,
    );
  }
}

/// Texto ajustado con un prefijo en la primera línea y sangría equivalente en
/// las siguientes (notas de línea, observaciones).
void printIndented(
  EscPosBuilder b,
  String text, {
  required String prefix,
  bool bold = false,
  bool doubleHeight = false,
}) {
  final indent = ' ' * runeLength(prefix);
  final width = b.paper.columns - runeLength(prefix);
  final lines = wrapWords(text, width);
  for (var i = 0; i < lines.length; i++) {
    b.line(
      '${i == 0 ? prefix : indent}${lines[i]}',
      bold: bold,
      doubleHeight: doubleHeight,
    );
  }
}

/// «Camarero: Ana» a la izquierda y «4 comensales» a la derecha; con uno solo
/// de los dos datos, solo ese; sin ninguno, nada. Lo que no cabe en el papel
/// se parte por palabras (un nombre largo a 58 mm).
void printCamareroYComensales(
  EscPosBuilder b, {
  String? camarero,
  int? comensales,
}) {
  final nombre = camarero?.trim();
  final izquierda = nombre == null || nombre.isEmpty
      ? null
      : 'Camarero: $nombre';
  final derecha = comensales == null ? null : textoComensales(comensales);
  switch ((izquierda, derecha)) {
    case (null, null):
      return;
    case (final String texto, null):
      b.paragraph(texto);
    case (final texto, final String comensales):
      b.columns2(texto ?? '', comensales);
  }
}

/// «1 comensal», «4 comensales».
String textoComensales(int comensales) =>
    comensales == 1 ? '1 comensal' : '$comensales comensales';

/// Ordinal abreviado: «1º», «2º»…
String ordinalTexto(int n) => '$nº';

/// Observaciones al final de un documento de preparación (aviso de impresora
/// de respaldo, observaciones de la comanda); nada si no las hay. No lleva
/// separador propio: el que cierra el bloque de líneas ya hace de divisor.
void printObservaciones(EscPosBuilder b, String? observaciones) {
  if (observaciones == null || observaciones.trim().isEmpty) return;
  b
    ..line('OBSERVACIONES:', bold: true)
    ..paragraph(observaciones.trim(), doubleHeight: true);
}

/// Anchuras de las tablas de tres columnas (etiqueta, importe, importe), que
/// suman exactamente las columnas del papel: la etiqueta recibe un tercio y el
/// resto se reparte entre los dos importes. Da (10, 11, 11) con 32 columnas,
/// (14, 14, 14) con 42 y (16, 16, 16) con 48, sin depender de los valores de
/// [PaperWidth].
(int, int, int) threeColumnWidths(PaperWidth paper) {
  final columnas = paper.columns;
  final etiqueta = columnas ~/ 3;
  final primerImporte = (columnas - etiqueta) ~/ 2;
  return (etiqueta, primerImporte, columnas - etiqueta - primerImporte);
}

/// Avance final y corte. El pulso del cajón ya no va aquí: los generadores lo
/// emiten justo después del `init`, para que el cajón se abra en cuanto la
/// impresora empieza el trabajo.
void finish(EscPosBuilder b, {required bool cortar}) {
  b.feed(2);
  if (cortar) b.cut();
}

String _two(int value) => value.toString().padLeft(2, '0');

String formatFecha(DateTime d) =>
    '${_two(d.day)}/${_two(d.month)}/${d.year.toString().padLeft(4, '0')}';

String formatHora(DateTime d) => '${_two(d.hour)}:${_two(d.minute)}';

String formatFechaHora(DateTime d) => '${formatFecha(d)} ${formatHora(d)}';

/// `true` si [a] y [b] caen en el mismo día natural.
bool mismoDia(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;
