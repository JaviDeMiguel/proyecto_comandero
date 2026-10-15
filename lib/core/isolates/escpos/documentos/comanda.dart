/// Comanda de cocina o barra, anulación y reimpresión: los DTOs
/// [LineaComandaPrint] y [KitchenOrderPrintData], la función pura
/// [generarComandaCocina] y su variante en isolate
/// [generarComandaCocinaEnIsolate]. Las líneas de preparación y su validación
/// se comparten con `marchar.dart`, que las importa directamente: el barril
/// `ticket_documents.dart` no las exporta.
library;

import 'dart:typed_data';

import 'package:equatable/equatable.dart';

import '../../../errors/app_exception.dart';
import '../../../money/money.dart';
import '../../isolate_runner.dart';
import '../escpos_builder.dart';
import 'piezas.dart';

/// Línea de una comanda de cocina o barra, de un MARCHAR o de una anulación.
final class LineaComandaPrint extends Equatable {
  const LineaComandaPrint({
    required this.cantidad,
    required this.descripcion,
    this.nota,
    this.anulada = false,
    this.pase,
    this.nombrePase,
    this.esperar = false,
    this.motivo,
    this.envio,
    this.pedidaEn,
  });

  /// Cantidad pedida, siempre positiva: en una línea anulada el generador
  /// imprime el signo («-1 x …»).
  final double cantidad;
  final String descripcion;
  final String? nota;

  /// Línea anulada tras enviarse: se imprime con la cantidad en negativo para
  /// que el puesto la retire.
  final bool anulada;

  /// Pase de la línea (1 = primeros…); nulo si es directa.
  final int? pase;

  /// Nombre del pase («Primeros»); nulo si el pase no está en la
  /// configuración, y entonces se rotula «PASE N».
  final String? nombrePase;

  /// El pase aún no se ha marchado: su grupo lleva la banda «ESPERAR».
  final bool esperar;

  /// Motivo de la anulación («el cliente cambia de plato», «mesa vaciada»).
  final String? motivo;

  /// Número de envío del turno en que se pidió la línea.
  final int? envio;

  /// Hora en que se pidió la línea.
  final DateTime? pedidaEn;

  @override
  List<Object?> get props => [
    cantidad,
    descripcion,
    nota,
    anulada,
    pase,
    nombrePase,
    esperar,
    motivo,
    envio,
    pedidaEn,
  ];
}

/// Datos de una comanda para cocina o barra, de una anulación (todas las
/// líneas con `anulada`) o de una reimpresión (con [banner]).
final class KitchenOrderPrintData extends Equatable {
  const KitchenOrderPrintData({
    required this.titulo,
    required this.mesa,
    required this.fechaHora,
    required this.lineas,
    this.camarero,
    this.numeroComanda,
    this.observaciones,
    this.zona,
    this.comensales,
    this.ordinalEnvio,
    this.abiertaEn,
    this.tituloEnBanda = false,
    this.banner,
    this.bannerDetalle = const [],
    this.avanceInicial = 0,
    this.muestra = false,
    this.paper = PaperWidth.mm80,
    this.cortar = true,
  });

  /// `'COCINA'`, `'BARRA'`, `'ANULACIÓN COCINA'`...
  final String titulo;

  /// Nombre de la mesa, impreso tal cual («Mesa 7», «Terraza 3»); si son
  /// solo dígitos, «Mesa 7».
  final String mesa;
  final String? camarero;

  /// Hora de aceptación del envío (comanda) o de la anulación.
  final DateTime fechaHora;

  /// Número de envío del turno («COMANDA Nº 12 · 21:14»). Varios números
  /// separados por coma («12, 15», reimpresión de toda la mesa) se rotulan
  /// «ENVÍOS Nº 12, 15»; sin número, «COMANDA · 21:14».
  final String? numeroComanda;
  final List<LineaComandaPrint> lineas;

  /// Aviso de impresora de respaldo u observaciones de la comanda, al final.
  final String? observaciones;

  /// Zona de la mesa («Terraza»), bajo la mesa.
  final String? zona;
  final int? comensales;

  /// Ordinal del envío dentro de la mesa («2º envío de la mesa»).
  final int? ordinalEnvio;

  /// Hora de apertura de la mesa («· abierta 21:02»), con [ordinalEnvio].
  final DateTime? abiertaEn;

  /// El título va en banda (blanco sobre negro, doble alto y ancho): la
  /// anulación.
  final bool tituloEnBanda;

  /// Banda de reimpresión con el motivo: `'REIMPRESIÓN · PREPARAR'` o
  /// `'COPIA · NO PREPARAR'`.
  final String? banner;

  /// Líneas bajo la banda («Reimpresa 09/10/2026 21:40 · Caja 1»).
  final List<String> bannerDetalle;

  /// Líneas en blanco tras el `init` (`perfil.lineasIniciales`), para que el
  /// título quede a la vista en una guía de tickets.
  final int avanceInicial;

  /// Documento de muestra: empieza con la banda «MUESTRA · SIN VALIDEZ».
  final bool muestra;
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
    zona,
    comensales,
    ordinalEnvio,
    abiertaEn,
    tituloEnBanda,
    banner,
    bannerDetalle,
    avanceInicial,
    muestra,
    paper,
    cortar,
  ];
}

/// Comanda de cocina / barra: legible a distancia (título y mesa en doble
/// tamaño, líneas en doble altura), agrupada por pases con la banda ESPERAR en
/// los que aún no se preparan, las notas destacadas en inverso y, si todas las
/// líneas están anuladas, el formato de anulación con las cantidades en
/// negativo, la nota original, el motivo y el envío.
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
  validarLineasComanda(
    data.lineas,
    documento: 'la comanda',
    deDocumento: 'de la comanda',
  );
  final comensales = data.comensales;
  if (comensales != null && comensales <= 0) {
    throw ValidationException(
      'La comanda indica $comensales comensales: debe ser un número positivo',
    );
  }
  final esAnulacion = data.lineas.every((l) => l.anulada);

  final b = EscPosBuilder(paper: data.paper)
    ..init()
    ..feed(data.avanceInicial);
  if (data.muestra) printBandaMuestra(b);
  _printBanner(b, data);
  _printTitulo(b, data);
  _printCabecera(b, data, esAnulacion: esAnulacion);

  final separador = esAnulacion ? '-' : '=';
  b.separator(separador);
  if (esAnulacion) {
    _printAnulacion(b, data.lineas);
  } else {
    _printGrupos(b, data.lineas);
  }
  b.separator(separador);
  printObservaciones(b, data.observaciones);

  finish(b, cortar: data.cortar);
  return b.build();
}

/// [generarComandaCocina] en un isolate.
Future<Uint8List> generarComandaCocinaEnIsolate(
  KitchenOrderPrintData data, {
  IsolateRunner runner = const SpawningIsolateRunner(),
}) => runner.run(generarComandaCocina, data, debugName: 'escpos-comanda');

/// Validación de las líneas de un documento de preparación (comanda,
/// MARCHAR, anulación): al menos una, con descripción, cantidad positiva y
/// pase positivo si lo lleva. [documento] es el nombre con su artículo, en
/// minúsculas («la comanda», «el MARCHAR»), y [deDocumento], el mismo con la
/// preposición («de la comanda», «del MARCHAR»), para que los mensajes
/// concuerden.
void validarLineasComanda(
  List<LineaComandaPrint> lineas, {
  required String documento,
  required String deDocumento,
}) {
  if (lineas.isEmpty) {
    throw ValidationException(
      '${_conMayuscula(documento)} no tiene líneas: no se imprime un '
      'documento vacío',
    );
  }
  for (final linea in lineas) {
    if (linea.descripcion.trim().isEmpty) {
      throw ValidationException('Una línea $deDocumento no tiene descripción');
    }
    if (linea.cantidad <= 0 || !linea.cantidad.isFinite) {
      throw ValidationException(
        'La línea "${linea.descripcion}" tiene cantidad ${linea.cantidad}: '
        'debe ser mayor que cero',
      );
    }
    final pase = linea.pase;
    if (pase != null && pase <= 0) {
      throw ValidationException(
        'La línea "${linea.descripcion}" tiene el pase $pase: debe ser '
        'positivo',
      );
    }
  }
}

/// Líneas de preparación: «2 x Entrecot» («-1 x …» si está anulada) en
/// negrita y doble alto, la nota destacada en inverso y, si lo hay, el motivo.
void printLineasComanda(EscPosBuilder b, List<LineaComandaPrint> lineas) {
  for (final linea in lineas) {
    b.paragraph(
      '${linea.anulada ? '-' : ''}${formatQuantity(linea.cantidad)} x '
      '${linea.descripcion.trim()}',
      bold: true,
      doubleHeight: true,
    );
    final nota = linea.nota;
    if (nota != null && nota.trim().isNotEmpty) {
      printNotaDestacada(b, nota);
    }
    _printMotivo(b, linea.motivo);
  }
}

String _conMayuscula(String texto) =>
    texto.isEmpty ? texto : '${texto[0].toUpperCase()}${texto.substring(1)}';

void _printMotivo(EscPosBuilder b, String? motivo) {
  if (motivo == null || motivo.trim().isEmpty) return;
  printIndented(b, 'Motivo: ${motivo.trim()}', prefix: '   ', bold: true);
}

/// Banda de reimpresión con el motivo y sus líneas de detalle, y un separador.
void _printBanner(EscPosBuilder b, KitchenOrderPrintData data) {
  final banner = data.banner?.trim();
  final detalles = data.bannerDetalle
      .map((d) => d.trim())
      .where((d) => d.isNotEmpty)
      .toList();
  if ((banner == null || banner.isEmpty) && detalles.isEmpty) return;
  if (banner != null && banner.isNotEmpty) {
    b.banda(banner, doubleHeight: true, doubleWidth: true);
  }
  for (final detalle in detalles) {
    b.paragraph(detalle, align: EscPosAlign.center);
  }
  b.separator();
}

/// Título del puesto en doble alto y ancho: en banda (anulación) o centrado
/// por la impresora y sin relleno.
void _printTitulo(EscPosBuilder b, KitchenOrderPrintData data) {
  final titulo = data.titulo.trim();
  if (data.tituloEnBanda) {
    b.banda(titulo, doubleHeight: true, doubleWidth: true);
  } else {
    b.paragraph(
      titulo,
      align: EscPosAlign.center,
      bold: true,
      doubleHeight: true,
      doubleWidth: true,
    );
  }
}

/// Mesa, zona, la línea del envío (o la de la anulación), camarero y
/// comensales y el ordinal del envío.
void _printCabecera(
  EscPosBuilder b,
  KitchenOrderPrintData data, {
  required bool esAnulacion,
}) {
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
  if (esAnulacion) {
    b.columns2(_comandaDeOrigen(data), 'Anulada ${formatHora(data.fechaHora)}');
  } else {
    b.paragraph(
      _tituloEnvio(data),
      align: EscPosAlign.center,
      bold: true,
      doubleHeight: true,
    );
  }
  printCamareroYComensales(
    b,
    camarero: data.camarero,
    comensales: data.comensales,
  );
  final ordinal = data.ordinalEnvio;
  if (!esAnulacion && ordinal != null && ordinal > 0) {
    final abiertaEn = data.abiertaEn;
    final abierta = abiertaEn == null
        ? ''
        : ' · abierta ${formatHora(abiertaEn)}';
    b.paragraph(
      '${ordinalTexto(ordinal)} envío de la mesa$abierta',
      align: EscPosAlign.center,
    );
  }
}

/// «COMANDA Nº 12 · 21:14», «ENVÍOS Nº 12, 15» o «COMANDA · 21:14».
String _tituloEnvio(KitchenOrderPrintData data) {
  final hora = formatHora(data.fechaHora);
  final numero = data.numeroComanda?.trim();
  if (numero == null || numero.isEmpty) return 'COMANDA · $hora';
  if (numero.contains(',')) return 'ENVÍOS Nº $numero';
  return 'COMANDA Nº $numero · $hora';
}

/// «Comanda nº 12 (21:14)»: el envío de las líneas anuladas ([numeroComanda]
/// o, si falta, los `envio` de las líneas) y la hora en que se pidieron, si
/// todas comparten la misma. Con varios envíos, «Comandas nº 12, 15».
String _comandaDeOrigen(KitchenOrderPrintData data) {
  var numero = data.numeroComanda?.trim() ?? '';
  if (numero.isEmpty) {
    numero = data.lineas
        .map((l) => l.envio)
        .whereType<int>()
        .toSet()
        .map((n) => n.toString())
        .join(', ');
  }
  final horas = data.lineas
      .map((l) => l.pedidaEn)
      .whereType<DateTime>()
      .map(formatHora)
      .toSet();
  final hora = horas.length == 1 ? ' (${horas.single})' : '';
  if (numero.isEmpty) return 'Comanda$hora';
  final etiqueta = numero.contains(',') ? 'Comandas nº' : 'Comanda nº';
  return '$etiqueta $numero$hora';
}

/// Bloque por línea anulada: cantidad en negativo, nota original en doble
/// alto, motivo y, si las líneas vienen de envíos distintos, el envío de cada
/// una.
void _printAnulacion(EscPosBuilder b, List<LineaComandaPrint> lineas) {
  final envios = lineas.map(_claveEnvio).toSet();
  final variosEnvios = envios.length > 1;
  for (final linea in lineas) {
    b.paragraph(
      '-${formatQuantity(linea.cantidad)} x ${linea.descripcion.trim()}',
      bold: true,
      doubleHeight: true,
    );
    final nota = linea.nota;
    if (nota != null && nota.trim().isNotEmpty) {
      printIndented(b, nota.trim(), prefix: '   > ', doubleHeight: true);
    }
    _printMotivo(b, linea.motivo);
    if (variosEnvios && _claveEnvio(linea).isNotEmpty) {
      b.line('   Comanda ${_envioDe(linea)}');
    }
  }
}

/// Clave del envío de una línea (número y hora), para saber si las líneas
/// anuladas vienen de envíos distintos; vacía si la línea no lo indica.
String _claveEnvio(LineaComandaPrint linea) {
  final pedidaEn = linea.pedidaEn;
  final envio = linea.envio;
  if (envio == null && pedidaEn == null) return '';
  return '${envio ?? ''}|${pedidaEn == null ? '' : formatHora(pedidaEn)}';
}

/// «nº 15 (21:20)», «nº 15» o «(21:20)».
String _envioDe(LineaComandaPrint linea) {
  final pedidaEn = linea.pedidaEn;
  final envio = linea.envio;
  return [
    if (envio != null) 'nº $envio',
    if (pedidaEn != null) '(${formatHora(pedidaEn)})',
  ].join(' ');
}

/// Grupos por pase: «DIRECTO» (solo si también hay líneas con pase) y los
/// pases de menor a mayor, marchados con un rótulo entre guiones y sin marchar
/// bajo la banda «N. NOMBRE · ESPERAR». Sin ninguna línea con pase, plana.
void _printGrupos(EscPosBuilder b, List<LineaComandaPrint> lineas) {
  final pases = lineas.map((l) => l.pase).whereType<int>().toSet().toList()
    ..sort();
  if (pases.isEmpty) {
    printLineasComanda(b, lineas);
    return;
  }
  final directas = lineas.where((l) => l.pase == null).toList();
  if (directas.isNotEmpty) {
    _printRotulo(b, 'DIRECTO');
    printLineasComanda(b, directas);
  }
  for (final pase in pases) {
    final delPase = lineas.where((l) => l.pase == pase).toList();
    final nombre =
        delPase
            .map((l) => l.nombrePase?.trim())
            .firstWhere((n) => n != null && n.isNotEmpty, orElse: () => null) ??
        'Pase $pase';
    final rotulo = '$pase. ${nombre.toUpperCase()}';
    if (delPase.any((l) => l.esperar)) {
      b.banda('$rotulo · ESPERAR');
    } else {
      _printRotulo(b, rotulo);
    }
    printLineasComanda(b, delPase);
  }
}

/// Rótulo de grupo centrado entre guiones a todo el ancho, en negrita:
/// «------- 1. PRIMEROS -------».
void _printRotulo(EscPosBuilder b, String rotulo) {
  final columns = b.paper.columns;
  final texto = ' $rotulo ';
  final longitud = runeLength(texto);
  if (longitud >= columns) {
    b.paragraph(rotulo, bold: true);
    return;
  }
  final antes = (columns - longitud) ~/ 2;
  b.line(
    '${'-' * antes}$texto${'-' * (columns - longitud - antes)}',
    bold: true,
  );
}
