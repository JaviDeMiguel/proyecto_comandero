/// Documentos de hostelería en ESC/POS: ticket / factura simplificada,
/// comanda de cocina e informe Z.
///
/// Cada documento tiene (a) un DTO plano de entrada, (b) una función pura
/// `generarXxx(data) → Uint8List` y (c) `generarXxxEnIsolate` que la ejecuta a
/// través de un [IsolateRunner]. Las funciones puras no hacen E/S ni leen
/// estado global (ni siquiera `DateTime.now()`): con los mismos datos
/// producen exactamente los mismos bytes.
library;

import 'dart:typed_data';

import 'package:equatable/equatable.dart';

import '../../errors/app_exception.dart';
import '../../money/money.dart';
import '../isolate_runner.dart';
import 'escpos_builder.dart';
import 'raster.dart';

// ---------------------------------------------------------------------------
// DTOs
// ---------------------------------------------------------------------------

/// Datos de la empresa para la cabecera de tickets e informes.
final class EmpresaTicket extends Equatable {
  const EmpresaTicket({
    required this.nombre,
    this.cifnif,
    this.direccion,
    this.codpostal,
    this.ciudad,
    this.telefono,
    this.pie,
    this.logoPng,
  });

  final String nombre;
  final String? cifnif;
  final String? direccion;
  final String? codpostal;
  final String? ciudad;
  final String? telefono;

  /// Texto legal o de cortesía al pie del ticket ("IVA incluido", "Gracias
  /// por su visita"...).
  final String? pie;

  /// Logo codificado (PNG, JPEG...) que se rasteriza dentro del isolate.
  final Uint8List? logoPng;

  @override
  List<Object?> get props => [
    nombre,
    cifnif,
    direccion,
    codpostal,
    ciudad,
    telefono,
    pie,
    logoPng,
  ];
}

/// Línea de un ticket. [pvpUnitarioCents] e [importeCents] llevan el IVA
/// incluido (es lo que paga el cliente); el desglose va aparte.
final class LineaTicket extends Equatable {
  const LineaTicket({
    required this.descripcion,
    required this.cantidad,
    required this.pvpUnitarioCents,
    required this.importeCents,
    this.nota,
  });

  final String descripcion;
  final double cantidad;
  final int pvpUnitarioCents;
  final int importeCents;
  final String? nota;

  @override
  List<Object?> get props => [
    descripcion,
    cantidad,
    pvpUnitarioCents,
    importeCents,
    nota,
  ];
}

/// Fila del desglose de IVA (base y cuota en céntimos, tipo en porcentaje).
final class DesgloseIvaTicketPrint extends Equatable {
  const DesgloseIvaTicketPrint({
    required this.ivaPct,
    required this.baseCents,
    required this.cuotaCents,
  });

  final double ivaPct;
  final int baseCents;
  final int cuotaCents;

  @override
  List<Object?> get props => [ivaPct, baseCents, cuotaCents];
}

/// Una parte del cobro de un ticket mixto ("Efectivo" 12,35 €).
final class PagoTicketPrint extends Equatable {
  const PagoTicketPrint({required this.formaPago, required this.importeCents});

  /// Texto de la forma de pago tal como se imprime.
  final String formaPago;
  final int importeCents;

  @override
  List<Object?> get props => [formaPago, importeCents];
}

/// Datos de un ticket o factura simplificada.
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
    this.mesa,
    this.camarero,
    this.entregadoCents,
    this.cambioCents,
    this.avisos = const [],
    this.paper = PaperWidth.mm80,
    this.abrirCajon = false,
    this.cortar = true,
  });

  final EmpresaTicket empresa;

  /// `'FACTURA SIMPLIFICADA'` o `'TICKET'`.
  final String tituloDocumento;

  /// Código de la factura en FacturaScripts (p. ej. `FS2026-123`). Si es nulo
  /// el ticket aún no se ha facturado y se indica de forma discreta.
  final String? codigoFactura;

  /// Clave idempotente del ticket (`numero2` de la factura).
  final String? numero2;

  final DateTime fechaHora;
  final String? mesa;
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

  /// Avisos destacados ("COPIA", "ANULADO"...).
  final List<String> avisos;

  final PaperWidth paper;
  final bool abrirCajon;
  final bool cortar;

  @override
  List<Object?> get props => [
    empresa,
    tituloDocumento,
    codigoFactura,
    numero2,
    fechaHora,
    mesa,
    camarero,
    lineas,
    desglose,
    totalCents,
    metodoPago,
    pagos,
    entregadoCents,
    cambioCents,
    avisos,
    paper,
    abrirCajon,
    cortar,
  ];
}

/// Datos de una precuenta: la cuenta provisional que se lleva a la mesa antes
/// de cobrar. No es un documento fiscal, así que no lleva número de factura,
/// clave ni forma de pago, se marca como "sin validez fiscal" y nunca abre el
/// cajón.
final class PrecuentaPrintData extends Equatable {
  const PrecuentaPrintData({
    required this.empresa,
    required this.fechaHora,
    required this.mesa,
    required this.lineas,
    required this.desglose,
    required this.totalCents,
    this.camarero,
    this.comensales,
    this.paper = PaperWidth.mm80,
    this.cortar = true,
  });

  final EmpresaTicket empresa;
  final DateTime fechaHora;
  final String mesa;
  final String? camarero;

  /// Si hay más de uno se imprime el importe orientativo por comensal.
  final int? comensales;
  final List<LineaTicket> lineas;
  final List<DesgloseIvaTicketPrint> desglose;
  final int totalCents;
  final PaperWidth paper;
  final bool cortar;

  @override
  List<Object?> get props => [
    empresa,
    fechaHora,
    mesa,
    camarero,
    comensales,
    lineas,
    desglose,
    totalCents,
    paper,
    cortar,
  ];
}

/// Línea de una comanda de cocina o barra.
final class LineaComandaPrint extends Equatable {
  const LineaComandaPrint({
    required this.cantidad,
    required this.descripcion,
    this.nota,
    this.anulada = false,
  });

  final double cantidad;
  final String descripcion;
  final String? nota;

  /// Línea anulada tras enviarse: se imprime marcada para que cocina la
  /// retire.
  final bool anulada;

  @override
  List<Object?> get props => [cantidad, descripcion, nota, anulada];
}

/// Datos de una comanda para cocina o barra.
final class KitchenOrderPrintData extends Equatable {
  const KitchenOrderPrintData({
    required this.titulo,
    required this.mesa,
    required this.fechaHora,
    required this.lineas,
    this.camarero,
    this.numeroComanda,
    this.observaciones,
    this.paper = PaperWidth.mm80,
    this.cortar = true,
  });

  /// `'COCINA'`, `'BARRA'`...
  final String titulo;
  final String mesa;
  final String? camarero;
  final DateTime fechaHora;
  final String? numeroComanda;
  final List<LineaComandaPrint> lineas;
  final String? observaciones;
  final PaperWidth paper;
  final bool cortar;

  @override
  List<Object?> get props => [
    titulo,
    mesa,
    camarero,
    fechaHora,
    numeroComanda,
    lineas,
    observaciones,
    paper,
    cortar,
  ];
}

/// Partida del asiento propuesto por el Cierre Z.
typedef PartidaZPrint = ({
  String codsubcuenta,
  String concepto,
  int debeCents,
  int haberCents,
});

/// Datos del informe Z (cierre de caja).
final class ZReportPrintData extends Equatable {
  const ZReportPrintData({
    required this.empresa,
    required this.nombreTpv,
    required this.fecha,
    required this.numTickets,
    required this.numAnulados,
    required this.ventasTotalCents,
    required this.ventasEfectivoCents,
    required this.ventasTarjetaCents,
    required this.ticketMedioCents,
    required this.porIva,
    required this.fondoCajaCents,
    required this.retiradasCents,
    required this.efectivoEsperadoCents,
    required this.descuadreCents,
    this.efectivoContadoCents,
    this.partidas = const [],
    this.paper = PaperWidth.mm80,
    this.cortar = true,
  });

  final EmpresaTicket empresa;
  final String nombreTpv;
  final DateTime fecha;
  final int numTickets;
  final int numAnulados;
  final int ventasTotalCents;
  final int ventasEfectivoCents;
  final int ventasTarjetaCents;
  final int ticketMedioCents;
  final List<DesgloseIvaTicketPrint> porIva;
  final int fondoCajaCents;
  final int retiradasCents;
  final int efectivoEsperadoCents;

  /// Nulo si el cierre se hizo sin recuento.
  final int? efectivoContadoCents;

  /// Contado − esperado: negativo = faltante, positivo = sobrante.
  final int descuadreCents;

  /// Asiento propuesto; vacío cuando no hay nada que contabilizar.
  final List<PartidaZPrint> partidas;
  final PaperWidth paper;
  final bool cortar;

  @override
  List<Object?> get props => [
    empresa,
    nombreTpv,
    fecha,
    numTickets,
    numAnulados,
    ventasTotalCents,
    ventasEfectivoCents,
    ventasTarjetaCents,
    ticketMedioCents,
    porIva,
    fondoCajaCents,
    retiradasCents,
    efectivoEsperadoCents,
    efectivoContadoCents,
    descuadreCents,
    partidas,
    paper,
    cortar,
  ];
}

// ---------------------------------------------------------------------------
// Generadores (funciones puras)
// ---------------------------------------------------------------------------

/// Ticket / factura simplificada. Lanza [ValidationException] ante datos
/// incoherentes (sin líneas, cantidades cero, importes negativos de cambio...).
Uint8List generarTicket(TicketPrintData data) {
  _validateEmpresa(data.empresa);
  if (data.tituloDocumento.trim().isEmpty) {
    throw const ValidationException(
      'El título del documento está vacío: debe ser "TICKET" o '
      '"FACTURA SIMPLIFICADA"',
    );
  }
  _validarLineasYDesglose(data.lineas, data.desglose, documento: 'El ticket');
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
  _validarPagos(data);

  final b = EscPosBuilder(paper: data.paper)..init();
  _printCabeceraEmpresa(b, data.empresa);
  b
    ..separator()
    ..line(data.tituloDocumento, align: EscPosAlign.center, bold: true);

  final codigo = data.codigoFactura;
  if (codigo != null && codigo.trim().isNotEmpty) {
    b.line('Factura: $codigo', align: EscPosAlign.center, bold: true);
  } else {
    b.line('Pendiente de facturar', align: EscPosAlign.center);
  }
  final numero2 = data.numero2;
  if (numero2 != null && numero2.trim().isNotEmpty) {
    b.line('Ref.: $numero2', align: EscPosAlign.center);
  }
  b.line(_formatFechaHora(data.fechaHora), align: EscPosAlign.center);

  final mesa = data.mesa;
  final camarero = data.camarero;
  if (mesa != null || camarero != null) {
    b.columns2(
      mesa == null ? '' : 'Mesa: $mesa',
      camarero == null ? '' : 'Camarero: $camarero',
    );
  }

  b.separator();
  _printLineas(b, data.lineas);
  _printTotalYDesglose(b, data.totalCents, data.desglose);

  b.separator();
  if (data.pagos.length > 1) {
    b.columns2('Forma de pago', 'Mixto');
    for (final pago in data.pagos) {
      b.columns2(pago.formaPago, formatCents(pago.importeCents));
    }
  } else {
    b.columns2('Forma de pago', data.metodoPago);
  }
  if (entregado != null) {
    b.columns2('Entregado', formatCents(entregado));
  }
  if (cambio != null) {
    b.columns2('Cambio', formatCents(cambio));
  }

  if (data.avisos.isNotEmpty) {
    b.feed();
    for (final aviso in data.avisos) {
      if (aviso.trim().isEmpty) continue;
      b.paragraph(
        aviso,
        align: EscPosAlign.center,
        bold: true,
        doubleHeight: true,
      );
    }
  }

  final pie = data.empresa.pie;
  if (pie != null && pie.trim().isNotEmpty) {
    b
      ..feed()
      ..paragraph(pie, align: EscPosAlign.center);
  }

  _finish(b, cortar: data.cortar, abrirCajon: data.abrirCajon);
  return b.build();
}

/// Precuenta (cuenta provisional de una mesa). Lanza [ValidationException]
/// ante datos incoherentes (sin mesa, sin líneas, comensales no positivos...).
Uint8List generarPrecuenta(PrecuentaPrintData data) {
  _validateEmpresa(data.empresa);
  if (data.mesa.trim().isEmpty) {
    throw const ValidationException('La precuenta no indica la mesa');
  }
  _validarLineasYDesglose(
    data.lineas,
    data.desglose,
    documento: 'La precuenta',
  );
  final comensales = data.comensales;
  if (comensales != null && comensales <= 0) {
    throw ValidationException(
      'La precuenta indica $comensales comensales: debe ser un número '
      'positivo',
    );
  }

  final b = EscPosBuilder(paper: data.paper)..init();
  _printCabeceraEmpresa(b, data.empresa);
  b
    ..separator()
    ..line('PRECUENTA', align: EscPosAlign.center, bold: true)
    ..line(_formatFechaHora(data.fechaHora), align: EscPosAlign.center);
  final camarero = data.camarero;
  b.columns2(
    'Mesa: ${data.mesa}',
    camarero == null ? '' : 'Camarero: $camarero',
  );

  b.separator();
  _printLineas(b, data.lineas);
  _printTotalYDesglose(b, data.totalCents, data.desglose);

  if (comensales != null && comensales > 1) {
    b
      ..separator()
      ..columns2(
        'Por comensal ($comensales)',
        formatCents(divideRounding(data.totalCents, comensales)),
      );
  }

  b
    ..feed()
    ..paragraph(
      'DOCUMENTO SIN VALIDEZ FISCAL',
      align: EscPosAlign.center,
      bold: true,
    )
    ..paragraph(
      'No es una factura: el ticket se entrega al cobrar.',
      align: EscPosAlign.center,
    );

  final pie = data.empresa.pie;
  if (pie != null && pie.trim().isNotEmpty) {
    b
      ..feed()
      ..paragraph(pie, align: EscPosAlign.center);
  }

  _finish(b, cortar: data.cortar, abrirCajon: false);
  return b.build();
}

/// Comanda de cocina / barra: legible a distancia (mesa en doble tamaño,
/// líneas en doble altura) y con las anulaciones bien marcadas.
Uint8List generarComandaCocina(KitchenOrderPrintData data) {
  if (data.titulo.trim().isEmpty) {
    throw const ValidationException(
      'El título de la comanda está vacío: debe indicar el destino '
      '(COCINA, BARRA...)',
    );
  }
  if (data.mesa.trim().isEmpty) {
    throw const ValidationException('La comanda no indica la mesa');
  }
  if (data.lineas.isEmpty) {
    throw const ValidationException(
      'La comanda no tiene líneas: no se imprime una comanda vacía',
    );
  }
  for (final linea in data.lineas) {
    if (linea.descripcion.trim().isEmpty) {
      throw const ValidationException(
        'Una línea de la comanda no tiene descripción',
      );
    }
    if (linea.cantidad <= 0 || !linea.cantidad.isFinite) {
      throw ValidationException(
        'La línea "${linea.descripcion}" tiene cantidad ${linea.cantidad}: '
        'debe ser mayor que cero',
      );
    }
  }

  final b = EscPosBuilder(paper: data.paper)
    ..init()
    ..line(
      data.titulo,
      align: EscPosAlign.center,
      bold: true,
      doubleHeight: true,
    )
    ..paragraph(
      'MESA ${data.mesa}',
      align: EscPosAlign.center,
      bold: true,
      doubleHeight: true,
      doubleWidth: true,
    );

  final numero = data.numeroComanda;
  if (numero != null && numero.trim().isNotEmpty) {
    b.line('Comanda $numero', align: EscPosAlign.center);
  }
  b.line(_formatFechaHora(data.fechaHora), align: EscPosAlign.center);
  final camarero = data.camarero;
  if (camarero != null && camarero.trim().isNotEmpty) {
    b.line('Camarero: $camarero', align: EscPosAlign.center);
  }

  b.separator();
  for (final linea in data.lineas) {
    if (linea.anulada) {
      b.line('** ANULADA **', bold: true, doubleHeight: true);
    }
    b.paragraph(
      '${formatQuantity(linea.cantidad)} x ${linea.descripcion}',
      bold: true,
      doubleHeight: true,
    );
    final nota = linea.nota;
    if (nota != null && nota.trim().isNotEmpty) {
      _printIndented(b, nota, prefix: '   > ', doubleHeight: true);
    }
  }

  final observaciones = data.observaciones;
  if (observaciones != null && observaciones.trim().isNotEmpty) {
    b
      ..separator()
      ..line('OBSERVACIONES:', bold: true)
      ..paragraph(observaciones, doubleHeight: true);
  }

  _finish(b, cortar: data.cortar, abrirCajon: false);
  return b.build();
}

/// Informe Z: magnitudes del día y asiento propuesto en formato Debe/Haber.
Uint8List generarInformeZ(ZReportPrintData data) {
  _validateEmpresa(data.empresa);
  if (data.nombreTpv.trim().isEmpty) {
    throw const ValidationException('El informe Z no indica el nombre del TPV');
  }
  if (data.numTickets < 0) {
    throw ValidationException(
      'El número de tickets es ${data.numTickets}: no puede ser negativo',
    );
  }
  if (data.numAnulados < 0) {
    throw ValidationException(
      'El número de tickets anulados es ${data.numAnulados}: '
      'no puede ser negativo',
    );
  }
  for (final partida in data.partidas) {
    if (partida.codsubcuenta.trim().isEmpty) {
      throw ValidationException(
        'La partida "${partida.concepto}" no tiene subcuenta',
      );
    }
    if (partida.debeCents < 0 || partida.haberCents < 0) {
      throw ValidationException(
        'La partida ${partida.codsubcuenta} tiene importes negativos '
        '(Debe ${formatCents(partida.debeCents)}, '
        'Haber ${formatCents(partida.haberCents)}): un asiento se expresa con '
        'importes positivos en la columna que corresponda',
      );
    }
  }

  final b = EscPosBuilder(paper: data.paper)..init();
  _printCabeceraEmpresa(b, data.empresa);
  b
    ..separator()
    ..line(
      'INFORME Z',
      align: EscPosAlign.center,
      bold: true,
      doubleHeight: true,
    )
    ..line('Cierre de caja', align: EscPosAlign.center)
    ..columns2('TPV', data.nombreTpv)
    ..columns2('Fecha', _formatFecha(data.fecha))
    ..separator()
    ..line('VENTAS', bold: true)
    ..columns2('Tickets emitidos', data.numTickets.toString())
    ..columns2('Tickets anulados', data.numAnulados.toString())
    ..columns2('Ventas totales', formatCents(data.ventasTotalCents), bold: true)
    ..columns2('Ventas en efectivo', formatCents(data.ventasEfectivoCents))
    ..columns2('Ventas con tarjeta', formatCents(data.ventasTarjetaCents))
    ..columns2('Ticket medio', formatCents(data.ticketMedioCents));

  if (data.porIva.isNotEmpty) {
    b
      ..separator()
      ..line('DESGLOSE DE IVA', bold: true);
    final widths = _threeColumnWidths(data.paper);
    b.row([
      Column('IVA', width: widths.$1),
      Column('Base', width: widths.$2, align: EscPosAlign.right),
      Column('Cuota', width: widths.$3, align: EscPosAlign.right),
    ]);
    for (final iva in data.porIva) {
      b.row([
        Column(
          '${formatQuantity(iva.ivaPct, maxDecimals: 2)} %',
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

  b
    ..separator()
    ..line('CAJA', bold: true)
    ..columns2('Fondo de caja', formatCents(data.fondoCajaCents))
    ..columns2('Retiradas', formatCents(data.retiradasCents))
    ..columns2('Efectivo esperado', formatCents(data.efectivoEsperadoCents));
  final contado = data.efectivoContadoCents;
  b.columns2(
    'Efectivo contado',
    contado == null ? 'sin recuento' : formatCents(contado),
  );
  final descuadre = data.descuadreCents;
  b.columns2(
    descuadre == 0
        ? 'Descuadre'
        : (descuadre < 0 ? 'Descuadre (faltante)' : 'Descuadre (sobrante)'),
    formatCents(descuadre),
    bold: true,
  );

  b
    ..separator()
    ..line('ASIENTO PROPUESTO', bold: true);
  if (data.partidas.isEmpty) {
    b.line('Nada que contabilizar');
  } else {
    final widths = _threeColumnWidths(data.paper);
    b.row([
      Column('Subcuenta', width: widths.$1),
      Column('Debe', width: widths.$2, align: EscPosAlign.right),
      Column('Haber', width: widths.$3, align: EscPosAlign.right),
    ]);
    var totalDebe = 0;
    var totalHaber = 0;
    for (final partida in data.partidas) {
      totalDebe += partida.debeCents;
      totalHaber += partida.haberCents;
      if (partida.concepto.trim().isNotEmpty) {
        b.paragraph(partida.concepto);
      }
      b.row([
        Column(partida.codsubcuenta, width: widths.$1),
        Column(
          partida.debeCents == 0
              ? ''
              : formatCents(partida.debeCents, symbol: false),
          width: widths.$2,
          align: EscPosAlign.right,
        ),
        Column(
          partida.haberCents == 0
              ? ''
              : formatCents(partida.haberCents, symbol: false),
          width: widths.$3,
          align: EscPosAlign.right,
        ),
      ]);
    }
    b.row(bold: true, [
      Column('TOTAL', width: widths.$1),
      Column(
        formatCents(totalDebe, symbol: false),
        width: widths.$2,
        align: EscPosAlign.right,
      ),
      Column(
        formatCents(totalHaber, symbol: false),
        width: widths.$3,
        align: EscPosAlign.right,
      ),
    ]);
    if (totalDebe != totalHaber) {
      b.line('ASIENTO DESCUADRADO', align: EscPosAlign.center, bold: true);
    }
  }

  _finish(b, cortar: data.cortar, abrirCajon: false);
  return b.build();
}

// ---------------------------------------------------------------------------
// Versiones en isolate
// ---------------------------------------------------------------------------

/// [generarTicket] en un isolate. El rasterizado del logo (decodificar PNG,
/// reescalar, dithering) es lo que justifica salir del hilo de UI.
Future<Uint8List> generarTicketEnIsolate(
  TicketPrintData data, {
  IsolateRunner runner = const SpawningIsolateRunner(),
}) => runner.run(generarTicket, data, debugName: 'escpos-ticket');

/// [generarPrecuenta] en un isolate.
Future<Uint8List> generarPrecuentaEnIsolate(
  PrecuentaPrintData data, {
  IsolateRunner runner = const SpawningIsolateRunner(),
}) => runner.run(generarPrecuenta, data, debugName: 'escpos-precuenta');

/// [generarComandaCocina] en un isolate.
Future<Uint8List> generarComandaCocinaEnIsolate(
  KitchenOrderPrintData data, {
  IsolateRunner runner = const SpawningIsolateRunner(),
}) => runner.run(generarComandaCocina, data, debugName: 'escpos-comanda');

/// [generarInformeZ] en un isolate.
Future<Uint8List> generarInformeZEnIsolate(
  ZReportPrintData data, {
  IsolateRunner runner = const SpawningIsolateRunner(),
}) => runner.run(generarInformeZ, data, debugName: 'escpos-informe-z');

// ---------------------------------------------------------------------------
// Piezas comunes
// ---------------------------------------------------------------------------

/// Validaciones comunes del ticket y de la precuenta. [documento] encabeza
/// los mensajes ("El ticket", "La precuenta").
void _validarLineasYDesglose(
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

/// Líneas de venta: "cantidad x descripción ... importe", precio unitario si
/// la cantidad no es 1 y la nota sangrada.
void _printLineas(EscPosBuilder b, List<LineaTicket> lineas) {
  for (final linea in lineas) {
    b.columns2(
      '${formatQuantity(linea.cantidad)} x ${linea.descripcion}',
      formatCents(linea.importeCents, symbol: false),
    );
    if (linea.cantidad != 1) {
      b.line('   (${formatCents(linea.pvpUnitarioCents)}/ud)');
    }
    final nota = linea.nota;
    if (nota != null && nota.trim().isNotEmpty) {
      _printIndented(b, nota, prefix: '   * ');
    }
  }
}

/// Total en doble tamaño y, si lo hay, desglose de IVA en tres columnas.
void _printTotalYDesglose(
  EscPosBuilder b,
  int totalCents,
  List<DesgloseIvaTicketPrint> desglose,
) {
  b
    ..separator()
    ..columns2(
      'TOTAL',
      formatCents(totalCents),
      bold: true,
      doubleHeight: true,
      doubleWidth: true,
    );

  if (desglose.isNotEmpty) {
    b.separator();
    final widths = _threeColumnWidths(b.paper);
    b.row([
      Column('IVA', width: widths.$1),
      Column('Base', width: widths.$2, align: EscPosAlign.right),
      Column('Cuota', width: widths.$3, align: EscPosAlign.right),
    ]);
    for (final iva in desglose) {
      b.row([
        Column(
          '${formatQuantity(iva.ivaPct, maxDecimals: 2)} %',
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

void _validateEmpresa(EmpresaTicket empresa) {
  if (empresa.nombre.trim().isEmpty) {
    throw const ValidationException(
      'El nombre de la empresa está vacío: es obligatorio en la cabecera',
    );
  }
}

/// Logo (si lo hay) y datos de la empresa centrados.
void _printCabeceraEmpresa(EscPosBuilder b, EmpresaTicket empresa) {
  final logo = empresa.logoPng;
  if (logo != null && logo.isNotEmpty) {
    b
      ..raster(rasterizarLogo(logo, maxWidthDots: b.paper.dots))
      ..feed();
  }
  b.paragraph(empresa.nombre, align: EscPosAlign.center, bold: true);
  final cifnif = empresa.cifnif;
  if (cifnif != null && cifnif.trim().isNotEmpty) {
    b.line('CIF/NIF: $cifnif', align: EscPosAlign.center);
  }
  final direccion = empresa.direccion;
  if (direccion != null && direccion.trim().isNotEmpty) {
    b.paragraph(direccion, align: EscPosAlign.center);
  }
  final localidad = [
    empresa.codpostal,
    empresa.ciudad,
  ].where((p) => p != null && p.trim().isNotEmpty).join(' ');
  if (localidad.isNotEmpty) {
    b.paragraph(localidad, align: EscPosAlign.center);
  }
  final telefono = empresa.telefono;
  if (telefono != null && telefono.trim().isNotEmpty) {
    b.line('Tel.: $telefono', align: EscPosAlign.center);
  }
}

/// Texto ajustado con un prefijo en la primera línea y sangría equivalente en
/// las siguientes (notas de línea, observaciones).
void _printIndented(
  EscPosBuilder b,
  String text, {
  required String prefix,
  bool doubleHeight = false,
}) {
  final indent = ' ' * runeLength(prefix);
  final width = b.paper.columns - runeLength(prefix);
  final lines = wrapWords(text, width);
  for (var i = 0; i < lines.length; i++) {
    b.line(
      '${i == 0 ? prefix : indent}${lines[i]}',
      doubleHeight: doubleHeight,
    );
  }
}

/// Anchuras de las tablas de tres columnas (etiqueta, importe, importe), que
/// suman exactamente las columnas del papel.
(int, int, int) _threeColumnWidths(PaperWidth paper) => switch (paper) {
  PaperWidth.mm58 => (10, 11, 11),
  PaperWidth.mm80 => (16, 16, 16),
};

void _finish(
  EscPosBuilder b, {
  required bool cortar,
  required bool abrirCajon,
}) {
  b.feed(2);
  if (cortar) b.cut();
  if (abrirCajon) b.openDrawer();
}

String _two(int value) => value.toString().padLeft(2, '0');

String _formatFecha(DateTime d) =>
    '${_two(d.day)}/${_two(d.month)}/${d.year.toString().padLeft(4, '0')}';

String _formatFechaHora(DateTime d) =>
    '${_formatFecha(d)} ${_two(d.hour)}:${_two(d.minute)}';
