/// Vista previa en pantalla de un flujo ESC/POS.
///
/// El decodificador tolerante ([decodeEscPos], el mismo que usan los tests)
/// reconstruye las líneas y el widget las pinta sobre una «caja de papel» de
/// la anchura del rollo, con su alineación, negrita, doble alto y doble ancho,
/// los tramos en inverso, las imágenes raster (logo, QR) y las marcas de
/// corte, cajón, aviso sonoro y avance de papel. Con bytes basura no lanza:
/// pinta lo que entiende.
///
/// No depende de Riverpod ni del runtime del host: recibe los bytes y el
/// papel por parámetros. La usan la página «Tickets y comandas», la prueba de
/// impresora y el detalle de ticket. No desplaza su contenido: quien la
/// coloca decide el scroll.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../../core/isolates/escpos/escpos_builder.dart' show PaperWidth;
import '../../../../core/isolates/escpos/escpos_decoder.dart';
import '../../../../core/isolates/escpos/raster.dart';

/// Cuerpo de la letra por píxel de columna: a 7 px por columna salen 11,5 px,
/// con los que las monoespaciadas habituales (Consolas, Courier New, Roboto
/// Mono: 0,55–0,6 em por glifo) quedan algo más estrechas que la columna y el
/// espaciado entre letras las ajusta a ella.
const double _cuerpoPorColumna = 1.65;

/// Interlineado relativo al cuerpo de la letra.
const double _interlineado = 1.25;

const List<String> _fuentesMonoespaciadas = [
  'Consolas',
  'Courier New',
  'RobotoMono',
];

/// Papel con el documento [bytes] tal como lo imprimiría una impresora de
/// [papel] columnas.
///
/// El papel mide `(papel.columns + 2) × anchoCaracter` de ancho (350 px en
/// 80 mm con el valor por defecto): la zona imprimible, de `papel.columns`
/// columnas, más un margen de una columna a cada lado. El margen evoca, sin
/// escala, el borde sin imprimir del rollo y separa del borde de la caja lo
/// que llena la zona imprimible, como el texto alineado a los extremos o las
/// bandas en inverso.
///
/// En un padre más ancho conserva esa anchura y queda arriba y centrado,
/// aunque el padre imponga la suya a los hijos (un `ListView`, una `Column`
/// con `CrossAxisAlignment.stretch`); en uno más estrecho se reduce a escala
/// hasta caber, sin desbordarse. En un padre de alto acotado también se
/// reduce para caber en alto: para que solo se ajuste al ancho, colócala
/// dentro de un desplazamiento.
class VistaPreviaEscPos extends StatelessWidget {
  const VistaPreviaEscPos({
    super.key,
    required this.bytes,
    required this.papel,
    this.anchoCaracter = 7,
  }) : assert(anchoCaracter > 0, 'anchoCaracter debe ser mayor que cero');

  /// Flujo ESC/POS tal como se enviaría a la impresora.
  final Uint8List bytes;

  /// Papel del perfil: fija las columnas (salto de línea) y los puntos por
  /// línea (escala de las imágenes).
  final PaperWidth papel;

  /// Anchura en píxeles lógicos de una columna de texto. La zona imprimible
  /// mide `papel.columns × anchoCaracter` y el papel, una columna más a cada
  /// lado.
  final double anchoCaracter;

  @override
  Widget build(BuildContext context) {
    final decodificado = decodeEscPos(bytes, wrapColumns: papel.columns);
    final metricas = _Metricas.medir(
      papel: papel,
      anchoCaracter: anchoCaracter,
    );
    // El FittedBox maqueta el papel sin restricciones, con su anchura, y solo
    // lo encoge si no cabe; el Align no le pasa la anchura que imponga el
    // padre y lo coloca arriba y centrado.
    return Align(
      alignment: Alignment.topCenter,
      widthFactor: 1,
      heightFactor: 1,
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Semantics(
          label: _textoCompleto(decodificado),
          container: true,
          excludeSemantics: true,
          child: Container(
            width: metricas.anchoPapel,
            padding: EdgeInsets.symmetric(
              horizontal: metricas.margen,
              vertical: metricas.altoLinea,
            ),
            decoration: const BoxDecoration(
              color: Colors.white,
              boxShadow: [
                BoxShadow(
                  color: Color(0x33000000),
                  blurRadius: 6,
                  offset: Offset(0, 2),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final elemento in decodificado.elements)
                  _widgetDe(elemento, metricas),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

Widget _widgetDe(
  DecodedElement elemento,
  _Metricas metricas,
) => switch (elemento) {
  ElementoTexto(:final linea) => _Linea(linea: linea, metricas: metricas),
  ElementoImagen(:final imagen) => _Imagen(imagen: imagen, metricas: metricas),
  ElementoMarca(:final comando) => _Marca(comando: comando, metricas: metricas),
};

/// Texto del documento para lectores de pantalla: las líneas y, entre
/// corchetes, las imágenes y las marcas.
String _textoCompleto(DecodedStream decodificado) {
  final partes = <String>[];
  for (final elemento in decodificado.elements) {
    final parte = switch (elemento) {
      ElementoTexto(:final linea) => linea.text.trimRight(),
      ElementoImagen(:final imagen) =>
        '[imagen de ${imagen.width}×${imagen.height} puntos]',
      ElementoMarca(:final comando) => switch (comando.name) {
        'cut' => '[corte]',
        'drawer' => '[abre el cajón]',
        'beep' => '[aviso sonoro]',
        _ => '',
      },
    };
    if (parte.isNotEmpty) partes.add(parte);
  }
  return partes.join('\n');
}

/// Medidas de la maqueta: estilo base con el espaciado que hace que cada
/// carácter ocupe exactamente [anchoCaracter], alto de línea y escala de las
/// imágenes.
final class _Metricas {
  const _Metricas({
    required this.estilo,
    required this.anchoCaracter,
    required this.altoLinea,
    required this.papel,
  });

  /// Mide un glifo con la fuente monoespaciada y ajusta `letterSpacing` para
  /// que el avance de cada carácter sea [anchoCaracter]: así las columnas
  /// cuadran en pantalla igual que en el papel, sea cual sea la fuente que
  /// resuelva la plataforma.
  factory _Metricas.medir({
    required PaperWidth papel,
    required double anchoCaracter,
  }) {
    final base = TextStyle(
      fontFamily: 'monospace',
      fontFamilyFallback: _fuentesMonoespaciadas,
      fontSize: anchoCaracter * _cuerpoPorColumna,
      height: _interlineado,
      color: Colors.black,
    );
    final pintor = TextPainter(
      text: TextSpan(text: '0', style: base),
      textDirection: TextDirection.ltr,
      textScaler: TextScaler.noScaling,
    )..layout();
    final anchoGlifo = pintor.width;
    final altoLinea = pintor.height;
    pintor.dispose();
    return _Metricas(
      estilo: base.copyWith(letterSpacing: anchoCaracter - anchoGlifo),
      anchoCaracter: anchoCaracter,
      altoLinea: altoLinea,
      papel: papel,
    );
  }

  final TextStyle estilo;
  final double anchoCaracter;
  final double altoLinea;
  final PaperWidth papel;

  /// Anchura de la zona imprimible: todas las columnas.
  double get anchoImpresion => papel.columns * anchoCaracter;

  /// Margen del papel a cada lado de la zona imprimible (una columna).
  double get margen => anchoCaracter;

  double get anchoPapel => anchoImpresion + 2 * margen;

  /// Píxeles por punto de impresora.
  double get escalaPuntos => anchoImpresion / papel.dots;
}

/// Una línea de texto: sus tramos en fila, con la alineación de la línea.
/// Una línea sin tramos (LF suelto) ocupa su alto en blanco.
class _Linea extends StatelessWidget {
  const _Linea({required this.linea, required this.metricas});

  final DecodedLine linea;
  final _Metricas metricas;

  @override
  Widget build(BuildContext context) {
    if (linea.runs.isEmpty) return SizedBox(height: metricas.altoLinea);
    return Row(
      mainAxisAlignment: switch (linea.align) {
        1 => MainAxisAlignment.center,
        2 => MainAxisAlignment.end,
        _ => MainAxisAlignment.start,
      },
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        for (final tramo in linea.runs)
          _Tramo(tramo: tramo, metricas: metricas),
      ],
    );
  }
}

/// Un tramo con atributos uniformes, en una caja de tantas columnas como
/// imprime (el doble ancho cuenta doble) y uno o dos altos de línea.
class _Tramo extends StatelessWidget {
  const _Tramo({required this.tramo, required this.metricas});

  final DecodedRun tramo;
  final _Metricas metricas;

  @override
  Widget build(BuildContext context) {
    final ancho = tramo.printedWidth * metricas.anchoCaracter;
    final alto = metricas.altoLinea * (tramo.doubleHeight ? 2 : 1);
    if (tramo.text.isEmpty) return SizedBox(width: ancho, height: alto);

    final color = tramo.inverse ? Colors.white : Colors.black;
    final texto = Text(
      tramo.text,
      style: metricas.estilo.copyWith(
        color: color,
        fontWeight: tramo.bold ? FontWeight.bold : FontWeight.normal,
        decoration: tramo.underline
            ? TextDecoration.underline
            : TextDecoration.none,
        decorationColor: color,
      ),
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.visible,
      textScaler: TextScaler.noScaling,
    );
    // El doble ancho y el doble alto se pintan escalando el tramo a su caja.
    final contenido = tramo.doubleWidth || tramo.doubleHeight
        ? FittedBox(
            fit: BoxFit.fill,
            alignment: Alignment.topLeft,
            child: texto,
          )
        : texto;
    return SizedBox(
      width: ancho,
      height: alto,
      child: tramo.inverse
          ? ColoredBox(color: Colors.black, child: contenido)
          : contenido,
    );
  }
}

/// Una imagen raster escalada de los puntos del papel a su anchura en
/// pantalla, con la alineación vigente al imprimirla.
class _Imagen extends StatelessWidget {
  const _Imagen({required this.imagen, required this.metricas});

  final DecodedRaster imagen;
  final _Metricas metricas;

  @override
  Widget build(BuildContext context) {
    final escala = metricas.escalaPuntos;
    return Align(
      alignment: switch (imagen.align) {
        1 => Alignment.center,
        2 => Alignment.centerRight,
        _ => Alignment.centerLeft,
      },
      child: RepaintBoundary(
        child: CustomPaint(
          size: Size(imagen.width * escala, imagen.height * escala),
          painter: RasterPainter(imagen.image),
        ),
      ),
    );
  }
}

/// Racha horizontal de puntos negros de una [RasterImage]: fila [y], desde la
/// columna [x0] hasta [x1] (exclusiva).
typedef RachaNegra = ({int y, int x0, int x1});

/// Rachas horizontales de puntos negros de [imagen], de arriba abajo y de
/// izquierda a derecha. Es lo que pinta [RasterPainter]: un rectángulo por
/// racha, muchos menos que un punto por bit.
List<RachaNegra> rachasNegras(RasterImage imagen) {
  final rachas = <RachaNegra>[];
  final bytesPorFila = imagen.bytesPerRow;
  for (var y = 0; y < imagen.height; y++) {
    final base = y * bytesPorFila;
    var inicio = -1;
    for (var b = 0; b < bytesPorFila; b++) {
      final byte = imagen.bits[base + b];
      // Atajos: un byte blanco sin racha abierta y un byte negro dentro de
      // una racha no cambian nada.
      if (byte == 0x00 && inicio < 0) continue;
      if (byte == 0xFF && inicio >= 0) continue;
      for (var bit = 0; bit < 8; bit++) {
        final x = b * 8 + bit;
        final negro = (byte >> (7 - bit)) & 1 == 1;
        if (negro) {
          if (inicio < 0) inicio = x;
        } else if (inicio >= 0) {
          rachas.add((y: y, x0: inicio, x1: x));
          inicio = -1;
        }
      }
    }
    if (inicio >= 0) rachas.add((y: y, x0: inicio, x1: imagen.width));
  }
  return rachas;
}

/// Pinta una [RasterImage] (1 bit, `1` = negro) escalada a la caja que se le
/// da, conservando la proporción: lo que se ve es lo que imprime `GS v 0`
/// (logo, QR). Sirve también para previsualizar un logo en los ajustes.
final class RasterPainter extends CustomPainter {
  const RasterPainter(this.imagen);

  final RasterImage imagen;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final escala = math.min(
      size.width / imagen.width,
      size.height / imagen.height,
    );
    // Sin suavizado: cada racha se ajusta a la rejilla de píxeles del
    // dispositivo y las filas contiguas encajan sin costuras. Con suavizado,
    // los bordes que comparten dos filas a coordenadas fraccionarias se
    // componen con alfa parcial y un bloque negro sale gris y con bandas.
    final pintura = Paint()
      ..color = Colors.black
      ..isAntiAlias = false;
    for (final racha in rachasNegras(imagen)) {
      canvas.drawRect(
        Rect.fromLTWH(
          racha.x0 * escala,
          racha.y * escala,
          (racha.x1 - racha.x0) * escala,
          escala,
        ),
        pintura,
      );
    }
  }

  @override
  bool shouldRepaint(RasterPainter oldDelegate) => oldDelegate.imagen != imagen;
}

/// Marca sin texto: corte, cajón, aviso sonoro o avance de papel.
class _Marca extends StatelessWidget {
  const _Marca({required this.comando, required this.metricas});

  final DecodedCommand comando;
  final _Metricas metricas;

  @override
  Widget build(BuildContext context) => switch (comando.name) {
    'cut' => _MarcaCorte(altoLinea: metricas.altoLinea),
    'drawer' => const _Chip(
      icono: Icons.point_of_sale_outlined,
      texto: 'Abre el cajón',
    ),
    'beep' => const _Chip(
      icono: Icons.volume_up_outlined,
      texto: 'Aviso sonoro',
    ),
    'feed' => SizedBox(height: metricas.altoLinea * _lineasDeAvance(comando)),
    _ => const SizedBox.shrink(),
  };

  /// `ESC d n`: el decodificador guarda `n` como único argumento.
  static int _lineasDeAvance(DecodedCommand comando) =>
      comando.args.isEmpty ? 1 : comando.args.first;
}

class _Chip extends StatelessWidget {
  const _Chip({required this.icono, required this.texto});

  final IconData icono;
  final String texto;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.center,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Chip(
          avatar: Icon(icono, size: 16),
          label: Text(texto),
          visualDensity: VisualDensity.compact,
        ),
      ),
    );
  }
}

/// Línea discontinua con «corte» en medio.
class _MarcaCorte extends StatelessWidget {
  const _MarcaCorte({required this.altoLinea});

  final double altoLinea;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: altoLinea / 2),
      child: const Row(
        children: [
          Expanded(child: _LineaDiscontinua()),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 6),
            child: Text(
              'corte',
              style: TextStyle(fontSize: 10, color: Colors.black54),
            ),
          ),
          Expanded(child: _LineaDiscontinua()),
        ],
      ),
    );
  }
}

class _LineaDiscontinua extends StatelessWidget {
  const _LineaDiscontinua();

  @override
  Widget build(BuildContext context) {
    return const CustomPaint(
      size: Size(double.infinity, 1),
      painter: _LineaDiscontinuaPainter(),
    );
  }
}

final class _LineaDiscontinuaPainter extends CustomPainter {
  const _LineaDiscontinuaPainter();

  static const double _trazo = 4;
  static const double _hueco = 3;

  @override
  void paint(Canvas canvas, Size size) {
    final pintura = Paint()
      ..color = Colors.black45
      ..strokeWidth = 1;
    final y = size.height / 2;
    for (var x = 0.0; x < size.width; x += _trazo + _hueco) {
      canvas.drawLine(
        Offset(x, y),
        Offset(math.min(x + _trazo, size.width), y),
        pintura,
      );
    }
  }

  @override
  bool shouldRepaint(_LineaDiscontinuaPainter oldDelegate) => false;
}
