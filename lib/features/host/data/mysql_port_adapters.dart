/// Adaptadores de los repositorios MySQL (`lib/core/database`) a los puertos
/// del host.
library;

import '../../../core/database/mysql_database.dart';
import '../../../core/database/repositories/escandallo_repository.dart';
import '../../../core/database/repositories/stock_repository.dart';
import '../../../core/inventory/inventory_models.dart';
import '../application/ports.dart';

/// Puertos de stock y recetas sobre una misma [MysqlDatabase].
final class MysqlPorts {
  MysqlPorts(MysqlDatabase db, {DateTime Function()? now})
    : stock = StockRepositoryAdapter(StockRepository(db, now: now)),
      recetas = EscandalloRepositoryAdapter(EscandalloRepository(db));

  final StockRepositoryAdapter stock;
  final EscandalloRepositoryAdapter recetas;
}

final class StockRepositoryAdapter implements StockPort {
  StockRepositoryAdapter(this._repository);

  final StockRepository _repository;

  @override
  Future<StockApplyResult> aplicarConsumos({
    required String operacion,
    required List<ConsumoStock> consumos,
    required String codalmacen,
    required String motivo,
    String? origen,
  }) => _repository.aplicarConsumos(
    operacion: operacion,
    consumos: consumos,
    codalmacen: codalmacen,
    motivo: motivo,
    origen: origen,
  );

  @override
  Future<List<NivelStock>> leerNiveles({
    required String codalmacen,
    Set<String>? referencias,
    bool soloConMinimo = false,
  }) => _repository.leerNiveles(
    codalmacen: codalmacen,
    referencias: referencias,
    soloConMinimo: soloConMinimo,
  );

  @override
  Future<List<OfertaProveedor>> leerOfertas(Set<String> referencias) =>
      _repository.leerOfertas(referencias);

  @override
  Future<Map<String, List<ConsumoStock>>> leerConsumosAplicados(
    String operacion,
  ) => _repository.leerConsumosAplicados(operacion);
}

final class EscandalloRepositoryAdapter implements RecetasPort {
  EscandalloRepositoryAdapter(this._repository);

  final EscandalloRepository _repository;

  @override
  Future<List<RecetaLinea>> listAll() => _repository.listAll();
}
