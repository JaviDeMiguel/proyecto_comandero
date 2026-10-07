import '../../../core/facturascripts/catalog/catalog_models.dart';
import '../../../core/network/discovery/udp_discovery_scanner.dart';
import '../../sala/domain/comanda.dart';
import '../../sala/protocol/sala_messages.dart';
import '../application/comandero_controller.dart';
import '../domain/comandero_config.dart';
import '../domain/comandero_state.dart';
import '../domain/pedido_en_edicion.dart';
import '../domain/traspaso_comandero.dart';

/// Lo que las pantallas del comandero necesitan del [ComanderoController].
///
/// El controlador es una clase `final` de la capa de aplicación; esta
/// interfaz permite sustituirlo por un doble en los tests de widgets. La
/// semántica de cada miembro es la del método homónimo del controlador.
abstract interface class ComanderoGateway {
  ComanderoConfig get config;
  ComanderoState get state;

  /// Cambios de estado (broadcast).
  Stream<ComanderoState> get states;

  /// Carritos modificados (broadcast).
  Stream<PedidoEnEdicion> get pedidosCambiados;

  /// Avisos puntuales para el camarero (líneas que el host ya tenía con otros
  /// datos, líneas editadas tras un envío dudoso...).
  Stream<AvisoComandero> get avisos;

  /// Último snapshot de sala recibido (se conserva al perder la conexión).
  SalaSnapshot? get sala;

  /// Catálogo vigente (del host o de la caché).
  CatalogSnapshot? get catalogo;

  /// Peticiones fiables en cola o sin respuesta del host.
  int get pendientes;

  PedidoEnEdicion pedido(String mesaId);

  Future<bool> iniciar({Duration? timeout});
  Future<List<DiscoveredHost>> buscarHosts({Duration? timeout});
  void conectar(HostObjetivo host, {String? pairingCode});
  void conectarDescubierto(DiscoveredHost host, {String? pairingCode});
  void conectarManual(String hostPuerto, {String? pairingCode});
  Future<void> desconectar();

  /// Aplica el código de emparejamiento y el host manual guardados en los
  /// ajustes sin recrear el controlador (reconecta si hace falta).
  void actualizarConexion({
    required String? pairingCode,
    required String? hostManual,
  });

  PedidoEnEdicion anadir(
    String mesaId,
    ArticuloCatalogo articulo, {
    double cantidad = 1,
    String? nota,
  });
  PedidoEnEdicion cambiarCantidad(
    String mesaId,
    String lineaId,
    double cantidad,
  );
  PedidoEnEdicion cambiarNota(String mesaId, String lineaId, String? nota);

  /// Cambia cantidad y nota de una línea en una sola edición.
  PedidoEnEdicion editarLinea(
    String mesaId,
    String lineaId, {
    required double cantidad,
    required String? nota,
  });
  PedidoEnEdicion quitar(String mesaId, String lineaId);
  PedidoEnEdicion vaciar(String mesaId);

  /// Carritos no vacíos de todas las mesas.
  List<PedidoEnEdicion> exportarPedidos();

  /// Añade a los carritos las líneas que no estén ya; devuelve cuántas.
  int importarPedidos(Iterable<PedidoEnEdicion> pedidos);

  Future<ComandaSubmitResult> enviar(
    String mesaId, {
    String? camarero,
    int? comensales,
  });
  Future<Comanda> anularLinea(String mesaId, String lineaId, {String? motivo});
  Future<Comanda> pedirCuenta(String mesaId, {bool solicitada = true});
  Future<void> refrescarSala();

  Future<void> dispose();

  /// Cierra el controlador entregando sus carritos (los envíos en cola
  /// vuelven al carrito) para que otro los retome; libera los recursos.
  Future<TraspasoComandero> cerrarParaTraspaso();
}

/// [ComanderoGateway] que delega en un [ComanderoController] real.
final class ControllerComanderoGateway implements ComanderoGateway {
  ControllerComanderoGateway(this.controller);

  final ComanderoController controller;

  @override
  ComanderoConfig get config => controller.config;

  @override
  ComanderoState get state => controller.state;

  @override
  Stream<ComanderoState> get states => controller.states;

  @override
  Stream<PedidoEnEdicion> get pedidosCambiados => controller.pedidosCambiados;

  @override
  Stream<AvisoComandero> get avisos => controller.avisos;

  @override
  SalaSnapshot? get sala => controller.sala;

  @override
  CatalogSnapshot? get catalogo => controller.catalogo;

  @override
  int get pendientes => controller.pendientes;

  @override
  PedidoEnEdicion pedido(String mesaId) => controller.pedido(mesaId);

  @override
  Future<bool> iniciar({Duration? timeout}) =>
      controller.iniciar(timeout: timeout);

  @override
  Future<List<DiscoveredHost>> buscarHosts({Duration? timeout}) =>
      controller.buscarHosts(timeout: timeout);

  @override
  void conectar(HostObjetivo host, {String? pairingCode}) =>
      controller.conectar(host, pairingCode: pairingCode);

  @override
  void conectarDescubierto(DiscoveredHost host, {String? pairingCode}) =>
      controller.conectarDescubierto(host, pairingCode: pairingCode);

  @override
  void conectarManual(String hostPuerto, {String? pairingCode}) =>
      controller.conectarManual(hostPuerto, pairingCode: pairingCode);

  @override
  Future<void> desconectar() => controller.desconectar();

  @override
  void actualizarConexion({
    required String? pairingCode,
    required String? hostManual,
  }) => controller.actualizarConexion(
    pairingCode: pairingCode,
    hostManual: hostManual,
  );

  @override
  PedidoEnEdicion anadir(
    String mesaId,
    ArticuloCatalogo articulo, {
    double cantidad = 1,
    String? nota,
  }) => controller.anadir(mesaId, articulo, cantidad: cantidad, nota: nota);

  @override
  PedidoEnEdicion cambiarCantidad(
    String mesaId,
    String lineaId,
    double cantidad,
  ) => controller.cambiarCantidad(mesaId, lineaId, cantidad);

  @override
  PedidoEnEdicion cambiarNota(String mesaId, String lineaId, String? nota) =>
      controller.cambiarNota(mesaId, lineaId, nota);

  @override
  PedidoEnEdicion editarLinea(
    String mesaId,
    String lineaId, {
    required double cantidad,
    required String? nota,
  }) => controller.editarLinea(mesaId, lineaId, cantidad: cantidad, nota: nota);

  @override
  PedidoEnEdicion quitar(String mesaId, String lineaId) =>
      controller.quitar(mesaId, lineaId);

  @override
  PedidoEnEdicion vaciar(String mesaId) => controller.vaciar(mesaId);

  @override
  List<PedidoEnEdicion> exportarPedidos() => controller.exportarPedidos();

  @override
  int importarPedidos(Iterable<PedidoEnEdicion> pedidos) =>
      controller.importarPedidos(pedidos);

  @override
  Future<ComandaSubmitResult> enviar(
    String mesaId, {
    String? camarero,
    int? comensales,
  }) => controller.enviar(mesaId, camarero: camarero, comensales: comensales);

  @override
  Future<Comanda> anularLinea(
    String mesaId,
    String lineaId, {
    String? motivo,
  }) => controller.anularLinea(mesaId, lineaId, motivo: motivo);

  @override
  Future<Comanda> pedirCuenta(String mesaId, {bool solicitada = true}) =>
      controller.pedirCuenta(mesaId, solicitada: solicitada);

  @override
  Future<void> refrescarSala() => controller.refrescarSala();

  @override
  Future<void> dispose() => controller.dispose();

  @override
  Future<TraspasoComandero> cerrarParaTraspaso() =>
      controller.cerrarParaTraspaso();
}
