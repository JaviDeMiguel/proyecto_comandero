/// Doble del controlador del comandero para los tests de widgets: estado
/// controlable a mano, carrito real ([PedidoEnEdicion]) y un "host" en
/// memoria que acepta comandas y marchas al instante si está conectado o las
/// deja en cola hasta [FakeComanderoGateway.reconectar].
library;

import 'dart:async';
import 'dart:io';

import 'package:proyecto_comandero/core/errors/app_exception.dart';
import 'package:proyecto_comandero/core/facturascripts/catalog/catalog_models.dart';
import 'package:proyecto_comandero/core/network/discovery/udp_discovery_scanner.dart';
import 'package:proyecto_comandero/core/network/tcp/tcp_comandero_client.dart';
import 'package:proyecto_comandero/features/comandero/application/comandero_controller.dart'
    show ComanderoPases;
import 'package:proyecto_comandero/features/comandero/domain/comandero_config.dart';
import 'package:proyecto_comandero/features/comandero/domain/comandero_exceptions.dart';
import 'package:proyecto_comandero/features/comandero/domain/comandero_state.dart';
import 'package:proyecto_comandero/features/comandero/domain/pedido_en_edicion.dart';
import 'package:proyecto_comandero/features/comandero/domain/traspaso_comandero.dart';
import 'package:proyecto_comandero/features/comandero/presentation/comandero_gateway.dart';
import 'package:proyecto_comandero/features/sala/domain/comanda.dart';
import 'package:proyecto_comandero/features/sala/domain/linea_comanda.dart';
import 'package:proyecto_comandero/features/sala/domain/marcha_pase.dart';
import 'package:proyecto_comandero/features/sala/domain/mesa.dart';
import 'package:proyecto_comandero/features/sala/domain/pases.dart';
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

/// Snapshot de sala de pruebas; con [pases] el "host" publica esa
/// configuración (sin ella se comporta como un host antiguo).
SalaSnapshot salaPrueba({
  List<Mesa> mesas = kMesasPrueba,
  List<Comanda> comandas = const [],
  PasesConfig? pases,
}) => SalaSnapshot(
  mesas: mesas,
  comandas: comandas,
  catalogoVersion: 'v1',
  generadoEn: kAhora,
  pases: pases,
);

LineaComanda lineaPrueba(
  String id,
  String referencia, {
  double cantidad = 1,
  EstadoLinea estado = EstadoLinea.enviada,
  int? pase,
  int? envio,
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
    pase: pase,
    envio: envio,
  );
}

/// Marcha de un pase para montar comandas de prueba.
MarchaPase marchaPrueba(
  String id,
  int pase, {
  bool automatica = false,
  bool repetida = false,
  String? camarero,
}) => MarchaPase(
  id: id,
  pase: pase,
  cuando: kAhora,
  camarero: camarero,
  automatica: automatica,
  repetida: repetida,
);

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

  /// Destino que el "host" asigna a cada artículo al aceptar las líneas
  /// (por defecto todo a cocina).
  DestinoPreparacion Function(ArticuloCatalogo articulo) destinoDe = (_) =>
      DestinoPreparacion.cocina;

  /// Si no es `null`, [marcharPase] falla con este error (p. ej. un
  /// `RemoteRequestException` con `unknown_type` de un host antiguo).
  Exception? errorMarchar;

  final List<Llamada> llamadas = [];
  final Map<String, PedidoEnEdicion> _pedidos = {};
  final List<_EnvioPendiente> _cola = [];
  final List<_MarchaPendiente> _marchasEnCola = [];
  final StreamController<ComanderoState> _states =
      StreamController<ComanderoState>.broadcast();
  final StreamController<PedidoEnEdicion> _pedidosCambiados =
      StreamController<PedidoEnEdicion>.broadcast();
  int _ids = 0;
  int _comandas = 0;
  int _envios = 0;
  int _marchas = 0;
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
      pendientes: pendientes,
    ),
  );

  /// Vuelve a [Conectado] y el "host" atiende los envíos y las marchas que
  /// estaban en cola, en orden.
  void reconectar() {
    _state = _conectadoActual();
    final cola = List.of(_cola);
    _cola.clear();
    for (final envio in cola) {
      envio.completer.complete(_aceptar(envio.mesaId, envio.ids));
    }
    final marchas = List.of(_marchasEnCola);
    _marchasEnCola.clear();
    for (final marcha in marchas) {
      try {
        marcha.completer.complete(_marchar(marcha.mesaId, marcha.pase));
      } on ComanderoSalaException catch (error, stackTrace) {
        marcha.completer.completeError(error, stackTrace);
      }
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
  PasesConfig? get pases => _sala?.pases;

  @override
  int get pendientes => _cola.length + _marchasEnCola.length;

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
    int? pase,
  }) => _guardar(
    pedido(mesaId).conArticulo(
      articulo,
      nuevoId: () => 'l${++_ids}',
      cantidad: cantidad,
      nota: nota,
      pase: pase,
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
    int? Function()? pase,
  }) => _guardar(
    pedido(mesaId).conCantidadYNota(
      lineaId,
      cantidad: cantidad,
      nota: nota,
      pase: pase,
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

  /// Como el controlador: sin host falla, sin comanda a la vista no manda
  /// nada, conectado marcha al instante y sin conexión queda en cola hasta
  /// [reconectar] (o se pierde en [cerrarParaTraspaso]). Con [errorMarchar]
  /// falla con ese error.
  @override
  Future<Comanda> marcharPase(String mesaId, int pase) async {
    llamadas.add((metodo: 'marcharPase', args: [mesaId, pase]));
    if (errorMarchar case final error?) throw error;
    if (_state.host == null) throw const SinConexionException();
    if (_sala?.comandaDeMesa(mesaId) == null) {
      throw _sinComanda(
        mesaId,
        'La mesa no tiene comanda abierta: no hay nada que marchar',
      );
    }
    if (_conectado) return _marchar(mesaId, pase);
    final marcha = _MarchaPendiente(mesaId, pase);
    _marchasEnCola.add(marcha);
    perderConexion();
    return marcha.completer.future;
  }

  /// Como el controlador: valida el rango y exige comanda abierta; el
  /// "host" aplica los comensales al instante (también sin conexión).
  @override
  Future<Comanda> fijarComensales(String mesaId, int comensales) async {
    llamadas.add((metodo: 'fijarComensales', args: [mesaId, comensales]));
    if (comensales < ComanderoPases.minComensales ||
        comensales > ComanderoPases.maxComensales) {
      throw ValidationException(
        'Los comensales deben estar entre ${ComanderoPases.minComensales} y '
        '${ComanderoPases.maxComensales} (recibido $comensales)',
      );
    }
    if (_state.host == null) throw const SinConexionException();
    final comanda = _sala?.comandaDeMesa(mesaId);
    if (comanda == null) {
      throw _sinComanda(
        mesaId,
        'La mesa no tiene comanda abierta: los comensales se enviarán con el '
        'primer pedido',
      );
    }
    final actualizada = comanda.copyWith(comensales: comensales);
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
  /// carrito como posiblemente transmitidas, se exportan y se libera. Las
  /// marchas en cola fallan y se cuentan como perdidas con las anulaciones.
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
    final marchas = List.of(_marchasEnCola);
    _marchasEnCola.clear();
    for (final marcha in marchas) {
      marcha.completer.completeError(
        const NetworkException('Conexión cerrada'),
      );
    }
    final traspaso = TraspasoComandero(
      pedidos: exportarPedidos(),
      lineasDevueltas: devueltas,
      peticionesPerdidas: anulacionesEnCola + marchas.length,
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

  /// Lo que haría el host al aceptar las líneas: destino según [destinoDe],
  /// nº de envío correlativo, pase conservado solo con los pases activos (sin
  /// marchas automáticas) y comanda nueva si la mesa estaba libre.
  ComandaSubmitResult _aceptar(String mesaId, Set<String> ids) {
    final envio = _envios + 1;
    final conservaPase = pases?.activos ?? false;
    final enviadas = [
      for (final linea in pedido(mesaId).lineas)
        if (ids.contains(linea.id))
          linea
              .aLineaComanda(
                creadaEn: kAhora,
                destino: destinoDe(linea.articulo),
              )
              .copyWith(pase: conservaPase ? null : () => null, envio: envio),
    ];
    final actual =
        _sala?.comandaDeMesa(mesaId) ??
        Comanda(id: 'c${++_comandas}', mesaId: mesaId, abiertaEn: kAhora);
    final resultado = actual.conLineas(enviadas);
    if (resultado.nuevas.isNotEmpty) _envios = envio;
    _guardar(pedido(mesaId).sinLineas(ids));
    _ponerComanda(resultado.comanda);
    return ComandaSubmitResult(
      comanda: resultado.comanda,
      lineasNuevas: resultado.nuevas.length,
      lineasDuplicadas: enviadas.length - resultado.nuevas.length,
    );
  }

  /// Lo que haría el host al marchar: exige comanda abierta y líneas
  /// activas del pase, y registra la marcha (repetida si ya estaba marchado).
  Comanda _marchar(String mesaId, int pase) {
    final comanda = _sala?.comandaDeMesa(mesaId);
    if (comanda == null) {
      throw _sinComanda(mesaId, 'La mesa no tiene comanda abierta');
    }
    if (!comanda.lineasActivas.any((linea) => linea.pase == pase)) {
      final config = pases;
      if (config == null || !config.activos || !config.existe(pase)) {
        throw ComanderoSalaException(
          'El pase $pase no existe',
          code: SalaErrorCodes.paseNoValido,
          mesaId: mesaId,
        );
      }
      throw ComanderoSalaException(
        'La mesa no tiene líneas de ${config.nombreDe(pase)}',
        code: SalaErrorCodes.paseSinLineas,
        mesaId: mesaId,
      );
    }
    final actualizada = comanda.conMarcha(
      MarchaPase(
        id: 'marcha-${++_marchas}',
        pase: pase,
        cuando: kAhora,
        repetida: comanda.pasesMarchados.contains(pase),
      ),
    );
    _ponerComanda(actualizada);
    return actualizada;
  }

  static ComanderoSalaException _sinComanda(String mesaId, String mensaje) =>
      ComanderoSalaException(
        mensaje,
        code: SalaErrorCodes.mesaSinComanda,
        mesaId: mesaId,
      );

  /// Sustituye la comanda de su mesa conservando el resto del snapshot
  /// (enrutamiento y pases incluidos).
  void _ponerComanda(Comanda comanda) {
    final sala = _sala ?? salaPrueba();
    _sala = sala.conComanda(comanda.mesaId, comanda, generadoEn: kAhora);
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

final class _MarchaPendiente {
  _MarchaPendiente(this.mesaId, this.pase);

  final String mesaId;
  final int pase;
  final Completer<Comanda> completer = Completer<Comanda>();
}
