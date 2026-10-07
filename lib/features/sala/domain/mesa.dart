import 'package:equatable/equatable.dart';

import '../../../core/utils/json_map.dart';

/// Mesa (o punto de venta: barra, terraza 3...) del salón.
///
/// Es un dato de configuración del host; su estado operativo (libre u
/// ocupada) se deriva de si existe una [Comanda] abierta para ella.
final class Mesa extends Equatable {
  const Mesa({
    required this.id,
    required this.nombre,
    this.zona = 'Salón',
    this.orden = 0,
    this.comensales,
  });

  factory Mesa.fromJson(Map<String, Object?> json) => Mesa(
    id: json.requireString('id'),
    nombre: json.requireString('nombre'),
    zona: json.optionalString('zona') ?? 'Salón',
    orden: json.optionalInt('orden') ?? 0,
    comensales: json.optionalInt('comensales'),
  );

  /// Identificador estable (no cambia aunque se renombre la mesa).
  final String id;
  final String nombre;

  /// Agrupación visual: salón, terraza, barra...
  final String zona;

  /// Posición dentro de la zona.
  final int orden;

  /// Capacidad habitual, solo informativa.
  final int? comensales;

  Map<String, Object?> toJson() => {
    'id': id,
    'nombre': nombre,
    'zona': zona,
    'orden': orden,
    if (comensales != null) 'comensales': comensales,
  };

  @override
  List<Object?> get props => [id, nombre, zona, orden, comensales];
}
