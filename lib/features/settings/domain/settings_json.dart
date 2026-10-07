/// Utilidades de (de)serialización compartidas por los ajustes.
///
/// Los ajustes se leen de forma *tolerante*: un campo ausente toma su valor
/// por defecto, pero un valor presente con tipo o contenido inválido es un
/// error de configuración ([ConfigException]) que la UI debe mostrar en vez de
/// arrancar con datos a medias.
library;

import '../../../core/errors/app_exception.dart';
import '../../../core/utils/json_map.dart';

/// Ejecuta [parse] traduciendo cualquier [FormatException] (de `JsonMapReader`
/// o de los `fromJson` de core) a [ConfigException] con el contexto [seccion].
T parseSeccion<T>(String seccion, T Function() parse) {
  try {
    return parse();
  } on FormatException catch (error) {
    throw ConfigException(
      "Ajustes '$seccion' no válidos: ${error.message}",
      cause: error,
    );
  } on ValidationException catch (error) {
    throw ConfigException(
      "Ajustes '$seccion' no válidos: ${error.message}",
      cause: error,
    );
  }
}

/// Resuelve un valor de enumeración por su `name`. Lanza [FormatException]
/// si [raw] no es nulo y no coincide con ningún valor; `null` devuelve
/// [fallback].
T enumPorNombre<T extends Enum>(
  List<T> values,
  Object? raw,
  T fallback, {
  required String campo,
}) => enumPorNombreOpcional(values, raw, campo: campo) ?? fallback;

/// Como [enumPorNombre] pero `null` (campo ausente) devuelve `null`.
T? enumPorNombreOpcional<T extends Enum>(
  List<T> values,
  Object? raw, {
  required String campo,
}) {
  if (raw == null) return null;
  if (raw is! String) {
    throw FormatException("Campo '$campo': se esperaba String");
  }
  for (final value in values) {
    if (value.name == raw) return value;
  }
  throw FormatException(
    "Campo '$campo': valor desconocido '$raw' "
    '(válidos: ${values.map((v) => v.name).join(', ')})',
  );
}

/// Lista opcional de objetos JSON ([JsonMapReader] solo tiene la variante
/// obligatoria). Lanza [FormatException] si algún elemento no es un objeto.
List<Map<String, Object?>>? optionalMapList(
  Map<String, Object?> json,
  String key,
) {
  if (json[key] == null) return null;
  return json.requireMapList(key);
}
