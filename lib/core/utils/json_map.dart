/// Lectura tipada y estricta de mapas JSON (tramas de red, respuestas del ERP,
/// ajustes persistidos).
///
/// Todos los métodos lanzan [FormatException] con el nombre del campo cuando
/// falta o su tipo no es el esperado; cada capa la traduce a su excepción
/// tipada (`ProtocolException`, `ErpApiException`...).
extension JsonMapReader on Map<String, Object?> {
  String requireString(String key) => _require<String>(key, 'String');

  String? optionalString(String key) => _optional<String>(key, 'String');

  int requireInt(String key) => _require<int>(key, 'int');

  int? optionalInt(String key) => _optional<int>(key, 'int');

  /// Acepta enteros y decimales JSON.
  double requireDouble(String key) => _require<num>(key, 'num').toDouble();

  double? optionalDouble(String key) => _optional<num>(key, 'num')?.toDouble();

  bool requireBool(String key) => _require<bool>(key, 'bool');

  bool? optionalBool(String key) => _optional<bool>(key, 'bool');

  Map<String, Object?> requireMap(String key) =>
      _require<Map<String, Object?>>(key, 'objeto');

  Map<String, Object?>? optionalMap(String key) =>
      _optional<Map<String, Object?>>(key, 'objeto');

  List<Object?> requireList(String key) =>
      _require<List<Object?>>(key, 'lista');

  List<Object?>? optionalList(String key) =>
      _optional<List<Object?>>(key, 'lista');

  /// Lista cuyos elementos son todos objetos JSON.
  List<Map<String, Object?>> requireMapList(String key) {
    final list = requireList(key);
    return [
      for (var i = 0; i < list.length; i++)
        if (list[i] case final Map<String, Object?> item)
          item
        else
          throw FormatException(
            "Campo '$key[$i]': se esperaba objeto y llegó ${_describe(list[i])}",
          ),
    ];
  }

  T _require<T extends Object>(String key, String expected) {
    final value = this[key];
    if (value is T) return value;
    if (value == null) {
      throw FormatException("Campo '$key' obligatorio ausente ($expected)");
    }
    throw FormatException(
      "Campo '$key': se esperaba $expected y llegó ${_describe(value)}",
    );
  }

  T? _optional<T extends Object>(String key, String expected) {
    final value = this[key];
    if (value == null || value is T) return value as T?;
    throw FormatException(
      "Campo '$key': se esperaba $expected y llegó ${_describe(value)}",
    );
  }
}

String _describe(Object? value) => switch (value) {
  null => 'null',
  String() => 'String',
  int() => 'int',
  double() => 'double',
  bool() => 'bool',
  List() => 'lista',
  Map() => 'objeto',
  _ => value.runtimeType.toString(),
};
