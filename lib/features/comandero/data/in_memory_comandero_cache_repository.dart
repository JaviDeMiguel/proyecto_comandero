import '../domain/comandero_cache_repository.dart';

/// Caché en memoria: para tests y para plataformas sin directorio de datos.
final class InMemoryComanderoCacheRepository
    implements ComanderoCacheRepository {
  InMemoryComanderoCacheRepository({CatalogoCacheado? inicial})
    : _catalogo = inicial;

  CatalogoCacheado? _catalogo;

  /// Veces que se ha guardado (útil en tests).
  int guardados = 0;

  CatalogoCacheado? get catalogo => _catalogo;

  @override
  Future<CatalogoCacheado?> leerCatalogo() async => _catalogo;

  @override
  Future<void> guardarCatalogo(CatalogoCacheado cacheado) async {
    _catalogo = cacheado;
    guardados++;
  }

  @override
  Future<void> borrarCatalogo() async => _catalogo = null;
}
