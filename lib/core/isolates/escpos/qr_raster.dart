/// Rasterizado del QR tributario para `GS v 0`.
///
/// Genera el símbolo con `package:qr` (Dart puro, así que puede ejecutarse
/// dentro del isolate del generador ESC/POS) y lo convierte en una
/// [RasterImage] en la que cada módulo es un bloque de n × n puntos. El
/// tamaño del módulo se elige para que el símbolo mida entre 30 y 40 mm en el
/// papel, sea a 203 o a 180 puntos por pulgada, y se rodea de un margen
/// blanco. No depende de `PaperWidth`: recibe los puntos por pulgada y la
/// anchura máxima en puntos.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:equatable/equatable.dart';
import 'package:qr/qr.dart';

import '../../errors/app_exception.dart';
import 'raster.dart';

const double _mmPorPulgada = 25.4;

/// Tamaño máximo del módulo en puntos (el mismo límite que `GS ( k`).
const int _moduloMaximoPuntos = 16;

/// Módulos del QR más pequeño (versión 1) y del mayor (versión 40).
const int _modulosMinimos = 21;
const int _modulosMaximos = 177;

/// QR convertido a imagen de 1 bit, con su margen blanco, y las medidas con
/// las que se construyó.
final class QrRasterizado extends Equatable {
  const QrRasterizado({
    required this.imagen,
    required this.version,
    required this.modulos,
    required this.puntosPorModulo,
    required this.ladoMm,
  });

  /// Imagen lista para `EscPosBuilder.raster`; incluye el margen blanco.
  final RasterImage imagen;

  /// Versión del QR, 1..40 (la elige el paquete por capacidad).
  final int version;

  /// Módulos por lado: `17 + 4 · version`.
  final int modulos;

  /// Puntos de impresora por módulo.
  final int puntosPorModulo;

  /// Lado del símbolo en mm, sin margen.
  final double ladoMm;

  /// Lado del símbolo en puntos, sin margen.
  int get ladoPuntos => modulos * puntosPorModulo;

  /// Filas blancas sobre el símbolo (las mismas que debajo).
  int get margenSuperior => (imagen.height - ladoPuntos) ~/ 2;

  /// Columnas blancas a la izquierda del símbolo (a la derecha hay las mismas
  /// o una más, por el redondeo de la anchura a múltiplo de 8).
  int get margenIzquierdo => (imagen.width - ladoPuntos) ~/ 2;

  @override
  List<Object?> get props => [
    imagen,
    version,
    modulos,
    puntosPorModulo,
    ladoMm,
  ];
}

/// Puntos por módulo para un símbolo de [modulos] × [modulos].
///
/// Un tamaño `m` (de 1 a 16) es candidato si el lado `modulos · m` mide entre
/// [minMm] y [maxMm] y, con [margenMinimoMm] de blanco a cada lado, cabe en
/// [anchoMaximoPuntos]. Se elige el candidato más cercano a [objetivoMm] y, en
/// caso de empate, el mayor. Es pura: la tabla de tamaños se prueba con ella,
/// versión a versión, sin fabricar una URL de cada longitud.
///
/// Lanza [ValidationException] si ningún tamaño cabe o si un parámetro no
/// tiene sentido ([modulos] no es el de una versión de QR, [dpi] no positivo,
/// [anchoMaximoPuntos] que no es un múltiplo positivo de 8...).
int elegirModulo(
  int modulos, {
  required int dpi,
  required int anchoMaximoPuntos,
  double minMm = 30,
  double maxMm = 40,
  double objetivoMm = 35,
  double margenMinimoMm = 2,
}) {
  _comprobarParametros(
    modulos: modulos,
    dpi: dpi,
    anchoMaximoPuntos: anchoMaximoPuntos,
    minMm: minMm,
    maxMm: maxMm,
    margenMinimoMm: margenMinimoMm,
  );
  final puntosPorMm = dpi / _mmPorPulgada;
  final margenMinimoPuntos = (margenMinimoMm * puntosPorMm).ceil();

  int? elegido;
  var mejorDistancia = double.infinity;
  for (var m = 1; m <= _moduloMaximoPuntos; m++) {
    final ladoPuntos = modulos * m;
    final ladoMm = ladoPuntos / puntosPorMm;
    if (ladoMm < minMm || ladoMm > maxMm) continue;
    if (ladoPuntos + 2 * margenMinimoPuntos > anchoMaximoPuntos) continue;
    final distancia = (ladoMm - objetivoMm).abs();
    // `<=`: en caso de empate gana el mayor, que es el último recorrido.
    if (distancia <= mejorDistancia) {
      elegido = m;
      mejorDistancia = distancia;
    }
  }
  if (elegido == null) {
    throw ValidationException(
      'El QR (versión ${_versionDe(modulos)}, $modulos módulos) no cabe '
      'entre ${_mm(minMm)} y ${_mm(maxMm)} mm en este papel '
      '($anchoMaximoPuntos puntos a $dpi ppp)',
    );
  }
  return elegido;
}

/// Rasteriza [datos] como QR con corrección M, con el módulo que da
/// [elegirModulo] para la versión que elige el paquete y un margen blanco de
/// [margenMm] arriba y abajo. A los lados el margen es el mismo salvo que no
/// quepa en [anchoMaximoPuntos], en cuyo caso se reduce (nunca por debajo de
/// [margenMinimoMm], garantizado por [elegirModulo]). La anchura se redondea
/// hacia arriba a múltiplo de 8 repartiendo el relleno entre ambos lados.
///
/// Es determinista: los mismos datos y parámetros dan los mismos bytes.
///
/// Lanza [ValidationException] si [datos] está vacío o no cabe en un QR
/// (versión 40), si el símbolo no cabe entre [minMm] y [maxMm] en este papel,
/// o si un parámetro no tiene sentido.
QrRasterizado rasterizarQr(
  String datos, {
  required int dpi,
  required int anchoMaximoPuntos,
  double minMm = 30,
  double maxMm = 40,
  double objetivoMm = 35,
  double margenMm = 6,
  double margenMinimoMm = 2,
}) {
  if (datos.isEmpty) {
    throw const ValidationException('El QR no tiene datos que codificar');
  }
  if (margenMm < margenMinimoMm) {
    throw ValidationException(
      'El margen del QR (${_mm(margenMm)} mm) es menor que el mínimo '
      '(${_mm(margenMinimoMm)} mm)',
    );
  }
  final simbolo = QrImage(_codificar(datos));
  final modulos = simbolo.moduleCount;
  final puntosPorModulo = elegirModulo(
    modulos,
    dpi: dpi,
    anchoMaximoPuntos: anchoMaximoPuntos,
    minMm: minMm,
    maxMm: maxMm,
    objetivoMm: objetivoMm,
    margenMinimoMm: margenMinimoMm,
  );
  final puntosPorMm = dpi / _mmPorPulgada;
  final ladoPuntos = modulos * puntosPorModulo;

  final margenVertical = (margenMm * puntosPorMm).round();
  final margenHorizontal = math.min(
    margenVertical,
    (anchoMaximoPuntos - ladoPuntos) ~/ 2,
  );
  final anchoContenido = ladoPuntos + 2 * margenHorizontal;
  final ancho = ((anchoContenido + 7) ~/ 8) * 8;
  final relleno = ancho - anchoContenido;
  final izquierda = margenHorizontal + relleno ~/ 2;
  final alto = ladoPuntos + 2 * margenVertical;

  final bits = _pintarModulos(
    simbolo,
    puntosPorModulo: puntosPorModulo,
    ancho: ancho,
    alto: alto,
    izquierda: izquierda,
    arriba: margenVertical,
  );
  return QrRasterizado(
    imagen: RasterImage(width: ancho, height: alto, bits: bits),
    version: simbolo.typeNumber,
    modulos: modulos,
    puntosPorModulo: puntosPorModulo,
    ladoMm: ladoPuntos / puntosPorMm,
  );
}

/// Codifica [datos] en modo byte (UTF-8) con corrección M; la versión la
/// elige el paquete por capacidad. Traduce `InputTooLongException` a
/// [ValidationException].
QrCode _codificar(String datos) {
  try {
    return QrCode(
      payload: QrPayload.fromString(datos),
      errorCorrectLevel: QrErrorCorrectLevel.medium,
    );
  } on InputTooLongException catch (error) {
    throw ValidationException(
      'Los datos del QR (${datos.length} caracteres) superan la capacidad '
      'de un código QR con corrección M',
      cause: error,
    );
  }
}

/// Bits de la imagen (`ancho / 8` bytes por fila, MSB primero, 1 = negro):
/// cada módulo oscuro `(fila, columna)` del símbolo es un bloque de
/// [puntosPorModulo] × [puntosPorModulo] puntos cuya esquina superior
/// izquierda está en `(izquierda + columna · m, arriba + fila · m)`.
Uint8List _pintarModulos(
  QrImage simbolo, {
  required int puntosPorModulo,
  required int ancho,
  required int alto,
  required int izquierda,
  required int arriba,
}) {
  final bytesPorFila = ancho ~/ 8;
  final bits = Uint8List(bytesPorFila * alto);
  final modulos = simbolo.moduleCount;
  for (var fila = 0; fila < modulos; fila++) {
    // Una fila de módulos son `m` filas de puntos idénticas: se pinta una vez
    // y se copia.
    final filaPuntos = Uint8List(bytesPorFila);
    for (var columna = 0; columna < modulos; columna++) {
      if (!simbolo.isDark(fila, columna)) continue;
      final desde = izquierda + columna * puntosPorModulo;
      for (var x = desde; x < desde + puntosPorModulo; x++) {
        filaPuntos[x >> 3] |= 0x80 >> (x & 7);
      }
    }
    final desdeY = arriba + fila * puntosPorModulo;
    for (var y = desdeY; y < desdeY + puntosPorModulo; y++) {
      bits.setRange(y * bytesPorFila, (y + 1) * bytesPorFila, filaPuntos);
    }
  }
  return bits;
}

void _comprobarParametros({
  required int modulos,
  required int dpi,
  required int anchoMaximoPuntos,
  required double minMm,
  required double maxMm,
  required double margenMinimoMm,
}) {
  if (modulos < _modulosMinimos ||
      modulos > _modulosMaximos ||
      (modulos - 17) % 4 != 0) {
    throw ValidationException(
      'Un QR no tiene $modulos módulos por lado: son 17 + 4 · versión, '
      'de $_modulosMinimos a $_modulosMaximos',
    );
  }
  if (dpi <= 0) {
    throw ValidationException(
      'La resolución de la impresora es $dpi ppp: debe ser positiva',
    );
  }
  if (anchoMaximoPuntos <= 0 || anchoMaximoPuntos % 8 != 0) {
    throw ValidationException(
      'La anchura máxima del QR es $anchoMaximoPuntos puntos: debe ser '
      'positiva y múltiplo de 8',
    );
  }
  if (minMm <= 0 || maxMm < minMm) {
    throw ValidationException(
      'El intervalo de tamaño del QR (${_mm(minMm)}-${_mm(maxMm)} mm) no es '
      'válido',
    );
  }
  if (margenMinimoMm < 0) {
    throw ValidationException(
      'El margen mínimo del QR (${_mm(margenMinimoMm)} mm) no puede ser '
      'negativo',
    );
  }
}

int _versionDe(int modulos) => (modulos - 17) ~/ 4;

/// Milímetros para mensajes: `30` o `2.5`, sin decimales de más.
String _mm(double valor) => valor == valor.roundToDouble()
    ? valor.toInt().toString()
    : valor.toStringAsFixed(1);
