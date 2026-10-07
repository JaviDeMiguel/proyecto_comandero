/// Validación de las claves de idempotencia que el TPV guarda en campos de
/// texto libre de FacturaScripts (`numero2`, `numproveedor`, `documento`).
///
/// FacturaScripts no ofrece idempotencia: el TPV consulta por esa clave antes
/// de crear. Para que la consulta sea fiable la clave debe sobrevivir intacta
/// al guardado, y `DataBase::var2str()` reescribe como fecha ISO **cualquier**
/// cadena con forma `d-m-aaaa` (con o sin hora), sea cual sea la columna.
library;

import '../../errors/app_exception.dart';
import '../fs_values.dart';

/// Longitud de `numero2`, `numproveedor` y `documento` (`varchar(50)`).
const int fsIdempotencyKeyMaxLength = 50;

final RegExp _dateLike = RegExp(
  r'^\s*\d{1,4}[-/.]\d{1,2}[-/.]\d{1,4}(?:[ T].*)?\s*$',
);

/// Comprueba que [clave] es válida como clave de idempotencia y la devuelve
/// recortada. Lanza [ValidationException] si está vacía, supera los 50
/// caracteres o podría confundirse con una fecha.
String validarClaveIdempotente(String clave, {required String campo}) {
  final value = clave.trim();
  if (value.isEmpty) {
    throw ValidationException('La clave $campo no puede estar vacía');
  }
  if (value.length > fsIdempotencyKeyMaxLength) {
    throw ValidationException(
      "La clave $campo '$value' supera los $fsIdempotencyKeyMaxLength "
      'caracteres (${value.length})',
    );
  }
  if (_dateLike.hasMatch(value) || fsParseDate(value) != null) {
    throw ValidationException(
      "La clave $campo '$value' parece una fecha: FacturaScripts la "
      'reescribiría al guardarla y la búsqueda posterior no la encontraría',
    );
  }
  return value;
}
