/// Documentos de hostelería en ESC/POS: documento provisional y factura
/// simplificada, precuenta, comanda de cocina (con anulación y reimpresión),
/// MARCHAR de un pase e informe Z.
///
/// Cada documento tiene (a) un DTO plano de entrada, (b) una función pura
/// `generarXxx(data) → Uint8List` y (c) `generarXxxEnIsolate` que la ejecuta a
/// través de un `IsolateRunner`. Las funciones puras no hacen E/S ni leen
/// estado global (ni siquiera `DateTime.now()`): con los mismos datos
/// producen exactamente los mismos bytes.
///
/// Este fichero es un barril: el código vive en `documentos/`, un fichero por
/// documento más los modelos comunes. `documentos/piezas.dart` (cabecera,
/// líneas, total, formatos de fecha...) es interno y no se exporta, y de
/// `documentos/comanda.dart` se ocultan los ayudantes que comparte con
/// `marchar.dart` (`printLineasComanda`, `validarLineasComanda`).
library;

export 'documentos/comanda.dart' hide printLineasComanda, validarLineasComanda;
export 'documentos/informe_z.dart';
export 'documentos/marchar.dart';
export 'documentos/modelos_comunes.dart';
export 'documentos/precuenta.dart';
export 'documentos/ticket.dart';
