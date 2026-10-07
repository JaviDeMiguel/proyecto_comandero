import '../../../core/errors/app_exception.dart';
import '../../sala/protocol/sala_messages.dart';

/// El host rechazó una operación de sala con uno de los [SalaErrorCodes]
/// (mesa desconocida, comanda cerrada, línea inexistente...).
///
/// Es un [RemoteRequestException] con ayudas para que la interfaz decida qué
/// mostrar sin comparar cadenas. Nunca es reintentable: hay que corregir el
/// pedido o refrescar la sala.
final class ComanderoSalaException extends RemoteRequestException {
  const ComanderoSalaException(
    super.message, {
    required super.code,
    this.mesaId,
    super.cause,
  });

  /// Construye la excepción tipada si [error] lleva un código de sala; si no,
  /// devuelve [error] tal cual.
  static RemoteRequestException desde(
    RemoteRequestException error, {
    String? mesaId,
  }) {
    if (error is ComanderoSalaException || !esCodigoDeSala(error.code)) {
      return error;
    }
    return ComanderoSalaException(
      error.message,
      code: error.code,
      mesaId: mesaId,
      cause: error,
    );
  }

  static bool esCodigoDeSala(String code) => const {
    SalaErrorCodes.mesaDesconocida,
    SalaErrorCodes.mesaSinComanda,
    SalaErrorCodes.lineaDesconocida,
    SalaErrorCodes.articuloDesconocido,
    SalaErrorCodes.comandaCerrada,
  }.contains(code);

  /// Mesa afectada, si la operación la tenía.
  final String? mesaId;

  bool get mesaDesconocida => code == SalaErrorCodes.mesaDesconocida;
  bool get mesaSinComanda => code == SalaErrorCodes.mesaSinComanda;
  bool get lineaDesconocida => code == SalaErrorCodes.lineaDesconocida;
  bool get articuloDesconocido => code == SalaErrorCodes.articuloDesconocido;
  bool get comandaCerrada => code == SalaErrorCodes.comandaCerrada;
}

/// La operación necesita sesión con el host y no la hay (ni se está
/// reconectando): el usuario debe conectar primero.
final class SinConexionException extends NetworkException {
  const SinConexionException([
    super.message = 'No hay conexión con el host',
    Object? cause,
  ]) : super(cause: cause);
}
