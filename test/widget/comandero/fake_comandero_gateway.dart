/// Doble del controlador del comandero para los tests de widgets: estado
/// controlable a mano, carrito real ([PedidoEnEdicion]) y un "host" en
/// memoria que acepta comandas al instante si está conectado o las deja en
/// cola hasta [FakeComanderoGateway.reconectar].
library;

import 'dart:async';
import 'dart:io';

import 'package:proyecto_comandero/core/errors/app_exception.dart';
import 'package:proyecto_comandero/core/facturascripts/catalog/catalog_models.dart';
import 'package:proyecto_comandero/core/network/discovery/udp_discovery_scanner.dart';
import 'package:proyecto_comandero/core/network/tcp/tcp_comandero_client.dart';
import 'package:proyecto_comandero/features/comandero/domain/comandero_config.dart';
import 'package:proyecto_comandero/features/comandero/domain/comandero_exceptions.dart';
import 'package:proyecto_comandero/features/comandero/domain/comandero_state.dart';
import 'package:proyecto_comandero/features/comandero/domain/pedido_en_edicion.dart';
import 'package:proyecto_comandero/features/comandero/domain/traspaso_comandero.dart';
import 'package:proyecto_comandero/features/comandero/presentation/comandero_gateway.dart';
import 'package:proyecto_comandero/features/sala/domain/comanda.dart';
import 'package:proyecto_comandero/features/sala/domain/linea_comanda.dart';
import 'package:proyecto_comandero/features/sala/domain/mesa.dart';
import 'package:proyecto_comandero/features/sala/protocol/sala_messages.dart';

import '../../features/comandero/fake_sala_host.dart'
    show kCatalogoPrueba, kMesasPrueba;

export '../../features/comandero/fake_sala_host.dart'
    show kCatalogoPrueba, kMesasPrueba;

const HostObjetivo kHostPrueba = HostObjetivo(
  endpoint: HostEndpoint(host: '192.168.1.10', port: 4040),
  hostId: 'host-1',
  hostName: 'Caja barra',
);

final DateTime kAhora = DateTime(2026, 10, 7, 13, 30);

DiscoveredHost hostDescubierto({
  String hostId = 'host-1',
  String hostName = 'Caja barra',
  String ip = '192.168.1.10',
  int tcpPort = 4040,
  bool requiresPairing = false,
}) => DiscoveredHost(
  hostId: hostId,
  hostName: hostName,
  address: InternetAddress(ip),
  tcpPort: tcpPort,
  requiresPairing: requiresPairing,
  roundTrip: const Duration(milliseconds: 5),
);

SalaSnapshot salaPrueba({
  List<Mesa> mesas = kMesasPrueba,
  List<Comanda> comandas = const [],
}) => SalaSnapshot(
  mesas: mesas,
  comandas: comandas,
  catalogoVersion: 'v1',
  generadoEn: kAhora,
);

LineaComanda lineaPrueba(
  String id,
  String referencia, {
  double cantidad = 1,
  EstadoLinea estado = EstadoLinea.enviada,
}) {
  final articulo = kCatalogoPrueba.porReferencia(referencia)!;
  return LineaComanda(
    id: id,
    referencia: referencia,
    descripcion: articulo.descripcion,
    cantidad: cantidad,
    pvpUnitarioCents: articulo.pvpCents,
    pvpUnitarioNeto: articulo.precioNeto,
    ivaBp: articulo.ivaBp,
    codimpuesto: articulo.codimpuesto,
    estado: estado,
    creadaEn: kAhora,
  );
}

/// Una llamada registrada (método y argumentos relevantes).
typedef Llamada = ({String metodo, List<Object?> args});

final class FakeComanderoGateway implements ComanderoGateway {
  FakeComanderoGateway({
    ComanderoConfig? config,
    ComanderoState state = const SinHost(),
    SalaSnapshot? sala,
    CatalogSnapshot? catalogo,
    this.hostsDeLaRed = const [],
  }) : _config =
           config ??
           const ComanderoConfig(deviceId: 'dev-1', deviceName: 'Móvil 1'),
       _state = state,
       _sala = sala ?? (state is Conectado ? state.sala : null),
       _catalogo =
           catalogo ?? (state is Conectado ? state.catalogo : kCatalogoPrueba);

  ComanderoConfig _config;
  ComanderoState _state;
  SalaSnapshot? _sala;
  CatalogSnapshot? _catalogo;

  /// Lo que devolverá [buscarHosts].
  List<DiscoveredHost> hostsDeLaRed;

  final List<Llamada> llamadas = [];
  final Map<String, PedidoEnEdicion> _pedidos = {};
  final List<_EnvioPendiente> _cola = [];
  final StreamController<ComanderoState> _states =
      StreamController<ComanderoState>.broadcast();
  final StreamController<PedidoEnEdicion> _pedidosCambiados =
      StreamController<PedidoEnEdicion>.broadcast();
  int _ids = 0;
  int _comandas = 0;
  bool disposed = false;

  bool get _conectado => _state is Conectado;

  // ---------------------------------------------------------------------------
  // Control desde el test
  // ---------------------------------------------------------------------------

  /// Fija el estado y lo emite.
  void emitir(ComanderoState state) {
    _state = state;
    if (state case Conectado(:final sala, :final catalogo)) {
      _sala = sala;
      _catalogo = catalogo ?? _catalogo;
    }
    _states.add(state);
  }

  /// Pasa a [Reconectando] conservando la sala.
  void perderConexion({int intento = 1}) => emitir(
    Reconectando(
      host: kHostPrueba,
      intento: intento,
      reintentoEn: const Duration(seconds: 2),
      pendientes: _cola.length,
    ),
  );

  /// Vuelve a [Conectado] y el "host" acepta lo que estaba en cola.
  void reconectar() {
    _state = _conectadoActual();
    final cola = List.of(_cola);
    _cola.clear();
    for (final envio in cola) {
      envio.completer.complete(_aceptar(envio.mesaId, envio.ids));
    }
    emitir(_conectadoActual());
  }

  List<String> metodos() => [for (final l in llamadas) l.metodo];

  // ---------------------------------------------------------------------------
  // ComanderoGateway
  // ---------------------------------------------------------------------------

  @override
  ComanderoConfig get config => _config;

  @override
  ComanderoState get state => _state;

  @override
  Stream<ComanderoState> get states => _states.stream;

  @override
  Stream<PedidoEnEdicion> get pedidosCambiados => _pedidosCambiados.stream;

  final StreamController<AvisoComandero> _avisos =
      StreamController<AvisoComandero>.broadcast();

  @override
  Stream<AvisoComandero> get avisos => _avisos.stream;

  /// Simula un aviso del controlador para el camarero.
  void emitirAviso(AvisoComandero aviso) => _avisos.add(aviso);

  @override
  SalaSnapshot? get sala => _sala;

  @override
  CatalogSnapshot? get catalogo => _catalogo;

  @override
  int get pendientes => _cola.length;

  @override
  PedidoEnEdicion pedido(String mesaId) =>
      _pedidos[mesaId] ?? PedidoEnEdicion.vacio(mesaId);

  @override
  Future<bool> iniciar({Duration? timeout}) async {
    llamadas.add((metodo: 'iniciar', args: const []));
    return false;
  }

  @override
  Future<List<DiscoveredHost>> buscarHosts({Duration? timeout}) async {
    llamadas.add((metodo: 'buscarHosts', args: const []));
    emitir(const Buscando());
    await Future<void>.delayed(Duration.zero);
    emitir(SinHost(hostsEncontrados: hostsDeLaRed));
    return hostsDeLaRed;
  }

  @override
  void conectar(HostObjetivo host, {String? pairingCode}) {
    llamadas.add((metodo: 'conectar', args: [host, pairingCode]));
    if (pairingCode != null) {
      _config = _config.copyWith(pairingCode: () => pairingCode);
    }
    emitir(Conectando(host: host));
  }

  @override
  void conectarDescubierto(DiscoveredHost host, {String? pairingCode}) {
    llamadas.add((metodo: 'conectarDescubierto', args: [host, pairingCode]));
    emitir(Conectando(host: HostObjetivo.desdeDescubierto(host)));
  }

  @override
  void conectarManual(String hostPuerto, {String? pairingCode}) {
    llamadas.add((metodo: 'conectarManual', args: [hostPuerto, pairingCode]));
    emitir(
      Conectando(host: HostObjetivo(endpoint: parseHostEndpoint(hostPuerto))),
    );
  }

  @override
  Future<void> desconectar() async {
    llamadas.add((metodo: 'desconectar', args: const []));
    emitir(const SinHost());
  }

  /// Datos de conexión recibidos por [actualizarConexion] (en orden).
  final List<({String? pairingCode, String? hostManual})>
  conexionesActualizadas = [];

  /// Reproduce las reglas de `ComanderoController.actualizarConexion`.
  @override
  void actualizarConexion({
    required String? pairingCode,
    required String? hostManual,
  }) {
    conexionesActualizadas.add((
      pairingCode: pairingCode,
      hostManual: hostManual,
    ));
    String? limpio(String? t) =>
        (t == null || t.trim().isEmpty) ? null : t.trim();
    final codigo = limpio(pairingCode);
    final manual = limpio(hostManual);
    final cambiaCodigo = codigo != limpio(_config.pairingCode);
    final cambiaManual = manual != limpio(_config.hostManual);
    if (!cambiaCodigo && !cambiaManual) return;
    _config = _config.copyWith(
      pairingCode: () => codigo,
      hostManual: () => manual,
    );
    final host = _state.host;
    if (cambiaManual && manual != null) {
      final endpoint = parseHostEndpoint(manual);
      if (host?.endpoint != endpoint) {
        conectar(HostObjetivo(endpoint: endpoint));
        return;
      }
    }
    if (cambiaCodigo &&
        host != null &&
        (_state is Rechazado ||
            _state is Reconectando ||
            _state is Conectando)) {
      conectar(host);
    }
  }

  @override
  PedidoEnEdicion anadir(
    String mesaId,
    ArticuloCatalogo articulo, {
    double cantidad = 1,
    String? nota,
  }) => _guardar(
    pedido(mesaId).conArticulo(
      articulo,
      nuevoId: () => 'l${++_ids}',
      cantidad: cantidad,
      nota: nota,
    ),
  );

  @override
  PedidoEnEdicion cambiarCantidad(
    String mesaId,
    String lineaId,
    double cantidad,
  ) => _guardar(pedido(mesaId).conCantidad(lineaId, cantidad));

  @override
  PedidoEnEdicion cambiarNota(String mesaId, String lineaId, String? nota) =>
      _guardar(pedido(mesaId).conNota(lineaId, nota));

  @override
  PedidoEnEdicion editarLinea(
    String mesaId,
    String lineaId, {
    required double cantidad,
    required String? nota,
  }) => _guardar(
    pedido(mesaId).conCantidadYNota(
      lineaId,
      cantidad: cantidad,
      nota: nota,
      nuevoId: () => 'l${++_ids}',
    ),
  );

  @override
  List<PedidoEnEdicion> exportarPedidos() => List.unmodifiable(_pedidos.values);

  @override
  int importarPedidos(Iterable<PedidoEnEdicion> pedidos) {
    var anadidas = 0;
    for (final importado in pedidos) {
      final actual = pedido(importado.mesaId);
      final fusionado = actual.fusionando(importado);
      if (identical(fusionado, actual)) continue;
      anadidas += fusionado.lineas.length - actual.lineas.length;
      _guardar(fusionado);
    }
    return anadidas;
  }

  @override
  PedidoEnEdicion quitar(String mesaId, String lineaId) =>
      _guardar(pedido(mesaId).sinLinea(lineaId));

  @override
  PedidoEnEdicion vaciar(String mesaId) {
    final actual = pedido(mesaId);
    return _guardar(
      actual.sinLineas({for (final l in actual.pendientesDeEnviar) l.id}),
    );
  }

  @override
  Future<ComandaSubmitResult> enviar(
    String mesaId, {
    String? camarero,
    int? comensales,
  }) async {
    llamadas.add((metodo: 'enviar', args: [mesaId]));
    final lineas = pedido(mesaId).pendientesDeEnviar;
    if (lineas.isEmpty) {
      throw const ValidationException('No hay líneas nuevas que enviar');
    }
    if (_state.host == null) throw const SinConexionException();
    final ids = {for (final l in lineas) l.id};
    _guardar(pedido(mesaId).marcandoEnvio(ids, enviando: true));
    if (_conectado) return _aceptar(mesaId, ids);
    final envio = _EnvioPendiente(mesaId, ids);
    _cola.add(envio);
    perderConexion();
    return envio.completer.future;
  }

  @override
  Future<Comanda> anularLinea(
    String mesaId,
    String lineaId, {
    String? motivo,
  }) async {
    llamadas.add((metodo: 'anularLinea', args: [mesaId, lineaId, motivo]));
    final comanda = _sala?.comandaDeMesa(mesaId);
    final linea = comanda?.lineaPorId(lineaId);
    if (comanda == null || linea == null) {
      throw const RemoteRequestException('Línea desconocida', code: 'x');
    }
    final actualizada = comanda.conLineaActualizada(
      linea.anular(cuando: kAhora, motivo: motivo),
    );
    _ponerComanda(actualizada);
    return actualizada;
  }

  @override
  Future<Comanda> pedirCuenta(String mesaId, {bool solicitada = true}) async {
    llamadas.add((metodo: 'pedirCuenta', args: [mesaId, solicitada]));
    if (!_conectado) throw const SinConexionException();
    final comanda = _sala!.comandaDeMesa(mesaId)!;
    final actualizada = comanda.copyWith(cuentaSolicitada: solicitada);
    _ponerComanda(actualizada);
    return actualizada;
  }

  @override
  Future<void> refrescarSala() async {
    llamadas.add((metodo: 'refrescarSala', args: const []));
    if (!_conectado) throw const SinConexionException();
  }

  /// Anulaciones que [cerrarParaTraspaso] dará por perdidas.
  int anulacionesEnCola = 0;

  /// Como el controlador: los envíos en cola fallan, sus líneas vuelven al
  /// carrito como posiblemente transmitidas, se exportan y se libera.
  @override
  Future<TraspasoComandero> cerrarParaTraspaso() async {
    llamadas.add((metodo: 'cerrarParaTraspaso', args: const []));
    if (disposed) return const TraspasoComandero();
    final cola = List.of(_cola);
    _cola.clear();
    var devueltas = 0;
    for (final envio in cola) {
      devueltas += envio.ids.length;
      _guardar(pedido(envio.mesaId).devolviendoTrasFalloDeRed(envio.ids));
      envio.completer.completeError(const NetworkException('Conexión cerrada'));
    }
    final traspaso = TraspasoComandero(
      pedidos: exportarPedidos(),
      lineasDevueltas: devueltas,
      peticionesPerdidas: anulacionesEnCola,
    );
    await dispose();
    return traspaso;
  }

  @override
  Future<void> dispose() async {
    if (disposed) return;
    disposed = true;
    await _states.close();
    await _pedidosCambiados.close();
    await _avisos.close();
  }

  // ---------------------------------------------------------------------------

  ComandaSubmitResult _aceptar(String mesaId, Set<String> ids) {
    final enviadas = [
      for (final linea in pedido(mesaId).lineas)
        if (ids.contains(linea.id))
          linea.aLineaComanda(
            creadaEn: kAhora,
            destino: DestinoPreparacion.cocina,
          ),
    ];
    final actual =
        _sala?.comandaDeMesa(mesaId) ??
        Comanda(id: 'c${++_comandas}', mesaId: mesaId, abiertaEn: kAhora);
    final resultado = actual.conLineas(enviadas);
    _guardar(pedido(mesaId).sinLineas(ids));
    _ponerComanda(resultado.comanda);
    return ComandaSubmitResult(
      comanda: resultado.comanda,
      lineasNuevas: resultado.nuevas.length,
      lineasDuplicadas: enviadas.length - resultado.nuevas.length,
    );
  }

  void _ponerComanda(Comanda comanda) {
    final sala = _sala ?? salaPrueba();
    _sala = SalaSnapshot(
      mesas: sala.mesas,
      comandas: [
        for (final c in sala.comandas)
          if (c.mesaId != comanda.mesaId) c,
        comanda,
      ],
      catalogoVersion: sala.catalogoVersion,
      generadoEn: kAhora,
    );
    if (_conectado) emitir(_conectadoActual());
  }

  Conectado _conectadoActual() => Conectado(
    host: kHostPrueba,
    sala: _sala ?? salaPrueba(),
    catalogo: _catalogo,
    pendientes: _cola.length,
  );

  PedidoEnEdicion _guardar(PedidoEnEdicion nuevo) {
    if (nuevo.estaVacio) {
      _pedidos.remove(nuevo.mesaId);
    } else {
      _pedidos[nuevo.mesaId] = nuevo;
    }
    _pedidosCambiados.add(nuevo);
    return nuevo;
  }
}

final class _EnvioPendiente {
  _EnvioPendiente(this.mesaId, this.ids);

  final String mesaId;
  final Set<String> ids;
  final Completer<ComandaSubmitResult> completer =
      Completer<ComandaSubmitResult>();
}
