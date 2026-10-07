import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../core/facturascripts/catalog/catalog_models.dart';
import '../../../core/money/money.dart';
import '../../sala/domain/comanda.dart';
import '../../sala/domain/linea_comanda.dart';
import '../../sala/domain/mesa.dart';
import '../../sala/protocol/sala_messages.dart';
import 'cobro_dialog.dart';
import 'providers.dart';
import 'widgets/catalogo_panel.dart';
import 'widgets/host_feedback.dart';
import 'widgets/host_formatos.dart';

const Uuid _uuid = Uuid();

/// Ancho a partir del cual la carta se muestra junto a la comanda.
const double kAnchoComandaYCarta = 840;

/// Artículo añadido en el TPV y aún no enviado a cocina. Su [id] es el de la
/// futura [LineaComanda]: reenviar tras un error no duplica la línea.
final class _Pendiente {
  _Pendiente({required this.articulo}) : id = _uuid.v4();

  final String id;
  final ArticuloCatalogo articulo;
  double cantidad = 1;
  String? nota;

  int get importeCents => lineTotalCents(articulo.pvpCents, cantidad);
}

/// Comanda de una mesa: líneas, alta de artículos desde la carta, anulación,
/// cuenta, precuenta y cobro.
class MesaPage extends ConsumerStatefulWidget {
  const MesaPage({super.key, required this.mesaId});

  final String mesaId;

  @override
  ConsumerState<MesaPage> createState() => _MesaPageState();
}

class _MesaPageState extends ConsumerState<MesaPage> {
  final List<_Pendiente> _pendientes = [];
  bool _enviando = false;

  int get _importePendiente =>
      _pendientes.fold(0, (total, p) => total + p.importeCents);

  @override
  Widget build(BuildContext context) {
    final snapshot = ref.watch(hostSnapshotProvider).value;
    final mesa = snapshot?.mesaPorId(widget.mesaId);
    final comanda = snapshot?.comandaDeMesa(widget.mesaId);

    if (snapshot == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (mesa == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const MensajeCentrado(
          icono: Icons.table_restaurant,
          titulo: 'Esta mesa ya no existe en la configuración',
        ),
      );
    }

    return PopScope(
      canPop: _pendientes.isEmpty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_salirDescartando());
      },
      child: Scaffold(
        // En vista estrecha la pantalla no tiene campos de texto propios (la
        // carta se abre aparte): el teclado de un diálogo no la redimensiona.
        resizeToAvoidBottomInset:
            MediaQuery.sizeOf(context).width >= kAnchoComandaYCarta,
        appBar: AppBar(
          title: Text(mesa.nombre),
          actions: [
            if (comanda != null)
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: Center(
                  child: Text(
                    'Abierta ${formatHora(comanda.abiertaEn)}',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
              ),
          ],
        ),
        body: LayoutBuilder(
          builder: (context, constraints) {
            final panelComanda = _panelComanda(context, mesa, comanda);
            if (constraints.maxWidth >= kAnchoComandaYCarta) {
              return Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(flex: 5, child: panelComanda),
                  const VerticalDivider(width: 1),
                  Expanded(flex: 6, child: _panelCarta(context, ref)),
                ],
              );
            }
            return panelComanda;
          },
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Paneles

  Widget _panelCarta(BuildContext context, WidgetRef ref) {
    final catalogo = ref.watch(catalogoProvider);
    if (catalogo == null) {
      final configurado = ref.watch(catalogServiceProvider).configurado;
      return MensajeCentrado(
        icono: Icons.menu_book_outlined,
        titulo: 'La carta no está disponible',
        detalle: configurado
            ? 'Todavía no se ha descargado el catálogo de FacturaScripts.'
            : 'Configura la conexión con FacturaScripts en los ajustes para '
                  'descargar la carta.',
        accion: configurado
            ? FilledButton.icon(
                onPressed: () => unawaited(
                  ejecutarAccion(
                    context,
                    () => ref.read(catalogServiceProvider).refrescar(),
                    exito: 'Carta actualizada',
                  ),
                ),
                icon: const Icon(Icons.download),
                label: const Text('Descargar carta'),
              )
            : null,
      );
    }
    return CatalogoPanel(catalogo: catalogo, onArticulo: _anadir);
  }

  Widget _panelComanda(BuildContext context, Mesa mesa, Comanda? comanda) {
    final theme = Theme.of(context);
    final ancho = MediaQuery.sizeOf(context).width >= kAnchoComandaYCarta;
    final lineas = comanda?.lineas ?? const <LineaComanda>[];
    final hayLineas = comanda != null && !comanda.estaVacia;

    // El bloque de acciones nunca ocupa más del 60 % del alto y se desplaza
    // si no cabe (teléfono vertical con el teclado de un diálogo abierto).
    return LayoutBuilder(
      builder: (context, constraints) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (comanda != null) _cabecera(context, comanda),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 8),
              children: [
                if (_pendientes.isNotEmpty) ...[
                  _titulo(context, 'Sin enviar'),
                  for (final p in _pendientes) _filaPendiente(context, p),
                  const Divider(),
                ],
                if (lineas.isEmpty && _pendientes.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(32),
                    child: Text(
                      comanda == null
                          ? 'Mesa libre. Añade artículos de la carta para '
                                'abrirla.'
                          : 'La comanda no tiene líneas.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyLarge,
                    ),
                  ),
                if (lineas.isNotEmpty) _titulo(context, 'Comanda'),
                for (final l in lineas) _filaLinea(context, mesa, l),
              ],
            ),
          ),
          const Divider(height: 1),
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: constraints.maxHeight * 0.6),
            child: SingleChildScrollView(
              key: const Key('acciones-mesa'),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (!ancho)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: OutlinedButton.icon(
                          key: const Key('abrir-carta'),
                          onPressed: () => _abrirCarta(context, mesa),
                          icon: const Icon(Icons.add),
                          label: const Text('Añadir artículos'),
                        ),
                      ),
                    if (_pendientes.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: FilledButton.icon(
                          key: const Key('enviar-pendientes'),
                          style: FilledButton.styleFrom(
                            minimumSize: const Size.fromHeight(56),
                          ),
                          onPressed: _enviando
                              ? null
                              : () => unawaited(_enviar()),
                          icon: _enviando
                              ? const SizedBox.square(
                                  dimension: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.send),
                          label: Text(
                            'Enviar ${_pendientes.length} · '
                            '${formatCents(_importePendiente)}',
                          ),
                        ),
                      ),
                    Row(
                      children: [
                        Text('Total', style: theme.textTheme.titleLarge),
                        const Spacer(),
                        Text(
                          formatCents(comanda?.importeCents ?? 0),
                          key: const Key('total-mesa'),
                          style: theme.textTheme.headlineSmall?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      alignment: WrapAlignment.end,
                      children: [
                        if (comanda != null)
                          OutlinedButton.icon(
                            key: const Key('marcar-cuenta'),
                            onPressed: () => unawaited(_marcarCuenta(comanda)),
                            icon: Icon(
                              comanda.cuentaSolicitada
                                  ? Icons.receipt_long
                                  : Icons.receipt_long_outlined,
                            ),
                            label: Text(
                              comanda.cuentaSolicitada
                                  ? 'Quitar cuenta'
                                  : 'Pedir cuenta',
                            ),
                          ),
                        if (hayLineas)
                          OutlinedButton.icon(
                            key: const Key('precuenta'),
                            onPressed: () =>
                                unawaited(_imprimirPrecuenta(mesa, comanda)),
                            icon: const Icon(Icons.print_outlined),
                            label: const Text('Precuenta'),
                          ),
                        if (comanda != null)
                          TextButton.icon(
                            key: const Key('vaciar-mesa'),
                            onPressed: () => unawaited(_vaciar(mesa)),
                            icon: const Icon(Icons.delete_sweep_outlined),
                            label: const Text('Vaciar mesa'),
                          ),
                        FilledButton.icon(
                          key: const Key('cobrar'),
                          style: FilledButton.styleFrom(
                            minimumSize: const Size(180, 56),
                            textStyle: theme.textTheme.titleMedium,
                          ),
                          onPressed: hayLineas && _pendientes.isEmpty
                              ? () => unawaited(_cobrar())
                              : null,
                          icon: const Icon(Icons.euro),
                          label: const Text('COBRAR'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _cabecera(BuildContext context, Comanda comanda) {
    final datos = [
      if (comanda.camarero != null) 'Camarero: ${comanda.camarero}',
      if (comanda.comensales != null) '${comanda.comensales} comensales',
    ];
    if (datos.isEmpty && !comanda.cuentaSolicitada) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Wrap(
        spacing: 8,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (datos.isNotEmpty) Text(datos.join(' · ')),
          if (comanda.cuentaSolicitada)
            Chip(
              avatar: const Icon(Icons.receipt_long),
              label: const Text('Cuenta solicitada'),
              backgroundColor: Theme.of(context).colorScheme.tertiaryContainer,
            ),
        ],
      ),
    );
  }

  Widget _titulo(BuildContext context, String texto) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
    child: Text(texto, style: Theme.of(context).textTheme.titleSmall),
  );

  Widget _filaPendiente(BuildContext context, _Pendiente p) {
    return ListTile(
      key: Key('pendiente-${p.articulo.referencia}'),
      contentPadding: const EdgeInsets.only(left: 8, right: 8),
      leading: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: 'Una menos',
            onPressed: _enviando ? null : () => _cambiarCantidad(p, -1),
            icon: const Icon(Icons.remove_circle_outline),
          ),
          Text(
            formatQuantity(p.cantidad),
            style: Theme.of(context).textTheme.titleMedium,
          ),
          IconButton(
            tooltip: 'Una más',
            onPressed: _enviando ? null : () => _cambiarCantidad(p, 1),
            icon: const Icon(Icons.add_circle_outline),
          ),
        ],
      ),
      title: Text(p.articulo.descripcion),
      subtitle: p.nota == null ? null : Text(p.nota!),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(formatCents(p.importeCents)),
          IconButton(
            tooltip: 'Nota para cocina',
            onPressed: _enviando ? null : () => unawaited(_editarNota(p)),
            icon: const Icon(Icons.edit_note),
          ),
        ],
      ),
    );
  }

  Widget _filaLinea(BuildContext context, Mesa mesa, LineaComanda l) {
    final theme = Theme.of(context);
    final tachado = l.anulada
        ? TextStyle(
            decoration: TextDecoration.lineThrough,
            color: theme.colorScheme.outline,
          )
        : null;
    final estado = switch (l.estado) {
      EstadoLinea.enviada => 'Enviada ${formatHora(l.creadaEn)}',
      EstadoLinea.servida => 'Servida',
      EstadoLinea.anulada =>
        'Anulada${l.motivoAnulacion == null ? '' : ': ${l.motivoAnulacion}'}',
    };
    return ListTile(
      key: Key('linea-${l.id}'),
      leading: CircleAvatar(child: Text(formatQuantity(l.cantidad))),
      title: Text(l.descripcion, style: tachado),
      subtitle: Text(
        [if (l.nota != null) l.nota!, estado].join(' · '),
        style: tachado,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            formatCents(lineTotalCents(l.pvpUnitarioCents, l.cantidad)),
            style: tachado ?? theme.textTheme.titleMedium,
          ),
          if (!l.anulada)
            IconButton(
              key: Key('anular-${l.id}'),
              tooltip: 'Anular línea',
              onPressed: () => unawaited(_anular(mesa, l)),
              icon: const Icon(Icons.cancel_outlined),
            ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Acciones

  void _anadir(ArticuloCatalogo articulo) {
    if (_enviando) return;
    setState(() {
      for (final p in _pendientes) {
        if (p.articulo.referencia == articulo.referencia && p.nota == null) {
          p.cantidad += 1;
          return;
        }
      }
      _pendientes.add(_Pendiente(articulo: articulo));
    });
  }

  void _cambiarCantidad(_Pendiente p, int delta) {
    setState(() {
      p.cantidad += delta;
      if (p.cantidad <= 0) _pendientes.remove(p);
    });
  }

  Future<void> _editarNota(_Pendiente p) async {
    final nota = await _pedirTexto(
      context,
      titulo: 'Nota para cocina',
      inicial: p.nota,
      sugerencias: const ['Sin cebolla', 'Muy hecho', 'Poco hecho', 'Sin sal'],
    );
    if (nota == null || !mounted) return;
    setState(() => p.nota = nota.isEmpty ? null : nota);
  }

  void _abrirCarta(BuildContext context, Mesa mesa) {
    unawaited(
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (context) => Scaffold(
            appBar: AppBar(title: Text('Añadir a ${mesa.nombre}')),
            body: Consumer(
              builder: (context, ref, _) {
                final catalogo = ref.watch(catalogoProvider);
                if (catalogo == null) return _panelCarta(context, ref);
                return CatalogoPanel(
                  catalogo: catalogo,
                  onArticulo: (a) {
                    _anadir(a);
                    mostrarMensaje(
                      context,
                      'Añadido: ${a.descripcion}',
                      duracion: const Duration(seconds: 1),
                    );
                  },
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _enviar() async {
    if (_pendientes.isEmpty) return;
    setState(() => _enviando = true);
    final ahora = ref.read(relojProvider)();
    final enviados = List.of(_pendientes);
    final payload = ComandaSubmitPayload(
      mesaId: widget.mesaId,
      lineas: [
        for (final p in enviados)
          LineaComanda(
            id: p.id,
            referencia: p.articulo.referencia,
            descripcion: p.articulo.descripcion,
            cantidad: p.cantidad,
            pvpUnitarioCents: p.articulo.pvpCents,
            pvpUnitarioNeto: p.articulo.precioNeto,
            ivaBp: p.articulo.ivaBp,
            codimpuesto: p.articulo.codimpuesto,
            nota: p.nota,
            creadaEn: ahora,
          ),
      ],
    );
    final ok = await ejecutarAccion(
      context,
      () => ref.read(salaServiceProvider).aceptarLineas(payload),
    );
    if (!mounted) return;
    setState(() {
      _enviando = false;
      if (ok) _pendientes.removeWhere(enviados.contains);
    });
  }

  Future<void> _anular(Mesa mesa, LineaComanda linea) async {
    final motivo = await _pedirTexto(
      context,
      titulo: 'Anular ${formatQuantity(linea.cantidad)} × ${linea.descripcion}',
      etiqueta: 'Motivo',
      textoAceptar: 'Anular línea',
      sugerencias: const [
        'Error de comanda',
        'Cliente cancela',
        'Producto agotado',
      ],
    );
    if (motivo == null || !mounted) return;
    await ejecutarAccion(
      context,
      () => ref
          .read(salaServiceProvider)
          .anularLinea(
            mesa.id,
            linea.id,
            motivo: motivo.isEmpty ? null : motivo,
          ),
      exito: 'Línea anulada',
    );
  }

  Future<void> _marcarCuenta(Comanda comanda) => ejecutarAccion(
    context,
    () => ref
        .read(salaServiceProvider)
        .marcarCuenta(widget.mesaId, !comanda.cuentaSolicitada),
  );

  /// Imprime la cuenta sin cobrar: documento propio, sin validez fiscal, sin
  /// numerar y sin abrir el cajón.
  Future<void> _imprimirPrecuenta(Mesa mesa, Comanda comanda) async {
    final activas = comanda.lineasActivas.toList();
    final totales = ref.read(salaServiceProvider).calcularTotales(activas);
    await ejecutarAccion(
      context,
      () => ref
          .read(printingServiceProvider)
          .imprimirPrecuenta(
            mesa,
            comanda,
            totales,
            cuando: ref.read(relojProvider)(),
          ),
      exito: 'Precuenta enviada a la impresora',
    );
  }

  Future<void> _vaciar(Mesa mesa) async {
    final ok = await confirmar(
      context,
      titulo: 'Vaciar ${mesa.nombre}',
      mensaje:
          'Se anularán todas las líneas sin cobrar y se devolverá su stock. '
          'Esta acción no se puede deshacer.',
      textoAceptar: 'Vaciar',
      peligroso: true,
    );
    if (!ok || !mounted) return;
    final hecho = await ejecutarAccion(
      context,
      () => ref
          .read(salaServiceProvider)
          .vaciarMesa(mesa.id, motivo: 'Mesa vaciada en el TPV'),
      exito: '${mesa.nombre} vaciada',
    );
    if (hecho && mounted) Navigator.of(context).pop();
  }

  Future<void> _cobrar() async {
    final ticket = await mostrarCobro(context, mesaId: widget.mesaId);
    if (ticket == null || !mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => ResultadoCobroDialog(ticket: ticket),
    );
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _salirDescartando() async {
    final ok = await confirmar(
      context,
      titulo: 'Artículos sin enviar',
      mensaje:
          'Hay ${_pendientes.length} artículos sin enviar a cocina. '
          '¿Salir y descartarlos?',
      textoAceptar: 'Descartar',
      peligroso: true,
    );
    if (!ok || !mounted) return;
    setState(_pendientes.clear);
    Navigator.of(context).pop();
  }
}

/// Pide un texto corto con sugerencias rápidas. Devuelve `null` si se
/// cancela y la cadena (posiblemente vacía) si se acepta.
Future<String?> _pedirTexto(
  BuildContext context, {
  required String titulo,
  String etiqueta = 'Texto',
  String? inicial,
  String textoAceptar = 'Aceptar',
  List<String> sugerencias = const [],
}) {
  return showDialog<String>(
    context: context,
    builder: (context) => _TextoDialog(
      titulo: titulo,
      etiqueta: etiqueta,
      inicial: inicial,
      textoAceptar: textoAceptar,
      sugerencias: sugerencias,
    ),
  );
}

class _TextoDialog extends StatefulWidget {
  const _TextoDialog({
    required this.titulo,
    required this.etiqueta,
    required this.inicial,
    required this.textoAceptar,
    required this.sugerencias,
  });

  final String titulo;
  final String etiqueta;
  final String? inicial;
  final String textoAceptar;
  final List<String> sugerencias;

  @override
  State<_TextoDialog> createState() => _TextoDialogState();
}

class _TextoDialogState extends State<_TextoDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.inicial,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // `scrollable`: con el teclado abierto en un teléfono el contenido se
    // desplaza en lugar de desbordarse.
    return AlertDialog(
      scrollable: true,
      title: Text(widget.titulo),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const Key('texto-dialogo'),
              controller: _controller,
              autofocus: true,
              maxLength: 100,
              decoration: InputDecoration(
                labelText: widget.etiqueta,
                border: const OutlineInputBorder(),
              ),
              onSubmitted: (v) => Navigator.of(context).pop(v.trim()),
            ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final s in widget.sugerencias)
                  ActionChip(
                    label: Text(s),
                    onPressed: () => setState(() => _controller.text = s),
                  ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          key: const Key('texto-aceptar'),
          onPressed: () => Navigator.of(context).pop(_controller.text.trim()),
          child: Text(widget.textoAceptar),
        ),
      ],
    );
  }
}
