/// Proveedores de la pantalla de escandallos (recetas y mermas).
///
/// Las recetas viven en la tabla propia `tpv_escandallos` y se leen y
/// escriben por MySQL directo (`EscandalloRepository`). Sin MySQL
/// configurado [escandallosGatewayProvider] es nulo y la pantalla lo explica.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/mysql_database.dart';
import '../../../core/database/repositories/escandallo_repository.dart';
import '../../../core/isolates/escandallos/escandallo_engine.dart';
import '../../../core/logging/app_logger.dart';
import '../../host/presentation/providers.dart';
import '../../settings/presentation/settings_providers.dart';

final Logger _log = appLogger('escandallos.ui');

Duration? _sinReintentos(int retryCount, Object error) => null;

/// Acceso a las recetas que necesita la interfaz.
abstract interface class EscandallosGateway {
  /// Todas las líneas de receta.
  Future<List<RecetaLinea>> listAll();

  /// Sustituye la receta completa de [refPlato] (vacía = sin receta).
  Future<void> guardarPlato(String refPlato, List<RecetaLinea> lineas);
}

/// Implementación sobre MySQL directo.
final class MysqlEscandallosGateway implements EscandallosGateway {
  MysqlEscandallosGateway(MysqlDatabase db)
    : _repository = EscandalloRepository(db);

  final EscandalloRepository _repository;

  @override
  Future<List<RecetaLinea>> listAll() => _repository.listAll();

  @override
  Future<void> guardarPlato(String refPlato, List<RecetaLinea> lineas) =>
      _repository.replacePlato(refPlato, lineas);
}

/// Pasarela de recetas, o `null` si MySQL no está configurado. Abre su
/// propia conexión mientras la pantalla está visible.
final escandallosGatewayProvider = Provider.autoDispose<EscandallosGateway?>((
  ref,
) {
  final mysql = ref.watch(appSettingsProvider.select((s) => s.value?.mysql));
  if (mysql == null) return null;
  final db = MysqlDatabase(mysql);
  ref.onDispose(
    () => unawaited(
      db.close().catchError((Object error, StackTrace stackTrace) {
        _log.warning('Error al cerrar MySQL de escandallos', error, stackTrace);
      }),
    ),
  );
  return MysqlEscandallosGateway(db);
});

/// Recetas agrupadas por plato (orden alfabético de referencia).
final recetasPorPlatoProvider =
    FutureProvider.autoDispose<Map<String, List<RecetaLinea>>>((ref) async {
      final gateway = ref.watch(escandallosGatewayProvider);
      if (gateway == null) return const {};
      final lineas = await gateway.listAll();
      final porPlato = <String, List<RecetaLinea>>{};
      for (final l in lineas) {
        porPlato.putIfAbsent(l.refPlato, () => []).add(l);
      }
      final claves = porPlato.keys.toList()..sort();
      return {for (final k in claves) k: porPlato[k]!};
    }, retry: _sinReintentos);

/// Coste teórico por plato (motor de escandallos en un isolate), con los
/// costes de compra (`variantes.coste`) del catálogo. Vacío si no hay
/// catálogo o costes.
final costesEscandallosProvider = FutureProvider.autoDispose<EscandalloResult?>(
  (ref) async {
    final recetas = await ref.watch(recetasPorPlatoProvider.future);
    final catalogo = ref.watch(catalogoProvider);
    if (recetas.isEmpty || catalogo == null) return null;
    final costes = <String, double>{
      for (final a in catalogo.articulos)
        if (a.coste > 0) a.referencia: a.coste,
    };
    if (costes.isEmpty) return null;
    return resolverEscandallosEnIsolate(
      EscandalloRequest(
        ventas: [
          for (final plato in recetas.keys)
            VentaLinea(referencia: plato, cantidad: 1),
        ],
        recetas: [for (final lineas in recetas.values) ...lineas],
        costeUnitario: costes,
      ),
      runner: ref.watch(isolateRunnerProvider),
    );
  },
  retry: _sinReintentos,
);
