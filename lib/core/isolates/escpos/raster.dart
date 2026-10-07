/// Conversión de imágenes (logo de la empresa) al formato raster de 1 bit que
/// imprimen las impresoras térmicas (`GS v 0`).
///
/// La decodificación y el reescalado usan `package:image` (Dart puro), por lo
/// que todo el trabajo puede hacerse dentro de un isolate; el resultado,
/// [RasterImage], es un DTO plano que cruza el isolate sin problema.
library;

import 'dart:typed_data';

import 'package:equatable/equatable.dart';
import 'package:image/image.dart' as img;

import '../../errors/app_exception.dart';

/// Imagen monocroma empaquetada tal como la espera `GS v 0`: filas de
/// `width / 8` bytes, bit más significativo primero, `1` = punto negro.
final class RasterImage extends Equatable {
  /// Lanza [ValidationException] si las dimensiones no son coherentes con
  /// [bits] o [width] no es múltiplo de 8 (el comando trabaja en bytes).
  RasterImage({required this.width, required this.height, required this.bits}) {
    if (width <= 0 || width % 8 != 0) {
      throw ValidationException(
        'La anchura de la imagen raster es $width puntos: '
        'debe ser positiva y múltiplo de 8',
      );
    }
    if (height <= 0) {
      throw ValidationException(
        'La altura de la imagen raster es $height filas: debe ser positiva',
      );
    }
    final expected = (width ~/ 8) * height;
    if (bits.length != expected) {
      throw ValidationException(
        'Los datos de la imagen raster ocupan ${bits.length} bytes y una '
        'imagen de $width×$height necesita exactamente $expected',
      );
    }
  }

  /// Anchura en puntos (múltiplo de 8).
  final int width;

  /// Altura en filas de puntos.
  final int height;

  /// `width / 8 × height` bytes, MSB primero, 1 = negro.
  final Uint8List bits;

  /// Bytes por fila.
  int get bytesPerRow => width ~/ 8;

  /// Valor del punto ([x], [y]): `true` si es negro. Útil en tests y vistas
  /// previas.
  bool isBlack(int x, int y) {
    final byte = bits[y * bytesPerRow + (x >> 3)];
    return (byte >> (7 - (x & 7))) & 1 == 1;
  }

  @override
  List<Object?> get props => [width, height, bits];
}

/// Altura máxima aceptada tras el reescalado. Un logo más alto que esto
/// (25 cm a 8 puntos/mm) es un error de datos, no un caso de uso.
const int rasterMaxHeight = 2048;

/// Decodifica un PNG/JPEG/GIF/BMP/WebP, lo reduce a gris, lo reescala para que
/// quepa en [maxWidthDots] conservando la proporción y lo convierte a 1 bit.
///
/// - Las zonas transparentes se componen sobre blanco (el papel).
/// - Gris = luminancia Rec. 601 (`0.299 R + 0.587 G + 0.114 B`), la misma que
///   usan los navegadores; se calcula a mano para que el resultado sea
///   bit a bit reproducible entre versiones de `package:image`.
/// - Con [dithering] se aplica Floyd-Steinberg (recorrido fijo de izquierda a
///   derecha y de arriba abajo; determinista) para que logos con degradados o
///   fotos no queden como manchas. Sin dithering, umbral fijo: gris < 128 →
///   negro. Un logo ya en blanco y negro puro da el mismo resultado con ambos.
/// - Si la anchura resultante no es múltiplo de 8 se rellena con blanco por la
///   derecha (nunca se recorta contenido). [maxWidthDots] debe ser múltiplo de
///   8 para que el relleno nunca lo supere.
/// - Solo se reduce: una imagen más estrecha que el papel no se amplía,
///   porque el escalado hacia arriba de un bitmap pequeño se ve pixelado.
///
/// Lanza [ValidationException] si los bytes no son una imagen reconocible o
/// la imagen resultante es demasiado alta ([rasterMaxHeight]).
RasterImage rasterizarLogo(
  Uint8List imagenCodificada, {
  required int maxWidthDots,
  bool dithering = true,
}) {
  if (maxWidthDots <= 0 || maxWidthDots % 8 != 0) {
    throw ValidationException(
      'La anchura máxima del logo es $maxWidthDots puntos: '
      'debe ser positiva y múltiplo de 8',
    );
  }
  if (imagenCodificada.isEmpty) {
    throw const ValidationException('El logo está vacío (0 bytes)');
  }

  img.Image? decoded;
  try {
    decoded = img.decodeImage(imagenCodificada);
  } on Object catch (error) {
    throw ValidationException(
      'El logo no se puede decodificar: ${_describe(error)}',
      cause: error,
    );
  }
  if (decoded == null) {
    throw const ValidationException(
      'El logo no es una imagen reconocible (se admiten PNG, JPEG, GIF, BMP y '
      'WebP)',
    );
  }
  if (decoded.width <= 0 || decoded.height <= 0) {
    throw ValidationException(
      'El logo tiene dimensiones ${decoded.width}×${decoded.height}: '
      'debe tener al menos un píxel',
    );
  }

  // Unificar a 8 bits por canal con alfa: así `r`, `g`, `b`, `a` están
  // siempre en 0..255 sea cual sea el formato de origen (paleta, 16 bits...).
  var image = decoded.convert(format: img.Format.uint8, numChannels: 4);

  if (image.width > maxWidthDots) {
    final newHeight = ((image.height * maxWidthDots) / image.width).round();
    image = img.copyResize(
      image,
      width: maxWidthDots,
      height: newHeight < 1 ? 1 : newHeight,
      interpolation: img.Interpolation.average,
    );
  }
  if (image.height > rasterMaxHeight) {
    throw ValidationException(
      'El logo mide ${image.height} filas tras el reescalado: el máximo es '
      '$rasterMaxHeight (unos 25 cm de papel)',
    );
  }

  final width = image.width;
  final height = image.height;
  final paddedWidth = ((width + 7) ~/ 8) * 8;

  // Gris en coma flotante para que el error de dithering no se trunque.
  final gray = Float64List(width * height);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final pixel = image.getPixel(x, y);
      final alpha = pixel.a / 255;
      // Numerador entero y una sola división: un gris uniforme (r = g = b)
      // da exactamente su valor, sin que 0.299 + 0.587 + 0.114 deje de
      // sumar 1 por el error de coma flotante.
      final lum =
          (299 * pixel.r.toInt() +
              587 * pixel.g.toInt() +
              114 * pixel.b.toInt()) /
          1000;
      // Composición sobre blanco: lo transparente es papel.
      gray[y * width + x] = lum * alpha + 255 * (1 - alpha);
    }
  }

  final bytesPerRow = paddedWidth ~/ 8;
  final bits = Uint8List(bytesPerRow * height);

  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final index = y * width + x;
      final value = gray[index];
      final black = value < 128;
      if (black) {
        bits[y * bytesPerRow + (x >> 3)] |= 0x80 >> (x & 7);
      }
      if (dithering) {
        // Error respecto al nivel elegido (0 negro / 255 blanco), repartido a
        // los vecinos aún no procesados con los pesos clásicos 7/16, 3/16,
        // 5/16, 1/16.
        final error = value - (black ? 0 : 255);
        if (x + 1 < width) gray[index + 1] += error * 7 / 16;
        if (y + 1 < height) {
          final below = index + width;
          if (x > 0) gray[below - 1] += error * 3 / 16;
          gray[below] += error * 5 / 16;
          if (x + 1 < width) gray[below + 1] += error * 1 / 16;
        }
      }
    }
  }

  return RasterImage(width: paddedWidth, height: height, bits: bits);
}

String _describe(Object error) {
  final text = error.toString();
  return text.length > 120 ? '${text.substring(0, 120)}…' : text;
}
