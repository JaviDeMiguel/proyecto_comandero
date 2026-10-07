import 'dart:convert';

import '../application/host_state_repository.dart';
import '../domain/host_snapshot.dart';

/// Repositorio en memoria. Sirve para tests y para simular un "reinicio":
/// un nuevo runtime sobre la misma instancia continúa donde quedó el anterior.
///
/// Guarda el snapshot como texto JSON, igual que el fichero, para que
/// cualquier valor no serializable se detecte también en los tests.
final class InMemoryHostStateRepository implements HostStateRepository {
  InMemoryHostStateRepository([HostSnapshot? initial]) {
    if (initial != null) _saved = jsonEncode(initial.toJson());
  }

  String? _saved;
  int _saves = 0;

  /// Número de escrituras realizadas.
  int get saves => _saves;

  /// Último snapshot guardado, como texto JSON.
  String? get savedJson => _saved;

  @override
  Future<HostSnapshot?> load() async {
    final json = _saved;
    if (json == null) return null;
    return HostSnapshot.fromJson(jsonDecode(json) as Map<String, Object?>);
  }

  @override
  Future<void> save(HostSnapshot snapshot) async {
    _saved = jsonEncode(snapshot.toJson());
    _saves++;
  }
}
