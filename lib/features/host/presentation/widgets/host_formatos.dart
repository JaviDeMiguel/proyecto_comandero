/// Formatos de fecha y duración de la interfaz del host (sin depender de la
/// inicialización de locales de `intl`).
library;

String _dos(int value) => value.toString().padLeft(2, '0');

/// `13:05`.
String formatHora(DateTime t) => '${_dos(t.hour)}:${_dos(t.minute)}';

/// `07/10/2026 13:05`.
String formatFechaHora(DateTime t) =>
    '${_dos(t.day)}/${_dos(t.month)}/${t.year} ${formatHora(t)}';

/// `07/10/2026`.
String formatFecha(DateTime t) => '${_dos(t.day)}/${_dos(t.month)}/${t.year}';

/// Duración compacta: `ahora`, `12 min`, `1 h 05 min`, `2 d 3 h`.
String formatDuracion(Duration d) {
  if (d.isNegative || d.inMinutes < 1) return 'ahora';
  if (d.inHours < 1) return '${d.inMinutes} min';
  if (d.inDays < 1) return '${d.inHours} h ${_dos(d.inMinutes % 60)} min';
  return '${d.inDays} d ${d.inHours % 24} h';
}

/// Porcentaje con coma decimal y sin ceros sobrantes: `10 %`, `5,5 %`.
String formatPorcentaje(double pct) {
  final texto = pct == pct.roundToDouble()
      ? pct.round().toString()
      : pct.toStringAsFixed(2).replaceFirst(RegExp(r'0+$'), '');
  return '${texto.replaceFirst('.', ',')} %';
}
