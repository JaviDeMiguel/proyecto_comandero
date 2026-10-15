/// Documentos de cliente de un ticket: el documento provisional del cobro y la
/// factura simplificada (ORIGINAL o DUPLICADO), con el DTO [TicketPrintData],
/// la función pura [generarTicket] y su variante en isolate
/// [generarTicketEnIsolate].
library;

import 'dart:typed_data';

import 'package:equatable/equatable.dart';

import '../../../errors/app_exception.dart';
import '../../../money/money.dart';
import '../../isolate_runner.dart';
import '../escpos_builder.dart';
import '../qr_raster.dart';
import '../raster.dart';
import 'modelos_comunes.dart';
import 'piezas.dart';

/// Frase del documento provisional sobre la factura.
const String _fraseProvisional =
    'Su factura simplificada se emite al cobrar: pídala en caja si la '
    'necesita.';

/// Longitud de la regla de la factura de muestra y separación de sus marcas;
/// cada [_reglaPasoLargoMm] la marca es más larga.
const int _reglaMm = 40;
const int _reglaPasoMm = 5;
const int _reglaPasoLargoMm = 10;

/// Alto de las marcas largas (todo el alto de la regla) y de las cortas.
const double _reglaAltoMm = 3;
const double _reglaAltoCortaMm = 1.5;

/// Grosor en puntos de los trazos de la regla: uno solo apenas se ve en el
/// papel térmico.
const int _reglaGrosor = 2;

/// Datos de un documento de cliente de un ticket.
///
/// Con [provisional] es el **documento provisional** del cobro: el título va
/// en banda, seguido de «NO VÁLIDO COMO FACTURA», sin número de factura ni
/// QR. Sin él es la **factura simplificada** (o el ticket de siempre si aún
/// no tiene código): `Nº <código>`, el QR tributario si lo hay y, con
/// [duplicado], la banda DUPLICADO.
final class TicketPrintData extends Equatable {
  const TicketPrintData({
    required this.empresa,
    required this.tituloDocumento,
    required this.fechaHora,
    required this.lineas,
    required this.desglose,
    required this.totalCents,
    required this.metodoPago,
    this.pagos = const [],
    this.codigoFactura,
    this.numero2,
    this.numeroLocal,
    this.mesa,
    this.zona,
    this.camarero,
    this.entregadoCents,
    this.cambioCents,
    this.avisos = const [],
    this.provisional = false,
    this.qrUrl,
    this.qrLeyenda,
    this.duplicado,
    this.fechaExpedicion,
    this.fechaOperacion,
    this.ivaIncluido = false,
    this.muestra = false,
    this.reglaQr = false,
    this.paper = PaperWidth.mm80,
    this.abrirCajon = false,
    this.cortar = true,
  });

  final EmpresaTicket empresa;

  /// `'DOCUMENTO PROVISIONAL'` (en banda, con [provisional]),
  /// `'FACTURA SIMPLIFICADA'` o `'TICKET'`.
  final String tituloDocumento;

  /// Código de la factura en FacturaScripts (p. ej. `F2026S12`), impreso como
  /// «Nº F2026S12». Si es nulo en un documento no provisional, el ticket aún
  /// no se ha facturado y se indica de forma discreta.
  final String? codigoFactura;

  /// Referencia del ticket (`numero2` de la factura), impresa como «Ref. …».
  final String? numero2;

  /// Número local del ticket, el que ve la caja («Ticket nº 15»).
  final int? numeroLocal;

  /// Fecha y hora del cobro.
  final DateTime fechaHora;
  final String? mesa;

  /// Zona de la mesa («Terraza»), tras la mesa en el documento provisional.
  final String? zona;
  final String? camarero;
  final List<LineaTicket> lineas;
  final List<DesgloseIvaTicketPrint> desglose;
  final int totalCents;

  /// Forma de pago impresa en un cobro simple (en uno mixto se imprime
  /// "Mixto" y el desglose de [pagos]).
  final String metodoPago;

  /// Desglose del cobro mixto. Vacío o con un solo pago, el ticket se
  /// imprime como siempre; con dos o más, una fila por pago. Si no está
  /// vacío debe sumar [totalCents].
  final List<PagoTicketPrint> pagos;

  /// Efectivo entregado (en un cobro mixto, para la parte en efectivo).
  final int? entregadoCents;

  /// Cambio devuelto (en un cobro mixto, sobre la parte en efectivo).
  final int? cambioCents;

  /// Avisos destacados ("COPIA", "Factura pendiente de revisión"...).
  final List<String> avisos;

  /// Documento provisional del cobro (decisión D1): nunca dice «factura».
  final bool provisional;

  /// URL del QR tributario, que se rasteriza dentro del isolate. Solo en la
  /// factura simplificada.
  final String? qrUrl;

  /// Leyenda bajo el QR («VERI*FACTU»); nula en el modo NO VERI*FACTU.
  final String? qrLeyenda;

  /// Marca de DUPLICADO de la factura; nula en el ORIGINAL.
  final DuplicadoPrint? duplicado;

  /// Fecha y hora de expedición de FacturaScripts. Sin ella se imprime la
  /// fecha del cobro ([fechaHora]) como hasta ahora.
  final DateTime? fechaExpedicion;

  /// Fecha de la operación (el cobro). Se imprime solo cuando su día difiere
  /// del de expedición; si coincide, el generador la omite.
  final DateTime? fechaOperacion;

  /// Imprime «IVA incluido» bajo el total.
  final bool ivaIncluido;

  /// Documento de muestra: empieza con la banda «MUESTRA · SIN VALIDEZ».
  final bool muestra;

  /// Factura de muestra (§5.18 del diseño de impresión): tras el bloque del
  /// QR, una regla raster de 40 mm con marcas cada 5 mm y la medida que debe
  /// dar el QR, para detectar un perfil con los ppp equivocados antes de
  /// activarlo. Solo cuenta con [qrUrl]; sin él no cambia nada.
  final bool reglaQr;

  final PaperWidth paper;

  /// Pulso del cajón justo después del `init`, antes de cualquier texto.
  final bool abrirCajon;
  final bool cortar;

  @override
  List<Object?> get props => [
    empresa,
    tituloDocumento,
    codigoFactura,
    numero2,
    numeroLocal,
    fechaHora,
    mesa,
    zona,
    camarero,
    lineas,
    desglose,
    totalCents,
    metodoPago,
    pagos,
    entregadoCents,
    cambioCents,
    avisos,
    provisional,
    qrUrl,
    qrLeyenda,
    duplicado,
    fechaExpedicion,
    fechaOperacion,
    ivaIncluido,
    muestra,
    reglaQr,
    paper,
    abrirCajon,
    cortar,
  ];
}

/// Documento provisional o factura simplificada. Lanza [ValidationException]
/// ante datos incoherentes (sin líneas, cantidades cero, importes negativos de
/// cambio, QR o DUPLICADO en un documento provisional...).
Uint8List generarTicket(TicketPrintData data) {
  _validar(data);

  final b = EscPosBuilder(paper: data.paper)..init();
  if (data.abrirCajon) b.openDrawer();
  if (data.muestra) printBandaMuestra(b);
  final qrUrl = data.qrUrl;
  if (qrUrl != null) {
    printQrTributario(b, url: qrUrl, leyenda: data.qrLeyenda);
    if (data.reglaQr) _printReglaQr(b, qrUrl);
  }
  printCabeceraEmpresa(b, data.empresa);
  b.separator();
  if (data.provisional) {
    _printCabeceraProvisional(b, data);
  } else {
    _printCabeceraFactura(b, data);
  }

  b.separator();
  printLineas(b, data.lineas);
  printTotalYDesglose(
    b,
    data.totalCents,
    data.desglose,
    ivaIncluido: data.ivaIncluido,
  );

  b.separator();
  _printCobro(b, data);
  _printAvisos(b, data.avisos);
  _printPie(b, data);

  finish(b, cortar: data.cortar);
  return b.build();
}

/// [generarTicket] en un isolate. El rasterizado del logo y del QR
/// (decodificar PNG, reescalar, dithering, módulos) es lo que justifica salir
/// del hilo de UI.
Future<Uint8List> generarTicketEnIsolate(
  TicketPrintData data, {
  IsolateRunner runner = const SpawningIsolateRunner(),
}) => runner.run(generarTicket, data, debugName: 'escpos-ticket');

void _validar(TicketPrintData data) {
  validateEmpresa(data.empresa);
  if (data.tituloDocumento.trim().isEmpty) {
    throw const ValidationException(
      'El título del documento está vacío: debe ser "DOCUMENTO PROVISIONAL", '
      '"FACTURA SIMPLIFICADA" o "TICKET"',
    );
  }
  validarLineasYDesglose(data.lineas, data.desglose, documento: 'El ticket');
  if (data.metodoPago.trim().isEmpty) {
    throw const ValidationException('La forma de pago del ticket está vacía');
  }
  final entregado = data.entregadoCents;
  if (entregado != null && entregado < 0) {
    throw ValidationException(
      'El importe entregado es ${formatCents(entregado)}: no puede ser '
      'negativo',
    );
  }
  final cambio = data.cambioCents;
  if (cambio != null && cambio < 0) {
    throw ValidationException(
      'El cambio es ${formatCents(cambio)}: no puede ser negativo',
    );
  }
  final numeroLocal = data.numeroLocal;
  if (numeroLocal != null && numeroLocal <= 0) {
    throw ValidationException(
      'El número local del ticket es $numeroLocal: debe ser positivo',
    );
  }
  final duplicado = data.duplicado;
  if (duplicado != null && duplicado.numero <= 0) {
    throw ValidationException(
      'El número de duplicado es ${duplicado.numero}: debe ser positivo',
    );
  }
  if (data.provisional && data.qrUrl != null) {
    throw const ValidationException(
      'El documento provisional no lleva QR tributario: el QR es solo de la '
      'factura simplificada',
    );
  }
  if (data.provisional && duplicado != null) {
    throw const ValidationException(
      'El documento provisional no se marca como DUPLICADO: esa marca es solo '
      'de la factura simplificada',
    );
  }
  _validarPagos(data);
}

/// Banda con el título, «NO VÁLIDO COMO FACTURA», el nº local con la hora del
/// cobro, la mesa con su zona y el camarero, y la referencia.
void _printCabeceraProvisional(EscPosBuilder b, TicketPrintData data) {
  b
    ..banda(data.tituloDocumento.trim(), doubleHeight: true)
    ..line('NO VÁLIDO COMO FACTURA', align: EscPosAlign.center, bold: true)
    ..separator();
  final numeroLocal = data.numeroLocal;
  b.columns2(
    numeroLocal == null ? '' : 'Ticket nº $numeroLocal',
    formatFechaHora(data.fechaHora),
  );
  _printMesaYCamarero(b, data, izquierda: _mesaYZona(data));
  _printReferencia(b, data.numero2);
}

/// Título, `Nº <código>` (o «Pendiente de facturar»), la banda DUPLICADO con
/// su número y hora, las fechas, «Ticket nº 15 · Mesa 7» con el camarero y la
/// referencia.
void _printCabeceraFactura(EscPosBuilder b, TicketPrintData data) {
  b.line(
    data.tituloDocumento.trim(),
    align: EscPosAlign.center,
    bold: true,
    doubleHeight: true,
  );
  final codigo = data.codigoFactura?.trim();
  if (codigo != null && codigo.isNotEmpty) {
    b.line(
      'Nº $codigo',
      align: EscPosAlign.center,
      bold: true,
      doubleHeight: true,
    );
  } else {
    b.line('Pendiente de facturar', align: EscPosAlign.center);
  }
  final duplicado = data.duplicado;
  if (duplicado != null) {
    b
      ..banda('DUPLICADO', doubleHeight: true, doubleWidth: true)
      ..columns2(
        'Duplicado nº ${duplicado.numero}',
        formatFechaHora(duplicado.impresoEn),
      );
  }
  final expedicion = data.fechaExpedicion;
  if (expedicion != null) {
    b.columns2('Fecha de expedición', formatFechaHora(expedicion));
  } else {
    // Sin fecha de FacturaScripts (ticket sin facturar o DTO anterior al
    // diseño): la fecha del cobro, como hasta ahora.
    b.line(formatFechaHora(data.fechaHora), align: EscPosAlign.center);
  }
  // «Fecha de operación» solo cuando su día difiere del de expedición (art.
  // 7.1.c del RD 1619/2012); el mismo día no aporta nada y se omite.
  final operacion = data.fechaOperacion;
  if (operacion != null && !mismoDia(operacion, expedicion ?? data.fechaHora)) {
    b.columns2('Fecha de operación', formatFecha(operacion));
  }
  final numeroLocal = data.numeroLocal;
  final mesa = data.mesa?.trim();
  final izquierda = [
    if (numeroLocal != null) 'Ticket nº $numeroLocal',
    if (mesa != null && mesa.isNotEmpty) etiquetaMesa(mesa),
  ].join(' · ');
  _printMesaYCamarero(b, data, izquierda: izquierda);
  _printReferencia(b, data.numero2);
}

/// «Mesa 7 · Terraza» para el documento provisional.
String _mesaYZona(TicketPrintData data) {
  final mesa = data.mesa?.trim();
  final zona = data.zona?.trim();
  return [
    if (mesa != null && mesa.isNotEmpty) etiquetaMesa(mesa),
    if (zona != null && zona.isNotEmpty) zona,
  ].join(' · ');
}

void _printMesaYCamarero(
  EscPosBuilder b,
  TicketPrintData data, {
  required String izquierda,
}) {
  final camarero = data.camarero?.trim();
  final derecha = camarero == null || camarero.isEmpty
      ? ''
      : 'Camarero: $camarero';
  if (izquierda.isEmpty && derecha.isEmpty) return;
  b.columns2(izquierda, derecha);
}

void _printReferencia(EscPosBuilder b, String? numero2) {
  final referencia = numero2?.trim();
  if (referencia == null || referencia.isEmpty) return;
  b.paragraph('Ref. $referencia');
}

void _printCobro(EscPosBuilder b, TicketPrintData data) {
  if (data.pagos.length > 1) {
    b.columns2('Forma de pago', 'Mixto');
    for (final pago in data.pagos) {
      b.columns2(pago.formaPago, formatCents(pago.importeCents));
    }
  } else {
    b.columns2('Forma de pago', data.metodoPago);
  }
  final entregado = data.entregadoCents;
  if (entregado != null) {
    b.columns2('Entregado', formatCents(entregado));
  }
  final cambio = data.cambioCents;
  if (cambio != null) {
    b.columns2('Cambio', formatCents(cambio));
  }
}

void _printAvisos(EscPosBuilder b, List<String> avisos) {
  final textos = avisos.where((a) => a.trim().isNotEmpty).toList();
  if (textos.isEmpty) return;
  b.feed();
  for (final aviso in textos) {
    b.paragraph(
      aviso,
      align: EscPosAlign.center,
      bold: true,
      doubleHeight: true,
    );
  }
}

/// Separador y, en el provisional, la frase sobre la factura; después el pie
/// de la empresa si lo hay.
void _printPie(EscPosBuilder b, TicketPrintData data) {
  final pie = data.empresa.pie?.trim();
  final hayPie = pie != null && pie.isNotEmpty;
  if (!data.provisional && !hayPie) return;
  b.separator();
  if (data.provisional) {
    b.paragraph(_fraseProvisional, align: EscPosAlign.center);
    if (hayPie) b.feed();
  }
  if (hayPie) {
    b.paragraph(pie, align: EscPosAlign.center);
  }
}

/// Bloque de la regla de la factura de muestra, tras el del QR: la regla, la
/// frase con el lado que debe medir el QR a la resolución del papel
/// (`QrRasterizado.ladoMm`, con coma decimal) y un separador.
void _printReglaQr(EscPosBuilder b, String qrUrl) {
  final qr = rasterizarQr(
    qrUrl,
    dpi: b.paper.dpi,
    anchoMaximoPuntos: b.paper.dots,
  );
  final lado = qr.ladoMm.toStringAsFixed(1).replaceAll('.', ',');
  b
    ..raster(_reglaRaster(b.paper))
    ..paragraph(
      'Regla de $_reglaMm mm. Este QR debe medir $lado mm: compruébelo con '
      'una regla',
      align: EscPosAlign.center,
    )
    ..separator();
}

/// Regla de [_reglaMm] mm a la resolución de [papel]: una base continua y una
/// marca cada [_reglaPasoMm] mm (puntos = mm × `papel.puntosPorMm`), más
/// larga cada [_reglaPasoLargoMm] mm. Todos los trazos tienen [_reglaGrosor]
/// puntos; la marca de cada medida empieza en su punto, así que de la primera
/// a la última hay exactamente `round(40 × puntosPorMm)` puntos.
RasterImage _reglaRaster(PaperWidth papel) {
  final puntosPorMm = papel.puntosPorMm;
  final largo = (_reglaMm * puntosPorMm).round();
  final alto = (_reglaAltoMm * puntosPorMm).round();
  final altoCorta = (_reglaAltoCortaMm * puntosPorMm).round();
  final ancho = ((largo + _reglaGrosor + 7) ~/ 8) * 8;
  final izquierda = (ancho - largo - _reglaGrosor) ~/ 2;
  final bytesPorFila = ancho ~/ 8;
  final bits = Uint8List(bytesPorFila * alto);
  void pintar(int x, int y) =>
      bits[y * bytesPorFila + (x >> 3)] |= 0x80 >> (x & 7);

  for (var y = alto - _reglaGrosor; y < alto; y++) {
    for (var x = izquierda; x < izquierda + largo + _reglaGrosor; x++) {
      pintar(x, y);
    }
  }
  for (var k = 0; k * _reglaPasoMm <= _reglaMm; k++) {
    final x = izquierda + (k * _reglaPasoMm * puntosPorMm).round();
    final larga = (k * _reglaPasoMm) % _reglaPasoLargoMm == 0;
    final altura = larga ? alto : altoCorta;
    for (var y = alto - altura; y < alto; y++) {
      for (var g = 0; g < _reglaGrosor; g++) {
        pintar(x + g, y);
      }
    }
  }
  return RasterImage(width: ancho, height: alto, bits: bits);
}

/// Desglose del cobro: formas no vacías y, si hay varias, distintas, con
/// importes positivos; en todo caso, suma igual al total.
void _validarPagos(TicketPrintData data) {
  final pagos = data.pagos;
  if (pagos.isEmpty) return;
  for (final pago in pagos) {
    if (pago.formaPago.trim().isEmpty) {
      throw const ValidationException(
        'Una de las formas de pago del ticket está vacía',
      );
    }
    if (pagos.length > 1 && pago.importeCents <= 0) {
      throw ValidationException(
        'El cobro con ${pago.formaPago} es ${formatCents(pago.importeCents)}: '
        'en un cobro mixto cada importe debe ser positivo',
      );
    }
  }
  final formas = pagos.map((p) => p.formaPago.trim().toLowerCase()).toSet();
  if (formas.length != pagos.length) {
    throw const ValidationException('El cobro mixto repite una forma de pago');
  }
  final suma = pagos.fold(0, (sum, p) => sum + p.importeCents);
  if (suma != data.totalCents) {
    throw ValidationException(
      'Los pagos suman ${formatCents(suma)} y el total es '
      '${formatCents(data.totalCents)}',
    );
  }
}
