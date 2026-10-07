/// Conversión de valores entre Dart y la API de FacturaScripts.
///
/// Escritura: la API solo entiende cuerpos `application/x-www-form-urlencoded`
/// y asigna cada valor como texto, sin convertir tipos. Lectura: el mismo
/// campo puede llegar como número (GET) o como texto (respuesta de un POST), y
/// las fechas como `d-m-Y` o `Y-m-d`.
library;

import 'dart:convert';

import 'fs_api.dart';

/// Codifica un valor para un campo de formulario.
///
/// * `null` → `"null"` (la API convierte ese literal en NULL).
/// * `bool` → `"1"` / `"0"` (el texto `"false"` se evalúa como verdadero en PHP).
/// * números → punto decimal, sin notación exponencial.
/// * listas y mapas → JSON (campo `lineas` de `crearFacturaCliente`).
/// * `String` → tal cual; las fechas deben venir ya formateadas con
///   [fsFormatDate], [fsFormatTime] o [fsFormatDateTime].
String fsEncodeValue(Object? value) => switch (value) {
  null => 'null',
  final bool flag => flag ? '1' : '0',
  final int number => number.toString(),
  final double number => fsFormatNumber(number),
  final String text => text,
  final List<Object?> list => jsonEncode(list),
  final Map<String, Object?> map => jsonEncode(map),
  _ => throw ArgumentError.value(
    value,
    'value',
    'Tipo no admitido en un campo de la API (${value.runtimeType})',
  ),
};

/// Codifica todos los campos de un formulario.
Map<String, String> fsEncodeFields(Map<String, Object?> fields) => {
  for (final MapEntry(:key, :value) in fields.entries)
    key: fsEncodeValue(value),
};

/// Número con punto decimal y sin exponente. Recorta ceros sobrantes:
/// `2.50` → `2.5`, `3.0` → `3`.
String fsFormatNumber(num value, {int maxDecimals = 6}) {
  if (value is int) return value.toString();
  if (value.isNaN || value.isInfinite) {
    throw ArgumentError.value(value, 'value', 'No es un número finito');
  }
  // A partir de 1e21 toStringAsFixed vuelve a la notación exponencial; ningún
  // importe, precio ni cantidad real se acerca a ese orden de magnitud.
  if (value.abs() >= 1e15) {
    throw ArgumentError.value(value, 'value', 'Fuera del rango admitido');
  }
  var text = value.toStringAsFixed(maxDecimals);
  if (text.contains('.')) {
    text = text.replaceFirst(RegExp(r'0+$'), '');
    if (text.endsWith('.')) text = text.substring(0, text.length - 1);
  }
  return text == '-0' ? '0' : text;
}

/// Fecha en el formato canónico de FacturaScripts: `dd-MM-yyyy`.
String fsFormatDate(DateTime date) =>
    '${_two(date.day)}-${_two(date.month)}-${date.year.toString().padLeft(4, '0')}';

/// Hora `HH:mm:ss`.
String fsFormatTime(DateTime date) =>
    '${_two(date.hour)}:${_two(date.minute)}:${_two(date.second)}';

/// Fecha y hora `dd-MM-yyyy HH:mm:ss` (los segundos son obligatorios).
String fsFormatDateTime(DateTime date) =>
    '${fsFormatDate(date)} ${fsFormatTime(date)}';

/// Fecha `yyyy-MM-dd`, la forma más segura en los FILTROS de listados.
String fsFormatIsoDate(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-${_two(date.month)}-${_two(date.day)}';

String _two(int value) => value.toString().padLeft(2, '0');

final RegExp _dayFirst = RegExp(
  r'^(\d{1,2})-(\d{1,2})-(\d{4})(?:[ T](\d{1,2}):(\d{2})(?::(\d{2}))?)?$',
);
final RegExp _yearFirst = RegExp(
  r'^(\d{4})-(\d{1,2})-(\d{1,2})(?:[ T](\d{1,2}):(\d{2})(?::(\d{2}))?)?$',
);

/// Interpreta una fecha de la API (`d-m-Y` o `Y-m-d`, con hora opcional) como
/// hora local. Devuelve `null` si el texto está vacío o no es una fecha.
DateTime? fsParseDate(String? text) {
  if (text == null) return null;
  final value = text.trim();
  if (value.isEmpty) return null;

  int part(RegExpMatch match, int group) =>
      int.parse(match.group(group) ?? '0');

  DateTime? build(RegExpMatch match, int year, int month, int day) {
    final hour = part(match, 4);
    final minute = part(match, 5);
    final second = part(match, 6);
    final date = DateTime(year, month, day, hour, minute, second);
    // DateTime normaliza fechas imposibles (31-02 → 03-03): se rechazan.
    final valid =
        date.year == year &&
        date.month == month &&
        date.day == day &&
        date.hour == hour &&
        date.minute == minute &&
        date.second == second;
    return valid ? date : null;
  }

  final dayFirst = _dayFirst.firstMatch(value);
  if (dayFirst != null) {
    return build(
      dayFirst,
      part(dayFirst, 3),
      part(dayFirst, 2),
      part(dayFirst, 1),
    );
  }
  final yearFirst = _yearFirst.firstMatch(value);
  if (yearFirst != null) {
    return build(
      yearFirst,
      part(yearFirst, 1),
      part(yearFirst, 2),
      part(yearFirst, 3),
    );
  }
  return null;
}

/// Lectura tolerante de registros de la API.
///
/// Los métodos `fs*` devuelven `null` cuando el campo falta, es nulo o es una
/// cadena vacía, y lanzan [FormatException] si trae un valor que no se puede
/// interpretar. Los `fsRequire*` lanzan también cuando falta.
extension FsRecordReader on FsRecord {
  String? fsString(String key) {
    final value = this[key];
    return switch (value) {
      null => null,
      final String text => text,
      final num number => fsFormatNumber(number),
      final bool flag => flag ? '1' : '0',
      _ => throw _typeError(key, 'texto', value),
    };
  }

  /// Como [fsString] pero convierte la cadena vacía en `null`.
  String? fsNonEmptyString(String key) {
    final value = fsString(key);
    return (value == null || value.isEmpty) ? null : value;
  }

  int? fsInt(String key) {
    final value = this[key];
    switch (value) {
      case null:
        return null;
      case final int number:
        return number;
      case final double number when number == number.truncateToDouble():
        return number.toInt();
      case final String text:
        final trimmed = text.trim();
        if (trimmed.isEmpty) return null;
        final parsed = int.tryParse(trimmed);
        if (parsed != null) return parsed;
        final asDouble = double.tryParse(trimmed);
        if (asDouble != null && asDouble == asDouble.truncateToDouble()) {
          return asDouble.toInt();
        }
    }
    throw _typeError(key, 'entero', value);
  }

  double? fsDouble(String key) {
    final value = this[key];
    switch (value) {
      case null:
        return null;
      case final num number:
        return number.toDouble();
      case final String text:
        final trimmed = text.trim();
        if (trimmed.isEmpty) return null;
        final parsed = double.tryParse(trimmed);
        if (parsed != null && parsed.isFinite) return parsed;
    }
    throw _typeError(key, 'número', value);
  }

  /// Acepta `true`/`false`, `1`/`0` y sus formas de texto (`"1"`, `"t"`,
  /// `"true"`...). Ausente, nulo o vacío → [orElse].
  bool fsBool(String key, {bool orElse = false}) {
    final value = this[key];
    switch (value) {
      case null:
        return orElse;
      case final bool flag:
        return flag;
      case final num number:
        return number != 0;
      case final String text:
        switch (text.trim().toLowerCase()) {
          case '':
            return orElse;
          case '1' || 't' || 'true':
            return true;
          case '0' || 'f' || 'false':
            return false;
        }
    }
    throw _typeError(key, 'booleano', value);
  }

  DateTime? fsDate(String key) {
    final text = fsNonEmptyString(key);
    if (text == null) return null;
    final date = fsParseDate(text);
    if (date == null) throw _typeError(key, 'fecha', text);
    return date;
  }

  String fsRequireString(String key) => fsString(key) ?? (throw _missing(key));

  int fsRequireInt(String key) => fsInt(key) ?? (throw _missing(key));

  double fsRequireDouble(String key) => fsDouble(key) ?? (throw _missing(key));

  FormatException _missing(String key) =>
      FormatException("Campo '$key' ausente en la respuesta del ERP");

  FormatException _typeError(String key, String expected, Object? value) =>
      FormatException(
        "Campo '$key': se esperaba $expected y llegó '$value' "
        '(${value.runtimeType})',
      );
}
