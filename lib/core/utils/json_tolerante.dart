// Lectura tolerante de los campos añadidos al diario y al protocolo después
// de su primera versión.
//
// `json_map.dart` es estricto y lanza `FormatException` ante un tipo
// inesperado. Un campo nuevo, en cambio, nunca debe invalidar el objeto
// entero: un `FormatException` en `SalaSnapshot.fromJson` dejaría al
// comandero en bucle y uno en el diario del host lo haría empezar de cero.
// Por eso los campos nuevos se leen con estos ayudantes, que tratan un valor
// ausente o de otro tipo como su valor por defecto.
import '../logging/app_logger.dart';

final Logger _log = appLogger('utils.json');

/// Entero o `null` (ausente u otro tipo).
int? enteroTolerante(Object? valor) => valor is int ? valor : null;

/// Entero positivo o `null` (ausente, otro tipo, cero o negativo).
int? enteroPositivoTolerante(Object? valor) =>
    valor is int && valor > 0 ? valor : null;

/// `bool` o [porDefecto].
bool booleanoTolerante(Object? valor, {bool porDefecto = false}) =>
    valor is bool ? valor : porDefecto;

/// Texto no vacío o `null`.
String? textoTolerante(Object? valor) =>
    valor is String && valor.trim().isNotEmpty ? valor : null;

/// Fecha ISO-8601 o `null`.
DateTime? fechaTolerante(Object? valor) =>
    valor is String ? DateTime.tryParse(valor) : null;

/// Lista de objetos: descarta los elementos que no son mapas o cuyo [leer]
/// lanza [FormatException] o [TypeError] (se registran en `fine`). Ausente o
/// de otro tipo → lista vacía.
List<T> listaTolerante<T>(
  Object? valor,
  T Function(Map<String, Object?> json) leer,
) {
  if (valor is! List<Object?>) return [];
  final leidos = <T>[];
  for (var i = 0; i < valor.length; i++) {
    final elemento = valor[i];
    if (elemento is! Map<String, Object?>) {
      _log.fine('Elemento [$i] descartado: no es un objeto JSON');
      continue;
    }
    try {
      leidos.add(leer(elemento));
    } on FormatException catch (error) {
      _log.fine('Elemento [$i] descartado: ${error.message}');
    } on TypeError catch (error) {
      _log.fine('Elemento [$i] descartado: $error');
    }
  }
  return leidos;
}
