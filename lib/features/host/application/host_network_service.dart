import 'dart:async';
import 'dart:io';

import '../../../core/errors/app_exception.dart';
import '../../../core/logging/app_logger.dart';
import '../../../core/network/discovery/discovery_protocol.dart';
import '../../../core/network/discovery/udp_discovery_responder.dart';
import '../../../core/network/protocol/message.dart';
import '../../../core/network/protocol/transport_messages.dart';
import '../../../core/network/tcp/tcp_host_server.dart';
import '../../../core/utils/streams.dart';
import '../../sala/protocol/sala_messages.dart';
import 'alert_bus.dart';
import 'catalog_service.dart';
import 'sala_service.dart';

/// Parámetros de red del host.
final class HostNetworkConfig {
  const HostNetworkConfig({
    required this.hostId,
    required this.hostName,
    this.tcpPort = kDefaultHostPort,
    this.discoveryPort = kDiscoveryPort,
    this.pairingCode,
    this.bindAddress,
    this.discoveryEnabled = true,
    this.serverOptions,
  });

  final String hostId;
  final String hostName;

  /// `0` pide un puerto efímero (tests).
  final int tcpPort;
  final int discoveryPort;
  final String? pairingCode;

  /// Interfaz de escucha (TCP y UDP); `null` = todas las IPv4.
  final InternetAddress? bindAddress;
  final bool discoveryEnabled;

  /// Opciones del servidor TCP distintas de las de producción (tests). El
  /// puerto, la interfaz y el código de emparejamiento de aquí tienen
  /// prioridad.
  final HostServerOptions? serverOptions;

  bool get requiresPairing {
    final code = pairingCode;
    return code != null && code.isNotEmpty;
  }

  HostServerOptions toServerOptions() {
    final base = serverOptions ?? const HostServerOptions();
    return HostServerOptions(
      port: tcpPort,
      bindAddress: bindAddress,
      handshakeTimeout: base.handshakeTimeout,
      heartbeatInterval: base.heartbeatInterval,
      idleTimeout: base.idleTimeout,
      maxClients: base.maxClients,
      maxFrameBytes: base.maxFrameBytes,
      pairingCode: pairingCode,
      dedupeCacheSize: base.dedupeCacheSize,
      maxConsecutiveBadFrames: base.maxConsecutiveBadFrames,
      closeTimeout: base.closeTimeout,
    );
  }
}

/// Red del host: servidor TCP de comanderos, respondedor UDP de
/// descubrimiento y difusión de los cambios de sala y catálogo.
///
/// Traduce los mensajes de aplicación (`sala_messages.dart`) a llamadas de
/// [SalaService] y [CatalogService]; los errores de negocio viajan como
/// `error` no reintentable con su código y un payload mal formado como
/// `validation`.
///
/// Los envíos de líneas (`comanda.submit`) y las marchas de pase
/// (`comanda.pase.marchar`) que llegan sin camarero se firman con el nombre
/// del dispositivo de la sesión: la línea y la marcha guardan quién las
/// pidió aunque el comandero no lo mande.
final class HostNetworkService {
  HostNetworkService({
    required this._sala,
    required this._catalog,
    required this._alerts,
    required HostNetworkConfig config,
  }) {
    _config = config;
  }

  static final Logger _log = appLogger('host.red');

  /// Código de `error` cuando el host aún no tiene catálogo (reintentable).
  static const String catalogoNoDisponible = 'catalogo_no_disponible';

  final SalaService _sala;
  final CatalogService _catalog;
  final AlertBus _alerts;
  late HostNetworkConfig _config;

  TcpHostServer? _server;
  UdpDiscoveryResponder? _responder;
  StreamSubscription<HostSessionEvent>? _serverEvents;
  StreamSubscription<SalaChangedEvent>? _salaEvents;
  StreamSubscription<CatalogoChangedEvent>? _catalogEvents;
  StreamSubscription<void>? _enrutamientoEvents;
  final StreamController<HostSessionEvent> _sessionEvents =
      StreamController<HostSessionEvent>.broadcast();
  Future<void>? _transition;

  HostNetworkConfig get config => _config;
  bool get isRunning => _server?.isRunning ?? false;

  /// Puerto TCP real de escucha (relevante con `tcpPort = 0`).
  int? get tcpPort => _server?.port;

  /// Puerto UDP real; `null` si el descubrimiento no está activo.
  int? get discoveryPort =>
      (_responder?.isRunning ?? false) ? _responder!.port : null;

  List<ClientSessionInfo> get sessions => _server?.sessions ?? const [];

  /// Altas y bajas de comanderos (sobrevive a reinicios del servidor).
  Stream<HostSessionEvent> get sessionEvents => _sessionEvents.stream;

  /// Abre el puerto TCP y, si está activado, el de descubrimiento. Si el UDP
  /// falla (puerto ocupado) el servidor TCP sigue en marcha y se avisa.
  ///
  /// Lanza [NetworkException] si el puerto TCP no se puede abrir.
  Future<void> start() => _serialize(_start);

  Future<void> _start() async {
    if (_server != null) return;
    final server = TcpHostServer(
      identity: HostIdentity(
        hostId: _config.hostId,
        hostName: _config.hostName,
      ),
      onRequest: _onRequest,
      options: _config.toServerOptions(),
    );
    _serverEvents = server.events.listen(_onSessionEvent);
    try {
      await server.start();
    } on NetworkException {
      await _serverEvents?.cancel();
      _serverEvents = null;
      await server.dispose();
      rethrow;
    }
    _server = server;
    _salaEvents = _sala.changes.listen(
      (event) => _broadcast(SalaMessageTypes.salaChanged, event.toJson()),
    );
    _catalogEvents = _catalog.changes.listen(
      (event) => _broadcast(SalaMessageTypes.catalogoChanged, event.toJson()),
    );
    _enrutamientoEvents = _sala.enrutamientoChanges.listen(
      (_) => _broadcast(SalaMessageTypes.enrutamientoChanged, const {}),
    );
    _log.info('Host "${_config.hostName}" escuchando en TCP ${server.port}');

    if (_config.discoveryEnabled) {
      final responder = UdpDiscoveryResponder(
        announcement: () => HostAnnouncement(
          hostId: _config.hostId,
          hostName: _config.hostName,
          tcpPort: server.port,
          requiresPairing: _config.requiresPairing,
        ),
        port: _config.discoveryPort,
        bindAddress: _config.bindAddress,
      );
      try {
        await responder.start();
        _responder = responder;
      } on NetworkException catch (error) {
        _alerts.aviso(
          'Descubrimiento UDP no disponible: los comanderos tendrán que '
          'introducir la IP a mano',
          detalle: error.message,
          origen: 'red',
        );
      }
    }
  }

  /// Despide a los comanderos y libera los puertos.
  Future<void> stop() => _serialize(_stop);

  Future<void> _stop() async {
    await _salaEvents?.cancel();
    await _catalogEvents?.cancel();
    await _enrutamientoEvents?.cancel();
    _salaEvents = null;
    _catalogEvents = null;
    _enrutamientoEvents = null;
    final responder = _responder;
    _responder = null;
    await responder?.stop();
    final server = _server;
    _server = null;
    if (server != null) {
      await server.dispose();
      await _serverEvents?.cancel();
      _serverEvents = null;
    }
  }

  /// Aplica una configuración nueva. Si cambia algo que exige reabrir el
  /// puerto (puerto, emparejamiento, interfaz, identidad) y el servicio está
  /// en marcha, se reinicia; el nombre se aplica en caliente al anuncio UDP.
  Future<void> applyConfig(HostNetworkConfig config) async {
    final previo = _config;
    _config = config;
    if (_server == null) return;
    final soloNombre =
        previo.hostId == config.hostId &&
        previo.tcpPort == config.tcpPort &&
        previo.discoveryPort == config.discoveryPort &&
        previo.pairingCode == config.pairingCode &&
        previo.bindAddress == config.bindAddress &&
        previo.discoveryEnabled == config.discoveryEnabled;
    if (soloNombre) return;
    await stop();
    await start();
  }

  /// Expulsa a un comandero.
  Future<void> disconnect(String deviceId) =>
      _server?.disconnect(deviceId) ?? Future<void>.value();

  Future<void> dispose() async {
    await stop();
    cerrarSinEsperar(_sessionEvents);
  }

  // ---------------------------------------------------------------------------
  // Peticiones

  Future<Map<String, Object?>> _onRequest(
    ClientSessionInfo session,
    ProtocolMessage request,
  ) async {
    final payload = request.payload;
    try {
      switch (request.type) {
        case SalaMessageTypes.salaSnapshotGet:
          return _sala.snapshot().toJson();
        case SalaMessageTypes.catalogoGet:
          final catalogo = _catalog.catalogo;
          if (catalogo == null) {
            throw const RemoteRequestException(
              'El host todavía no tiene catálogo',
              code: catalogoNoDisponible,
              retryable: true,
            );
          }
          return catalogo.toJson();
        case SalaMessageTypes.comandaSubmit:
          final envio = ComandaSubmitPayload.fromJson(payload);
          final result = await _sala.aceptarLineas(
            envio.copyWith(camarero: _camareroDe(envio.camarero, session)),
          );
          return result.toJson();
        case SalaMessageTypes.lineaAnular:
          final anular = LineaAnularPayload.fromJson(payload);
          final result = await _sala.anularLinea(
            anular.mesaId,
            anular.lineaId,
            motivo: anular.motivo ?? 'Anulada desde ${session.deviceName}',
          );
          return result.toJson();
        case SalaMessageTypes.mesaCuenta:
          final cuenta = MesaCuentaPayload.fromJson(payload);
          final result = await _sala.marcarCuenta(
            cuenta.mesaId,
            cuenta.solicitada,
          );
          return result.toJson();
        case SalaMessageTypes.paseMarchar:
          final marcha = MarcharPasePayload.fromJson(payload);
          final result = await _sala.marcharPase(
            marcha.mesaId,
            marcha.pase,
            marchaId: marcha.marchaId,
            comandaId: marcha.comandaId,
            camarero: _camareroDe(marcha.camarero, session),
          );
          return result.toJson();
        default:
          throw RemoteRequestException(
            "El host no entiende '${request.type}'",
            code: ErrorCodes.unknownType,
          );
      }
    } on FormatException catch (error) {
      throw ValidationException(
        "Petición '${request.type}' mal formada: ${error.message}",
        cause: error,
      );
    }
  }

  /// Camarero de una petición de un comandero: el que manda o, si falta o
  /// viene en blanco, el nombre del dispositivo de la sesión (la tablet
  /// manda el suyo, `nombreTpv`, sin pasar por la red).
  static String _camareroDe(String? camarero, ClientSessionInfo session) =>
      camarero == null || camarero.trim().isEmpty
      ? session.deviceName
      : camarero;

  void _broadcast(String type, Map<String, Object?> payload) {
    final server = _server;
    if (server == null) return;
    try {
      server.broadcast(type, payload);
    } on ProtocolException catch (error) {
      _log.severe('No se pudo difundir $type', error);
    }
  }

  void _onSessionEvent(HostSessionEvent event) {
    switch (event) {
      case ClientConnected(:final session):
        _alerts.info(
          'Comandero conectado: ${session.deviceName}',
          detalle: '${session.remoteAddress}:${session.remotePort}',
          origen: 'red',
        );
      case ClientDisconnected(:final session, :final reason):
        if (reason == kConnectionLostReason ||
            reason == ByeReasons.idleTimeout) {
          _alerts.aviso(
            'Comandero desconectado: ${session.deviceName}',
            detalle: reason,
            origen: 'red',
          );
        }
    }
    if (!_sessionEvents.isClosed) _sessionEvents.add(event);
  }

  /// Encadena start/stop para que nunca se solapen; un fallo no rompe la
  /// cadena (el llamador lo recibe igualmente).
  Future<void> _serialize(Future<void> Function() action) {
    final run = (_transition ?? Future<void>.value()).then((_) => action());
    _transition = run.then((_) {}, onError: (Object _) {});
    return run;
  }
}
