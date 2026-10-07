/// Réplica del `Calculator` de FacturaScripts (Core/Lib/Calculator.php y
/// CalculatorModSpain.php, versión 2026.5).
///
/// El TPV muestra, cobra e imprime el total que FacturaScripts va a poner en
/// la factura simplificada, así que debe calcularlo con el MISMO algoritmo:
/// los importes se acumulan sin redondear por grupo de IVA (clave
/// `iva|recargo`), cada grupo se redondea una vez y la cabecera es la suma de
/// los grupos redondeados. No se redondea por línea (salvo en el método
/// `price-adjusted`), y por eso "PVP con IVA × cantidad" puede diferir en un
/// céntimo del total legal.
library;

import 'dart:math' as math;

import 'package:equatable/equatable.dart';

import '../errors/app_exception.dart';
import '../money/money.dart';

/// Ajuste `default.taxcalculationmethod` de FacturaScripts.
enum MetodoIva {
  /// `classic`: la cuota se calcula sobre el neto acumulado del grupo.
  classic,

  /// `price-adjusted`: pensado para precios con IVA incluido; la cuota de
  /// cada línea es `round(importe con IVA) - round(importe neto)`.
  priceAdjusted;

  /// Interpreta el valor del ajuste (`classic` si no se reconoce).
  static MetodoIva parse(String? value) => switch (value?.trim()) {
    'price-adjusted' => MetodoIva.priceAdjusted,
    _ => MetodoIva.classic,
  };
}

/// Línea de documento tal como la ve el `Calculator`.
final class LineaCalculo extends Equatable {
  const LineaCalculo({
    required this.cantidad,
    required this.pvpunitario,
    required this.ivaPct,
    this.recargoPct = 0,
    this.dtopor = 0,
    this.dtopor2 = 0,
    this.codimpuesto,
    this.suplido = false,
    this.irpfPct = 0,
  });

  /// Unidades (negativas en rectificativas).
  final double cantidad;

  /// Precio unitario NETO (sin IVA), hasta 5 decimales.
  final double pvpunitario;

  /// Porcentaje de IVA (`10`, `21`, `4`, `0`).
  final double ivaPct;

  /// Recargo de equivalencia (0 en hostelería).
  final double recargoPct;

  /// Descuentos de línea en porcentaje (`0..100`).
  final double dtopor;
  final double dtopor2;
  final String? codimpuesto;

  /// Suplido: no lleva IVA ni IRPF.
  final bool suplido;
  final double irpfPct;

  @override
  List<Object?> get props => [
    cantidad,
    pvpunitario,
    ivaPct,
    recargoPct,
    dtopor,
    dtopor2,
    codimpuesto,
    suplido,
    irpfPct,
  ];
}

/// Subtotal de un grupo `iva|recargo`, ya redondeado.
final class GrupoIva extends Equatable {
  const GrupoIva({
    this.codimpuesto,
    required this.ivaPct,
    required this.recargoPct,
    required this.netoCents,
    required this.cuotaIvaCents,
    required this.cuotaRecargoCents,
  });

  /// Código del impuesto de la primera línea del grupo (informativo).
  final String? codimpuesto;
  final double ivaPct;
  final double recargoPct;
  final int netoCents;
  final int cuotaIvaCents;
  final int cuotaRecargoCents;

  int get totalCents => netoCents + cuotaIvaCents + cuotaRecargoCents;

  @override
  List<Object?> get props => [
    codimpuesto,
    ivaPct,
    recargoPct,
    netoCents,
    cuotaIvaCents,
    cuotaRecargoCents,
  ];
}

/// Totales de cabecera, en céntimos.
final class TotalesFs extends Equatable {
  TotalesFs({
    required this.netoCents,
    required this.netoSinDtoCents,
    required this.totalIvaCents,
    required this.totalRecargoCents,
    required this.totalIrpfCents,
    required this.totalSuplidosCents,
    required this.totalCents,
    required List<GrupoIva> grupos,
    required this.metodo,
    required this.decimales,
  }) : grupos = List.unmodifiable(grupos);

  final int netoCents;

  /// Neto antes de los descuentos globales de cabecera.
  final int netoSinDtoCents;
  final int totalIvaCents;
  final int totalRecargoCents;
  final int totalIrpfCents;
  final int totalSuplidosCents;
  final int totalCents;

  /// Grupos ordenados por `ivaPct` y `recargoPct`.
  final List<GrupoIva> grupos;
  final MetodoIva metodo;
  final int decimales;

  @override
  List<Object?> get props => [
    netoCents,
    netoSinDtoCents,
    totalIvaCents,
    totalRecargoCents,
    totalIrpfCents,
    totalSuplidosCents,
    totalCents,
    grupos,
    metodo,
    decimales,
  ];
}

/// `round()` de PHP a [decimales] decimales: mitad hacia fuera de cero con la
/// normalización previa a 15 cifras significativas (`1.005` → `1.01`).
double roundFs(double value, int decimales) {
  if (value.isNaN || value.isInfinite) {
    throw ArgumentError.value(value, 'value', 'No es un número finito');
  }
  if (decimales < 0 || decimales > 10) {
    throw ArgumentError.value(decimales, 'decimales', 'Fuera de rango');
  }
  final scale = math.pow(10, decimales).toDouble();
  return roundHalfAwayFromZero(value * scale) / scale;
}

/// Precio unitario neto con 5 decimales (`Producto::ROUND_DECIMALS`) a partir
/// de un PVP con IVA en céntimos.
double pvpUnitarioDesdePvpConIva(int pvpCents, double ivaPct) {
  if (ivaPct < 0) throw ArgumentError.value(ivaPct, 'ivaPct', 'Negativo');
  return roundFs(pvpCents / 100 / (1 + ivaPct / 100), 5);
}

/// PVP con IVA en céntimos de un precio neto, como lo muestra FacturaScripts
/// (`precio * (100 + iva) / 100` redondeado a 2 decimales).
int pvpConIvaCents(double pvpunitario, double ivaPct) {
  if (ivaPct < 0) throw ArgumentError.value(ivaPct, 'ivaPct', 'Negativo');
  return roundHalfAwayFromZero(pvpunitario * (100 + ivaPct));
}

final class _Grupo {
  _Grupo(this.codimpuesto, this.ivaPct, this.recargoPct);

  final String? codimpuesto;
  final double ivaPct;
  final double recargoPct;
  double neto = 0;
  double netoSinDto = 0;
  double totalIva = 0;
  double totalRecargo = 0;
}

/// Calcula los totales de un documento exactamente como FacturaScripts.
///
/// [dtopor1] y [dtopor2] son los descuentos globales de cabecera. Las líneas
/// con importe cero se ignoran, igual que hace el ERP.
TotalesFs calcularTotalesFs(
  List<LineaCalculo> lineas, {
  MetodoIva metodo = MetodoIva.classic,
  int decimales = 2,
  double dtopor1 = 0,
  double dtopor2 = 0,
}) {
  _validarPorcentaje(dtopor1, 'dtopor1');
  _validarPorcentaje(dtopor2, 'dtopor2');
  if (decimales < 0 || decimales > 6) {
    throw ValidationException('Decimales fuera de rango: $decimales');
  }

  final eud = (1 - dtopor1 / 100) * (1 - dtopor2 / 100);
  final grupos = <String, _Grupo>{};
  var totalIrpf = 0.0;
  var totalSuplidos = 0.0;

  for (var i = 0; i < lineas.length; i++) {
    final linea = lineas[i];
    _validarLinea(linea, i);

    final pvpSinDto = linea.cantidad * linea.pvpunitario;
    final pvpTotalLinea =
        pvpSinDto * (100 - linea.dtopor) / 100 * (100 - linea.dtopor2) / 100;
    if (pvpTotalLinea == 0) continue;

    final pvpTotal = pvpTotalLinea * eud;
    if (linea.suplido) {
      totalSuplidos += pvpTotal;
      continue;
    }
    totalIrpf += pvpTotal * linea.irpfPct / 100;

    final clave = '${linea.ivaPct}|${linea.recargoPct}';
    final grupo = grupos.putIfAbsent(
      clave,
      () => _Grupo(linea.codimpuesto, linea.ivaPct, linea.recargoPct),
    );
    grupo.neto += pvpTotal;
    grupo.netoSinDto += pvpTotalLinea;

    switch (metodo) {
      case MetodoIva.classic:
        grupo.totalIva += pvpTotal * linea.ivaPct / 100;
      case MetodoIva.priceAdjusted:
        final pvpIva = roundFs(
          linea.pvpunitario * (100 + linea.ivaPct) / 100,
          decimales,
        );
        final conIva =
            linea.cantidad *
            pvpIva *
            (100 - linea.dtopor) /
            100 *
            (100 - linea.dtopor2) /
            100 *
            eud;
        grupo.totalIva +=
            roundFs(conIva, decimales) - roundFs(pvpTotal, decimales);
    }
    if (linea.recargoPct > 0) {
      grupo.totalRecargo += pvpTotal * linea.recargoPct / 100;
    }
  }

  int cents(double value) =>
      roundHalfAwayFromZero(roundFs(value, decimales) * 100);

  final gruposOrdenados = grupos.values.toList()
    ..sort((a, b) {
      final porIva = a.ivaPct.compareTo(b.ivaPct);
      return porIva != 0 ? porIva : a.recargoPct.compareTo(b.recargoPct);
    });

  // Cada grupo se redondea una vez; la cabecera suma los grupos ya redondeados
  // (Calculator.php:239-266) y se vuelve a redondear.
  var neto = 0.0;
  var netoSinDto = 0.0;
  var totalIva = 0.0;
  var totalRecargo = 0.0;
  final resultadoGrupos = <GrupoIva>[];
  for (final grupo in gruposOrdenados) {
    final netoGrupo = roundFs(grupo.neto, decimales);
    final netoSinDtoGrupo = roundFs(grupo.netoSinDto, decimales);
    final ivaGrupo = roundFs(grupo.totalIva, decimales);
    final recargoGrupo = roundFs(grupo.totalRecargo, decimales);
    neto += netoGrupo;
    netoSinDto += netoSinDtoGrupo;
    totalIva += ivaGrupo;
    totalRecargo += recargoGrupo;
    resultadoGrupos.add(
      GrupoIva(
        codimpuesto: grupo.codimpuesto,
        ivaPct: grupo.ivaPct,
        recargoPct: grupo.recargoPct,
        netoCents: cents(netoGrupo),
        cuotaIvaCents: cents(ivaGrupo),
        cuotaRecargoCents: cents(recargoGrupo),
      ),
    );
  }

  final netoRedondeado = roundFs(neto, decimales);
  final totalIvaRedondeado = roundFs(totalIva, decimales);
  final totalRecargoRedondeado = roundFs(totalRecargo, decimales);
  final totalIrpfRedondeado = roundFs(totalIrpf, decimales);
  final totalSuplidosRedondeado = roundFs(totalSuplidos, decimales);
  final total = roundFs(
    netoRedondeado +
        totalSuplidosRedondeado +
        totalIvaRedondeado +
        totalRecargoRedondeado -
        totalIrpfRedondeado,
    decimales,
  );

  return TotalesFs(
    netoCents: cents(netoRedondeado),
    netoSinDtoCents: cents(roundFs(netoSinDto, decimales)),
    totalIvaCents: cents(totalIvaRedondeado),
    totalRecargoCents: cents(totalRecargoRedondeado),
    totalIrpfCents: cents(totalIrpfRedondeado),
    totalSuplidosCents: cents(totalSuplidosRedondeado),
    totalCents: cents(total),
    grupos: resultadoGrupos,
    metodo: metodo,
    decimales: decimales,
  );
}

void _validarPorcentaje(double value, String campo) {
  if (value.isNaN || value < 0 || value > 100) {
    throw ValidationException(
      '$campo debe estar entre 0 y 100 (recibido $value)',
    );
  }
}

void _validarLinea(LineaCalculo linea, int indice) {
  if (!linea.cantidad.isFinite) {
    throw ValidationException('Línea ${indice + 1}: cantidad no válida');
  }
  if (!linea.pvpunitario.isFinite) {
    throw ValidationException('Línea ${indice + 1}: precio unitario no válido');
  }
  if (linea.ivaPct.isNaN || linea.ivaPct < 0) {
    throw ValidationException(
      'Línea ${indice + 1}: IVA negativo (${linea.ivaPct})',
    );
  }
  if (linea.recargoPct.isNaN || linea.recargoPct < 0) {
    throw ValidationException('Línea ${indice + 1}: recargo negativo');
  }
  if (linea.irpfPct.isNaN || linea.irpfPct < 0 || linea.irpfPct > 100) {
    throw ValidationException('Línea ${indice + 1}: IRPF fuera de rango');
  }
  for (final (valor, nombre) in [
    (linea.dtopor, 'dtopor'),
    (linea.dtopor2, 'dtopor2'),
  ]) {
    if (valor.isNaN || valor < 0 || valor > 100) {
      throw ValidationException(
        'Línea ${indice + 1}: $nombre debe estar entre 0 y 100',
      );
    }
  }
}
