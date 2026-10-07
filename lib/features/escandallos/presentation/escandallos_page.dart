import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/repositories/escandallo_repository.dart';
import '../../../core/facturascripts/catalog/catalog_models.dart';
import '../../../core/isolates/escandallos/escandallo_engine.dart';
import '../../../core/money/money.dart';
import '../../host/presentation/providers.dart';
import '../../host/presentation/widgets/host_feedback.dart';
import 'escandallos_providers.dart';

/// Lee un número tecleado con coma o punto decimal (`null` si no es válido).
double? parseNumeroUsuario(String texto) {
  final limpio = texto.trim().replaceAll(',', '.');
  if (limpio.isEmpty) return null;
  final valor = double.tryParse(limpio);
  return (valor == null || !valor.isFinite) ? null : valor;
}

/// Margen bruto sobre el precio neto de venta (0..1), o `null` si no hay
/// precio.
double? margenSobreNeto({required double precioNeto, required double coste}) =>
    precioNeto <= 0 ? null : (precioNeto - coste) / precioNeto;

/// Margen en porcentaje con un decimal y coma: `92,0 %`.
String formatMargen(double margen) =>
    '${(margen * 100).toStringAsFixed(1).replaceFirst('.', ',')} %';

/// Escandallos: recetas por plato (ingrediente, cantidad neta, merma), coste
/// teórico y margen. Requiere MySQL configurado.
class EscandallosPage extends ConsumerWidget {
  const EscandallosPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final gateway = ref.watch(escandallosGatewayProvider);
    if (gateway == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Escandallos')),
        body: const MensajeCentrado(
          icono: Icons.storage,
          titulo: 'Los escandallos necesitan MySQL',
          detalle:
              'Las recetas se guardan en la tabla tpv_escandallos de la base '
              'de datos de FacturaScripts. Configura la conexión MySQL en los '
              'ajustes del TPV para verlas y editarlas.',
        ),
      );
    }
    final recetas = ref.watch(recetasPorPlatoProvider);
    final catalogo = ref.watch(catalogoProvider);
    final costes = ref.watch(costesEscandallosProvider);
    // Sin las recetas leídas no se sabe si el plato ya tiene escandallo: el
    // editor se abriría vacío y, al guardar, sustituiría la receta existente.
    final recetasListas =
        recetas.hasValue && !recetas.hasError && !recetas.isLoading;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Escandallos'),
        actions: [
          IconButton(
            tooltip: 'Recargar',
            onPressed: () => ref.invalidate(recetasPorPlatoProvider),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('nuevo-escandallo'),
        onPressed: recetasListas
            ? () => unawaited(_nuevo(context, ref, catalogo))
            : null,
        icon: const Icon(Icons.add),
        label: const Text('Nuevo escandallo'),
      ),
      body: switch (recetas) {
        AsyncData(:final value) when value.isEmpty => const MensajeCentrado(
          icono: Icons.menu_book_outlined,
          titulo: 'Todavía no hay escandallos',
          detalle:
              'Crea la receta de cada plato para descontar sus materias '
              'primas al venderlo.',
        ),
        AsyncData(:final value) => _Lista(
          recetas: value,
          catalogo: catalogo,
          costes: costes.value,
        ),
        AsyncError(:final error) => MensajeCentrado(
          icono: Icons.error_outline,
          titulo: 'No se pudieron leer los escandallos',
          detalle: mensajeDeError(error),
          accion: FilledButton.icon(
            onPressed: () => ref.invalidate(recetasPorPlatoProvider),
            icon: const Icon(Icons.refresh),
            label: const Text('Reintentar'),
          ),
        ),
        _ => const Center(child: CircularProgressIndicator()),
      },
    );
  }

  Future<void> _nuevo(
    BuildContext context,
    WidgetRef ref,
    CatalogSnapshot? catalogo,
  ) async {
    final plato = await seleccionarArticulo(
      context,
      catalogo: catalogo,
      titulo: 'Plato del escandallo',
      soloVendibles: true,
    );
    if (plato == null || !context.mounted) return;
    // Las recetas vigentes (las espera si se están recargando): sin ellas no
    // se abre el editor, que mostraría vacía una receta que sí existe.
    final Map<String, List<RecetaLinea>> existentes;
    try {
      existentes = await ref.read(recetasPorPlatoProvider.future);
    } on Object catch (error) {
      if (context.mounted) {
        mostrarMensaje(
          context,
          'No se pudieron leer los escandallos: ${mensajeDeError(error)}',
          error: true,
        );
      }
      return;
    }
    if (!context.mounted) return;
    await abrirEditorEscandallo(
      context,
      refPlato: plato,
      lineas: existentes[plato] ?? const [],
    );
  }
}

class _Lista extends StatelessWidget {
  const _Lista({required this.recetas, this.catalogo, this.costes});

  final Map<String, List<RecetaLinea>> recetas;
  final CatalogSnapshot? catalogo;
  final EscandalloResult? costes;

  @override
  Widget build(BuildContext context) {
    final costePorPlato = {
      for (final c in costes?.costes ?? const <CostePlato>[]) c.referencia: c,
    };
    final theme = Theme.of(context);
    final avisos = costes?.avisos ?? const <String>[];
    return ListView(
      padding: const EdgeInsets.only(bottom: 96),
      children: [
        if (catalogo == null)
          const ListTile(
            leading: Icon(Icons.info_outline),
            title: Text(
              'Sin catálogo de FacturaScripts: no se pueden mostrar nombres, '
              'costes ni márgenes.',
            ),
          ),
        for (final MapEntry(key: plato, value: lineas) in recetas.entries)
          _filaPlato(context, plato, lineas, costePorPlato[plato], theme),
        if (avisos.isNotEmpty) ...[
          const Divider(),
          for (final aviso in avisos)
            ListTile(
              dense: true,
              leading: const Icon(Icons.warning_amber),
              title: Text(aviso),
            ),
        ],
      ],
    );
  }

  Widget _filaPlato(
    BuildContext context,
    String plato,
    List<RecetaLinea> lineas,
    CostePlato? coste,
    ThemeData theme,
  ) {
    final articulo = catalogo?.porReferencia(plato);
    final partes = <String>[
      plato,
      '${lineas.length} ${lineas.length == 1 ? 'ingrediente' : 'ingredientes'}',
    ];
    if (coste != null) {
      partes.add(
        'coste ${formatCents(centsFromDecimal(coste.costeUnitario))}'
        '${coste.completo ? '' : ' (incompleto)'}',
      );
      final margen = articulo == null
          ? null
          : margenSobreNeto(
              precioNeto: articulo.precioNeto,
              coste: coste.costeUnitario,
            );
      if (margen != null) {
        partes.add('margen ${formatMargen(margen)}');
      }
    }
    return ListTile(
      key: Key('plato-$plato'),
      leading: const Icon(Icons.restaurant_menu),
      title: Text(articulo?.descripcion ?? plato),
      subtitle: Text(partes.join(' · ')),
      trailing: articulo == null ? null : Text(formatCents(articulo.pvpCents)),
      onTap: () => unawaited(
        abrirEditorEscandallo(context, refPlato: plato, lineas: lineas),
      ),
    );
  }
}

/// Abre el editor de la receta de [refPlato].
Future<void> abrirEditorEscandallo(
  BuildContext context, {
  required String refPlato,
  required List<RecetaLinea> lineas,
}) => Navigator.of(context).push(
  MaterialPageRoute<void>(
    builder: (_) => EscandalloEditorPage(refPlato: refPlato, lineas: lineas),
  ),
);

class _LineaEditable {
  _LineaEditable({
    required this.refIngrediente,
    required String cantidad,
    required String merma,
  }) : cantidad = TextEditingController(text: cantidad),
       merma = TextEditingController(text: merma);

  final String refIngrediente;
  final TextEditingController cantidad;
  final TextEditingController merma;

  void dispose() {
    cantidad.dispose();
    merma.dispose();
  }
}

/// Editor de la receta de un plato: ingredientes, cantidad neta y merma.
class EscandalloEditorPage extends ConsumerStatefulWidget {
  const EscandalloEditorPage({
    super.key,
    required this.refPlato,
    required this.lineas,
  });

  final String refPlato;
  final List<RecetaLinea> lineas;

  @override
  ConsumerState<EscandalloEditorPage> createState() =>
      _EscandalloEditorPageState();
}

class _EscandalloEditorPageState extends ConsumerState<EscandalloEditorPage> {
  late final List<_LineaEditable> _lineas = [
    for (final l in widget.lineas)
      _LineaEditable(
        refIngrediente: l.refIngrediente,
        cantidad: formatQuantity(l.cantidadNeta, maxDecimals: 6),
        merma: formatQuantity(l.mermaPct, maxDecimals: 2),
      ),
  ];
  bool _guardando = false;

  @override
  void dispose() {
    for (final l in _lineas) {
      l.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final catalogo = ref.watch(catalogoProvider);
    final plato = catalogo?.porReferencia(widget.refPlato);
    final costes = <String, double>{
      for (final a in catalogo?.articulos ?? const <ArticuloCatalogo>[])
        if (a.coste > 0) a.referencia: a.coste,
    };
    final coste = _costeDirecto(costes);
    final margen = (plato == null || coste == null)
        ? null
        : margenSobreNeto(precioNeto: plato.precioNeto, coste: coste);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text('Receta de ${plato?.descripcion ?? widget.refPlato}'),
        actions: [
          if (widget.lineas.isNotEmpty)
            IconButton(
              key: const Key('borrar-escandallo'),
              tooltip: 'Borrar la receta',
              onPressed: _guardando ? null : () => unawaited(_borrar()),
              icon: const Icon(Icons.delete_outline),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'Cantidad neta por unidad de plato, en la unidad de stock del '
            'ingrediente. La merma es el % que se pierde al limpiar: sale del '
            'almacén neta / (1 − merma/100).',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 12),
          for (final (i, l) in _lineas.indexed)
            _filaIngrediente(context, i, l, catalogo, costes),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              key: const Key('anadir-ingrediente'),
              onPressed: _guardando
                  ? null
                  : () => unawaited(_anadirIngrediente(catalogo)),
              icon: const Icon(Icons.add),
              label: const Text('Añadir ingrediente'),
            ),
          ),
          const SizedBox(height: 16),
          if (coste != null)
            Text(
              'Coste teórico directo: ${formatCents(centsFromDecimal(coste))}'
              '${margen == null ? '' : ' · margen ${formatMargen(margen)} sobre '
                        '${formatCents(centsFromDecimal(plato!.precioNeto))} sin IVA'}',
              key: const Key('coste-teorico'),
              style: theme.textTheme.titleMedium,
            )
          else
            Text(
              'Sin costes de compra en el catálogo para calcular el coste '
              'teórico.',
              style: theme.textTheme.bodySmall,
            ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: FilledButton.icon(
            key: const Key('guardar-escandallo'),
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(56),
            ),
            onPressed: _guardando ? null : () => unawaited(_guardar()),
            icon: _guardando
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.save),
            label: const Text('Guardar receta'),
          ),
        ),
      ),
    );
  }

  /// Coste con los ingredientes directos (sin expandir subrecetas); `null`
  /// si ningún ingrediente tiene coste o hay datos no válidos.
  double? _costeDirecto(Map<String, double> costes) {
    if (costes.isEmpty || _lineas.isEmpty) return null;
    var total = 0.0;
    var alguno = false;
    for (final l in _lineas) {
      final cantidad = parseNumeroUsuario(l.cantidad.text);
      final merma = parseNumeroUsuario(l.merma.text) ?? 0;
      final unitario = costes[l.refIngrediente];
      if (cantidad == null || unitario == null || merma >= 100 || merma < 0) {
        continue;
      }
      alguno = true;
      total += unitario * cantidad / (1 - merma / 100);
    }
    return alguno ? total : null;
  }

  Widget _filaIngrediente(
    BuildContext context,
    int indice,
    _LineaEditable l,
    CatalogSnapshot? catalogo,
    Map<String, double> costes,
  ) {
    final articulo = catalogo?.porReferencia(l.refIngrediente);
    final unitario = costes[l.refIngrediente];
    return Card(
      key: Key('ingrediente-${l.refIngrediente}'),
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Wrap(
          spacing: 12,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SizedBox(
              width: 240,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    articulo?.descripcion ?? l.refIngrediente,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  Text(
                    '${l.refIngrediente}'
                    '${unitario == null ? '' : ' · ${formatCents(centsFromDecimal(unitario))}/ud'}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            SizedBox(
              width: 140,
              child: TextField(
                key: Key('cantidad-${l.refIngrediente}'),
                controller: l.cantidad,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  labelText: 'Cantidad neta',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ),
            SizedBox(
              width: 110,
              child: TextField(
                key: Key('merma-${l.refIngrediente}'),
                controller: l.merma,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  labelText: 'Merma %',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ),
            IconButton(
              tooltip: 'Quitar ingrediente',
              onPressed: _guardando
                  ? null
                  : () => setState(() => _lineas.removeAt(indice).dispose()),
              icon: const Icon(Icons.remove_circle_outline),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _anadirIngrediente(CatalogSnapshot? catalogo) async {
    final referencia = await seleccionarArticulo(
      context,
      catalogo: catalogo,
      titulo: 'Ingrediente',
      excluir: {widget.refPlato, for (final l in _lineas) l.refIngrediente},
    );
    if (referencia == null || !mounted) return;
    setState(
      () => _lineas.add(
        _LineaEditable(refIngrediente: referencia, cantidad: '', merma: '0'),
      ),
    );
  }

  /// Valida y convierte; lanza `ValidationException` con el primer error.
  List<RecetaLinea> _construir() => [
    for (final l in _lineas)
      () {
        final linea = RecetaLinea(
          refPlato: widget.refPlato,
          refIngrediente: l.refIngrediente,
          cantidadNeta: parseNumeroUsuario(l.cantidad.text) ?? double.nan,
          mermaPct: parseNumeroUsuario(l.merma.text) ?? 0,
        );
        EscandalloRepository.validate(linea);
        return linea;
      }(),
  ];

  /// Guardar sin ingredientes una receta que los tenía equivale a borrarla:
  /// pasa por la misma confirmación.
  Future<void> _guardar() => _lineas.isEmpty && widget.lineas.isNotEmpty
      ? _borrar()
      : _persistir(() => _construir(), exito: 'Receta guardada');

  Future<void> _borrar() async {
    final ok = await confirmar(
      context,
      titulo: 'Borrar receta',
      mensaje:
          'El plato dejará de descontar materias primas al venderse. ¿Borrar '
          'su escandallo?',
      textoAceptar: 'Borrar',
      peligroso: true,
    );
    if (!ok || !mounted) return;
    await _persistir(() => const [], exito: 'Receta borrada');
  }

  Future<void> _persistir(
    List<RecetaLinea> Function() lineas, {
    required String exito,
  }) async {
    final gateway = ref.read(escandallosGatewayProvider);
    if (gateway == null) return;
    setState(() => _guardando = true);
    final hecho = await ejecutarAccion(context, () async {
      await gateway.guardarPlato(widget.refPlato, lineas());
      ref.invalidate(recetasPorPlatoProvider);
      // El host cachea las recetas: que el próximo descuento use las nuevas.
      final runtime = ref.read(hostRuntimeProvider).value;
      if (runtime != null) {
        unawaited(
          runtime.stock.recetasVigentes(forzar: true).catchError((Object _) {
            return null;
          }),
        );
      }
    }, exito: exito);
    if (!mounted) return;
    setState(() => _guardando = false);
    if (hecho) Navigator.of(context).pop();
  }
}

/// Elige un artículo del catálogo (o teclea una referencia si no lo hay).
/// Devuelve la referencia o `null` si se cancela.
Future<String?> seleccionarArticulo(
  BuildContext context, {
  required CatalogSnapshot? catalogo,
  required String titulo,
  bool soloVendibles = false,
  Set<String> excluir = const {},
}) => showDialog<String>(
  context: context,
  builder: (_) => _SelectorArticulo(
    catalogo: catalogo,
    titulo: titulo,
    soloVendibles: soloVendibles,
    excluir: excluir,
  ),
);

class _SelectorArticulo extends StatefulWidget {
  const _SelectorArticulo({
    required this.catalogo,
    required this.titulo,
    required this.soloVendibles,
    required this.excluir,
  });

  final CatalogSnapshot? catalogo;
  final String titulo;
  final bool soloVendibles;
  final Set<String> excluir;

  @override
  State<_SelectorArticulo> createState() => _SelectorArticuloState();
}

class _SelectorArticuloState extends State<_SelectorArticulo> {
  final TextEditingController _texto = TextEditingController();

  static const int _maxResultados = 60;

  @override
  void dispose() {
    _texto.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final consulta = _texto.text.trim();
    final minus = consulta.toLowerCase();
    final fuente = widget.soloVendibles
        ? widget.catalogo?.vendibles
        : widget.catalogo?.articulos;
    final resultados = [
      for (final a in fuente ?? const <ArticuloCatalogo>[])
        if (!widget.excluir.contains(a.referencia) &&
            (minus.isEmpty ||
                a.descripcion.toLowerCase().contains(minus) ||
                a.referencia.toLowerCase().contains(minus)))
          a,
    ];
    final exacta = resultados.any((a) => a.referencia == consulta);
    final manualValida =
        consulta.isNotEmpty &&
        !exacta &&
        consulta.length <= EscandalloRepository.maxReferenciaLength &&
        !widget.excluir.contains(consulta);

    return AlertDialog(
      title: Text(widget.titulo),
      content: SizedBox(
        width: 480,
        height: 420,
        child: Column(
          children: [
            TextField(
              key: const Key('selector-buscar'),
              controller: _texto,
              autofocus: true,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Descripción o referencia',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView(
                children: [
                  if (manualValida)
                    ListTile(
                      key: const Key('selector-manual'),
                      leading: const Icon(Icons.keyboard),
                      title: Text('Usar la referencia "$consulta"'),
                      onTap: () => Navigator.of(context).pop(consulta),
                    ),
                  for (final a in resultados.take(_maxResultados))
                    ListTile(
                      key: Key('selector-${a.referencia}'),
                      title: Text(a.descripcion),
                      subtitle: Text(a.referencia),
                      onTap: () => Navigator.of(context).pop(a.referencia),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
      ],
    );
  }
}
