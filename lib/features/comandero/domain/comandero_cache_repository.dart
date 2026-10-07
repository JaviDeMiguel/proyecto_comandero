import 'package:equatable/equatable.dart';

import '../../../core/facturascripts/catalog/catalog_models.dart';
import '../../../core/utils/json_map.dart';

/// Catálogo guardado en el comandero junto con la versión que anunció el
/// host, para no volver a pedirlo si no ha cambiado.
final class CatalogoCacheado extends Equatable {
  const CatalogoCacheado({
    required this.version,
    required this.catalogo,
    required this.guardadoEn,
  });

  /// Lanza [FormatException] si el JSON no tiene la forma esperada.
  factory CatalogoCacheado.fromJson(Map<String, Object?> json) =>
      CatalogoCacheado(
        version: json.optionalString('version'),
        catalogo: CatalogSnapshot.fromJson(json.requireMap('catalogo')),
        guardadoEn: DateTime.parse(json.requireString('guardadoEn')),
      );

  /// `catalogoVersion` del snapshot de sala con el que se obtuvo; `null` si
  /// el host no versiona su catálogo.
  final String? version;
  final CatalogSnapshot catalogo;
  final DateTime guardadoEn;

  Map<String, Object?> toJson() => {
    'version': version,
    'catalogo': catalogo.toJson(),
    'guardadoEn': guardadoEn.toIso8601String(),
  };

  @override
  List<Object?> get props => [version, catalogo, guardadoEn];
}

/// Persistencia local del comandero (solo caché: todo se puede volver a pedir
/// al host). Las implementaciones no lanzan por errores de E/S: una caché
/// ilegible equivale a una caché vacía.
abstract interface class ComanderoCacheRepository {
  Future<CatalogoCacheado?> leerCatalogo();

  Future<void> guardarCatalogo(CatalogoCacheado cacheado);

  Future<void> borrarCatalogo();
}
