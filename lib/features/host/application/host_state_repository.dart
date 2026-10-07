import '../domain/host_snapshot.dart';

/// Persistencia del diario local del host.
///
/// Implementaciones en `data/`: fichero JSON atómico y memoria (tests).
abstract interface class HostStateRepository {
  /// Último snapshot guardado, o `null` si no hay ninguno (primer arranque)
  /// o el guardado no es legible (la implementación lo registra y empieza de
  /// cero antes que impedir abrir la sala).
  Future<HostSnapshot?> load();

  /// Guarda el snapshot completo. Lanza [Exception] si no se pudo escribir.
  Future<void> save(HostSnapshot snapshot);
}
