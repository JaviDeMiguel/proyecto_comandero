import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../core/facturascripts/catalog/catalog_models.dart';
import '../../../core/money/money.dart';
import '../../sala/domain/comanda.dart';
import '../../sala/domain/linea_comanda.dart';
import '../../sala/domain/mesa.dart';
import '../../sala/domain/pases.dart';
import '../../sala/domain/precuenta_emitida.dart';
import '../../sala/presentation/comensales_dialog.dart';
import '../../sala/presentation/selector_pase.dart';
import '../../sala/protocol/sala_messages.dart';
import 'cobro_dialog.dart';
import 'impresion_providers.dart';
import 'providers.dart';
import 'widgets/catalogo_panel.dart';
import 'widgets/comanda_por_pases.dart';
import 'widgets/host_feedback.dart';
import 'widgets/host_formatos.dart';
import 'widgets/reimprimir_comanda_dialog.dart';
import 'widgets/texto_dialog.dart';

const Uuid _uuid = Uuid();

/// Ancho a partir del cual la carta se muestra junto a la comanda.
const double kAnchoComandaYCarta = 840;

/// Artículo añadido en el TPV y aún no enviado a cocina. Su [id] es el de la
/// futura [LineaComanda]: reenviar tras un error no duplica la línea.
final class _Pendiente {
  _Pendiente({required this.articulo, this.pase}) : id = _uuid.v4();

  final String id;
  final ArticuloCatalogo articulo;
  double cantidad = 1;
  String? nota;

  /// Pase de la línea (`null` = directa).
  int? pase;

  int get importeCents => lineTotalCents(articulo.pvpCents, cantidad);
}

/// Comanda de una mesa: líneas agrupadas por pase, alta de artículos desde
/// la carta, marchas, anulación, comensales, cuenta, precuenta, reimpresión
/// y cobro.
class MesaPage extends ConsumerStatefulWidget {
  const MesaPage({super.key, required this.mesaId});

  final String mesaId;

  @override
  ConsumerState<MesaPage> createState() => _MesaPageState();
}

class _MesaPageState extends ConsumerState<MesaPage> {
  final List<_Pendiente> _pendientes = [];

  /// Pase al que van los artículos que se añaden (`null` = directo). Lo
  /// comparten la carta de la vista ancha y la de la ruta estrecha.
  final ValueNotifier<int?> _paseActivo = ValueNotifier<int?>(null);

  /// Pases con una marcha esperando respuesta.
  final Set<int> _marchando = {};
  bool _enviando = false;

  /// Comensales de una mesa libre: van en el primer envío.
  int? _comensales;

  int get _importePendiente =>
      _pendientes.fold(0, (total, p) => total + p.importeCents);

  @override
  void dispose() {
    _paseActivo.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = ref.watch(hostSnapshotProvider).value;
    final mesa = snapshot?.mesaPorId(widget.mesaId);
    final comanda = snapshot?.comandaDeMesa(widget.mesaId);
    final pases = ref.watch(pasesConfigProvider);
    // Con comanda mandan sus comensales: los de la mesa libre se descartan.
    if (comanda != null) _comensales = null;

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
      canPop: _pendientes.isEmpty && _comensales == null,
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
            final panelComanda = _panelComanda(context, mesa, comanda, pases);
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

  /// Carta con el selector de pase encima (solo con los pases activos).
  Widget _panelCarta(
    BuildContext context,
    WidgetRef ref, {
    ValueChanged<ArticuloCatalogo>? onArticulo,
  }) {
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
    final pases = ref.watch(pasesConfigProvider);
    return CatalogoPanel(
      catalogo: catalogo,
      onArticulo: onArticulo ?? _anadir,
      encabezado: pases.activos
          ? ValueListenableBuilder<int?>(
              valueListenable: _paseActivo,
              builder: (context, pase, _) => SelectorPase(
                pases: pases,
                seleccionado: pase,
                onCambio: (nuevo) => _paseActivo.value = nuevo,
              ),
            )
          : null,
    );
  }

  Widget _panelComanda(
    BuildContext context,
    Mesa mesa,
    Comanda? comanda,
    PasesConfig pases,
  ) {
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
          _cabecera(context, comanda),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 8),
              children: [
                if (_pendientes.isNotEmpty) ...[
                  _titulo(context, 'Sin enviar'),
                  ..._filasPendientes(pases),
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
                if (comanda != null && lineas.isNotEmpty) ...[
                  _titulo(context, 'Comanda'),
                  ComandaPorPases(
                    comanda: comanda,
                    pases: pases,
                    onAnular: (l) => unawaited(_anular(mesa, l)),
                    onMarchar: (pase, {required repetir}) => unawaited(
                      _marchar(mesa, comanda, pase, repetir: repetir),
                    ),
                    pasesMarchando: _marchando,
                  ),
                ],
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
                        if (hayLineas)
                          OutlinedButton.icon(
                            key: const Key('reimprimir-comanda'),
                            onPressed: () =>
                                unawaited(_reimprimir(mesa, comanda)),
                            icon: const Icon(Icons.replay),
                            label: const Text('Reimprimir comanda'),
                          ),
                        if (comanda != null)
                          TextButton.icon(
                            key: const Key('vaciar-mesa'),
                            onPressed: () => unawaited(_vaciar(mesa, comanda)),
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

  /// Camarero, comensales (chip `editar-comensales`, también con la mesa
  /// libre) y si se ha pedido la cuenta.
  Widget _cabecera(BuildContext context, Comanda? comanda) {
    final comensales = comanda?.comensales ?? _comensales;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Wrap(
        spacing: 8,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (comanda?.camarero case final camarero?)
            Text('Camarero: $camarero'),
          ActionChip(
            key: const Key('editar-comensales'),
            avatar: const Icon(Icons.people_outline),
            label: Text(
              comensales == null ? 'Comensales' : '$comensales comensales',
            ),
            onPressed: () => unawaited(_editarComensales(comanda)),
          ),
          if (comanda?.cuentaSolicitada ?? false)
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

  /// «Sin enviar», agrupado por pase como la comanda (cabeceras
  /// `pendientes-pase-directo` / `pendientes-pase-<n>`).
  Iterable<Widget> _filasPendientes(PasesConfig pases) sync* {
    if (!pases.activos && _pendientes.every((p) => p.pase == null)) {
      yield* _pendientes.map((p) => _filaPendiente(p, pases));
      return;
    }
    for (final grupo in agruparPorPaseDe(_pendientes, (p) => p.pase)) {
      yield CabeceraPase(
        key: Key('pendientes-pase-${grupo.pase ?? 'directo'}'),
        texto: pases.etiqueta(grupo.pase),
      );
      yield* grupo.elementos.map((p) => _filaPendiente(p, pases));
    }
  }

  // El id distingue dos filas del mismo artículo (otra nota u otro pase).
  Widget _filaPendiente(_Pendiente p, PasesConfig pases) => FilaPendiente(
    key: ValueKey(p.id),
    referencia: p.articulo.referencia,
    descripcion: p.articulo.descripcion,
    cantidad: p.cantidad,
    importeCents: p.importeCents,
    nota: p.nota,
    pase: p.pase,
    pases: pases,
    habilitada: !_enviando,
    onCantidad: (delta) => _cambiarCantidad(p, delta),
    onPase: (pase) => setState(() => p.pase = pase),
    onNota: () => unawaited(_editarNota(p)),
  );

  // ---------------------------------------------------------------------------
  // Acciones

  /// Añade el artículo al pase activo, sumándolo a una fila sin nota del
  /// mismo artículo y pase si la hay.
  void _anadir(ArticuloCatalogo articulo) {
    if (_enviando) return;
    final pase = ref.read(pasesConfigProvider).activos
        ? _paseActivo.value
        : null;
    setState(() {
      for (final p in _pendientes) {
        if (p.articulo.referencia == articulo.referencia &&
            p.nota == null &&
            p.pase == pase) {
          p.cantidad += 1;
          return;
        }
      }
      _pendientes.add(_Pendiente(articulo: articulo, pase: pase));
    });
  }

  void _cambiarCantidad(_Pendiente p, int delta) {
    setState(() {
      p.cantidad += delta;
      if (p.cantidad <= 0) _pendientes.remove(p);
    });
  }

  Future<void> _editarNota(_Pendiente p) async {
    final nota = await pedirTexto(
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
              builder: (context, ref, _) => _panelCarta(
                context,
                ref,
                onArticulo: (a) {
                  _anadir(a);
                  mostrarMensaje(
                    context,
                    'Añadido: ${a.descripcion}',
                    duracion: const Duration(seconds: 1),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Envía lo pendiente con el pase de cada línea, el TPV como camarero y,
  /// si la mesa estaba libre, sus comensales (§5.1, §5.14).
  Future<void> _enviar() async {
    if (_pendientes.isEmpty) return;
    setState(() => _enviando = true);
    final ahora = ref.read(relojProvider)();
    final enviados = List.of(_pendientes);
    final payload = ComandaSubmitPayload(
      mesaId: widget.mesaId,
      camarero: ref.read(nombreTpvProvider),
      // Los de la mesa libre, solo si sigue libre: si otro camarero la abrió,
      // no se pisan los comensales de su comanda.
      comensales:
          ref.read(salaServiceProvider).comandaDeMesa(widget.mesaId) == null
          ? _comensales
          : null,
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
            pase: p.pase,
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
      if (ok) {
        _pendientes.removeWhere(enviados.contains);
        _comensales = null;
      }
    });
  }

  Future<void> _anular(Mesa mesa, LineaComanda linea) async {
    final motivo = await pedirTexto(
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

  /// Marcha el [pase] (o lo vuelve a marchar: el host lo imprime REPETIDO).
  /// Mientras espera respuesta, el pase no admite otra marcha, y «Marchar»
  /// sobre un pase que ya está en marcha (un botón aún sin redibujar) no
  /// hace nada.
  Future<void> _marchar(
    Mesa mesa,
    Comanda comanda,
    int pase, {
    required bool repetir,
  }) async {
    if (_marchando.contains(pase)) return;
    final actual = ref.read(salaServiceProvider).comandaDeMesa(mesa.id);
    if (!repetir && actual?.ultimaMarchaDe(pase) != null) return;
    setState(() => _marchando.add(pase));
    final pases = ref.read(pasesConfigProvider);
    await ejecutarAccion(
      context,
      () => ref
          .read(salaServiceProvider)
          .marcharPase(
            mesa.id,
            pase,
            marchaId: _uuid.v4(),
            comandaId: comanda.id,
            camarero: ref.read(nombreTpvProvider),
          ),
      exito: mensajeMarcha(pases, pase, repetir: repetir),
    );
    if (mounted) setState(() => _marchando.remove(pase));
  }

  /// Con comanda, fija sus comensales en el host; con la mesa libre, los
  /// guarda para el primer envío.
  Future<void> _editarComensales(Comanda? comanda) async {
    final n = await pedirComensales(
      context,
      inicial: comanda?.comensales ?? _comensales,
    );
    if (n == null || !mounted) return;
    if (ref.read(salaServiceProvider).comandaDeMesa(widget.mesaId) == null) {
      setState(() => _comensales = n);
      return;
    }
    await ejecutarAccion(
      context,
      () => ref
          .read(salaServiceProvider)
          .fijarComensales(
            widget.mesaId,
            n,
            camarero: ref.read(nombreTpvProvider),
          ),
      exito: '$n comensales',
    );
  }

  Future<void> _marcarCuenta(Comanda comanda) => ejecutarAccion(
    context,
    () => ref
        .read(salaServiceProvider)
        .marcarCuenta(widget.mesaId, !comanda.cuentaSolicitada),
  );

  /// Reimprime la comanda en los puestos, con el alcance y el motivo que se
  /// elijan en el diálogo (§5.10). No escribe nada en el diario.
  Future<void> _reimprimir(Mesa mesa, Comanda comanda) =>
      reimprimirComandaDeMesa(context, ref, mesa: mesa, comanda: comanda);

  /// Registra una precuenta de la mesa (documento sin validez fiscal, con nº
  /// correlativo en la comanda) y la imprime (§5.8). Primero se registra y
  /// después se imprime: si la impresión falla, la precuenta queda registrada
  /// y el mensaje lo dice.
  Future<void> _imprimirPrecuenta(Mesa mesa, Comanda _) async {
    final printing = ref.read(printingServiceProvider);
    if (!printing.hayImpresoraTickets) {
      mostrarMensaje(
        context,
        'No hay impresora de tickets configurada',
        error: true,
      );
      return;
    }
    PrecuentaEmitida? registrada;
    final ok = await ejecutarAccion(context, () async {
      registrada = await ref
          .read(salaServiceProvider)
          .emitirPrecuenta(mesa.id, emitidaPor: ref.read(nombreTpvProvider));
    });
    final precuenta = registrada;
    // Registrada la precuenta, se imprime aunque la página se haya cerrado
    // mientras tanto: solo los mensajes necesitan la página montada.
    if (!ok || precuenta == null) return;
    try {
      await printing.imprimirPrecuenta(precuenta, zona: mesa.zona);
      if (mounted) {
        mostrarMensaje(
          context,
          'Precuenta nº ${precuenta.numero} enviada a la impresora',
        );
      }
    } on Object catch (error) {
      if (mounted) {
        mostrarMensaje(
          context,
          'La precuenta nº ${precuenta.numero} quedó registrada, pero no se '
          'pudo imprimir: ${mensajeDeError(error)}',
          error: true,
        );
      }
    }
  }

  /// Vacía la mesa tras confirmar; si la comanda tiene precuentas, avisa de
  /// que quedarán como precuentas sin cobro (§5.8).
  Future<void> _vaciar(Mesa mesa, Comanda comanda) async {
    final precuentas = comanda.precuentas.length;
    final aviso = switch (precuentas) {
      0 => '',
      1 =>
        '\n\nTiene 1 precuenta impresa: quedará registrada como precuenta '
            'sin cobro y saldrá en el Cierre Z.',
      _ =>
        '\n\nTiene $precuentas precuentas impresas: quedarán registradas '
            'como precuentas sin cobro y saldrán en el Cierre Z.',
    };
    final ok = await confirmar(
      context,
      titulo: 'Vaciar ${mesa.nombre}',
      mensaje:
          'Se anularán todas las líneas sin cobrar y se devolverá su stock. '
          'Esta acción no se puede deshacer.$aviso',
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
      titulo: _pendientes.isEmpty
          ? 'Comensales sin guardar'
          : 'Artículos sin enviar',
      mensaje: _pendientes.isEmpty
          ? 'Los $_comensales comensales no se guardan hasta enviar algo a '
                'la mesa. ¿Salir y descartarlos?'
          : 'Hay ${_pendientes.length} artículos sin enviar a cocina. '
                '¿Salir y descartarlos?',
      textoAceptar: 'Descartar',
      peligroso: true,
    );
    if (!ok || !mounted) return;
    setState(() {
      _pendientes.clear();
      _comensales = null;
    });
    Navigator.of(context).pop();
  }
}
