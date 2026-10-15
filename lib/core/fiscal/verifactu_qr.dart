/// QR tributario de la factura simplificada: la URL de validación de la AEAT
/// (sistemas VERI*FACTU y no VERI*FACTU), la normalización del NIF y la
/// leyenda que acompaña al código.
///
/// Dart puro. La URL se construye una vez, al imprimir el ORIGINAL, y se guarda
/// en el ticket para que los DUPLICADOS la reutilicen; el rasterizado para la
/// impresora vive en `lib/core/isolates/escpos/qr_raster.dart`.
library;

import 'package:equatable/equatable.dart';

import '../errors/app_exception.dart';
import '../facturascripts/fs_values.dart';

/// Modo del QR tributario (ajuste `verifactu.modo`).
enum ModoQrVerifactu {
  /// No se imprime el QR.
  desactivado,

  /// Sistema VERI*FACTU: URL `ValidarQR` y leyenda «VERI*FACTU».
  verifactu,

  /// Sistema de emisión no verificable: URL `ValidarQRNoVerifactu`, sin
  /// leyenda.
  noVerifactu,
}

/// Entorno de la AEAT al que apunta la URL (ajuste `verifactu.entorno`).
enum EntornoVerifactu {
  /// Sede electrónica real.
  produccion,

  /// Entorno de pruebas (`prewww2.aeat.es`).
  pruebas,
}

/// Base de la URL de validación en producción, sistema VERI*FACTU.
const String urlBaseVerifactuProduccion =
    'https://www2.agenciatributaria.gob.es/wlpl/TIKE-CONT/ValidarQR';

/// Base en producción, sistema no VERI*FACTU.
const String urlBaseNoVerifactuProduccion =
    '${urlBaseVerifactuProduccion}NoVerifactu';

/// Base en el entorno de pruebas, sistema VERI*FACTU.
const String urlBaseVerifactuPruebas =
    'https://prewww2.aeat.es/wlpl/TIKE-CONT/ValidarQR';

/// Base en el entorno de pruebas, sistema no VERI*FACTU.
const String urlBaseNoVerifactuPruebas =
    '${urlBaseVerifactuPruebas}NoVerifactu';

/// Leyenda impresa junto al QR en modo VERI*FACTU.
const String leyendaVerifactu = 'VERI*FACTU';

/// Longitud máxima del parámetro `numserie`.
const int numSerieLongitudMaxima = 60;

/// Importe máximo en valor absoluto: 12 dígitos enteros y 2 decimales
/// (999.999.999.999,99).
const int importeQrMaximoCents = 99999999999999;

final RegExp _nifNormalizado = RegExp(r'^[A-Z0-9]{9}$');
final RegExp _separadoresNif = RegExp(r'[\s\-./]');
final RegExp _asciiImprimible = RegExp(r'^[\x20-\x7E]+$');

/// Contenido del QR tributario de una factura: los cuatro datos que exige la
/// AEAT más el sistema (VERI*FACTU o no) y el entorno, de los que depende la
/// base de la URL.
///
/// Es un valor: dos instancias con los mismos datos son iguales y dan la
/// misma [url]. El NIF se guarda ya normalizado y de [fecha] solo se conserva
/// el día (la URL no lleva hora).
final class QrTributario extends Equatable {
  const QrTributario._({
    required this.nif,
    required this.numSerie,
    required this.fecha,
    required this.importeCents,
    required this.verifactu,
    required this.pruebas,
  });

  /// Lanza [ValidationException] si un dato no cumple la especificación:
  /// [nif] que no tiene 9 caracteres `[A-Z0-9]` tras [normalizarNif];
  /// [numSerie] vacío, de más de [numSerieLongitudMaxima] caracteres o con
  /// caracteres fuera de ASCII 0x20-0x7E; `|importeCents|` mayor que
  /// [importeQrMaximoCents].
  factory QrTributario({
    required String nif,
    required String numSerie,
    required DateTime fecha,
    required int importeCents,
    required bool verifactu,
    bool pruebas = false,
  }) {
    final nifLimpio = _validarNif(nif);
    _validarNumSerie(numSerie);
    _validarImporte(importeCents);
    return QrTributario._(
      nif: nifLimpio,
      numSerie: numSerie,
      fecha: DateTime(fecha.year, fecha.month, fecha.day),
      importeCents: importeCents,
      verifactu: verifactu,
      pruebas: pruebas,
    );
  }

  /// QR según los ajustes: `null` si [modo] es [ModoQrVerifactu.desactivado].
  /// Valida igual que el constructor.
  static QrTributario? segunAjustes({
    required ModoQrVerifactu modo,
    required EntornoVerifactu entorno,
    required String nif,
    required String numSerie,
    required DateTime fecha,
    required int importeCents,
  }) {
    if (modo == ModoQrVerifactu.desactivado) return null;
    return QrTributario(
      nif: nif,
      numSerie: numSerie,
      fecha: fecha,
      importeCents: importeCents,
      verifactu: modo == ModoQrVerifactu.verifactu,
      pruebas: entorno == EntornoVerifactu.pruebas,
    );
  }

  /// NIF del emisor, normalizado con [normalizarNif].
  final String nif;

  /// Número de serie y factura (`FacturaSincronizada.codigo`), tal cual; en
  /// la URL va codificado.
  final String numSerie;

  /// Fecha de expedición (solo día, hora local a las 00:00).
  final DateTime fecha;

  /// Importe total de la factura en céntimos (negativo en rectificativas).
  final int importeCents;

  /// `true` en el sistema VERI*FACTU; `false` en el no verificable.
  final bool verifactu;

  /// `true` para apuntar al entorno de pruebas de la AEAT.
  final bool pruebas;

  /// Modo equivalente de los ajustes (nunca [ModoQrVerifactu.desactivado]).
  ModoQrVerifactu get modo =>
      verifactu ? ModoQrVerifactu.verifactu : ModoQrVerifactu.noVerifactu;

  /// Entorno equivalente de los ajustes.
  EntornoVerifactu get entorno =>
      pruebas ? EntornoVerifactu.pruebas : EntornoVerifactu.produccion;

  /// Base de la URL (sin barra final ni consulta).
  String get base => switch ((verifactu, pruebas)) {
    (true, false) => urlBaseVerifactuProduccion,
    (false, false) => urlBaseNoVerifactuProduccion,
    (true, true) => urlBaseVerifactuPruebas,
    (false, true) => urlBaseNoVerifactuPruebas,
  };

  /// Parámetro `fecha`: `DD-MM-AAAA`.
  String get fechaTexto => fsFormatDate(fecha);

  /// Parámetro `importe`: punto decimal y dos decimales.
  String get importeTexto => importeQr(importeCents);

  /// Los cuatro parámetros de la consulta, en el orden exigido y sin
  /// codificar.
  Map<String, String> get parametros => {
    'nif': nif,
    'numserie': numSerie,
    'fecha': fechaTexto,
    'importe': importeTexto,
  };

  /// URL completa: `<base>?nif=…&numserie=…&fecha=…&importe=…`. Los valores
  /// se codifican con [Uri.encodeQueryComponent] (UTF-8, espacio como `+`),
  /// igual que el `urlencode` del plugin Verifactu de FacturaScripts.
  String get url {
    final consulta = parametros.entries
        .map(
          (parametro) =>
              '${parametro.key}=${Uri.encodeQueryComponent(parametro.value)}',
        )
        .join('&');
    return '$base?$consulta';
  }

  /// «VERI*FACTU» en ese sistema; `null` en el no verificable.
  String? get leyenda => verifactu ? leyendaVerifactu : null;

  @override
  List<Object?> get props => [
    nif,
    numSerie,
    fecha,
    importeCents,
    verifactu,
    pruebas,
  ];

  static String _validarNif(String nif) {
    final limpio = normalizarNif(nif);
    if (!_nifNormalizado.hasMatch(limpio)) {
      throw ValidationException(
        "El NIF '$nif' no sirve para el QR tributario: tras normalizarlo "
        "queda '$limpio' y debe tener exactamente 9 letras o cifras",
      );
    }
    return limpio;
  }

  static void _validarNumSerie(String numSerie) {
    if (numSerie.isEmpty) {
      throw const ValidationException(
        'El número de serie de la factura está vacío: el QR tributario lo '
        'necesita',
      );
    }
    if (numSerie.length > numSerieLongitudMaxima) {
      throw ValidationException(
        "El número de serie '$numSerie' tiene ${numSerie.length} caracteres: "
        'el QR tributario admite como mucho $numSerieLongitudMaxima',
      );
    }
    if (!_asciiImprimible.hasMatch(numSerie)) {
      throw ValidationException(
        "El número de serie '$numSerie' tiene caracteres fuera de ASCII "
        'imprimible (0x20-0x7E), que el QR tributario no admite',
      );
    }
  }

  static void _validarImporte(int importeCents) {
    if (importeCents.abs() > importeQrMaximoCents) {
      throw ValidationException(
        'El importe ${importeQr(importeCents)} supera los 12 dígitos enteros '
        'que admite el QR tributario',
      );
    }
  }
}

/// Normaliza un NIF para la URL: MAYÚSCULAS, sin espacios ni `-`, `.`, `/`, y
/// sin el prefijo `ES` del NIF-IVA si tras limpiarlo quedan 11 caracteres.
///
/// `b-1234567-8` → `B12345678`; `ES B12345678` → `B12345678`.
String normalizarNif(String nif) {
  final limpio = nif.toUpperCase().replaceAll(_separadoresNif, '');
  return limpio.length == 11 && limpio.startsWith('ES')
      ? limpio.substring(2)
      : limpio;
}

/// Importe en céntimos con el formato del parámetro `importe`: punto decimal
/// y exactamente dos decimales. `6700` → `67.00`; `5` → `0.05`; `-320` →
/// `-3.20`.
String importeQr(int cents) {
  final absoluto = cents.abs();
  final enteros = absoluto ~/ 100;
  final decimales = (absoluto % 100).toString().padLeft(2, '0');
  return '${cents < 0 ? '-' : ''}$enteros.$decimales';
}
