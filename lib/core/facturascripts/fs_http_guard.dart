/// Estado del cortafuegos anti-baneo del cliente HTTP de FacturaScripts.
///
/// FacturaScripts cuenta una incidencia por cada 401/403 y, con cinco en diez
/// minutos, responde 429 a TODA la IP (también con token válido) durante diez
/// minutos. Como todos los dispositivos del local comparten IP pública ante el
/// servidor, un bucle de reintentos con una clave mal copiada dejaría sin ERP
/// a todo el negocio. El cortafuegos corta en local tras el primer rechazo.
library;

import 'package:meta/meta.dart';

import '../errors/app_exception.dart';

/// Estado del cortafuegos. Las llamadas a la API solo salen a la red en
/// [FsGuardOk]; en los demás estados fallan localmente sin tocar el servidor.
@immutable
sealed class FsGuardState {
  const FsGuardState();
}

/// Sin restricciones.
final class FsGuardOk extends FsGuardState {
  const FsGuardOk();

  @override
  bool operator ==(Object other) => other is FsGuardOk;

  @override
  int get hashCode => (FsGuardOk).hashCode;

  @override
  String toString() => 'FsGuardOk';
}

/// El servidor rechazó la clave (401) o el permiso (403) en [since]. Solo se
/// sale con `resetGuard()` (el usuario corrige la configuración o pulsa
/// "reintentar"): nunca por tiempo, porque cada reintento fallido acerca el
/// baneo.
final class FsGuardAuthLocked extends FsGuardState {
  const FsGuardAuthLocked({required this.since, required this.error});

  final DateTime since;

  /// Excepción original (401/403) que provocó el bloqueo.
  final ErpApiException error;

  @override
  bool operator ==(Object other) =>
      other is FsGuardAuthLocked &&
      other.since == since &&
      other.error.statusCode == error.statusCode;

  @override
  int get hashCode => Object.hash(since, error.statusCode);

  @override
  String toString() =>
      'FsGuardAuthLocked(since: $since, status: ${error.statusCode})';
}

/// El servidor respondió 429 (IP baneada). Hasta [until] las llamadas fallan
/// localmente; después el cliente vuelve solo a [FsGuardOk].
final class FsGuardCooldown extends FsGuardState {
  const FsGuardCooldown({required this.until});

  final DateTime until;

  @override
  bool operator ==(Object other) =>
      other is FsGuardCooldown && other.until == until;

  @override
  int get hashCode => Object.hash(FsGuardCooldown, until);

  @override
  String toString() => 'FsGuardCooldown(until: $until)';
}
