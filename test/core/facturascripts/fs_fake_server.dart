/// Servidor HTTP falso para probar el cliente de FacturaScripts sin red ni
/// sandbox: registra cada petición recibida y responde lo que el test indique.
///
/// Los casos 401/403/429 se prueban SOLO aquí: contra el sandbox real
/// contarían como incidencias y banearían la IP de todos los agentes.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Petición registrada por el servidor falso.
final class RecordedRequest {
  RecordedRequest({
    required this.method,
    required this.path,
    required this.query,
    required this.rawQuery,
    required this.headers,
    required this.body,
  });

  final String method;
  final String path;

  /// Parámetros de la query decodificados (`filter[codcliente]` → valor).
  final Map<String, String> query;
  final String rawQuery;

  /// Cabeceras en minúsculas.
  final Map<String, String> headers;
  final String body;

  /// Campos del cuerpo `application/x-www-form-urlencoded` decodificados.
  Map<String, String> get formFields =>
      body.isEmpty ? const {} : Uri.splitQueryString(body);

  @override
  String toString() => '$method $path${rawQuery.isEmpty ? '' : '?$rawQuery'}';
}

/// Respuesta que debe devolver el servidor falso.
final class FakeResponse {
  const FakeResponse(
    this.statusCode, {
    this.body = '',
    this.contentType = 'application/json',
    this.headers = const {},
    this.delay,
  });

  FakeResponse.json(this.statusCode, Object? json, {this.headers = const {}})
    : body = jsonEncode(json),
      contentType = 'application/json',
      delay = null;

  final int statusCode;
  final String body;
  final String contentType;
  final Map<String, String> headers;

  /// Retraso antes de responder (para probar timeouts).
  final Duration? delay;
}

typedef FakeHandler = FutureOr<FakeResponse> Function(RecordedRequest request);

/// Servidor en `127.0.0.1` con puerto efímero.
final class FsFakeServer {
  FsFakeServer._(this._server);

  static Future<FsFakeServer> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fake = FsFakeServer._(server);
    fake._subscription = server.listen(fake._handle);
    return fake;
  }

  final HttpServer _server;
  late final StreamSubscription<HttpRequest> _subscription;
  final List<RecordedRequest> requests = [];
  final List<FakeResponse> _queue = [];
  FakeHandler? handler;

  String get baseUrl => 'http://127.0.0.1:${_server.port}';

  /// Encola respuestas que se consumen en orden; agotadas, se usa [handler]
  /// o un 500 por defecto.
  void enqueue(FakeResponse response) => _queue.add(response);

  void enqueueJson(int status, Object? json, {Map<String, String>? headers}) =>
      enqueue(FakeResponse.json(status, json, headers: headers ?? const {}));

  Future<void> _handle(HttpRequest request) async {
    final body = await utf8.decoder.bind(request).join();
    final headers = <String, String>{};
    request.headers.forEach((name, values) {
      headers[name.toLowerCase()] = values.join(', ');
    });
    final recorded = RecordedRequest(
      method: request.method,
      path: request.uri.path,
      query: request.uri.queryParameters,
      rawQuery: request.uri.query,
      headers: headers,
      body: body,
    );
    requests.add(recorded);

    FakeResponse response;
    if (_queue.isNotEmpty) {
      response = _queue.removeAt(0);
    } else if (handler != null) {
      response = await handler!(recorded);
    } else {
      response = const FakeResponse(
        500,
        body: '{"error":"API-ERROR: sin respuesta programada"}',
      );
    }
    if (response.delay != null) await Future<void>.delayed(response.delay!);

    try {
      request.response.statusCode = response.statusCode;
      request.response.headers.contentType = ContentType.parse(
        response.contentType,
      );
      response.headers.forEach(request.response.headers.set);
      // Bytes UTF-8 sin declarar charset, como hace PHP: `write()` usaría
      // latin1 por defecto y no reproduciría al servidor real.
      request.response.add(utf8.encode(response.body));
      await request.response.close();
    } on IOException {
      // El cliente cerró antes de tiempo (timeout): nada que hacer.
    }
  }

  Future<void> close() async {
    await _subscription.cancel();
    await _server.close(force: true);
  }
}
