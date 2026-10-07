import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/errors/app_exception.dart';
import '../../../core/facturascripts/catalog/catalog_models.dart';
import '../../../core/money/money.dart';
import '../../sala/domain/comanda.dart';
import '../../sala/domain/linea_comanda.dart';
import '../../sala/protocol/sala_messages.dart';
import '../domain/comandero_state.dart';
import '../domain/pedido_en_edicion.dart';
import 'comandero_carga.dart';
import 'comandero_gateway.dart';
import 'comandero_widgets.dart';
import 'providers.dart';

/// Toma de pedido de una mesa: comanda enviada y carrito arriba (o a la
/// izquierda en pantallas anchas), carta por familias abajo (o a la derecha)
/// y barra inferior con el total del carrito y el botón ENVIAR.
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

  @override
  Widget build(BuildContext context) {
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
    // Se mira fuera del Scaffold: dentro del cuerpo, el Scaffold ya descuenta
    // el teclado y quita su hueco de MediaQuery.
    final buscandoConTeclado =
        _focoBusqueda.hasFocus && MediaQuery.viewInsetsOf(context).bottom > 0;

    final panelPedido = _PanelPedido(
      comanda: comanda,
      pedido: pedido,
      onEditarLinea: (linea) => _editarLineaCarrito(gateway, linea),
      onQuitarLinea: (linea) =>
          _accion(() => gateway.quitar(_mesaId, linea.id)),
      onAnularLinea: (linea) => _anular(gateway, linea),
    );
    final panelCarta = _PanelCarta(
      catalogo: catalogo,
      focoBusqueda: _focoBusqueda,
      onAnadir: (articulo) => _accion(() => gateway.anadir(_mesaId, articulo)),
      onAnadirConDetalle: (articulo) => _anadirConDetalle(gateway, articulo),
    );

    return Scaffold(
      appBar: AppBar(
        title: Text(nombreMesa),
        actions: [
          IndicadorConexion(state: state, pendientes: pendientes),
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
                          Expanded(flex: 3, child: panelCarta),
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
  Future<void> _enviar(ComanderoGateway gateway, ComanderoState state) async {
    final messenger = ScaffoldMessenger.of(context);
    final Future<ComandaSubmitResult> envio;
    try {
      envio = gateway.enviar(_mesaId);
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
      final n = result.lineasNuevas;
      mostrarMensaje(
        messenger,
        n == 1 ? 'Enviada 1 línea a cocina' : 'Enviadas $n líneas a cocina',
      );
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
      builder: (_) => _DialogoAnular(linea: linea),
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
  ) async {
    final resultado = await showDialog<DetalleLinea>(
      context: context,
      builder: (_) => DialogoDetalleLinea(
        titulo: linea.articulo.descripcion,
        cantidad: linea.cantidad,
        nota: linea.nota,
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
      // Cantidad y nota en una sola edición: con una línea devuelta tras un
      // corte, cambiarlas por separado le daría un id nuevo con la primera y
      // la segunda ya no la encontraría.
      if (resultado.cantidad != vigente.cantidad ||
          (resultado.nota ?? '') != (vigente.nota ?? '')) {
        gateway.editarLinea(
          _mesaId,
          linea.id,
          cantidad: resultado.cantidad,
          nota: resultado.nota,
        );
      }
    });
  }

  Future<void> _anadirConDetalle(
    ComanderoGateway gateway,
    ArticuloCatalogo articulo,
  ) async {
    final resultado = await showDialog<DetalleLinea>(
      context: context,
      builder: (_) => DialogoDetalleLinea(
        titulo: articulo.descripcion,
        cantidad: 1,
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
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// Panel del pedido: comanda enviada + carrito
// -----------------------------------------------------------------------------

class _PanelPedido extends StatelessWidget {
  const _PanelPedido({
    required this.comanda,
    required this.pedido,
    required this.onEditarLinea,
    required this.onQuitarLinea,
    required this.onAnularLinea,
  });

  final Comanda? comanda;
  final PedidoEnEdicion pedido;
  final void Function(LineaPedido linea) onEditarLinea;
  final void Function(LineaPedido linea) onQuitarLinea;
  final void Function(LineaComanda linea) onAnularLinea;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final comanda = this.comanda;
    final enviadas = comanda?.lineas ?? const <LineaComanda>[];
    return ListView(
      key: const Key('pedido.panel'),
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        _Cabecera(
          titulo: 'Sin enviar',
          detalle: pedido.estaVacio ? null : formatCents(pedido.importeCents),
        ),
        if (pedido.estaVacio)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text('Toca un artículo de la carta para añadirlo.'),
          )
        else
          for (final linea in pedido.lineas)
            ListTile(
              key: Key('carrito.linea.${linea.id}'),
              dense: true,
              leading: CircleAvatar(
                radius: 18,
                child: Text(formatQuantity(linea.cantidad)),
              ),
              title: Text(linea.articulo.descripcion),
              subtitle: linea.enviando
                  ? const Text('Enviando…')
                  : (linea.nota == null ? null : Text(linea.nota!)),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(formatCents(linea.importeCents)),
                  if (linea.enviando)
                    const Padding(
                      padding: EdgeInsets.all(12),
                      child: SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  else
                    IconButton(
                      tooltip: 'Quitar',
                      icon: const Icon(Icons.remove_circle_outline),
                      onPressed: () => onQuitarLinea(linea),
                    ),
                ],
              ),
              onTap: linea.enviando ? null : () => onEditarLinea(linea),
            ),
        const Divider(),
        _Cabecera(
          titulo: 'Enviado',
          detalle: comanda == null ? null : formatCents(comanda.importeCents),
        ),
        if (enviadas.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text('La mesa no tiene nada pedido.'),
          )
        else
          for (final linea in enviadas.reversed)
            ListTile(
              key: Key('comanda.linea.${linea.id}'),
              dense: true,
              leading: CircleAvatar(
                radius: 18,
                backgroundColor: linea.anulada
                    ? theme.colorScheme.errorContainer
                    : theme.colorScheme.secondaryContainer,
                child: Text(formatQuantity(linea.cantidad)),
              ),
              title: Text(
                linea.descripcion,
                style: linea.anulada
                    ? const TextStyle(decoration: TextDecoration.lineThrough)
                    : null,
              ),
              subtitle: Text(_detalleEnviada(linea)),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    formatCents(
                      lineTotalCents(linea.pvpUnitarioCents, linea.cantidad),
                    ),
                    style: linea.anulada
                        ? const TextStyle(
                            decoration: TextDecoration.lineThrough,
                          )
                        : null,
                  ),
                  if (!linea.anulada)
                    IconButton(
                      key: Key('comanda.anular.${linea.id}'),
                      tooltip: 'Anular',
                      icon: const Icon(Icons.block),
                      onPressed: () => onAnularLinea(linea),
                    )
                  else
                    const SizedBox(width: 48),
                ],
              ),
            ),
      ],
    );
  }

  static String _detalleEnviada(LineaComanda linea) {
    final partes = <String>[
      switch (linea.estado) {
        EstadoLinea.enviada =>
          linea.destino == DestinoPreparacion.barra ? 'En barra' : 'En cocina',
        EstadoLinea.servida => 'Servida',
        EstadoLinea.anulada =>
          'Anulada${linea.motivoAnulacion == null ? '' : ': ${linea.motivoAnulacion}'}',
      },
      if (linea.nota != null) linea.nota!,
    ];
    return partes.join(' · ');
  }
}

class _Cabecera extends StatelessWidget {
  const _Cabecera({required this.titulo, this.detalle});

  final String titulo;
  final String? detalle;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.titleSmall;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Row(
        children: [
          Expanded(child: Text(titulo, style: style)),
          if (detalle != null) Text(detalle!, style: style),
        ],
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// Carta: familias como pestañas, búsqueda y rejilla de artículos
// -----------------------------------------------------------------------------

/// Normaliza un texto para buscar sin distinguir mayúsculas ni tildes.
String normalizarBusqueda(String texto) {
  const tildes = {
    'á': 'a',
    'à': 'a',
    'ä': 'a',
    'é': 'e',
    'è': 'e',
    'ë': 'e',
    'í': 'i',
    'ì': 'i',
    'ï': 'i',
    'ó': 'o',
    'ò': 'o',
    'ö': 'o',
    'ú': 'u',
    'ù': 'u',
    'ü': 'u',
    'ñ': 'n',
    'ç': 'c',
  };
  final buffer = StringBuffer();
  for (final char in texto.toLowerCase().split('')) {
    buffer.write(tildes[char] ?? char);
  }
  return buffer.toString().trim();
}

/// Artículos vendibles de [familia] (todas si es `null`) que contienen
/// [busqueda] en la descripción, la referencia o el código de barras.
List<ArticuloCatalogo> filtrarArticulos(
  CatalogSnapshot catalogo, {
  String? familia,
  String busqueda = '',
}) {
  final consulta = normalizarBusqueda(busqueda);
  return [
    for (final articulo in catalogo.vendibles)
      if ((familia == null || articulo.codfamilia == familia) &&
          (consulta.isEmpty ||
              normalizarBusqueda(articulo.descripcion).contains(consulta) ||
              normalizarBusqueda(articulo.referencia).contains(consulta) ||
              (articulo.codbarras ?? '') == busqueda.trim()))
        articulo,
  ];
}

class _PanelCarta extends StatefulWidget {
  const _PanelCarta({
    required this.catalogo,
    required this.focoBusqueda,
    required this.onAnadir,
    required this.onAnadirConDetalle,
  });

  final CatalogSnapshot? catalogo;
  final FocusNode focoBusqueda;
  final void Function(ArticuloCatalogo articulo) onAnadir;
  final void Function(ArticuloCatalogo articulo) onAnadirConDetalle;

  @override
  State<_PanelCarta> createState() => _PanelCartaState();
}

class _PanelCartaState extends State<_PanelCarta> {
  final TextEditingController _busqueda = TextEditingController();
  String? _familia;

  @override
  void dispose() {
    _busqueda.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final catalogo = widget.catalogo;
    if (catalogo == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'La carta todavía no ha llegado del host.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    final conArticulos = {
      for (final articulo in catalogo.vendibles) articulo.codfamilia,
    };
    final familias = [
      for (final familia in catalogo.familias)
        if (conArticulos.contains(familia.codfamilia)) familia,
    ];
    final familia = familias.any((f) => f.codfamilia == _familia)
        ? _familia
        : null;
    final articulos = filtrarArticulos(
      catalogo,
      familia: familia,
      busqueda: _busqueda.text,
    );

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: TextField(
            key: const Key('pedido.buscar'),
            controller: _busqueda,
            focusNode: widget.focoBusqueda,
            onChanged: (_) => setState(() {}),
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              isDense: true,
              hintText: 'Buscar en la carta',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _busqueda.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Borrar búsqueda',
                      icon: const Icon(Icons.clear),
                      onPressed: () => setState(_busqueda.clear),
                    ),
            ),
          ),
        ),
        SizedBox(
          height: 48,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            children: [
              _PestanaFamilia(
                key: const Key('familia.todas'),
                texto: 'Todo',
                seleccionada: familia == null,
                onTap: () => setState(() => _familia = null),
              ),
              for (final f in familias)
                _PestanaFamilia(
                  key: Key('familia.${f.codfamilia}'),
                  texto: f.descripcion,
                  seleccionada: familia == f.codfamilia,
                  onTap: () => setState(() => _familia = f.codfamilia),
                ),
            ],
          ),
        ),
        Expanded(
          child: articulos.isEmpty
              ? const Center(child: Text('Ningún artículo coincide'))
              : GridView.builder(
                  key: const Key('pedido.carta'),
                  padding: const EdgeInsets.all(12),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 160,
                    mainAxisSpacing: 8,
                    crossAxisSpacing: 8,
                    childAspectRatio: 1.3,
                  ),
                  itemCount: articulos.length,
                  itemBuilder: (context, index) {
                    final articulo = articulos[index];
                    return _ArticuloTile(
                      articulo: articulo,
                      onTap: () => widget.onAnadir(articulo),
                      onLongPress: () => widget.onAnadirConDetalle(articulo),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _PestanaFamilia extends StatelessWidget {
  const _PestanaFamilia({
    super.key,
    required this.texto,
    required this.seleccionada,
    required this.onTap,
  });

  final String texto;
  final bool seleccionada;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        label: Text(texto),
        selected: seleccionada,
        onSelected: (_) => onTap(),
      ),
    );
  }
}

class _ArticuloTile extends StatelessWidget {
  const _ArticuloTile({
    required this.articulo,
    required this.onTap,
    required this.onLongPress,
  });

  final ArticuloCatalogo articulo;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      key: Key('articulo.${articulo.referencia}'),
      clipBehavior: Clip.antiAlias,
      color: theme.colorScheme.surfaceContainerHigh,
      child: InkWell(
        onTap: () {
          HapticFeedback.selectionClick().ignore();
          onTap();
        },
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  articulo.descripcion,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall,
                ),
              ),
              Text(
                formatCents(articulo.pvpCents),
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
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

// -----------------------------------------------------------------------------
// Diálogos
// -----------------------------------------------------------------------------

/// Resultado de [DialogoDetalleLinea].
typedef DetalleLinea = ({double cantidad, String? nota, bool quitar});

/// Edita cantidad y nota de una línea (o de un artículo antes de añadirlo).
class DialogoDetalleLinea extends StatefulWidget {
  const DialogoDetalleLinea({
    super.key,
    required this.titulo,
    required this.cantidad,
    this.nota,
    this.permiteQuitar = false,
    this.textoConfirmar = 'Guardar',
  });

  final String titulo;
  final double cantidad;
  final String? nota;
  final bool permiteQuitar;
  final String textoConfirmar;

  @override
  State<DialogoDetalleLinea> createState() => _DialogoDetalleLineaState();
}

class _DialogoDetalleLineaState extends State<DialogoDetalleLinea> {
  late double _cantidad = widget.cantidad;
  late final TextEditingController _nota = TextEditingController(
    text: widget.nota ?? '',
  );

  @override
  void dispose() {
    _nota.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(widget.titulo),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton.filledTonal(
                key: const Key('detalle.menos'),
                iconSize: 32,
                tooltip: 'Una menos',
                onPressed: _cantidad > 1
                    ? () => setState(() => _cantidad -= 1)
                    : null,
                icon: const Icon(Icons.remove),
              ),
              SizedBox(
                width: 72,
                child: Text(
                  formatQuantity(_cantidad),
                  key: const Key('detalle.cantidad'),
                  textAlign: TextAlign.center,
                  style: theme.textTheme.headlineMedium,
                ),
              ),
              IconButton.filledTonal(
                key: const Key('detalle.mas'),
                iconSize: 32,
                tooltip: 'Una más',
                onPressed: () => setState(() => _cantidad += 1),
                icon: const Icon(Icons.add),
              ),
            ],
          ),
          const SizedBox(height: 16),
          TextField(
            key: const Key('detalle.nota'),
            controller: _nota,
            maxLength: 120,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'Nota para cocina',
              hintText: 'Sin cebolla, muy hecho…',
            ),
          ),
        ],
      ),
      actions: [
        if (widget.permiteQuitar)
          TextButton(
            onPressed: () => Navigator.of(context).pop<DetalleLinea>((
              cantidad: _cantidad,
              nota: null,
              quitar: true,
            )),
            child: const Text('Quitar'),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          key: const Key('detalle.confirmar'),
          onPressed: () {
            final nota = _nota.text.trim();
            Navigator.of(context).pop<DetalleLinea>((
              cantidad: _cantidad,
              nota: nota.isEmpty ? null : nota,
              quitar: false,
            ));
          },
          child: Text(widget.textoConfirmar),
        ),
      ],
    );
  }
}

class _DialogoAnular extends StatefulWidget {
  const _DialogoAnular({required this.linea});

  final LineaComanda linea;

  @override
  State<_DialogoAnular> createState() => _DialogoAnularState();
}

class _DialogoAnularState extends State<_DialogoAnular> {
  static const List<String> _motivos = [
    'Error al pedir',
    'El cliente lo cancela',
    'Agotado',
    'Invitación',
  ];

  final TextEditingController _motivo = TextEditingController();

  @override
  void dispose() {
    _motivo.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final linea = widget.linea;
    return AlertDialog(
      title: Text(
        'Anular ${formatQuantity(linea.cantidad)} × ${linea.descripcion}',
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final motivo in _motivos)
                ActionChip(
                  label: Text(motivo),
                  onPressed: () => setState(() => _motivo.text = motivo),
                ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('anular.motivo'),
            controller: _motivo,
            maxLength: 100,
            decoration: const InputDecoration(labelText: 'Motivo'),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          key: const Key('anular.confirmar'),
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.error,
            foregroundColor: Theme.of(context).colorScheme.onError,
          ),
          onPressed: () => Navigator.of(context).pop(_motivo.text.trim()),
          child: const Text('Anular'),
        ),
      ],
    );
  }
}
