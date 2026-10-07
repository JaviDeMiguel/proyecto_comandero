/// Jerarquía de errores tipados de la aplicación.
///
/// Las capas de infraestructura (red local, MySQL, API del ERP, impresora)
/// traducen sus errores nativos (`SocketException`, errores del servidor
/// MySQL, respuestas HTTP...) a una de estas excepciones, de modo que las capas
/// superiores decidan qué hacer (reintentar, compensar, avisar al usuario) sin
/// conocer el origen concreto.
library;

sealed class AppException implements Exception {
  const AppException(this.message, {this.cause});

  /// Descripción legible, apta para mostrarse en la interfaz.
  final String message;

  /// Error original que provocó la excepción, si lo hay.
  final Object? cause;

  @override
  String toString() => cause == null
      ? '$runtimeType: $message'
      : '$runtimeType: $message (causa: $cause)';
}

/// Fallo de transporte en la red local (TCP/UDP): conexión rechazada, timeout,
/// socket cerrado por el otro extremo, red no disponible.
base class NetworkException extends AppException {
  const NetworkException(super.message, {super.cause});
}

/// Violación del protocolo de mensajes: trama mal formada o demasiado grande,
/// versión incompatible, mensaje inesperado para el estado de la sesión.
base class ProtocolException extends AppException {
  const ProtocolException(super.message, {super.cause});
}

/// El otro extremo recibió la petición y respondió con un error de aplicación
/// (p. ej. el host rechaza una comanda para una mesa ya cobrada).
///
/// A diferencia de [NetworkException], aquí el mensaje sí llegó: reintentar
/// solo tiene sentido si [retryable].
base class RemoteRequestException extends AppException {
  const RemoteRequestException(
    super.message, {
    required this.code,
    this.retryable = false,
    super.cause,
  });

  /// Código estable legible por máquina (`validation`, `internal`, ...).
  final String code;
  final bool retryable;
}

/// Error de MySQL. [errorCode] es el `errno` del servidor cuando se conoce.
base class DatabaseException extends AppException {
  const DatabaseException(
    super.message, {
    super.cause,
    this.errorCode,
    this.sqlState,
  });

  final int? errorCode;
  final String? sqlState;

  /// ER_LOCK_DEADLOCK: InnoDB abortó la transacción; es seguro repetirla entera.
  bool get isDeadlock => errorCode == 1213;

  /// ER_LOCK_WAIT_TIMEOUT.
  bool get isLockWaitTimeout => errorCode == 1205;

  /// ER_DUP_ENTRY: violación de clave única (base de la idempotencia del diario de stock).
  bool get isDuplicateKey => errorCode == 1062;

  /// La transacción completa puede reintentarse sin riesgo.
  bool get isRetryable => isDeadlock || isLockWaitTimeout;
}

/// Clasificación de un fallo de la API del ERP según su código HTTP. Los
/// mensajes de FacturaScripts están traducidos y no son estables: nunca se
/// decide por el texto.
enum ErpApiErrorKind {
  /// Sin respuesta HTTP: fallo de red o timeout.
  network,

  /// 400 / 422: el ERP rechazó los datos. Reintentar no cambia el resultado.
  validation,

  /// 401: clave de API ausente o inválida.
  unauthorized,

  /// 403: la clave no tiene permiso sobre ese recurso o método.
  forbidden,

  /// 404: el registro o el recurso no existe.
  notFound,

  /// 409: la API está desactivada en el panel del ERP.
  disabled,

  /// 429: IP bloqueada temporalmente por exceso de intentos fallidos.
  banned,

  /// 5xx: error interno del ERP.
  server,

  /// Cualquier otro código, o respuesta 2xx que no se pudo interpretar.
  unexpected,
}

/// Error de la API REST del ERP (FacturaScripts).
///
/// [statusCode] nulo significa que no llegó a haber respuesta HTTP (fallo de
/// red o timeout), por lo que el resultado de la operación es desconocido.
base class ErpApiException extends AppException {
  const ErpApiException(
    super.message, {
    super.cause,
    this.statusCode,
    this.responseBody,
  });

  final int? statusCode;
  final String? responseBody;

  ErpApiErrorKind get kind => switch (statusCode) {
    null => ErpApiErrorKind.network,
    400 || 422 => ErpApiErrorKind.validation,
    401 => ErpApiErrorKind.unauthorized,
    403 => ErpApiErrorKind.forbidden,
    404 => ErpApiErrorKind.notFound,
    409 => ErpApiErrorKind.disabled,
    429 => ErpApiErrorKind.banned,
    >= 500 => ErpApiErrorKind.server,
    _ => ErpApiErrorKind.unexpected,
  };

  /// Puede reintentarse más tarde sin intervención del usuario.
  bool get isTransient =>
      kind == ErpApiErrorKind.network ||
      kind == ErpApiErrorKind.server ||
      kind == ErpApiErrorKind.banned;

  /// El ERP pudo haber completado la operación aunque no llegase la respuesta
  /// (timeout, corte, 5xx): antes de repetir un alta hay que comprobar si ya
  /// existe.
  bool get outcomeUnknown =>
      kind == ErpApiErrorKind.network || kind == ErpApiErrorKind.server;

  /// Fallo de credenciales o permisos. No debe reintentarse automáticamente:
  /// cinco fallos en diez minutos bloquean la IP en FacturaScripts.
  bool get isAuthFailure =>
      kind == ErpApiErrorKind.unauthorized || kind == ErpApiErrorKind.forbidden;
}

/// Fallo al comunicarse con la impresora térmica (TCP 9100).
base class PrinterException extends AppException {
  const PrinterException(super.message, {super.cause});
}

/// Datos de negocio inválidos: receta cíclica, merma fuera de rango, asiento
/// descuadrado, importe negativo, etc.
base class ValidationException extends AppException {
  const ValidationException(super.message, {super.cause});
}

/// Configuración ausente o incoherente (URL del ERP, credenciales, cuentas).
base class ConfigException extends AppException {
  const ConfigException(super.message, {super.cause});
}
