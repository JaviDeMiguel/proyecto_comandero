/// Aritmética monetaria en céntimos enteros.
///
/// Dentro de la aplicación los importes son `int` (céntimos) y los tipos de
/// IVA son puntos básicos (`1000` = 10 %), de modo que los cuadres (ticket,
/// Cierre Z, Debe/Haber) son exactos. FacturaScripts guarda importes como
/// `double`: la conversión se hace únicamente en el borde (cliente de la API y
/// MySQL) con [centsFromDecimal] y [centsToDecimal].
library;

/// Redondea al entero más cercano, con la mitad hacia fuera de cero y
/// tolerando el error de representación binaria.
///
/// `1.005 * 100` vale `100.49999999999999` en coma flotante; normalizando a 15
/// cifras significativas se obtiene `100.5` y por tanto `101`, igual que el
/// `round()` de PHP con el que FacturaScripts calcula sus totales.
int roundHalfAwayFromZero(num value) {
  if (value is int) return value;
  if (value.isNaN || value.isInfinite) {
    throw ArgumentError.value(value, 'value', 'No es un número finito');
  }
  return double.parse(value.toStringAsPrecision(15)).round();
}

/// División entera redondeando al más cercano (mitad hacia fuera de cero).
int divideRounding(int numerator, int denominator) {
  if (denominator == 0) {
    throw ArgumentError.value(denominator, 'denominator', 'División por cero');
  }
  final negative = (numerator < 0) != (denominator < 0);
  final n = numerator.abs();
  final d = denominator.abs();
  final quotient = (2 * n + d) ~/ (2 * d);
  return negative ? -quotient : quotient;
}

/// Convierte un importe decimal (euros) a céntimos.
int centsFromDecimal(num amount) => roundHalfAwayFromZero(amount * 100);

/// Convierte céntimos al `double` que espera FacturaScripts.
double centsToDecimal(int cents) => cents / 100;

/// Convierte un porcentaje (`10`, `21`, `5.2`) a puntos básicos.
int basisPointsFromPercent(num percent) => roundHalfAwayFromZero(percent * 100);

/// Convierte puntos básicos al porcentaje `double` que espera FacturaScripts.
double basisPointsToPercent(int basisPoints) => basisPoints / 100;

/// Importe de una línea: precio unitario × cantidad (admite cantidades
/// fraccionarias, p. ej. venta al peso), redondeado al céntimo.
int lineTotalCents(int unitCents, num quantity) =>
    roundHalfAwayFromZero(unitCents * quantity);

/// Desglosa un importe con IVA incluido en base imponible y cuota.
///
/// La base se redondea al céntimo y la cuota es la diferencia, así que
/// `baseCents + taxCents == totalCents` siempre.
({int baseCents, int taxCents}) splitTaxIncluded(
  int totalCents,
  int taxBasisPoints,
) {
  if (taxBasisPoints < 0) {
    throw ArgumentError.value(taxBasisPoints, 'taxBasisPoints', 'Negativo');
  }
  final base = divideRounding(totalCents * 10000, 10000 + taxBasisPoints);
  return (baseCents: base, taxCents: totalCents - base);
}

/// Formatea céntimos al estilo español: `1.234,56 €`.
String formatCents(int cents, {bool symbol = true}) {
  final negative = cents < 0;
  final absolute = cents.abs();
  final units = (absolute ~/ 100).toString();
  final decimals = (absolute % 100).toString().padLeft(2, '0');

  final grouped = StringBuffer();
  for (var i = 0; i < units.length; i++) {
    if (i > 0 && (units.length - i) % 3 == 0) grouped.write('.');
    grouped.write(units[i]);
  }

  return '${negative ? '-' : ''}$grouped,$decimals${symbol ? ' €' : ''}';
}

/// Formatea una cantidad sin decimales superfluos: `2`, `0,5`, `1,25`.
String formatQuantity(num quantity, {int maxDecimals = 3}) {
  if (quantity is int || quantity == quantity.roundToDouble()) {
    return quantity.round().toString();
  }
  var text = quantity.toStringAsFixed(maxDecimals);
  text = text.replaceFirst(RegExp(r'0+$'), '');
  if (text.endsWith('.')) text = text.substring(0, text.length - 1);
  return text.replaceFirst('.', ',');
}
