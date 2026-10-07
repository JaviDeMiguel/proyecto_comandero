import 'package:flutter/material.dart';

import '../../../../core/facturascripts/catalog/catalog_models.dart';
import '../../../../core/money/money.dart';

/// Filtra los artículos vendibles por familia (nula = todas) y por texto
/// (descripción o referencia que lo contengan, o código de barras exacto).
List<ArticuloCatalogo> filtrarArticulos(
  CatalogSnapshot catalogo, {
  String? codfamilia,
  String texto = '',
}) {
  final consulta = texto.trim().toLowerCase();
  final resultado = [
    for (final a in catalogo.vendibles)
      if ((codfamilia == null || a.codfamilia == codfamilia) &&
          (consulta.isEmpty ||
              a.descripcion.toLowerCase().contains(consulta) ||
              a.referencia.toLowerCase().contains(consulta) ||
              a.codbarras == texto.trim()))
        a,
  ]..sort((a, b) => a.descripcion.compareTo(b.descripcion));
  return resultado;
}

/// Carta del TPV: buscador, familias y rejilla de artículos táctiles. Cada
/// artículo lleva la clave `articulo-<referencia>`.
class CatalogoPanel extends StatefulWidget {
  const CatalogoPanel({
    super.key,
    required this.catalogo,
    required this.onArticulo,
  });

  final CatalogSnapshot catalogo;
  final ValueChanged<ArticuloCatalogo> onArticulo;

  @override
  State<CatalogoPanel> createState() => _CatalogoPanelState();
}

class _CatalogoPanelState extends State<CatalogoPanel> {
  final TextEditingController _buscar = TextEditingController();
  String? _familia;

  @override
  void dispose() {
    _buscar.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final catalogo = widget.catalogo;
    final conArticulos = {for (final a in catalogo.vendibles) a.codfamilia};
    final familias = [
      for (final f in catalogo.familias)
        if (conArticulos.contains(f.codfamilia)) f,
    ]..sort((a, b) => a.descripcion.compareTo(b.descripcion));
    final articulos = filtrarArticulos(
      catalogo,
      codfamilia: _familia,
      texto: _buscar.text,
    );
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
          child: TextField(
            key: const Key('buscar-articulo'),
            controller: _buscar,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search),
              hintText: 'Buscar artículo o código de barras',
              border: const OutlineInputBorder(),
              isDense: true,
              suffixIcon: _buscar.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Borrar búsqueda',
                      icon: const Icon(Icons.clear),
                      onPressed: () => setState(_buscar.clear),
                    ),
            ),
          ),
        ),
        SizedBox(
          height: 56,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            children: [
              ChoiceChip(
                label: const Text('Todas'),
                selected: _familia == null,
                onSelected: (_) => setState(() => _familia = null),
              ),
              for (final f in familias) ...[
                const SizedBox(width: 8),
                ChoiceChip(
                  key: Key('familia-${f.codfamilia}'),
                  label: Text(f.descripcion),
                  selected: _familia == f.codfamilia,
                  onSelected: (_) => setState(() => _familia = f.codfamilia),
                ),
              ],
            ],
          ),
        ),
        Expanded(
          child: articulos.isEmpty
              ? Center(
                  child: Text(
                    'No hay artículos que coincidan',
                    style: theme.textTheme.bodyLarge,
                  ),
                )
              : GridView.builder(
                  padding: const EdgeInsets.all(12),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 170,
                    mainAxisExtent: 88,
                    crossAxisSpacing: 8,
                    mainAxisSpacing: 8,
                  ),
                  itemCount: articulos.length,
                  itemBuilder: (context, i) {
                    final a = articulos[i];
                    return FilledButton.tonal(
                      key: Key('articulo-${a.referencia}'),
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.all(8),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      onPressed: () => widget.onArticulo(a),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            a.descripcion,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            formatCents(a.pvpCents),
                            style: theme.textTheme.labelLarge,
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
