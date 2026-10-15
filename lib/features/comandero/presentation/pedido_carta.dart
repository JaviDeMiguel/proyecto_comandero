/// Carta del comandero: selector del pase de las líneas nuevas, buscador,
/// familias como pestañas y rejilla de artículos.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/facturascripts/catalog/catalog_models.dart';
import '../../../core/money/money.dart';
import '../../sala/domain/pases.dart';
import '../../sala/presentation/selector_pase.dart';

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

/// Carta de la toma de pedido.
///
/// Con [pases] activos muestra encima del buscador los chips [SelectorPase]
/// (clave `pedido.pases`) en una sola fila, desplazable a lo ancho si no
/// caben, con el pase que llevarán las líneas nuevas ([paseActivo], `null` =
/// directo); el estado lo guarda la página, que recibe los cambios por
/// [onCambioPase]. Con un host antiguo o los pases desactivados no hay chips.
///
/// Si no le llega el alto para la cabecera y una fila de artículos (un
/// teléfono en horizontal o con el teclado abierto), la carta entera se
/// desplaza en vertical en lugar de desbordar.
class PanelCarta extends StatefulWidget {
  const PanelCarta({
    super.key,
    required this.catalogo,
    required this.focoBusqueda,
    required this.onAnadir,
    required this.onAnadirConDetalle,
    this.pases,
    this.paseActivo,
    this.onCambioPase,
  });

  final CatalogSnapshot? catalogo;
  final FocusNode focoBusqueda;
  final void Function(ArticuloCatalogo articulo) onAnadir;
  final void Function(ArticuloCatalogo articulo) onAnadirConDetalle;

  /// Configuración de pases del host; `null` oculta el selector.
  final PasesConfig? pases;

  /// Pase de las líneas nuevas (`null` = directo).
  final int? paseActivo;
  final ValueChanged<int?>? onCambioPase;

  @override
  State<PanelCarta> createState() => _PanelCartaState();
}

class _PanelCartaState extends State<PanelCarta> {
  /// Alto con el que caben la cabecera (pases, buscador y familias) y una
  /// fila de artículos; con menos, la carta se desplaza entera.
  static const double _altoMinimo = 260;

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
    final pases = widget.pases;
    final onCambioPase = widget.onCambioPase;

    final columna = Column(
      children: [
        if (pases != null && pases.activos && onCambioPase != null)
          // Una sola fila: en varias líneas se comería la rejilla en un
          // teléfono. Los pases que no caben se alcanzan desplazándola.
          SingleChildScrollView(
            key: const Key('pedido.pases'),
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: SelectorPase(
              pases: pases,
              seleccionado: widget.paseActivo,
              onCambio: onCambioPase,
              compacto: true,
            ),
          ),
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
    // El mismo árbol con alto de sobra o escaso (el buscador no se recrea
    // al abrir el teclado): con alto de sobra no hay nada que desplazar.
    // `primary: false` deja el controlador principal a la rejilla, como antes.
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        primary: false,
        child: SizedBox(
          height: math.max(constraints.maxHeight, _altoMinimo),
          child: columna,
        ),
      ),
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
