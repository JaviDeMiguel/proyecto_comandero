import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/errors/app_exception.dart';
import '../../../core/facturascripts/catalog/catalog_models.dart';
import '../../../core/money/money.dart';
import '../../sala/domain/comanda.dart';
import '../../sala/domain/linea_comanda.dart';
import '../../sala/domain/pases.dart';
import '../../sala/presentation/comensales_dialog.dart';
import '../../sala/protocol/sala_messages.dart';
import '../domain/comandero_state.dart';
import '../domain/pedido_en_edicion.dart';
import 'comandero_carga.dart';
import 'comandero_gateway.dart';
import 'comandero_widgets.dart';
import 'pedido_carta.dart';
import 'pedido_dialogos.dart';
import 'pedido_panel.dart';
import 'providers.dart';

export 'pedido_carta.dart' show filtrarArticulos, normalizarBusqueda;
export 'pedido_dialogos.dart' show DetalleLinea, DialogoDetalleLinea;

/// Aviso del envío por puesto (§7.10): «Enviadas 5 líneas: 3 a cocina, 2 a
/// barra (nº 12)», o «Enviada 1 línea a barra (nº 12)» con un solo puesto.
///
/// El destino y el nº de envío los fija el host: se leen de las líneas de
/// [enviadas] (ids) en la comanda devuelta y, si el host ya conocía alguna
/// de un envío anterior, solo cuentan las del último. Si no cuadran con
/// `lineasNuevas`, solo da el número. Sin líneas nuevas (retransmisión que
/// el host ya había aceptado), dice que ya estaban enviadas.
String mensajeDeEnvio(ComandaSubmitResult result, Set<String> enviadas) {
  final n = result.lineasNuevas;
  if (n == 0) {
    final d = result.lineasDuplicadas;
    if (d == 0) return 'No había líneas nuevas que enviar';
    return d == 1
        ? 'Ya estaba enviada 1 línea'
        : 'Ya estaban enviadas $d líneas';
  }
  final total = n == 1 ? 'Enviada 1 línea' : 'Enviadas $n líneas';
  final propias = [
    for (final linea in result.comanda.lineas)
      if (enviadas.contains(linea.id)) linea,
  ];
  final envios = [for (final linea in propias) ?linea.envio];
  final envio = envios.isEmpty ? null : envios.reduce(math.max);
  final nuevas = [
    for (final linea in propias)
      if (envio == null || linea.envio == envio) linea,
  ];
  if (nuevas.length != n) return total;
  final porPuesto = <DestinoPreparacion, int>{
    for (final destino in DestinoPreparacion.values)
      if (nuevas.where((l) => l.destino == destino).length case final c
          when c > 0)
        destino: c,
  };
  String puesto(DestinoPreparacion destino) => switch (destino) {
    DestinoPreparacion.cocina => 'cocina',
    DestinoPreparacion.barra => 'barra',
  };
  final partes = [
    for (final MapEntry(key: destino, value: lineas) in porPuesto.entries)
      '$lineas a ${puesto(destino)}',
  ];
  final detalle = partes.length == 1
      ? ' a ${puesto(porPuesto.keys.single)}'
      : ': ${partes.join(', ')}';
  return '$total$detalle${envio == null ? '' : ' (nº $envio)'}';
}

/// Toma de pedido de una mesa: comanda enviada y carrito arriba (o a la
/// izquierda en pantallas anchas), carta por familias abajo (o a la derecha)
/// y barra inferior con el total del carrito y el botón ENVIAR.
///
/// Si el host publica los pases activos, la carta lleva el selector del pase
/// de las líneas nuevas y lo enviado se agrupa por pases con su botón
/// «MARCHAR» ([PanelPedido]). Con un host antiguo no hay nada de eso. La
/// barra superior fija los comensales (clave `pedido.comensales`).
class PedidoPage extends ConsumerStatefulWidget {
  const PedidoPage({super.key, required this.mesaId});

  final String mesaId;

  @override
  ConsumerState<PedidoPage> createState() => _PedidoPageState();
}

class _PedidoPageState extends ConsumerState<PedidoPage> {
  /// Anchura a partir de la cual el pedido y la carta van lado a lado.
  static const double _anchoDosColumnas = 720;

  bool _pidiendoCuenta = false;
  bool _fijandoComensales = false;

  /// Pase de las líneas que se añaden desde la carta (`null` = directo).
  /// Solo se aplica con los pases activos.
  int? _paseActivo;

  /// Comensales elegidos con la mesa libre: viajan con el primer envío y se
  /// olvidan en cuanto la mesa tiene comanda.
  int? _comensalesPendientes;

  /// Foco del buscador de la carta: con él y el teclado abierto, en una
  /// columna, la carta ocupa todo el alto.
  final FocusNode _focoBusqueda = FocusNode(debugLabel: 'pedido.buscar');

  String get _mesaId => widget.mesaId;

  @override
  void initState() {
    super.initState();
    _focoBusqueda.addListener(_alCambiarFoco);
  }

  @override
  void dispose() {
    _focoBusqueda
      ..removeListener(_alCambiarFoco)
      ..dispose();
    super.dispose();
  }

  void _alCambiarFoco() {
    if (mounted) setState(() {});
  }

  /// Los comensales pendientes solo valen para la mesa libre: en cuanto la
  /// mesa tiene comanda (la del primer envío o la de otro camarero) se
  /// olvidan, para no aplicarlos a otra comanda.
  void _alCambiarEstado(
    AsyncValue<ComanderoState>? _,
    AsyncValue<ComanderoState> siguiente,
  ) {
    final state = siguiente.value;
    if (_comensalesPendientes != null &&
        state is Conectado &&
        state.sala.comandaDeMesa(_mesaId) != null) {
      setState(() => _comensalesPendientes = null);
    }
  }

  /// Comensales que se muestran: los de la comanda o, con la mesa libre, los
  /// pendientes del primer envío.
  int? _comensalesDe(Comanda? comanda) =>
      comanda == null ? _comensalesPendientes : comanda.comensales;

  @override
  Widget build(BuildContext context) {
    ref.listen(comanderoStateProvider, _alCambiarEstado);
    final gatewayAsync = ref.watch(comanderoControllerProvider);
    final gateway = gatewayAsync.value;
    if (gateway == null) return CargandoComandero(error: gatewayAsync.error);
    final state = ref.watch(comanderoStateProvider).value ?? gateway.state;
    final sala = state is Conectado ? state.sala : gateway.sala;
    final catalogo = state is Conectado
        ? (state.catalogo ?? gateway.catalogo)
        : gateway.catalogo;
    final pedido =
        ref.watch(pedidoProvider(_mesaId)).value ?? gateway.pedido(_mesaId);
    final comanda = sala?.comandaDeMesa(_mesaId);
    final nombreMesa =
        sala?.mesas.where((m) => m.id == _mesaId).firstOrNull?.nombre ??
        _mesaId;
    final pendientes = pendientesDe(state, fallback: gateway.pendientes);
    final marchando = ref.watch(marchasEnCursoProvider(_mesaId));
    final pases = sala?.pases;
    final pasesActivos = pases?.activos ?? false;
    final comensales = _comensalesDe(comanda);
    // Se mira fuera del Scaffold: dentro del cuerpo, el Scaffold ya descuenta
    // el teclado y quita su hueco de MediaQuery.
    final buscandoConTeclado =
        _focoBusqueda.hasFocus && MediaQuery.viewInsetsOf(context).bottom > 0;

    final panelPedido = PanelPedido(
      comanda: comanda,
      pedido: pedido,
      pases: pases,
      pasesMarchando: marchando,
      onEditarLinea: (linea) => _editarLineaCarrito(gateway, linea, pases),
      onQuitarLinea: (linea) =>
          _accion(() => gateway.quitar(_mesaId, linea.id)),
      onAnularLinea: (linea) => _anular(gateway, linea),
      onMarcharPase: (pase, {required repetir}) =>
          _marchar(gateway, pase, pases, repetir: repetir),
    );
    final panelCarta = PanelCarta(
      catalogo: catalogo,
      focoBusqueda: _focoBusqueda,
      // También buscando con el teclado abierto: es una sola fila y así se
      // ve siempre el pase de lo que se añade.
      pases: pases,
      paseActivo: _paseActivo,
      onCambioPase: (pase) => setState(() => _paseActivo = pase),
      onAnadir: (articulo) => _accion(
        () => gateway.anadir(
          _mesaId,
          articulo,
          pase: pasesActivos ? _paseActivo : null,
        ),
      ),
      onAnadirConDetalle: (articulo) =>
          _anadirConDetalle(gateway, articulo, pases),
    );

    return Scaffold(
      appBar: AppBar(
        title: Text(nombreMesa),
        actions: [
          IndicadorConexion(state: state, pendientes: pendientes),
          Padding(
            padding: const EdgeInsets.only(left: 8),
            child: ActionChip(
              key: const Key('pedido.comensales'),
              avatar: const Icon(Icons.people_outline),
              label: Text(comensales == null ? '–' : '$comensales'),
              tooltip: comensales == null
                  ? 'Indicar comensales'
                  : 'Comensales: $comensales',
              visualDensity: VisualDensity.compact,
              onPressed: _fijandoComensales
                  ? null
                  : () => _elegirComensales(gateway),
            ),
          ),
          IconButton(
            key: const Key('pedido.cuenta'),
            tooltip: comanda?.cuentaSolicitada ?? false
                ? 'Quitar petición de cuenta'
                : 'Pedir cuenta',
            isSelected: comanda?.cuentaSolicitada ?? false,
            icon: const Icon(Icons.receipt_long_outlined),
            selectedIcon: const Icon(Icons.receipt_long),
            onPressed: comanda == null || _pidiendoCuenta
                ? null
                : () => _pedirCuenta(gateway, !comanda.cuentaSolicitada),
          ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final dosColumnas = constraints.maxWidth >= _anchoDosColumnas;
          // Buscando en la carta con el teclado abierto en una columna: el
          // alto es escaso, así que la carta lo ocupa todo (el pedido y la
          // franja de aviso vuelven al cerrar el teclado; el estado de la
          // conexión sigue en la barra superior).
          final soloCarta = !dosColumnas && buscandoConTeclado;
          return Column(
            children: [
              if (!soloCarta)
                AvisoSinConexion(state: state, pendientes: pendientes),
              Expanded(
                child: dosColumnas
                    ? Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(flex: 2, child: panelPedido),
                          const VerticalDivider(width: 1),
                          Expanded(flex: 3, child: panelCarta),
                        ],
                      )
                    : Column(
                        children: [
                          if (!soloCarta) ...[
                            Expanded(flex: 2, child: panelPedido),
                            const Divider(height: 1),
                          ],
                          // Con clave, la carta conserva su estado (búsqueda,
                          // familia y desplazamientos) aunque el pedido se
                          // quite y vuelva al abrir y cerrar el teclado.
                          Expanded(
                            key: const ValueKey('pedido.huecoCarta'),
                            flex: 3,
                            child: panelCarta,
                          ),
                        ],
                      ),
              ),
            ],
          );
        },
      ),
      bottomNavigationBar: _BarraEnvio(
        pedido: pedido,
        onEnviar: () => _enviar(gateway, state),
        onVaciar: pedido.pendientesDeEnviar.isEmpty
            ? null
            : () => _vaciar(gateway),
      ),
    );
  }

  /// Ejecuta una operación síncrona del carrito mostrando su error, si lo hay.
  void _accion(void Function() operacion) {
    try {
      operacion();
    } on AppException catch (error) {
      mostrarMensaje(
        ScaffoldMessenger.of(context),
        describirError(error),
        error: true,
      );
    } on StateError catch (error) {
      mostrarMensaje(
        ScaffoldMessenger.of(context),
        describirError(error),
        error: true,
      );
    }
  }

  /// Vacía lo no enviado y ofrece deshacerlo durante unos segundos.
  void _vaciar(ComanderoGateway gateway) {
    final messenger = ScaffoldMessenger.of(context);
    final PedidoEnEdicion antes;
    try {
      antes = gateway.pedido(_mesaId);
      gateway.vaciar(_mesaId);
    } on AppException catch (error) {
      mostrarMensaje(messenger, describirError(error), error: true);
      return;
    } on StateError catch (error) {
      mostrarMensaje(messenger, describirError(error), error: true);
      return;
    }
    final quitadas = antes.pendientesDeEnviar;
    if (quitadas.isEmpty) return;
    mostrarMensaje(
      messenger,
      quitadas.length == 1
          ? 'Se ha quitado 1 línea sin enviar'
          : 'Se han quitado ${quitadas.length} líneas sin enviar',
      accion: SnackBarAction(
        key: const Key('pedido.deshacerVaciar'),
        label: 'Deshacer',
        onPressed: () {
          try {
            gateway.importarPedidos([
              PedidoEnEdicion(mesaId: _mesaId, lineas: quitadas),
            ]);
          } on StateError catch (error) {
            mostrarMensaje(messenger, describirError(error), error: true);
          }
        },
      ),
    );
  }

  /// Envía lo no enviado. La petición es fiable: sin conexión queda en cola
  /// (las líneas se ven "Enviando…") y sale al reconectar. El botón no se
  /// bloquea: lo que se añada mientras tanto irá en el siguiente envío.
  ///
  /// Con la mesa libre, los comensales elegidos viajan con este envío: nunca
  /// se manda un envío vacío para una mesa libre.
  Future<void> _enviar(ComanderoGateway gateway, ComanderoState state) async {
    final messenger = ScaffoldMessenger.of(context);
    final comensales = gateway.sala?.comandaDeMesa(_mesaId) == null
        ? _comensalesPendientes
        : null;
    final Future<ComandaSubmitResult> envio;
    final Set<String> enviadas;
    try {
      // Las mismas líneas que toma el envío, para el mensaje por puesto.
      enviadas = {
        for (final linea in gateway.pedido(_mesaId).pendientesDeEnviar)
          linea.id,
      };
      envio = gateway.enviar(_mesaId, comensales: comensales);
    } on StateError catch (error) {
      mostrarMensaje(messenger, describirError(error), error: true);
      return;
    }
    if (state is! Conectado) {
      mostrarMensaje(
        messenger,
        'Sin conexión: el pedido queda pendiente y se enviará al reconectar',
      );
    }
    try {
      final result = await envio;
      if (mounted &&
          comensales != null &&
          _comensalesPendientes == comensales) {
        // El host ya tiene los comensales en la comanda que acaba de abrir.
        setState(() => _comensalesPendientes = null);
      }
      mostrarMensaje(messenger, mensajeDeEnvio(result, enviadas));
    } on AppException catch (error) {
      mostrarMensaje(
        messenger,
        'No se envió el pedido: ${describirError(error)}',
        error: true,
      );
    } on StateError catch (error) {
      mostrarMensaje(messenger, describirError(error), error: true);
    }
  }

  /// Marcha (o, con [repetir], vuelve a marchar) un pase de la comanda. La
  /// petición es fiable: sin conexión queda en cola y sale al reconectar con
  /// el mismo `marchaId`. Hasta que termine, el pase muestra un indicador en
  /// lugar del botón, para no encolar dos marchas; lo lleva
  /// [marchasEnCursoProvider], así que sigue igual si el camarero sale de la
  /// mesa y vuelve.
  Future<void> _marchar(
    ComanderoGateway gateway,
    int pase,
    PasesConfig? pases, {
    required bool repetir,
  }) async {
    final messenger = ScaffoldMessenger.of(context);
    final Future<Comanda> marcha;
    try {
      marcha = gateway.marcharPase(_mesaId, pase);
    } on StateError catch (error) {
      mostrarMensaje(messenger, describirError(error), error: true);
      return;
    }
    ref.read(marchasEnCursoProvider(_mesaId).notifier).seguir(pase, marcha);
    if (_quedaEnCola(gateway.state)) {
      mostrarMensaje(
        messenger,
        'Sin conexión: la marcha queda pendiente y saldrá al reconectar',
      );
    }
    try {
      await marcha;
      mostrarMensaje(messenger, _textoMarchado(pases, pase, repetir: repetir));
    } on AppException catch (error) {
      mostrarMensaje(messenger, describirError(error), error: true);
    } on StateError catch (error) {
      mostrarMensaje(messenger, describirError(error), error: true);
    }
  }

  /// Comensales de la mesa: con comanda se fijan en el host (envío fiable sin
  /// líneas con su `comandaId`); con la mesa libre se guardan para el primer
  /// envío.
  Future<void> _elegirComensales(ComanderoGateway gateway) async {
    final elegido = await pedirComensales(
      context,
      inicial: _comensalesDe(gateway.sala?.comandaDeMesa(_mesaId)),
    );
    if (elegido == null || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    if (gateway.sala?.comandaDeMesa(_mesaId) == null) {
      setState(() => _comensalesPendientes = elegido);
      mostrarMensaje(
        messenger,
        elegido == 1
            ? 'Se indicará 1 comensal con el primer envío'
            : 'Se indicarán $elegido comensales con el primer envío',
      );
      return;
    }
    final Future<Comanda> fijar;
    try {
      fijar = gateway.fijarComensales(_mesaId, elegido);
    } on StateError catch (error) {
      mostrarMensaje(messenger, describirError(error), error: true);
      return;
    }
    setState(() => _fijandoComensales = true);
    if (_quedaEnCola(gateway.state)) {
      mostrarMensaje(
        messenger,
        'Sin conexión: los comensales se fijarán al reconectar',
      );
    }
    try {
      await fijar;
      mostrarMensaje(
        messenger,
        elegido == 1 ? 'Mesa con 1 comensal' : 'Mesa con $elegido comensales',
      );
    } on AppException catch (error) {
      mostrarMensaje(
        messenger,
        'No se fijaron los comensales: ${describirError(error)}',
        error: true,
      );
    } on StateError catch (error) {
      mostrarMensaje(messenger, describirError(error), error: true);
    } finally {
      if (mounted) setState(() => _fijandoComensales = false);
    }
  }

  Future<void> _pedirCuenta(ComanderoGateway gateway, bool solicitada) async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _pidiendoCuenta = true);
    try {
      await gateway.pedirCuenta(_mesaId, solicitada: solicitada);
      mostrarMensaje(
        messenger,
        solicitada ? 'Cuenta pedida a caja' : 'Petición de cuenta retirada',
      );
    } on AppException catch (error) {
      mostrarMensaje(messenger, describirError(error), error: true);
    } on StateError catch (error) {
      mostrarMensaje(messenger, describirError(error), error: true);
    } finally {
      if (mounted) setState(() => _pidiendoCuenta = false);
    }
  }

  Future<void> _anular(ComanderoGateway gateway, LineaComanda linea) async {
    final messenger = ScaffoldMessenger.of(context);
    final motivo = await showDialog<String>(
      context: context,
      builder: (_) => DialogoAnular(linea: linea),
    );
    if (motivo == null || !mounted) return;
    try {
      await gateway.anularLinea(
        _mesaId,
        linea.id,
        motivo: motivo.isEmpty ? null : motivo,
      );
      mostrarMensaje(messenger, "Anulada '${linea.descripcion}'");
    } on AppException catch (error) {
      mostrarMensaje(
        messenger,
        'No se anuló la línea: ${describirError(error)}',
        error: true,
      );
    } on StateError catch (error) {
      mostrarMensaje(messenger, describirError(error), error: true);
    }
  }

  Future<void> _editarLineaCarrito(
    ComanderoGateway gateway,
    LineaPedido linea,
    PasesConfig? pases,
  ) async {
    final resultado = await showDialog<DetalleLinea>(
      context: context,
      builder: (_) => DialogoDetalleLinea(
        titulo: linea.articulo.descripcion,
        cantidad: linea.cantidad,
        nota: linea.nota,
        pases: pases,
        pase: linea.pase,
        permiteQuitar: true,
      ),
    );
    if (resultado == null || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final PedidoEnEdicion actual;
    try {
      actual = gateway.pedido(_mesaId);
    } on StateError catch (error) {
      mostrarMensaje(messenger, describirError(error), error: true);
      return;
    }
    final vigente = actual.lineaPorId(linea.id);
    if (vigente == null || vigente.enviando) {
      // Mientras el diálogo estaba abierto la línea se envió, se quitó o
      // cambió.
      mostrarMensaje(
        messenger,
        vigente == null
            ? 'La línea ha cambiado mientras la editabas; vuelve a abrirla'
            : 'La línea ya se está enviando; espera la confirmación del host',
        error: true,
      );
      return;
    }
    _accion(() {
      if (resultado.quitar) {
        gateway.quitar(_mesaId, linea.id);
        return;
      }
      // Cantidad, nota y pase en una sola edición: con una línea devuelta
      // tras un corte, cambiarlos por separado le daría un id nuevo con el
      // primero y el segundo ya no la encontraría.
      final cambiaPase = resultado.pase != vigente.pase;
      if (resultado.cantidad != vigente.cantidad ||
          (resultado.nota ?? '') != (vigente.nota ?? '') ||
          cambiaPase) {
        gateway.editarLinea(
          _mesaId,
          linea.id,
          cantidad: resultado.cantidad,
          nota: resultado.nota,
          pase: cambiaPase ? () => resultado.pase : null,
        );
      }
    });
  }

  /// Pulsación larga en la carta: cantidad, nota y pase antes de añadir (con
  /// el pase activo preseleccionado).
  Future<void> _anadirConDetalle(
    ComanderoGateway gateway,
    ArticuloCatalogo articulo,
    PasesConfig? pases,
  ) async {
    final resultado = await showDialog<DetalleLinea>(
      context: context,
      builder: (_) => DialogoDetalleLinea(
        titulo: articulo.descripcion,
        cantidad: 1,
        pases: pases,
        pase: (pases?.activos ?? false) ? _paseActivo : null,
        textoConfirmar: 'Añadir',
      ),
    );
    if (resultado == null || resultado.quitar || !mounted) return;
    _accion(
      () => gateway.anadir(
        _mesaId,
        articulo,
        cantidad: resultado.cantidad,
        nota: resultado.nota,
        pase: resultado.pase,
      ),
    );
  }
}

/// Una petición fiable hecha en este estado queda en cola hasta reconectar:
/// hay host objetivo pero no sesión. Sin host falla al momento.
bool _quedaEnCola(ComanderoState state) =>
    state is! Conectado && state.host != null;

/// «Marchados los Segundos» (o «Marchados de nuevo los Segundos»); un pase
/// que no está en la configuración: «Marchado el pase 4».
String _textoMarchado(PasesConfig? pases, int pase, {required bool repetir}) {
  final deNuevo = repetir ? ' de nuevo' : '';
  if (pases != null && pases.existe(pase)) {
    return 'Marchados$deNuevo los ${pases.nombreDe(pase)}';
  }
  return 'Marchado$deNuevo el pase $pase';
}

// -----------------------------------------------------------------------------
// Barra inferior
// -----------------------------------------------------------------------------

class _BarraEnvio extends StatelessWidget {
  const _BarraEnvio({
    required this.pedido,
    required this.onEnviar,
    required this.onVaciar,
  });

  final PedidoEnEdicion pedido;
  final VoidCallback onEnviar;
  final VoidCallback? onVaciar;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final porEnviar = pedido.pendientesDeEnviar;
    final unidades = porEnviar.fold(0.0, (total, l) => total + l.cantidad);
    final importe = porEnviar.fold(0, (total, l) => total + l.importeCents);
    return Material(
      elevation: 8,
      color: theme.colorScheme.surfaceContainer,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Row(
            children: [
              IconButton(
                tooltip: 'Vaciar lo no enviado',
                icon: const Icon(Icons.delete_sweep),
                onPressed: onVaciar,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      porEnviar.isEmpty
                          ? 'Nada por enviar'
                          : '${formatQuantity(unidades)} uds. por enviar',
                      style: theme.textTheme.bodySmall,
                    ),
                    Text(
                      formatCents(importe),
                      key: const Key('pedido.total'),
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
              FilledButton.icon(
                key: const Key('pedido.enviar'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size(140, 56),
                  textStyle: theme.textTheme.titleMedium,
                ),
                onPressed: porEnviar.isEmpty ? null : onEnviar,
                icon: const Icon(Icons.send),
                label: const Text('ENVIAR'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
