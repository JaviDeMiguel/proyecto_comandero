import 'dart:async';

import 'package:uuid/uuid.dart';

import '../../../core/errors/app_exception.dart';
import '../../../core/facturascripts/catalog/catalog_models.dart';
import '../../../core/logging/app_logger.dart';
import '../../../core/network/discovery/discovery_protocol.dart';
import '../../../core/network/discovery/udp_discovery_scanner.dart';
import '../../../core/network/protocol/message.dart';
import '../../../core/network/tcp/tcp_comandero_client.dart';
import '../../sala/domain/comanda.dart';
import '../../sala/domain/enrutamiento_comandas.dart';
import '../../sala/domain/linea_comanda.dart' show DestinoPreparacion;
import '../../sala/domain/mesa.dart';
import '../../sala/domain/pases.dart';
import '../../sala/protocol/sala_messages.dart';
import '../domain/comandero_cache_repository.dart';
import '../domain/comandero_config.dart';
import '../domain/comandero_exceptions.dart';
import '../domain/comandero_state.dart';
import '../domain/pedido_en_edicion.dart';
import '../domain/traspaso_comandero.dart';

part 'comandero_pases.dart';

final Logger _log = appLogger('comandero.controller');
const Uuid _uuid = Uuid();
const SinConexionException _sinHostObjetivo = SinConexionException(
  'No hay ningún host configurado; conecta antes de enviar',
);

/// Construye el cliente TCP. Existe para que los tests acorten los
/// temporizadores o inyecten un `Random` fijo.
typedef ComanderoClientFactory = TcpComanderoClient Function(
  ClientIdentity identity,
  ClientOptions options,
  Future<HostEndpoint?> Function() rediscover,
);

/// Cerebro de la aplicación del comandero (móvil): descubre el host, mantiene
/// la sesión, refleja la sala y el catálogo, guarda el carrito de cada mesa y
/// envía las comandas de forma fiable.
///
/// Es Dart puro: la capa de presentación lo envuelve en un provider y pinta
/// [states]. Toda la red la hace [TcpComanderoClient] (reconexión incluida);
/// aquí solo se traducen sus estados y se gestionan los mensajes de sala.
final class ComanderoController {
  ComanderoController({
    required ComanderoConfig config,
    ComanderoClientFactory? clientFactory,
    UdpDiscoveryScanner? scanner,
    this._cache,
    ClientOptions clientOptions = const ClientOptions(),
    this._scanOptions,
    this.reintentoCargaSala = const Duration(seconds: 2),
    this.reintentoCatalogo = const Duration(seconds: 2),
    this.reintentoCatalogoMax = const Duration(minutes: 1),
    DateTime Function()? now,
    String Function()? newId,
  }) : _config = config,
       _clientFactory = clientFactory ?? _defaultClientFactory,
       _scanner = scanner ?? UdpDiscoveryScanner(),
       _baseClientOptions = clientOptions,
       _now = now ?? DateTime.now,
       _newId = newId ?? _uuid.v4 {
    _client = _createClient(config.pairingCode);
    _cacheLoaded = _loadCache();
  }

  /// Espera entre intentos de pedir el snapshot de sala cuando el host
  /// responde algo inválido estando conectado.
  final Duration reintentoCargaSala;

  /// Primera espera antes de reintentar la carga del catálogo cuando falla;
  /// se duplica en cada fallo seguido hasta [reintentoCatalogoMax].
  final Duration reintentoCatalogo;

  /// Espera máxima entre reintentos de carga del catálogo.
  final Duration reintentoCatalogoMax;

  final ComanderoClientFactory _clientFactory;
  final UdpDiscoveryScanner _scanner;
  final ComanderoCacheRepository? _cache;
  final ClientOptions _baseClientOptions;
  final DiscoveryScanOptions? _scanOptions;
  final DateTime Function() _now;
  final String Function() _newId;

  ComanderoConfig _config;
  late TcpComanderoClient _client;
  String? _pairingCode;
  StreamSubscription<ClientConnectionState>? _clientStates;
  StreamSubscription<ProtocolMessage>? _clientMessages;
  late final Future<void> _cacheLoaded;

  final StreamController<ComanderoState> _states =
      StreamController<ComanderoState>.broadcast();
  final StreamController<PedidoEnEdicion> _pedidosCambiados =
      StreamController<PedidoEnEdicion>.broadcast();
  final StreamController<AvisoComandero> _avisos =
      StreamController<AvisoComandero>.broadcast();

  ComanderoState _state = const SinHost();
  HostObjetivo? _host;
  SalaSnapshot? _sala;
  CatalogSnapshot? _catalogo;
  String? _catalogoVersion;

  /// Versión del catálogo que anuncia el host (snapshot o `catalogo.changed`).
  String? _catalogoVersionHost;
  bool _sesionLista = false;

  /// Reintento programado de la carga del catálogo (se cancela al perder la
  /// sesión) y fallos seguidos para la espera creciente.
  Timer? _reintentoCatalogo;
  int _fallosCatalogo = 0;

  /// Cada carga de catálogo toma un número; solo aplica su resultado la más
  /// reciente (una respuesta lenta no pisa a otra posterior).
  int _cargaCatalogo = 0;

  /// Cambia con cada `welcome` y con cada pérdida de sesión: invalida las
  /// cargas de sala/catálogo de una sesión anterior.
  int _sesion = 0;
  final Map<String, PedidoEnEdicion> _pedidos = {};

  /// Envíos de comanda sin terminar (para esperarlos en [cerrarParaTraspaso]);
  /// cada futuro termina sin error.
  final Set<Future<void>> _enviosEnCurso = {};

  /// Anulaciones y marchas de pase fiables sin respuesta del host.
  int _anulacionesEnCurso = 0;
  int _marchasEnCurso = 0;
  Timer? _reintentoSala;
  bool _disposed = false;

  // ---------------------------------------------------------------------------
  // Lectura
  // ---------------------------------------------------------------------------

  ComanderoConfig get config => _config;
  ComanderoState get state => _state;

  /// Cambios de estado (broadcast); se cierra en [dispose].
  Stream<ComanderoState> get states => _states.stream;

  /// Carritos modificados (añadir, cambiar, quitar, enviar, confirmar).
  Stream<PedidoEnEdicion> get pedidosCambiados => _pedidosCambiados.stream;

  /// Avisos puntuales para el camarero (broadcast): p. ej. un envío en el que
  /// el host ya tenía alguna línea, posiblemente con otra cantidad o nota.
  Stream<AvisoComandero> get avisos => _avisos.stream;

  /// `true` si no hay catálogo o no es la versión que anuncia el host.
  bool get catalogoDesactualizado =>
      _catalogo == null ||
      (_catalogoVersionHost != null &&
          _catalogoVersion != _catalogoVersionHost);

  /// Último snapshot de sala recibido (aunque se haya perdido la conexión).
  SalaSnapshot? get sala => _sala;

  /// Catálogo vigente (del host o de la caché).
  CatalogSnapshot? get catalogo => _catalogo;

  /// Mesas de la sala en el orden del host; vacío si aún no se cargó.
  List<Mesa> get mesas => _sala?.mesas ?? const [];

  /// Enrutamiento de comandas en uso: el que publica el host en el snapshot
  /// de sala (es quien fija el destino definitivo) o, si el host no lo
  /// publica, el de la configuración local.
  EnrutamientoComandas get enrutamiento =>
      _sala?.enrutamiento ?? _config.enrutamiento;

  /// Destino de preparación (cocina/barra) de un artículo de [codfamilia]
  /// según [enrutamiento], heredando por las familias del catálogo y con los
  /// destinos del ERP que trae el catálogo. El host publica su enrutamiento
  /// efectivo con los destinos del ERP ya aplanados como reglas del TPV, y
  /// esas reglas mandan sobre el ERP del mismo nivel: volver a aplicar el ERP
  /// solo es neutro si el snapshot y el catálogo son de la MISMA versión. Por
  /// eso, tras cargar un catálogo de otra versión (`catalogo.changed`) o
  /// cuando el host avisa de reglas nuevas (`enrutamiento.changed`), el
  /// comandero vuelve a pedir el snapshot; mientras llega puede calcular el
  /// destino antiguo (el host lo corrige al aceptar la línea). Aplicar el ERP
  /// aquí cubre el enrutamiento local de reserva y los hosts que no lo
  /// publican.
  DestinoPreparacion destinoDe(String? codfamilia) {
    final familias = _catalogo?.familias ?? const [];
    return enrutamiento.destinoDe(
      codfamilia,
      madreDe: EnrutamientoComandas.jerarquia(familias),
      erp: EnrutamientoComandas.destinosErp(familias),
    );
  }

  Comanda? comandaDe(String mesaId) => _sala?.comandaDeMesa(mesaId);

  /// Peticiones fiables (envíos, anulaciones, marchas) en cola o sin respuesta.
  int get pendientes => _client.pendingReliableCount;

  /// Carrito de la mesa (vacío si no se ha añadido nada).
  PedidoEnEdicion pedido(String mesaId) =>
      _pedidos[mesaId] ?? PedidoEnEdicion.vacio(mesaId);

  // ---------------------------------------------------------------------------
  // Descubrimiento y conexión
  // ---------------------------------------------------------------------------

  /// Arranque habitual: conecta con el host manual si está configurado; si
  /// no, busca por UDP y conecta cuando hay exactamente un host sin
  /// emparejamiento pendiente de código. Devuelve `true` si inició una
  /// conexión.
  Future<bool> iniciar({Duration? timeout}) async {
    _checkNotDisposed();
    final manual = _config.hostManual;
    if (manual != null && manual.trim().isNotEmpty) {
      conectarManual(manual);
      return true;
    }
    final hosts = await buscarHosts(timeout: timeout);
    if (hosts.length != 1) return false;
    final host = hosts.single;
    if (host.requiresPairing && (_config.pairingCode ?? '').isEmpty) {
      return false;
    }
    conectar(HostObjetivo.desdeDescubierto(host));
    return true;
  }

  /// Busca hosts por UDP durante [timeout]. Mientras no haya sesión, el
  /// estado pasa a [Buscando] y al terminar a [SinHost] con lo encontrado.
  /// Si ya hay sesión el estado no cambia (sirve para "cambiar de host").
  ///
  /// Lanza [NetworkException] si no hay red para enviar la sonda.
  Future<List<DiscoveredHost>> buscarHosts({Duration? timeout}) async {
    _checkNotDisposed();
    final escaneo = _opcionesEscaneo(timeout: timeout);
    final options = escaneo is DiscoveryScanOptions ? escaneo : await escaneo;
    final hosts = <DiscoveredHost>[];
    final reflejar = _host == null && _state is! Rechazado;
    if (reflejar) _setState(const Buscando());
    try {
      await for (final host in _scanner.discover(options)) {
        if (_disposed) break;
        hosts.add(host);
        if (reflejar && _host == null) {
          _setState(Buscando(hosts: List.unmodifiable(hosts)));
        }
      }
    } on NetworkException catch (error) {
      if (reflejar && _host == null) {
        _setState(SinHost(hostsEncontrados: hosts, error: error));
      }
      rethrow;
    }
    if (reflejar && _host == null && !_disposed) {
      _setState(SinHost(hostsEncontrados: List.unmodifiable(hosts)));
    }
    return hosts;
  }

  /// Conecta con [host] y mantiene la sesión hasta [desconectar]. Si se pasa
  /// [pairingCode] sustituye al de la configuración.
  void conectar(HostObjetivo host, {String? pairingCode}) {
    _checkNotDisposed();
    if (pairingCode != null) {
      _config = _config.copyWith(pairingCode: () => pairingCode);
    }
    _ensureClient(_config.pairingCode);
    final mismoHost = _host?.endpoint == host.endpoint;
    _host = mismoHost
        ? _host!.copyWith(hostId: host.hostId, hostName: host.hostName)
        : host;
    if (!mismoHost) _abandonarSesion();
    final actual = _client.state;
    if (mismoHost && actual is Connected && actual.endpoint == host.endpoint) {
      // Ya hay sesión con ese host (y el mismo emparejamiento, o el cliente
      // se habría recreado): el cliente no haría nada y no llegaría ningún
      // `Connected`, así que no se pasa por Conectando.
      if (_sesionLista) {
        _emitirConectado();
      } else {
        _setState(Conectando(host: _host!));
      }
      return;
    }
    _setState(Conectando(host: _host!));
    _client.connect(host.endpoint);
  }

  /// [conectar] con un host descubierto por UDP.
  void conectarDescubierto(DiscoveredHost host, {String? pairingCode}) =>
      conectar(HostObjetivo.desdeDescubierto(host), pairingCode: pairingCode);

  /// [conectar] con `ip` o `ip:puerto` escrito por el usuario. Lanza
  /// [ValidationException] si el texto no es una dirección válida.
  void conectarManual(String hostPuerto, {String? pairingCode}) {
    final HostEndpoint endpoint;
    try {
      endpoint = parseHostEndpoint(hostPuerto);
    } on FormatException catch (error) {
      throw ValidationException(
        'Dirección del host no válida: ${error.message}',
        cause: error,
      );
    }
    conectar(HostObjetivo(endpoint: endpoint), pairingCode: pairingCode);
  }

  /// Aplica el código de emparejamiento y el host manual guardados en los
  /// ajustes (textos vacíos = ausentes) sin recrear el controlador.
  ///
  /// - Si el host manual cambia a una dirección distinta del host objetivo,
  ///   conecta con ella.
  /// - Si cambia el código y la conexión está rechazada, reconectando o
  ///   abriéndose, reconecta con el código nuevo (el cliente se recrea: las
  ///   peticiones fiables en cola fallan y sus líneas vuelven al carrito).
  /// - Con sesión abierta, el código nuevo se usará en la próxima conexión;
  ///   borrar el host manual no corta la sesión.
  ///
  /// Un host manual inválido se registra y se ignora (no lanza).
  void actualizarConexion({
    required String? pairingCode,
    required String? hostManual,
  }) {
    if (_disposed) return;
    final codigo = _sinVacio(pairingCode);
    final manual = _sinVacio(hostManual);
    final cambiaCodigo = codigo != _sinVacio(_config.pairingCode);
    final cambiaManual = manual != _sinVacio(_config.hostManual);
    if (!cambiaCodigo && !cambiaManual) return;
    _config = _config.copyWith(
      pairingCode: () => codigo,
      hostManual: () => manual,
    );
    if (cambiaManual && manual != null) {
      final HostEndpoint endpoint;
      try {
        endpoint = parseHostEndpoint(manual);
      } on FormatException catch (error) {
        _log.warning('Host manual de los ajustes no válido: ${error.message}');
        return;
      }
      if (_host?.endpoint != endpoint) {
        conectar(HostObjetivo(endpoint: endpoint));
        return;
      }
    }
    final host = _host;
    if (cambiaCodigo &&
        host != null &&
        (_state is Rechazado ||
            _state is Reconectando ||
            _state is Conectando)) {
      conectar(host);
    }
  }

  static String? _sinVacio(String? texto) {
    final limpio = texto?.trim();
    return (limpio == null || limpio.isEmpty) ? null : limpio;
  }

  /// Cierra la sesión y deja de reconectar. Las peticiones fiables en cola
  /// fallan con [NetworkException] y sus líneas vuelven al carrito. Los
  /// carritos y el último snapshot se conservan.
  Future<void> desconectar() async {
    if (_disposed) return;
    _host = null;
    _abandonarSesion();
    await _client.disconnect();
    _setState(const SinHost());
  }

  /// [desconectar] y liberación de todos los recursos.
  Future<void> dispose() async {
    if (_disposed) return;
    _host = null;
    _abandonarSesion();
    await _clientStates?.cancel();
    await _clientMessages?.cancel();
    await _client.dispose();
    _disposed = true;
    await _states.close();
    await _pedidosCambiados.close();
    await _avisos.close();
  }

  /// Cierra el controlador para que otro retome su trabajo: corta la sesión
  /// (las comandas en cola fallan y sus líneas vuelven al carrito como tras
  /// un fallo de red), espera a que esos envíos terminen, exporta los
  /// carritos y libera los recursos ([dispose]).
  ///
  /// Las anulaciones y marchas en cola no se pueden traspasar: se cuentan en
  /// [TraspasoComandero.peticionesPerdidas] para avisar al camarero.
  Future<TraspasoComandero> cerrarParaTraspaso({
    Duration espera = const Duration(seconds: 5),
  }) async {
    if (_disposed) return const TraspasoComandero();
    final lineasEnEnvio = _pedidos.values.fold(
      0,
      (total, pedido) => total + pedido.enEnvio.length,
    );
    final perdidas = _anulacionesEnCurso + _marchasEnCurso;
    final envios = List.of(_enviosEnCurso);
    try {
      await desconectar();
      await Future.wait(envios).timeout(
        espera,
        onTimeout: () {
          _log.warning('Envíos sin terminar al cerrar para el traspaso');
          return const [];
        },
      );
      return TraspasoComandero(
        pedidos: exportarPedidos(),
        lineasDevueltas: lineasEnEnvio,
        peticionesPerdidas: perdidas,
      );
    } finally {
      await dispose();
    }
  }

  // ---------------------------------------------------------------------------
  // Carrito
  // ---------------------------------------------------------------------------

  /// Añade [articulo] al carrito de la mesa con el [pase] (`null` = directo);
  /// acumula si ya estaba con la misma nota y pase. Lanza [ValidationException]
  /// si no es vendible o la cantidad o el pase no son válidos.
  PedidoEnEdicion anadir(
    String mesaId,
    ArticuloCatalogo articulo, {
    double cantidad = 1,
    String? nota,
    int? pase,
  }) {
    _checkNotDisposed();
    return _guardarPedido(
      pedido(mesaId).conArticulo(
        articulo,
        nuevoId: _newId,
        cantidad: cantidad,
        nota: nota,
        pase: pase,
      ),
    );
  }

  /// Añade por referencia del catálogo vigente. Lanza [ValidationException]
  /// si no hay catálogo o la referencia no existe.
  PedidoEnEdicion anadirReferencia(
    String mesaId,
    String referencia, {
    double cantidad = 1,
    String? nota,
    int? pase,
  }) {
    final articulo = _catalogo?.porReferencia(referencia);
    if (articulo == null) {
      throw ValidationException(
        _catalogo == null
            ? 'Todavía no se ha recibido el catálogo del host'
            : "La referencia '$referencia' no está en el catálogo",
      );
    }
    return anadir(mesaId, articulo, cantidad: cantidad, nota: nota, pase: pase);
  }

  PedidoEnEdicion cambiarCantidad(
    String mesaId,
    String lineaId,
    double cantidad,
  ) {
    _checkNotDisposed();
    return _guardarPedido(
      pedido(mesaId).conCantidad(lineaId, cantidad, nuevoId: _newId),
    );
  }

  PedidoEnEdicion cambiarNota(String mesaId, String lineaId, String? nota) {
    _checkNotDisposed();
    return _guardarPedido(
      pedido(mesaId).conNota(lineaId, nota, nuevoId: _newId),
    );
  }

  /// Cambia cantidad, nota y, si se pasa [pase], el pase de una línea en una
  /// sola edición (ver [PedidoEnEdicion.conCantidadYNota]).
  PedidoEnEdicion editarLinea(
    String mesaId,
    String lineaId, {
    required double cantidad,
    required String? nota,
    int? Function()? pase,
  }) {
    _checkNotDisposed();
    return _guardarPedido(
      pedido(mesaId).conCantidadYNota(
        lineaId,
        cantidad: cantidad,
        nota: nota,
        pase: pase,
        nuevoId: _newId,
      ),
    );
  }

  /// Carritos no vacíos de todas las mesas.
  List<PedidoEnEdicion> exportarPedidos() => List.unmodifiable(_pedidos.values);

  /// Añade a los carritos las líneas de [pedidos] que no estén ya (por id);
  /// las que llegan "en envío" vuelven como editables y posiblemente
  /// transmitidas ([PedidoEnEdicion.fusionando]). Devuelve cuántas líneas
  /// se añadieron.
  int importarPedidos(Iterable<PedidoEnEdicion> pedidos) {
    _checkNotDisposed();
    var anadidas = 0;
    for (final importado in pedidos) {
      final actual = pedido(importado.mesaId);
      final fusionado = actual.fusionando(importado);
      if (identical(fusionado, actual)) continue;
      anadidas += fusionado.lineas.length - actual.lineas.length;
      _guardarPedido(fusionado);
    }
    return anadidas;
  }

  PedidoEnEdicion quitar(String mesaId, String lineaId) {
    _checkNotDisposed();
    return _guardarPedido(pedido(mesaId).sinLinea(lineaId));
  }

  /// Vacía las líneas aún no enviadas del carrito (las que están en envío se
  /// quedan hasta que el host responda).
  PedidoEnEdicion vaciar(String mesaId) {
    _checkNotDisposed();
    final actual = pedido(mesaId);
    return _guardarPedido(
      actual.sinLineas({for (final l in actual.pendientesDeEnviar) l.id}),
    );
  }

  // ---------------------------------------------------------------------------
  // Operaciones contra el host
  // ---------------------------------------------------------------------------

  /// Envía al host las líneas del carrito que aún no han salido.
  ///
  /// Las líneas se marcan "en envío" (ids fijos) y la petición es fiable: si
  /// no hay conexión queda en cola y se transmite al reconectar; mientras
  /// tanto siguen en el carrito. Al `ack` se quitan del carrito y se actualiza
  /// la comanda de la mesa. Si el host la rechaza ([ComanderoSalaException])
  /// o se llama a [desconectar]/[dispose] ([NetworkException]) vuelven a ser
  /// editables.
  ///
  /// Lanza [ValidationException] si no hay nada que enviar, y
  /// [SinConexionException] sin host objetivo (ni conectado ni reconectando).
  Future<ComandaSubmitResult> enviar(
    String mesaId, {
    String? camarero,
    int? comensales,
  }) {
    final envio = _enviar(mesaId, camarero: camarero, comensales: comensales);
    final seguimiento = envio.then<void>((_) {}, onError: (Object _) {});
    _enviosEnCurso.add(seguimiento);
    unawaited(
      seguimiento.whenComplete(() => _enviosEnCurso.remove(seguimiento)),
    );
    return envio;
  }

  Future<ComandaSubmitResult> _enviar(
    String mesaId, {
    String? camarero,
    int? comensales,
  }) async {
    _checkNotDisposed();
    final actual = pedido(mesaId);
    final lineas = actual.pendientesDeEnviar;
    if (lineas.isEmpty) {
      throw const ValidationException('No hay líneas nuevas que enviar');
    }
    final ids = {for (final linea in lineas) linea.id};
    final creadaEn = _now();
    final payload = ComandaSubmitPayload(
      mesaId: mesaId,
      lineas: [
        for (final linea in lineas)
          linea.aLineaComanda(
            creadaEn: creadaEn,
            destino: destinoDe(linea.articulo.codfamilia),
            camarero: camarero,
          ),
      ],
      camarero: camarero,
      comensales: comensales,
    );
    _guardarPedido(actual.marcandoEnvio(ids, enviando: true));

    final ProtocolMessage ack;
    try {
      ack = await _requestFiable(
        SalaMessageTypes.comandaSubmit,
        payload.toJson(),
        mesaId: mesaId,
      );
    } on AppException catch (error) {
      if (!_disposed) {
        final actual = pedido(mesaId);
        _guardarPedido(
          _pudoLlegarAlHost(error)
              ? actual.devolviendoTrasFalloDeRed(ids)
              : actual.marcandoEnvio(ids, enviando: false),
        );
      }
      rethrow;
    }
    final ComandaSubmitResult result;
    try {
      result = _parse(
        () => ComandaSubmitResult.fromJson(ack.payload),
        SalaMessageTypes.comandaSubmit,
      );
    } on ProtocolException {
      // El host respondió `ack`: aceptó las líneas aunque la respuesta no se
      // entienda. Se quitan del carrito (si no, quedarían bloqueadas "en
      // envío") y se pide la sala para ver la comanda real.
      if (!_disposed) {
        _guardarPedido(pedido(mesaId).sinLineas(ids));
        if (_client.state is Connected) {
          unawaited(
            refrescarSala().catchError((Object error) {
              _log.warning('No se pudo refrescar la sala tras el envío', error);
            }),
          );
        }
      }
      rethrow;
    }
    if (_disposed) return result;
    _guardarPedido(pedido(mesaId).sinLineas(ids));
    _actualizarComanda(mesaId, result.comanda);
    _avisarSiDuplicadas(mesaId, lineas, result);
    return result;
  }

  /// Un fallo tras poner la petición en la cola fiable puede ocurrir con la
  /// petición ya entregada al host (se perdió el `ack`). Solo un rechazo del
  /// host o la falta de host objetivo garantizan que no llegó.
  static bool _pudoLlegarAlHost(AppException error) =>
      error is! RemoteRequestException && error is! SinConexionException;

  /// Si el host ya conocía alguna línea enviada (retransmisión), avisa cuando
  /// lo que tiene difiere de lo enviado o cuando una línea editada sustituye
  /// a otra que el host ya había registrado.
  void _avisarSiDuplicadas(
    String mesaId,
    List<LineaPedido> enviadas,
    ComandaSubmitResult result,
  ) {
    final comanda = result.comanda;
    final distintas = <String>[];
    final reemplazadas = <String>[];
    if (result.lineasDuplicadas > 0) {
      for (final linea in enviadas) {
        final enHost = comanda.lineaPorId(linea.id);
        if (enHost != null &&
            (enHost.cantidad != linea.cantidad ||
                (enHost.nota ?? '') != (linea.nota ?? ''))) {
          distintas.add(linea.id);
        }
      }
      _log.warning(
        'Mesa $mesaId: el host ya tenía ${result.lineasDuplicadas} línea(s) '
        'del envío (${distintas.length} distinta(s))',
      );
    }
    for (final linea in enviadas) {
      final anterior = linea.reemplazaA;
      if (anterior != null && comanda.lineaPorId(anterior) != null) {
        reemplazadas.add(anterior);
      }
    }
    if (distintas.isEmpty && reemplazadas.isEmpty) return;
    const distintasTexto =
        'línea(s) con otra cantidad o nota, y conserva la suya';
    const reemplazadasTexto =
        'línea(s) editada(s) tras un corte ya habían '
        'llegado al host: pueden estar duplicadas';
    final partes = [
      if (distintas.isNotEmpty)
        'el host ya tenía ${distintas.length} $distintasTexto',
      if (reemplazadas.isNotEmpty) '${reemplazadas.length} $reemplazadasTexto',
    ];
    _emitirAviso(
      AvisoComandero(
        mesaId: mesaId,
        mensaje: 'Revisa la comanda: ${partes.join('; ')}.',
        lineaIds: List.unmodifiable([...distintas, ...reemplazadas]),
      ),
    );
  }

  void _emitirAviso(AvisoComandero aviso) {
    if (!_avisos.isClosed) _avisos.add(aviso);
  }

  /// Anula una línea ya enviada (petición fiable).
  Future<Comanda> anularLinea(
    String mesaId,
    String lineaId, {
    String? motivo,
  }) async {
    _checkNotDisposed();
    final ProtocolMessage ack;
    _anulacionesEnCurso++;
    try {
      ack = await _requestFiable(
        SalaMessageTypes.lineaAnular,
        LineaAnularPayload(
          mesaId: mesaId,
          lineaId: lineaId,
          motivo: motivo,
        ).toJson(),
        mesaId: mesaId,
      );
    } finally {
      _anulacionesEnCurso--;
    }
    final result = _parse(
      () => ComandaResult.fromJson(ack.payload),
      SalaMessageTypes.lineaAnular,
    );
    _actualizarComanda(mesaId, result.comanda);
    return result.comanda;
  }

  /// Marca o desmarca "cuenta solicitada". No es fiable: exige sesión
  /// ([SinConexionException] si no la hay) y falla si cae la conexión.
  Future<Comanda> pedirCuenta(String mesaId, {bool solicitada = true}) async {
    _checkNotDisposed();
    if (_client.state is! Connected) {
      throw const SinConexionException(
        'No hay conexión con el host para pedir la cuenta',
      );
    }
    final ack = await _request(
      SalaMessageTypes.mesaCuenta,
      MesaCuentaPayload(mesaId: mesaId, solicitada: solicitada).toJson(),
      mesaId: mesaId,
    );
    final result = _parse(
      () => ComandaResult.fromJson(ack.payload),
      SalaMessageTypes.mesaCuenta,
    );
    _actualizarComanda(mesaId, result.comanda);
    return result.comanda;
  }

  /// Vuelve a pedir el snapshot de sala (p. ej. "tirar para refrescar").
  Future<void> refrescarSala() async {
    _checkNotDisposed();
    if (_client.state is! Connected) throw const SinConexionException();
    final ack = await _request(SalaMessageTypes.salaSnapshotGet, const {});
    _sala = _parse(
      () => SalaSnapshot.fromJson(ack.payload),
      SalaMessageTypes.salaSnapshotGet,
    );
    _emitirConectado();
  }

  // ---------------------------------------------------------------------------
  // Cliente TCP: estados y mensajes
  // ---------------------------------------------------------------------------

  TcpComanderoClient _createClient(String? pairingCode) {
    _pairingCode = pairingCode;
    final client = _clientFactory(
      _config.identity,
      _withPairing(_baseClientOptions, pairingCode),
      _rediscover,
    );
    _clientStates = client.states.listen(_onClientState);
    _clientMessages = client.messages.listen(_onMessage);
    return client;
  }

  /// El código de emparejamiento viaja en las opciones del cliente, que son
  /// inmutables: si cambia hay que recrearlo. Las fiables en cola del cliente
  /// anterior fallan con [NetworkException] (sus líneas vuelven al carrito).
  void _ensureClient(String? pairingCode) {
    if ((pairingCode ?? '') == (_pairingCode ?? '')) return;
    final old = _client;
    final oldStates = _clientStates;
    final oldMessages = _clientMessages;
    _client = _createClient(pairingCode);
    unawaited(oldStates?.cancel());
    unawaited(oldMessages?.cancel());
    unawaited(
      old.dispose().catchError((Object error) {
        _log.warning('Error al liberar el cliente anterior', error);
      }),
    );
  }

  void _onClientState(ClientConnectionState state) {
    if (_disposed) return;
    final host = _host;
    switch (state) {
      case Connected(:final welcome):
        if (host == null) return;
        _host = host.copyWith(
          hostId: welcome.hostId,
          hostName: welcome.hostName,
        );
        unawaited(_onSesionAbierta(++_sesion));
      case Connecting():
        if (host == null) return;
        _perderSesion();
        _setState(Conectando(host: host));
      case Reconnecting(:final attempt, :final retryIn, :final lastError):
        if (host == null) return;
        _perderSesion();
        _setState(
          Reconectando(
            host: host,
            intento: attempt,
            reintentoEn: retryIn,
            error: lastError,
            pendientes: pendientes,
          ),
        );
      case Rejected(:final code, :final message):
        _perderSesion();
        _setState(
          Rechazado(
            codigo: code,
            mensaje: message,
            host: host,
            pendientes: pendientes,
          ),
        );
      case Disconnected():
        _perderSesion();
        if (host == null && _state is! Buscando) _setState(const SinHost());
    }
  }

  /// Tras cada `welcome`: snapshot de sala y, si hace falta, catálogo.
  Future<void> _onSesionAbierta(int sesion) async {
    await _cacheLoaded;
    while (_vigente(sesion)) {
      final ProtocolMessage ack;
      try {
        ack = await _client.request(SalaMessageTypes.salaSnapshotGet, const {});
      } on NetworkException {
        return; // la sesión cayó: el próximo welcome volverá a pedirlo
      } on AppException catch (error) {
        _log.warning('El host no sirvió el snapshot de sala: $error');
        await _esperarReintento();
        continue;
      }
      if (!_vigente(sesion)) return;
      final SalaSnapshot snapshot;
      try {
        snapshot = SalaSnapshot.fromJson(ack.payload);
      } on FormatException catch (error) {
        _log.warning('Snapshot de sala inválido: ${error.message}');
        await _esperarReintento();
        continue;
      }
      _sala = snapshot;
      _catalogoVersionHost = snapshot.catalogoVersion;
      _depurarCarritos(snapshot);
      if (_catalogo == null || snapshot.catalogoVersion != _catalogoVersion) {
        final cargado = await _cargarCatalogo(snapshot.catalogoVersion, sesion);
        if (!cargado) _programarReintentoCatalogo(sesion);
      }
      if (!_vigente(sesion)) return;
      _sesionLista = true;
      _emitirConectado();
      return;
    }
  }

  /// Quita de los carritos las líneas que el host ya tiene (su `ack` se
  /// perdió) y avisa de las líneas editadas tras un corte cuya original ya
  /// había llegado al host.
  void _depurarCarritos(SalaSnapshot snapshot) {
    for (final pedido in List.of(_pedidos.values)) {
      final comanda = snapshot.comandaDeMesa(pedido.mesaId);
      if (comanda == null) continue;
      final idsEnHost = {for (final linea in comanda.lineas) linea.id};
      final depurado = pedido.sinLineasYaEnHost(idsEnHost);
      if (depurado.lineas.length != pedido.lineas.length) {
        _log.info(
          'Mesa ${pedido.mesaId}: '
          '${pedido.lineas.length - depurado.lineas.length} línea(s) del '
          'carrito ya estaban en el host',
        );
        _guardarPedido(depurado);
      }
      final reemplazadas = [
        for (final linea in depurado.lineas)
          if (linea.reemplazaA case final anterior?)
            if (idsEnHost.contains(anterior)) anterior,
      ];
      if (reemplazadas.isNotEmpty) {
        _emitirAviso(
          AvisoComandero(
            mesaId: pedido.mesaId,
            mensaje:
                'Revisa el pedido: ${reemplazadas.length} línea(s) editada(s) '
                'tras un corte ya habían llegado al host; si las envías, '
                'pueden quedar duplicadas.',
            lineaIds: List.unmodifiable(reemplazadas),
          ),
        );
      }
    }
  }

  /// Pide el catálogo al host. Devuelve `false` si falló y conviene
  /// reintentar (sigue la sesión); `true` si se cargó o si el resultado ya no
  /// importa (sesión caída o carga más reciente en curso).
  Future<bool> _cargarCatalogo(String? version, int sesion) async {
    final carga = ++_cargaCatalogo;
    final ProtocolMessage ack;
    try {
      ack = await _client.request(SalaMessageTypes.catalogoGet, const {});
    } on AppException catch (error) {
      _log.warning('No se pudo cargar el catálogo: $error');
      return false;
    }
    if (!_vigente(sesion) || carga != _cargaCatalogo) return true;
    final CatalogSnapshot catalogo;
    try {
      catalogo = CatalogSnapshot.fromJson(ack.payload);
    } on FormatException catch (error) {
      _log.warning('Catálogo inválido del host: ${error.message}');
      return false;
    }
    _catalogo = catalogo;
    _catalogoVersion = version;
    _fallosCatalogo = 0;
    _reintentoCatalogo?.cancel();
    _reintentoCatalogo = null;
    _log.info(
      'Catálogo cargado (${catalogo.articulos.length} artículos, versión '
      '${version ?? 'sin versionar'})',
    );
    final cache = _cache;
    if (cache != null) {
      try {
        await cache.guardarCatalogo(
          CatalogoCacheado(
            version: version,
            catalogo: catalogo,
            guardadoEn: _now(),
          ),
        );
      } on Object catch (error, stackTrace) {
        _log.warning(
          'No se pudo guardar el catálogo en caché',
          error,
          stackTrace,
        );
      }
    }
    return true;
  }

  /// Programa otro intento de cargar el catálogo con espera creciente
  /// ([reintentoCatalogo] × 2^fallos, hasta [reintentoCatalogoMax]) mientras
  /// la sesión siga vigente. [_perderSesion] lo cancela.
  void _programarReintentoCatalogo(int sesion) {
    if (!_vigente(sesion) || _reintentoCatalogo != null) return;
    final factor = 1 << (_fallosCatalogo < 16 ? _fallosCatalogo : 16);
    final espera = reintentoCatalogo * factor;
    final limitada = espera > reintentoCatalogoMax
        ? reintentoCatalogoMax
        : espera;
    _fallosCatalogo++;
    _log.info('Reintento del catálogo en ${limitada.inMilliseconds} ms');
    _reintentoCatalogo = Timer(limitada, () {
      _reintentoCatalogo = null;
      if (!_vigente(sesion)) return;
      unawaited(_recargarCatalogo(sesion));
    });
  }

  /// Carga la versión del catálogo que anuncia el host y, si falla, programa
  /// otro intento. Reemite Conectado para reflejar el resultado.
  Future<void> _recargarCatalogo(int sesion) async {
    final cargado = await _cargarCatalogo(_catalogoVersionHost, sesion);
    if (!_vigente(sesion)) return;
    if (!cargado) _programarReintentoCatalogo(sesion);
    if (_sesionLista) _emitirConectado();
    // El enrutamiento del snapshot lleva aplanados los destinos del ERP del
    // catálogo con el que se generó: si es de otra versión que el recién
    // cargado, se pide de nuevo (si no, una regla aplanada antigua taparía el
    // `tpv_destino` nuevo del catálogo). Si el host ya anuncia otra versión,
    // lo hará la carga de esa versión.
    final sala = _sala;
    if (cargado &&
        sala != null &&
        _catalogoVersion == _catalogoVersionHost &&
        sala.catalogoVersion != _catalogoVersion) {
      await _refrescarSalaEnSesion(sesion, 'tras cambiar el catálogo');
    }
  }

  /// Número de intentos de [_refrescarSalaEnSesion] antes de rendirse (el
  /// siguiente `welcome` vuelve a pedir el snapshot de todos modos).
  static const int _intentosRefrescoSala = 3;

  /// Vuelve a pedir el snapshot de sala dentro de la sesión [sesion] (sin
  /// lanzar: los fallos se registran y se reintenta unas pocas veces). Lo
  /// usan `catalogo.changed` y `enrutamiento.changed` para que el
  /// enrutamiento efectivo del host esté al día, y `fijarComensales` si la
  /// comanda que veía ya se cerró.
  Future<void> _refrescarSalaEnSesion(int sesion, String motivo) async {
    for (var intento = 1; intento <= _intentosRefrescoSala; intento++) {
      if (!_vigente(sesion)) return;
      final ProtocolMessage ack;
      try {
        ack = await _client.request(SalaMessageTypes.salaSnapshotGet, const {});
      } on NetworkException {
        return; // la sesión cayó: el próximo welcome lo vuelve a pedir
      } on AppException catch (error) {
        _log.warning('No se pudo refrescar la sala ($motivo): $error');
        await Future<void>.delayed(reintentoCargaSala);
        continue;
      }
      if (!_vigente(sesion)) return;
      try {
        _sala = SalaSnapshot.fromJson(ack.payload);
      } on FormatException catch (error) {
        _log.warning('Snapshot de sala inválido ($motivo): ${error.message}');
        await Future<void>.delayed(reintentoCargaSala);
        continue;
      }
      _emitirConectado();
      return;
    }
  }

  void _onMessage(ProtocolMessage message) {
    if (_disposed) return;
    switch (message.type) {
      case SalaMessageTypes.salaChanged:
        final SalaChangedEvent event;
        try {
          event = SalaChangedEvent.fromJson(message.payload);
        } on FormatException catch (error) {
          _log.warning('Evento sala.changed inválido: ${error.message}');
          return;
        }
        _actualizarComanda(event.mesaId, event.comanda);
      case SalaMessageTypes.catalogoChanged:
        final CatalogoChangedEvent event;
        try {
          event = CatalogoChangedEvent.fromJson(message.payload);
        } on FormatException catch (error) {
          _log.warning('Evento catalogo.changed inválido: ${error.message}');
          return;
        }
        _catalogoVersionHost = event.version;
        if (event.version == _catalogoVersion && _catalogo != null) return;
        final sesion = _sesion;
        if (_sesionLista) _emitirConectado(); // marca el catálogo desfasado
        // Una carga nueva sustituye al reintento pendiente.
        _reintentoCatalogo?.cancel();
        _reintentoCatalogo = null;
        unawaited(_recargarCatalogo(sesion));
      case SalaMessageTypes.enrutamientoChanged:
        // Reglas del TPV nuevas: el enrutamiento efectivo viaja en el
        // snapshot. Se pide aunque la sesión aún no esté lista (el snapshot
        // de `_onSesionAbierta` pudo responderse antes del cambio).
        unawaited(
          _refrescarSalaEnSesion(_sesion, 'tras cambiar el enrutamiento'),
        );
      default:
        _log.fine("Mensaje '${message.type}' del host sin manejador");
    }
  }

  /// Redescubrimiento que usa el cliente TCP tras varios fallos seguidos: el
  /// host puede haber cambiado de IP. Solo tiene sentido con `hostId`.
  Future<HostEndpoint?> _rediscover() async {
    final hostId = _host?.hostId;
    if (hostId == null || _disposed) return null;
    final options = await _opcionesEscaneo();
    try {
      await for (final host in _scanner.discover(options)) {
        if (host.hostId == hostId) {
          return HostEndpoint(host: host.address.address, port: host.tcpPort);
        }
      }
    } on NetworkException catch (error) {
      _log.info('Redescubrimiento sin red: ${error.message}');
    }
    return null;
  }

  /// Opciones del escaneo UDP: las inyectadas (tests) o las del puerto de
  /// descubrimiento configurado; [timeout] sustituye al de la base. Solo es
  /// asíncrono si hay que calcular destinos (así [Buscando] sale sin esperar).
  FutureOr<DiscoveryScanOptions> _opcionesEscaneo({Duration? timeout}) {
    final base = _scanOptions ?? const DiscoveryScanOptions();
    DiscoveryScanOptions con(List<DiscoveryTarget>? targets) =>
        DiscoveryScanOptions(
          timeout: timeout ?? base.timeout,
          probes: base.probes,
          probeInterval: base.probeInterval,
          targets: targets,
        );
    if (base.targets != null || _config.discoveryPort == kDiscoveryPort) {
      return con(base.targets);
    }
    final puerto = _config.discoveryPort;
    return UdpDiscoveryScanner.defaultTargets(port: puerto).then(con);
  }

  // ---------------------------------------------------------------------------
  // Utilidades
  // ---------------------------------------------------------------------------

  Future<ProtocolMessage> _requestFiable(
    String type,
    Map<String, Object?> payload, {
    String? mesaId,
  }) async {
    // Sin host objetivo la cola fiable no saldría nunca: mejor avisar.
    if (_host == null) throw _sinHostObjetivo;
    final future = _request(type, payload, mesaId: mesaId, reliable: true);
    _emitirPendientes();
    try {
      return await future;
    } finally {
      _emitirPendientes();
    }
  }

  Future<ProtocolMessage> _request(
    String type,
    Map<String, Object?> payload, {
    String? mesaId,
    bool reliable = false,
  }) async {
    try {
      return await _client.request(type, payload, reliable: reliable);
    } on RemoteRequestException catch (error) {
      throw ComanderoSalaException.desde(error, mesaId: mesaId);
    }
  }

  /// Traduce un `ack` con payload inesperado a [ProtocolException].
  T _parse<T>(T Function() parse, String type) {
    try {
      return parse();
    } on FormatException catch (error) {
      throw ProtocolException(
        "Respuesta a '$type' con formato inesperado: ${error.message}",
        cause: error,
      );
    }
  }

  void _actualizarComanda(String mesaId, Comanda? comanda) {
    final sala = _sala;
    if (sala == null) return;
    _sala = sala.conComanda(mesaId, comanda, generadoEn: _now());
    if (_sesionLista) _emitirConectado();
  }

  PedidoEnEdicion _guardarPedido(PedidoEnEdicion nuevo) {
    if (nuevo.estaVacio) {
      _pedidos.remove(nuevo.mesaId);
    } else {
      _pedidos[nuevo.mesaId] = nuevo;
    }
    if (!_pedidosCambiados.isClosed) _pedidosCambiados.add(nuevo);
    return nuevo;
  }

  void _emitirConectado() {
    final host = _host;
    final sala = _sala;
    if (host == null || sala == null || !_sesionLista) return;
    _setState(
      Conectado(
        host: host,
        sala: sala,
        catalogo: _catalogo,
        pendientes: pendientes,
        catalogoDesactualizado: catalogoDesactualizado,
      ),
    );
  }

  /// Vuelve a emitir el estado actual con el contador de pendientes al día.
  void _emitirPendientes() {
    if (_disposed) return;
    switch (_state) {
      case Conectado():
        _emitirConectado();
      case Reconectando(
        :final host,
        :final intento,
        :final reintentoEn,
        :final error,
      ):
        _setState(
          Reconectando(
            host: host,
            intento: intento,
            reintentoEn: reintentoEn,
            error: error,
            pendientes: pendientes,
          ),
        );
      case Rechazado(:final codigo, :final mensaje, :final host):
        _setState(
          Rechazado(
            codigo: codigo,
            mensaje: mensaje,
            host: host,
            pendientes: pendientes,
          ),
        );
      case SinHost() || Buscando() || Conectando():
        break;
    }
  }

  /// La sesión TCP se perdió: lo que estuviera cargándose ya no vale.
  void _perderSesion() {
    _sesion++;
    _sesionLista = false;
    _reintentoSala?.cancel();
    _reintentoSala = null;
    _reintentoCatalogo?.cancel();
    _reintentoCatalogo = null;
    _fallosCatalogo = 0;
  }

  /// Además de perder la sesión, el host deja de ser el objetivo: el snapshot
  /// de sala ya no describe nada.
  void _abandonarSesion() {
    _perderSesion();
    _sala = null;
  }

  bool _vigente(int sesion) =>
      !_disposed && sesion == _sesion && _client.state is Connected;

  Future<void> _esperarReintento() {
    final completer = Completer<void>();
    _reintentoSala?.cancel();
    _reintentoSala = Timer(reintentoCargaSala, completer.complete);
    return completer.future;
  }

  Future<void> _loadCache() async {
    final cache = _cache;
    if (cache == null) return;
    try {
      final cacheado = await cache.leerCatalogo();
      if (cacheado == null || _disposed) return;
      _catalogo ??= cacheado.catalogo;
      _catalogoVersion ??= cacheado.version;
    } on Object catch (error, stackTrace) {
      _log.warning('No se pudo leer la caché del comandero', error, stackTrace);
    }
  }

  void _setState(ComanderoState state) {
    if (_disposed || state == _state) return;
    _state = state;
    _log.fine('Estado: ${state.runtimeType}');
    if (!_states.isClosed) _states.add(state);
  }

  void _checkNotDisposed() {
    if (_disposed) {
      throw StateError('ComanderoController ya está liberado (dispose)');
    }
  }

  static TcpComanderoClient _defaultClientFactory(
    ClientIdentity identity,
    ClientOptions options,
    Future<HostEndpoint?> Function() rediscover,
  ) => TcpComanderoClient(
    identity: identity,
    options: options,
    rediscover: rediscover,
  );

  static ClientOptions _withPairing(ClientOptions base, String? pairingCode) =>
      ClientOptions(
        connectTimeout: base.connectTimeout,
        handshakeTimeout: base.handshakeTimeout,
        requestTimeout: base.requestTimeout,
        reconnectBaseDelay: base.reconnectBaseDelay,
        reconnectMaxDelay: base.reconnectMaxDelay,
        reconnectJitter: base.reconnectJitter,
        rediscoverAfterFailures: base.rediscoverAfterFailures,
        maxFrameBytes: base.maxFrameBytes,
        pairingCode: (pairingCode ?? '').isEmpty ? null : pairingCode,
        closeTimeout: base.closeTimeout,
      );
}
