/// MARCHAR de un pase en un puesto: el DTO [MarcharPrintData], la función pura
/// [generarMarchar] y su variante en isolate [generarMarcharEnIsolate].
library;

import 'dart:typed_data';

import 'package:equatable/equatable.dart';

import '../../../errors/app_exception.dart';
import '../../isolate_runner.dart';
import '../escpos_builder.dart';
import 'comanda.dart';
import 'piezas.dart';

/// Datos del MARCHAR de un pase en un puesto: solo las líneas activas de ese
/// pase en ese puesto.
final class MarcharPrintData extends Equatable {
  const MarcharPrintData({
    required this.titulo,
    required this.mesa,
    required this.pase,
    required this.fechaHora,
    required this.lineas,
    this.nombrePase,
    this.zona,
    this.repetida = false,
    this.ultimaMarchaEn,
    this.numerosComanda = const [],
    this.pedidaEn,
    this.camarero,
    this.comensales,
    this.observaciones,
    this.avanceInicial = 0,
    this.muestra = false,
    this.paper = PaperWidth.mm80,
    this.cortar = true,
  });

  /// Título del puesto: `'COCINA'`, `'BARRA'`.
  final String titulo;

  /// Nombre de la mesa, impreso tal cual; si son solo dígitos, «Mesa 7».
  final String mesa;

  /// Zona de la mesa («Terraza»), bajo la mesa.
  final String? zona;

  /// Número del pase que se marcha (1 = primeros…).
  final int pase;

  /// Nombre del pase («Segundos»): la banda dice «MARCHAR SEGUNDOS». Nulo si
  /// el pase no está en la configuración: «MARCHAR PASE 4».
  final String? nombrePase;

  /// El pase ya estaba marchado: se imprime la línea «REPETIDO».
  final bool repetida;

  /// Hora de la marcha anterior («REPETIDO · ya marchado a las 21:52»).
  final DateTime? ultimaMarchaEn;

  /// Números de envío de las líneas («Comanda nº 12», «Comandas nº 12, 15»).
  final List<int> numerosComanda;

  /// Hora en que se pidieron (la menor de las líneas): «Comanda nº 12 (21:14)».
  final DateTime? pedidaEn;

  /// Hora de esta marcha («Marcha 21:52»).
  final DateTime fechaHora;

  /// Quien marcha el pase.
  final String? camarero;
  final int? comensales;
  final List<LineaComandaPrint> lineas;

  /// Aviso de impresora de respaldo («Sin impresora de barra: llevar a
  /// barra»), al final.
  final String? observaciones;

  /// Líneas en blanco tras el `init` (`perfil.lineasIniciales`).
  final int avanceInicial;

  /// Documento de muestra: empieza con la banda «MUESTRA · SIN VALIDEZ».
  final bool muestra;
  final PaperWidth paper;
  final bool cortar;

  @override
  List<Object?> get props => [
    titulo,
    mesa,
    zona,
    pase,
    nombrePase,
    repetida,
    ultimaMarchaEn,
    numerosComanda,
    pedidaEn,
    fechaHora,
    camarero,
    comensales,
    lineas,
    observaciones,
    avanceInicial,
    muestra,
    paper,
    cortar,
  ];
}

/// MARCHAR de un pase: el título del puesto, la banda `MARCHAR <PASE>`, la
/// marca REPETIDO si procede, la mesa, las comandas de origen con la hora de
/// la marcha, el camarero y los comensales, y las líneas del pase con sus
/// notas. Lanza [ValidationException] ante datos incoherentes.
Uint8List generarMarchar(MarcharPrintData data) {
  _validar(data);

  final b = EscPosBuilder(paper: data.paper)
    ..init()
    ..feed(data.avanceInicial);
  if (data.muestra) printBandaMuestra(b);
  b
    ..paragraph(
      data.titulo.trim(),
      align: EscPosAlign.center,
      bold: true,
      doubleHeight: true,
      doubleWidth: true,
    )
    ..banda(
      'MARCHAR ${_nombrePase(data).toUpperCase()}',
      doubleHeight: true,
      doubleWidth: true,
    );
  if (data.repetida) {
    final anterior = data.ultimaMarchaEn;
    b.paragraph(
      anterior == null
          ? 'REPETIDO'
          : 'REPETIDO · ya marchado a las ${formatHora(anterior)}',
      align: EscPosAlign.center,
      bold: true,
      doubleHeight: true,
    );
  }
  b.paragraph(
    etiquetaMesa(data.mesa),
    align: EscPosAlign.center,
    bold: true,
    doubleHeight: true,
    doubleWidth: true,
  );
  final zona = data.zona?.trim();
  if (zona != null && zona.isNotEmpty) {
    b.paragraph(zona, align: EscPosAlign.center);
  }
  b.columns2(_comandasDeOrigen(data), 'Marcha ${formatHora(data.fechaHora)}');
  printCamareroYComensales(
    b,
    camarero: data.camarero,
    comensales: data.comensales,
  );

  b.separator();
  printLineasComanda(b, data.lineas);
  b.separator();
  printObservaciones(b, data.observaciones);

  finish(b, cortar: data.cortar);
  return b.build();
}

/// [generarMarchar] en un isolate.
Future<Uint8List> generarMarcharEnIsolate(
  MarcharPrintData data, {
  IsolateRunner runner = const SpawningIsolateRunner(),
}) => runner.run(generarMarchar, data, debugName: 'escpos-marchar');

void _validar(MarcharPrintData data) {
  if (data.titulo.trim().isEmpty) {
    throw const ValidationException(
      'El título del MARCHAR está vacío: debe indicar el puesto '
      '(COCINA, BARRA...)',
    );
  }
  if (data.mesa.trim().isEmpty) {
    throw const ValidationException('El MARCHAR no indica la mesa');
  }
  if (data.pase <= 0) {
    throw ValidationException(
      'El pase del MARCHAR es ${data.pase}: debe ser positivo',
    );
  }
  validarLineasComanda(
    data.lineas,
    documento: 'el MARCHAR',
    deDocumento: 'del MARCHAR',
  );
  for (final linea in data.lineas) {
    if (linea.anulada) {
      throw ValidationException(
        'La línea "${linea.descripcion}" está anulada: un MARCHAR solo lleva '
        'líneas activas',
      );
    }
  }
  final comensales = data.comensales;
  if (comensales != null && comensales <= 0) {
    throw ValidationException(
      'El MARCHAR indica $comensales comensales: debe ser un número positivo',
    );
  }
  for (final numero in data.numerosComanda) {
    if (numero <= 0) {
      throw ValidationException(
        'El número de comanda $numero no es válido: debe ser positivo',
      );
    }
  }
}

String _nombrePase(MarcharPrintData data) {
  final nombre = data.nombrePase?.trim();
  return nombre == null || nombre.isEmpty ? 'Pase ${data.pase}' : nombre;
}

/// «Comanda nº 12 (21:14)», «Comandas nº 12, 15 (21:14)» o, sin números,
/// solo la hora entre paréntesis (o nada).
String _comandasDeOrigen(MarcharPrintData data) {
  final numeros = data.numerosComanda.toSet().toList()..sort();
  final pedidaEn = data.pedidaEn;
  final hora = pedidaEn == null ? '' : '(${formatHora(pedidaEn)})';
  if (numeros.isEmpty) return hora.isEmpty ? '' : 'Comanda $hora';
  final etiqueta = numeros.length == 1 ? 'Comanda nº' : 'Comandas nº';
  return '$etiqueta ${numeros.join(', ')}${hora.isEmpty ? '' : ' $hora'}';
}
