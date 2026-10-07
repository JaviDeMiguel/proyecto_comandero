/// Contrato de bajo nivel de la API REST v3 de FacturaScripts.
///
/// Los servicios de negocio (facturas, pedidos a proveedor, asientos,
/// catálogo) dependen solo de [FsApi], lo que permite probarlos con un doble
/// en memoria. La implementación HTTP real vive en `fs_http_api.dart`.
library;

/// Registro JSON de la API: las claves son las columnas del modelo.
///
/// Los tipos NO son fiables (la respuesta de un POST devuelve como texto lo
/// que un GET devuelve como número): léelos siempre con `FsRecordReader`
/// (`fs_values.dart`).
typedef FsRecord = Map<String, Object?>;

enum FsSortOrder { asc, desc }

/// Página de un listado.
final class FsPage {
  const FsPage({required this.items, this.totalCount});

  final List<FsRecord> items;

  /// Total de registros que cumplen el filtro (cabecera `X-Total-Count`).
  final int? totalCount;
}

/// Operaciones genéricas sobre la API. Todas lanzan `ErpApiException`.
abstract interface class FsApi {
  /// `GET /api/3`: nombres de los recursos disponibles. Sirve como prueba de
  /// conexión y de validez de la clave.
  Future<List<String>> resources();

  /// `GET /api/3/{resource}` con filtros, orden y paginación.
  ///
  /// Las claves de [filters] son el nombre de la columna con sufijo de
  /// operador opcional (`fecha_gte`, `numero2`, `idasiento_notnull`...).
  Future<FsPage> list(
    String resource, {
    Map<String, Object?> filters = const {},
    Map<String, FsSortOrder> sort = const {},
    int limit = 50,
    int offset = 0,
  });

  /// Recorre todas las páginas de un listado. [sortBy] es obligatorio porque
  /// sin `ORDER BY` la paginación de MySQL no es estable.
  Future<List<FsRecord>> listAll(
    String resource, {
    Map<String, Object?> filters = const {},
    required String sortBy,
    int pageSize = 200,
  });

  /// `GET /api/3/{resource}/{id}`. Devuelve `null` si no existe (404).
  Future<FsRecord?> get(String resource, Object id);

  /// `POST /api/3/{resource}`. Devuelve el registro creado (`data`).
  Future<FsRecord> create(String resource, Map<String, Object?> fields);

  /// `PUT /api/3/{resource}/{id}`. Envía SOLO los campos de [fields]:
  /// FacturaScripts trata cada campo recibido como modificado aunque no
  /// cambie, y eso dispara efectos (regenerar asientos, mover stock, duplicar
  /// cobros). Devuelve el registro (`data`).
  Future<FsRecord> update(
    String resource,
    Object id,
    Map<String, Object?> fields,
  );

  /// `DELETE /api/3/{resource}/{id}`. Devuelve `false` si no existía (404).
  Future<bool> delete(String resource, Object id);

  /// `POST /api/3/{endpoint}[/{path...}]` para los endpoints que no son de
  /// modelo (`crearFacturaCliente`, `pagarFacturaCliente/{id}`...). Devuelve
  /// el objeto JSON completo de la respuesta.
  Future<FsRecord> call(
    String endpoint, {
    List<Object> path = const [],
    Map<String, Object?> fields = const {},
  });
}
