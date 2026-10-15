/// Precuenta (cuenta provisional de una mesa): el DTO [PrecuentaPrintData], la
/// función pura [generarPrecuenta] y su variante en isolate
/// [generarPrecuentaEnIsolate].
library;

import 'dart:typed_data';

import 'package:equatable/equatable.dart';

import '../../../errors/app_exception.dart';
import '../../../money/money.dart';
import '../../isolate_runner.dart';
import '../escpos_builder.dart';
import 'modelos_comunes.dart';
import 'piezas.dart';

/// Datos de una precuenta: la cuenta provisional que se lleva a la mesa antes
/// de cobrar. No es un documento fiscal, así que no lleva número de factura,
/// clave, QR ni forma de pago, se marca como "sin validez fiscal" y nunca abre
/// el cajón. Se arma desde el registro guardado en la comanda
/// (`PrecuentaEmitida`), no desde la comanda viva.
final class PrecuentaPrintData extends Equatable {
  const PrecuentaPrintData({
    required this.empresa,
    required this.fechaHora,
    required this.mesa,
    required this.lineas,
    required this.desglose,
    required this.totalCents,
    this.numero,
    this.zona,
    this.camarero,
    this.comensales,
    this.ivaIncluido = false,
    this.muestra = false,
    this.paper = PaperWidth.mm80,
    this.cortar = true,
  });

  final EmpresaTicket empresa;
  final DateTime fechaHora;
  final String mesa;

  /// Zona de la mesa («Terraza»), tras la mesa.
  final String? zona;

  /// Número correlativo dentro de la comanda («PRECUENTA Nº 2»); sin él, solo
  /// «PRECUENTA».
  final int? numero;

  /// Nulo cuando «Mostrar el camarero» está apagado.
  final String? camarero;

  /// Si hay más de uno se imprime el importe orientativo por comensal. Nulo
  /// cuando «Mostrar los comensales» está apagado.
  final int? comensales;
  final List<LineaTicket> lineas;
  final List<DesgloseIvaTicketPrint> desglose;
  final int totalCents;

  /// Imprime «IVA incluido» bajo el total.
  final bool ivaIncluido;

  /// Documento de muestra: empieza con la banda «MUESTRA · SIN VALIDEZ».
  final bool muestra;
  final PaperWidth paper;
  final bool cortar;

  @override
  List<Object?> get props => [
    empresa,
    fechaHora,
    mesa,
    zona,
    numero,
    camarero,
    comensales,
    lineas,
    desglose,
    totalCents,
    ivaIncluido,
    muestra,
    paper,
    cortar,
  ];
}

/// Precuenta (cuenta provisional de una mesa). Lanza [ValidationException]
/// ante datos incoherentes (sin mesa, sin líneas, comensales no positivos...).
Uint8List generarPrecuenta(PrecuentaPrintData data) {
  validateEmpresa(data.empresa);
  if (data.mesa.trim().isEmpty) {
    throw const ValidationException('La precuenta no indica la mesa');
  }
  validarLineasYDesglose(data.lineas, data.desglose, documento: 'La precuenta');
  final comensales = data.comensales;
  if (comensales != null && comensales <= 0) {
    throw ValidationException(
      'La precuenta indica $comensales comensales: debe ser un número '
      'positivo',
    );
  }
  final numero = data.numero;
  if (numero != null && numero <= 0) {
    throw ValidationException(
      'El número de la precuenta es $numero: debe ser positivo',
    );
  }

  final b = EscPosBuilder(paper: data.paper)..init();
  if (data.muestra) printBandaMuestra(b);
  printCabeceraEmpresa(b, data.empresa);
  b
    ..separator()
    ..line(
      numero == null ? 'PRECUENTA' : 'PRECUENTA Nº $numero',
      align: EscPosAlign.center,
      bold: true,
      doubleHeight: true,
    )
    ..line('NO VÁLIDO COMO FACTURA', align: EscPosAlign.center, bold: true);
  final zona = data.zona?.trim();
  final mesaYZona = [
    etiquetaMesa(data.mesa),
    if (zona != null && zona.isNotEmpty) zona,
  ].join(' · ');
  if (comensales == null) {
    b.paragraph(mesaYZona);
  } else {
    b.columns2(mesaYZona, textoComensales(comensales));
  }
  final camarero = data.camarero?.trim();
  b.columns2(
    camarero == null || camarero.isEmpty ? '' : 'Camarero: $camarero',
    formatFechaHora(data.fechaHora),
  );

  b.separator();
  printLineas(b, data.lineas);
  printTotalYDesglose(
    b,
    data.totalCents,
    data.desglose,
    ivaIncluido: data.ivaIncluido,
  );

  if (comensales != null && comensales > 1) {
    b
      ..separator()
      ..columns2(
        'Por comensal ($comensales)',
        formatCents(divideRounding(data.totalCents, comensales)),
        bold: true,
      );
  }

  b
    ..separator()
    ..paragraph(
      'DOCUMENTO SIN VALIDEZ FISCAL',
      align: EscPosAlign.center,
      bold: true,
    )
    ..paragraph(
      'No es una factura: la factura simplificada se emite al cobrar.',
      align: EscPosAlign.center,
    );

  final pie = data.empresa.pie;
  if (pie != null && pie.trim().isNotEmpty) {
    b
      ..feed()
      ..paragraph(pie, align: EscPosAlign.center);
  }

  finish(b, cortar: data.cortar);
  return b.build();
}

/// [generarPrecuenta] en un isolate.
Future<Uint8List> generarPrecuentaEnIsolate(
  PrecuentaPrintData data, {
  IsolateRunner runner = const SpawningIsolateRunner(),
}) => runner.run(generarPrecuenta, data, debugName: 'escpos-precuenta');
