/// Informe Z (cierre de caja): el DTO [ZReportPrintData] con sus partidas
/// [PartidaZPrint], la función pura [generarInformeZ] y su variante en isolate
/// [generarInformeZEnIsolate].
library;

import 'dart:typed_data';

import 'package:equatable/equatable.dart';

import '../../../errors/app_exception.dart';
import '../../../money/money.dart';
import '../../isolate_runner.dart';
import '../escpos_builder.dart';
import 'modelos_comunes.dart';
import 'piezas.dart';

/// Partida del asiento propuesto por el Cierre Z.
typedef PartidaZPrint = ({
  String codsubcuenta,
  String concepto,
  int debeCents,
  int haberCents,
});

/// Precuenta de una mesa que se vació sin cobrar durante el turno, para la
/// sección «PRECUENTAS SIN COBRO» del informe.
typedef PrecuentaZPrint = ({
  int numero,
  String mesa,
  DateTime emitidaEn,
  int totalCents,
  String? motivo,
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
    this.precuentasSinCobro = const [],
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

  /// Precuentas de mesas vaciadas sin cobrar; la sección solo se imprime si
  /// hay alguna.
  final List<PrecuentaZPrint> precuentasSinCobro;
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
    precuentasSinCobro,
    paper,
    cortar,
  ];
}

/// Informe Z: magnitudes del día y asiento propuesto en formato Debe/Haber.
Uint8List generarInformeZ(ZReportPrintData data) {
  validateEmpresa(data.empresa);
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
  for (final precuenta in data.precuentasSinCobro) {
    if (precuenta.numero <= 0) {
      throw ValidationException(
        'Una precuenta sin cobro tiene el número ${precuenta.numero}: debe '
        'ser positivo',
      );
    }
    if (precuenta.mesa.trim().isEmpty) {
      throw ValidationException(
        'La precuenta sin cobro nº ${precuenta.numero} no indica la mesa',
      );
    }
  }

  final b = EscPosBuilder(paper: data.paper)..init();
  printCabeceraEmpresa(b, data.empresa);
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
    ..columns2('Fecha', formatFecha(data.fecha))
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
    final widths = threeColumnWidths(data.paper);
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
    final widths = threeColumnWidths(data.paper);
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

  _printPrecuentasSinCobro(b, data);

  finish(b, cortar: data.cortar);
  return b.build();
}

/// Sección «PRECUENTAS SIN COBRO»: una fila por precuenta (nº, mesa, hora y
/// total) con su motivo debajo, y al final el recuento y la suma. Solo si hay
/// alguna.
void _printPrecuentasSinCobro(EscPosBuilder b, ZReportPrintData data) {
  final precuentas = data.precuentasSinCobro;
  if (precuentas.isEmpty) return;
  b
    ..separator()
    ..line('PRECUENTAS SIN COBRO', bold: true);
  var suma = 0;
  for (final precuenta in precuentas) {
    suma += precuenta.totalCents;
    final cuando = mismoDia(precuenta.emitidaEn, data.fecha)
        ? formatHora(precuenta.emitidaEn)
        : formatFechaHora(precuenta.emitidaEn);
    b.columns2(
      'Nº ${precuenta.numero} · ${etiquetaMesa(precuenta.mesa)} · $cuando',
      formatCents(precuenta.totalCents),
    );
    final motivo = precuenta.motivo;
    if (motivo != null && motivo.trim().isNotEmpty) {
      printIndented(b, motivo.trim(), prefix: '   ');
    }
  }
  b
    ..columns2('Precuentas sin cobro', precuentas.length.toString())
    ..columns2('Suma', formatCents(suma), bold: true);
}

/// [generarInformeZ] en un isolate.
Future<Uint8List> generarInformeZEnIsolate(
  ZReportPrintData data, {
  IsolateRunner runner = const SpawningIsolateRunner(),
}) => runner.run(generarInformeZ, data, debugName: 'escpos-informe-z');
