/// Implementación HTTP del contrato [FsApi] contra la API v3 de FacturaScripts.
///
/// Reglas de transporte verificadas en el código fuente de FacturaScripts
/// 2026.5 (`scratchpad/research/fs_api_transporte.md`):
///
/// * autenticación con la cabecera `Token` (no existe `FS-TOKEN`);
/// * cuerpos SOLO `application/x-www-form-urlencoded` (el JSON se ignora);
/// * éxito siempre 200; dos formas de error (`{"error":..}` y
///   `{"status":"error","message":..}`) y 500 que pueden venir en HTML;
/// * los errores se clasifican por código HTTP, nunca por texto;
/// * 401/403 cuentan como incidencia y cinco incidencias banean la IP.
///
/// El cliente NUNCA reintenta por su cuenta: los reintentos son de la cola de
/// sincronización, que conoce la idempotencia de cada operación.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import '../errors/app_exception.dart';
import '../logging/app_logger.dart';
import 'fs_api.dart';
import 'fs_api_config.dart';
import 'fs_http_guard.dart';
import 'fs_values.dart';

export 'fs_http_guard.dart';

/// Cliente HTTP de la API v3 con cortafuegos anti-baneo.
final class FsHttpApi implements FsApi {
  /// [client] permite inyectar un `MockClient` en tests; si se omite se crea
  /// un cliente propio con el `connectTimeout` de [config] (un cliente
  /// inyectado no puede recibir ese ajuste y lo cierra quien lo creó).
  /// [now] es el reloj del cortafuegos (inyectable para probar el cooldown).
  FsHttpApi(this.config, {http.Client? client, DateTime Function()? now})
    : _ownsClient = client == null,
      _client =
          client ??
          IOClient(HttpClient()..connectionTimeout = config.connectTimeout),
      _now = now ?? DateTime.now;

  /// Duración del bloqueo de IP de FacturaScripts (`INCIDENT_EXPIRATION_TIME`).
  static const Duration cooldownDuration = Duration(minutes: 10);

  /// Tamaño máximo de página en [listAll]: FacturaScripts no limita `limit`,
  /// pero una página enorme bloquea PHP y MySQL durante segundos.
  static const int maxPageSize = 500;

  /// Longitud máxima del cuerpo que se conserva en `ErpApiException`.
  static const int maxStoredBodyLength = 2048;

  final FsApiConfig config;
  final http.Client _client;
  final bool _ownsClient;
  final DateTime Function() _now;
  final Logger _log = appLogger('facturascripts.http');
  final StreamController<FsGuardState> _guardStates =
      StreamController<FsGuardState>.broadcast();

  FsGuardState _guard = const FsGuardOk();
  bool _closed = false;

  /// Estado actual del cortafuegos.
  FsGuardState get guardState => _guard;

  /// Cambios de estado del cortafuegos (para la interfaz: "clave rechazada",
  /// "IP bloqueada hasta las 12:34"). Solo emite cambios, no el estado inicial.
  Stream<FsGuardState> get guardStates => _guardStates.stream;

  /// Vuelve a [FsGuardOk]. Lo invoca la capa superior cuando el usuario pulsa
  /// "reintentar" o guarda una configuración nueva. No comprueba nada: la
  /// siguiente llamada real decidirá.
  void resetGuard() => _setGuard(const FsGuardOk());

  /// Cierra el cliente HTTP propio y el flujo de estados. Tras cerrar, toda
  /// llamada lanza [StateError].
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    if (_ownsClient) _client.close();
    await _guardStates.close();
  }

  // ---------------------------------------------------------------------------
  // FsApi
  // ---------------------------------------------------------------------------

  @override
  Future<List<String>> resources() async {
    const action = 'consultar los recursos';
    final response = await _send('GET', _url(const []), action: action);
    final json = _successMap(response, action);
    final list = json['resources'];
    if (list is! List<Object?>) {
      throw _unexpected(response, action, "falta la lista 'resources'");
    }
    return [for (final item in list) item.toString()];
  }

  @override
  Future<FsPage> list(
    String resource, {
    Map<String, Object?> filters = const {},
    Map<String, FsSortOrder> sort = const {},
    int limit = 50,
    int offset = 0,
  }) async {
    // Con limit <= 0 FacturaScripts devuelve la tabla ENTERA e ignora offset.
    if (limit <= 0) {
      throw ArgumentError.value(limit, 'limit', 'Debe ser mayor que cero');
    }
    if (offset < 0) {
      throw ArgumentError.value(offset, 'offset', 'No puede ser negativo');
    }
    final action = 'listar $resource';
    final query = <String, String>{
      for (final MapEntry(:key, :value) in filters.entries)
        'filter[$key]': fsEncodeValue(value),
      for (final MapEntry(:key, :value) in sort.entries)
        'sort[$key]': value == FsSortOrder.asc ? 'ASC' : 'DESC',
      'limit': '$limit',
      'offset': '$offset',
    };
    final url = _url([resource]).replace(queryParameters: query);
    final response = await _send('GET', url, action: action);
    final json = _successJson(response, action);
    if (json is! List<Object?>) {
      throw _unexpected(response, action, 'se esperaba una lista JSON');
    }
    final items = <FsRecord>[
      for (var i = 0; i < json.length; i++)
        if (json[i] case final FsRecord record)
          record
        else
          throw _unexpected(response, action, 'el elemento $i no es un objeto'),
    ];
    final totalHeader = response.headers['x-total-count'];
    final totalCount = totalHeader == null ? null : int.tryParse(totalHeader);
    return FsPage(items: items, totalCount: totalCount);
  }

  @override
  Future<List<FsRecord>> listAll(
    String resource, {
    Map<String, Object?> filters = const {},
    required String sortBy,
    int pageSize = 200,
  }) async {
    final size = pageSize.clamp(1, maxPageSize);
    final all = <FsRecord>[];
    var offset = 0;
    while (true) {
      final page = await list(
        resource,
        filters: filters,
        sort: {sortBy: FsSortOrder.asc},
        limit: size,
        offset: offset,
      );
      all.addAll(page.items);
      // Página incompleta: no hay más. Si el servidor informa del total, se
      // usa como segunda condición de parada para no pedir una página vacía.
      if (page.items.length < size) break;
      final total = page.totalCount;
      if (total != null && all.length >= total) break;
      offset += size;
    }
    return all;
  }

  @override
  Future<FsRecord?> get(String resource, Object id) async {
    final action = 'leer $resource/$id';
    final response = await _send(
      'GET',
      _url([resource, '$id']),
      action: action,
    );
    if (response.statusCode == 404 && _isModelError(response)) return null;
    return _successMap(response, action);
  }

  @override
  Future<FsRecord> create(String resource, Map<String, Object?> fields) async {
    final action = 'crear $resource';
    final response = await _send(
      'POST',
      _url([resource]),
      fields: fields,
      action: action,
    );
    return _dataOf(response, action);
  }

  @override
  Future<FsRecord> update(
    String resource,
    Object id,
    Map<String, Object?> fields,
  ) async {
    final action = 'modificar $resource/$id';
    final response = await _send(
      'PUT',
      _url([resource, '$id']),
      fields: fields,
      action: action,
    );
    return _dataOf(response, action);
  }

  @override
  Future<bool> delete(String resource, Object id) async {
    final action = 'borrar $resource/$id';
    final response = await _send(
      'DELETE',
      _url([resource, '$id']),
      action: action,
    );
    if (response.statusCode == 404 && _isModelError(response)) return false;
    _successJson(response, action);
    return true;
  }

  @override
  Future<FsRecord> call(
    String endpoint, {
    List<Object> path = const [],
    Map<String, Object?> fields = const {},
  }) async {
    final action = 'llamar a ${[endpoint, ...path].join('/')}';
    final response = await _send(
      'POST',
      _url([endpoint, for (final segment in path) '$segment']),
      fields: fields,
      action: action,
    );
    return _successMap(response, action);
  }

  // ---------------------------------------------------------------------------
  // Transporte
  // ---------------------------------------------------------------------------

  Uri _url(List<String> segments) {
    final buffer = StringBuffer(config.apiRoot);
    for (final segment in segments) {
      buffer
        ..write('/')
        ..write(segment);
    }
    return Uri.parse(buffer.toString());
  }

  /// Ejecuta la petición si el cortafuegos lo permite y traduce los fallos de
  /// transporte a [ErpApiException] sin código (resultado desconocido).
  Future<http.Response> _send(
    String method,
    Uri url, {
    Map<String, Object?>? fields,
    required String action,
  }) async {
    if (_closed) throw StateError('FsHttpApi cerrado');
    _checkGuard();

    final request = http.Request(method, url)
      ..headers['Token'] = config.token
      ..headers['Accept'] = 'application/json';
    if (fields != null) request.bodyFields = fsEncodeFields(fields);

    final started = _now();
    final http.Response response;
    try {
      response = await _execute(request).timeout(config.requestTimeout);
    } on TimeoutException catch (error) {
      _log.warning('$method $url sin respuesta en ${config.requestTimeout}');
      throw ErpApiException(
        'FacturaScripts no respondió en ${config.requestTimeout.inSeconds} s '
        'al $action',
        cause: error,
      );
    } on IOException catch (error) {
      _log.warning('$method $url fallo de red: $error');
      throw ErpApiException(
        'No se pudo conectar con FacturaScripts al $action: ${error.toString()}',
        cause: error,
      );
    } on http.ClientException catch (error) {
      _log.warning('$method $url fallo del cliente HTTP: ${error.message}');
      throw ErpApiException(
        'No se pudo conectar con FacturaScripts al $action: ${error.message}',
        cause: error,
      );
    }
    _log.fine(
      '$method ${url.path}${url.hasQuery ? '?${url.query}' : ''} '
      '-> ${response.statusCode} '
      '(${_now().difference(started).inMilliseconds} ms)',
    );
    return response;
  }

  Future<http.Response> _execute(http.Request request) async {
    final streamed = await _client.send(request);
    return http.Response.fromStream(streamed);
  }

  // ---------------------------------------------------------------------------
  // Cortafuegos
  // ---------------------------------------------------------------------------

  void _checkGuard() {
    switch (_guard) {
      case FsGuardOk():
        return;
      case FsGuardAuthLocked(:final since, :final error):
        throw ErpApiException(
          'Clave de API rechazada el ${fsFormatDateTime(since)}; '
          'no se reintenta automáticamente',
          statusCode: error.statusCode,
          responseBody: error.responseBody,
          cause: error,
        );
      case FsGuardCooldown(:final until):
        if (!_now().isBefore(until)) {
          _setGuard(const FsGuardOk());
          return;
        }
        throw ErpApiException(
          'Acceso a FacturaScripts suspendido hasta ${fsFormatDateTime(until)} '
          'por bloqueo de IP; no se reintenta automáticamente',
          statusCode: 429,
        );
    }
  }

  void _setGuard(FsGuardState state) {
    if (state == _guard) return;
    _guard = state;
    _log.info('Cortafuegos FacturaScripts: $state');
    if (!_guardStates.isClosed) _guardStates.add(state);
  }

  // ---------------------------------------------------------------------------
  // Decodificación de respuestas
  // ---------------------------------------------------------------------------

  /// FacturaScripts no declara `charset` y escapa el no ASCII en JSON, pero
  /// las páginas HTML de error sí traen UTF-8: se decodifica siempre así.
  String _bodyText(http.Response response) =>
      utf8.decode(response.bodyBytes, allowMalformed: true);

  Object? _tryDecode(String text) {
    try {
      return jsonDecode(text);
    } on FormatException {
      return null;
    }
  }

  /// `true` si el cuerpo tiene la forma de error de recurso de modelo
  /// (`{"error":"Registro no encontrado"}`). Un 404 con la forma del kernel
  /// (`{"status":"error","message":"Recurso de API no válido"}`) significa
  /// que el RECURSO no existe: eso es un error de configuración, no un
  /// registro ausente, y debe lanzar.
  bool _isModelError(http.Response response) {
    final json = _tryDecode(_bodyText(response));
    return json is Map<String, Object?> && json.containsKey('error');
  }

  /// Lanza si el código no es 2xx o el cuerpo no es JSON; devuelve el JSON.
  Object? _successJson(http.Response response, String action) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw _failure(response, action);
    }
    final text = _bodyText(response);
    try {
      return jsonDecode(text);
    } on FormatException catch (error) {
      throw ErpApiException(
        'FacturaScripts respondió ${response.statusCode} al $action con un '
        'cuerpo que no es JSON',
        statusCode: response.statusCode,
        responseBody: _truncate(text),
        cause: error,
      );
    }
  }

  FsRecord _successMap(http.Response response, String action) {
    final json = _successJson(response, action);
    if (json is FsRecord) return json;
    throw _unexpected(response, action, 'se esperaba un objeto JSON');
  }

  /// Campo `data` de `{"ok":..,"data":{..}}` (POST/PUT).
  FsRecord _dataOf(http.Response response, String action) {
    final json = _successMap(response, action);
    final data = json['data'];
    if (data is FsRecord) return data;
    throw _unexpected(response, action, "falta el objeto 'data'");
  }

  ErpApiException _unexpected(
    http.Response response,
    String action,
    String detail,
  ) => ErpApiException(
    'Respuesta inesperada de FacturaScripts al $action: $detail',
    statusCode: response.statusCode,
    responseBody: _truncate(_bodyText(response)),
  );

  /// Construye la excepción de un código de error y actualiza el cortafuegos.
  ErpApiException _failure(http.Response response, String action) {
    final text = _bodyText(response);
    final error = ErpApiException(
      'FacturaScripts respondió ${response.statusCode} al $action: '
      '${_errorDetail(text)}',
      statusCode: response.statusCode,
      responseBody: _truncate(text),
    );
    switch (response.statusCode) {
      case 401 || 403:
        _setGuard(FsGuardAuthLocked(since: _now(), error: error));
      case 429:
        _setGuard(FsGuardCooldown(until: _now().add(cooldownDuration)));
    }
    _log.warning(error.message);
    return error;
  }

  /// Texto legible del error: `error` o `message` del JSON, o el cuerpo sin
  /// etiquetas HTML recortado.
  String _errorDetail(String text) {
    final json = _tryDecode(text);
    if (json is Map<String, Object?>) {
      final detail = json['error'] ?? json['message'];
      if (detail is String && detail.trim().isNotEmpty) return detail.trim();
    }
    final plain = text
        .replaceAll(RegExp(r'<[^>]*>'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (plain.isEmpty) return 'sin detalle';
    return plain.length > 200 ? '${plain.substring(0, 200)}…' : plain;
  }

  String _truncate(String text) => text.length <= maxStoredBodyLength
      ? text
      : text.substring(0, maxStoredBodyLength);
}
