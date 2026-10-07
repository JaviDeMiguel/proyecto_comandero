/// Doble en memoria de `FsApi` para probar los servicios de negocio sin HTTP.
///
/// Guarda registros por recurso, aplica los filtros de igualdad, ordena y
/// pagina como el servidor real (incluida la cabecera `X-Total-Count`), y
/// registra cada llamada. Permite programar fallos por recurso.
library;

import 'package:proyecto_comandero/core/errors/app_exception.dart';
import 'package:proyecto_comandero/core/facturascripts/fs_api.dart';
import 'package:proyecto_comandero/core/facturascripts/fs_values.dart';

final class FakeFsApi implements FsApi {
  FakeFsApi({
    List<String>? resources,
    Map<String, List<FsRecord>> records = const {},
    Map<String, String> primaryKeys = const {},
  }) : resources_ = resources,
       primaryKeys = {..._defaultPrimaryKeys, ...primaryKeys} {
    records.forEach((resource, list) {
      this.records[resource] = [for (final r in list) Map.of(r)];
    });
  }

  static const Map<String, String> _defaultPrimaryKeys = {
    'settings': 'name',
    'empresas': 'idempresa',
    'series': 'codserie',
    'formapagos': 'codpago',
    'almacenes': 'codalmacen',
    'estadodocumentos': 'idestado',
    'clientes': 'codcliente',
    'familias': 'codfamilia',
    'impuestos': 'codimpuesto',
    'productos': 'idproducto',
    'variantes': 'idvariante',
  };

  final List<String>? resources_;
  final Map<String, String> primaryKeys;
  final Map<String, List<FsRecord>> records = {};

  /// Llamadas realizadas, como `'list productos'`, `'get clientes/TPV'`...
  final List<String> calls = [];

  /// Excepción a lanzar en cualquier operación sobre ese recurso.
  final Map<String, ErpApiException> failures = {};

  /// Excepción a lanzar en [resources].
  ErpApiException? resourcesFailure;

  /// Si se fija, cada `list` devuelve como máximo tantos registros aunque se
  /// pida más (simula un servidor con `limit` recortado) y la cabecera total.
  bool sendTotalCount = true;

  void _maybeFail(String resource) {
    final failure = failures[resource];
    if (failure != null) throw failure;
  }

  @override
  Future<List<String>> resources() async {
    calls.add('resources');
    if (resourcesFailure != null) throw resourcesFailure!;
    return resources_ ?? records.keys.toList();
  }

  @override
  Future<FsPage> list(
    String resource, {
    Map<String, Object?> filters = const {},
    Map<String, FsSortOrder> sort = const {},
    int limit = 50,
    int offset = 0,
  }) async {
    calls.add('list $resource offset=$offset limit=$limit');
    _maybeFail(resource);
    var items = (records[resource] ?? const <FsRecord>[]).where((record) {
      for (final MapEntry(:key, :value) in filters.entries) {
        if (fsEncodeValue(record[key]) != fsEncodeValue(value)) return false;
      }
      return true;
    }).toList();
    for (final MapEntry(:key, :value) in sort.entries.toList().reversed) {
      items.sort((a, b) {
        final result = _compare(a[key], b[key]);
        return value == FsSortOrder.asc ? result : -result;
      });
    }
    final total = items.length;
    items = items.skip(offset).take(limit).toList();
    return FsPage(
      items: [for (final r in items) Map.of(r)],
      totalCount: sendTotalCount ? total : null,
    );
  }

  @override
  Future<List<FsRecord>> listAll(
    String resource, {
    Map<String, Object?> filters = const {},
    required String sortBy,
    int pageSize = 200,
  }) async {
    final all = <FsRecord>[];
    var offset = 0;
    while (true) {
      final page = await list(
        resource,
        filters: filters,
        sort: {sortBy: FsSortOrder.asc},
        limit: pageSize,
        offset: offset,
      );
      all.addAll(page.items);
      if (page.items.length < pageSize) break;
      offset += pageSize;
    }
    return all;
  }

  @override
  Future<FsRecord?> get(String resource, Object id) async {
    calls.add('get $resource/$id');
    _maybeFail(resource);
    final pk = primaryKeys[resource] ?? 'id';
    for (final record in records[resource] ?? const <FsRecord>[]) {
      if (fsEncodeValue(record[pk]) == fsEncodeValue(id)) return Map.of(record);
    }
    return null;
  }

  @override
  Future<FsRecord> create(String resource, Map<String, Object?> fields) async {
    calls.add('create $resource');
    _maybeFail(resource);
    final pk = primaryKeys[resource] ?? 'id';
    final list = records.putIfAbsent(resource, () => []);
    final key = fields[pk];
    if (key != null &&
        list.any((r) => fsEncodeValue(r[pk]) == fsEncodeValue(key))) {
      throw const ErpApiException(
        'FacturaScripts respondió 400 al crear: Registro duplicado',
        statusCode: 400,
      );
    }
    // Como el servidor real: `data` devuelve lo enviado como texto.
    final data = <String, Object?>{
      for (final MapEntry(:key, :value) in fields.entries)
        key: fsEncodeValue(value),
    };
    list.add(Map.of(data));
    return data;
  }

  @override
  Future<FsRecord> update(
    String resource,
    Object id,
    Map<String, Object?> fields,
  ) async {
    calls.add('update $resource/$id');
    _maybeFail(resource);
    final pk = primaryKeys[resource] ?? 'id';
    for (final record in records[resource] ?? const <FsRecord>[]) {
      if (fsEncodeValue(record[pk]) == fsEncodeValue(id)) {
        record.addAll(fields);
        return Map.of(record);
      }
    }
    throw ErpApiException(
      'FacturaScripts respondió 404 al modificar $resource/$id',
      statusCode: 404,
    );
  }

  @override
  Future<bool> delete(String resource, Object id) async {
    calls.add('delete $resource/$id');
    _maybeFail(resource);
    final pk = primaryKeys[resource] ?? 'id';
    final list = records[resource];
    if (list == null) return false;
    final before = list.length;
    list.removeWhere((r) => fsEncodeValue(r[pk]) == fsEncodeValue(id));
    return list.length != before;
  }

  @override
  Future<FsRecord> call(
    String endpoint, {
    List<Object> path = const [],
    Map<String, Object?> fields = const {},
  }) async {
    calls.add('call ${[endpoint, ...path].join('/')}');
    _maybeFail(endpoint);
    return {'ok': 'ok', 'data': fields};
  }

  static int _compare(Object? a, Object? b) {
    if (a is num && b is num) return a.compareTo(b);
    return fsEncodeValue(a).compareTo(fsEncodeValue(b));
  }
}
