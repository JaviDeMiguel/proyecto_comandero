import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/facturascripts/catalog/catalog_models.dart';
import '../../sala/domain/enrutamiento_comandas.dart';
import '../../sala/domain/linea_comanda.dart' show DestinoPreparacion;
import '../../settings/domain/app_settings.dart';
import '../../settings/presentation/settings_providers.dart';
import 'providers.dart';
import 'widgets/host_feedback.dart';

/// Familia del catálogo con su profundidad en el árbol (0 = raíz).
typedef FamiliaEnArbol = ({FamiliaCatalogo familia, int nivel});

/// Ordena [familias] como un árbol (cada madre seguida de sus subfamilias,
/// por descripción). Las familias cuya madre no existe en el catálogo se
/// tratan como raíces y las atrapadas en un ciclo (datos corruptos del ERP)
/// se añaden al final como raíces, de modo que ninguna se queda fuera.
List<FamiliaEnArbol> ordenarArbolFamilias(List<FamiliaCatalogo> familias) {
  final porCodigo = {for (final f in familias) f.codfamilia: f};
  final hijas = <String, List<FamiliaCatalogo>>{};
  final raices = <FamiliaCatalogo>[];
  for (final familia in familias) {
    final madre = familia.madre?.trim();
    if (madre == null ||
        madre.isEmpty ||
        madre == familia.codfamilia ||
        !porCodigo.containsKey(madre)) {
      raices.add(familia);
    } else {
      hijas.putIfAbsent(madre, () => []).add(familia);
    }
  }
  int porNombre(FamiliaCatalogo a, FamiliaCatalogo b) =>
      a.descripcion.toLowerCase().compareTo(b.descripcion.toLowerCase());

  final resultado = <FamiliaEnArbol>[];
  final vistas = <String>{};
  void visitar(FamiliaCatalogo familia, int nivel) {
    if (!vistas.add(familia.codfamilia)) return;
    resultado.add((familia: familia, nivel: nivel));
    final suyas = [...?hijas[familia.codfamilia]]..sort(porNombre);
    for (final hija in suyas) {
      visitar(hija, nivel + 1);
    }
  }

  for (final raiz in [...raices]..sort(porNombre)) {
    visitar(raiz, 0);
  }
  final enCiclo = [
    for (final f in familias)
      if (!vistas.contains(f.codfamilia)) f,
  ]..sort(porNombre);
  for (final familia in enCiclo) {
    visitar(familia, 0);
  }
  return resultado;
}

/// Texto del destino para la interfaz.
String nombreDestino(DestinoPreparacion destino) => switch (destino) {
  DestinoPreparacion.cocina => 'Cocina',
  DestinoPreparacion.barra => 'Barra',
};

/// Opción del selector de cada familia: un destino propio o heredar.
enum _Opcion { cocina, barra, heredar }

_Opcion _opcionDe(DestinoPreparacion? regla) => switch (regla) {
  DestinoPreparacion.cocina => _Opcion.cocina,
  DestinoPreparacion.barra => _Opcion.barra,
  null => _Opcion.heredar,
};

DestinoPreparacion? _reglaDe(_Opcion opcion) => switch (opcion) {
  _Opcion.cocina => DestinoPreparacion.cocina,
  _Opcion.barra => DestinoPreparacion.barra,
  _Opcion.heredar => null,
};

/// Enrutamiento de comandas: qué familias del catálogo se preparan en
/// cocina y cuáles en barra.
///
/// Muestra el árbol de familias del catálogo del host con un selector por
/// familia (Cocina / Barra / Heredar) y el destino efectivo resultante, el
/// destino por defecto y el estado de las impresoras de comandas. Guarda en
/// los ajustes de impresión; el host lo aplica en caliente a las líneas que
/// acepte a partir de entonces.
class EnrutamientoPage extends ConsumerStatefulWidget {
  const EnrutamientoPage({super.key});

  @override
  ConsumerState<EnrutamientoPage> createState() => _EnrutamientoPageState();
}

class _EnrutamientoPageState extends ConsumerState<EnrutamientoPage> {
  /// Copia de trabajo; `null` hasta que cargan los ajustes.
  EnrutamientoComandas? _borrador;
  bool _guardando = false;

  bool _modificado(AppSettings ajustes) =>
      _borrador != null && _borrador != ajustes.impresion.enrutamiento;

  void _cambiar(EnrutamientoComandas nuevo) =>
      setState(() => _borrador = nuevo);

  @override
  Widget build(BuildContext context) {
    final ajustes = ref.watch(appSettingsProvider).value;
    if (ajustes == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Enrutamiento de comandas')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    final borrador = _borrador ??= ajustes.impresion.enrutamiento;
    final catalogo = ref.watch(catalogoProvider);
    final modificado = _modificado(ajustes);

    return PopScope(
      canPop: !modificado,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_salirSinGuardar());
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Enrutamiento de comandas'),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: FilledButton.icon(
                key: const Key('enrutamiento-guardar'),
                onPressed: modificado && !_guardando
                    ? () => unawaited(_guardar())
                    : null,
                icon: _guardando
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.save_outlined),
                label: const Text('Guardar'),
              ),
            ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _EstadoImpresoras(
              impresion: ajustes.impresion,
              enrutamiento: borrador,
            ),
            const SizedBox(height: 16),
            _PorDefecto(
              valor: borrador.porDefecto,
              onChanged: (destino) => _cambiar(borrador.conPorDefecto(destino)),
            ),
            const SizedBox(height: 16),
            if (catalogo == null || catalogo.familias.isEmpty)
              _SinFamilias(hayCatalogo: catalogo != null)
            else
              ..._familias(context, catalogo, borrador),
            ..._reglasHuerfanas(context, catalogo, borrador),
          ],
        ),
      ),
    );
  }

  List<Widget> _familias(
    BuildContext context,
    CatalogSnapshot catalogo,
    EnrutamientoComandas borrador,
  ) {
    final theme = Theme.of(context);
    final madreDe = EnrutamientoComandas.jerarquia(catalogo.familias);
    final nombres = {
      for (final f in catalogo.familias) f.codfamilia: f.descripcion,
    };
    final articulos = <String, int>{};
    for (final articulo in catalogo.vendibles) {
      final familia = articulo.codfamilia;
      if (familia != null) {
        articulos[familia] = (articulos[familia] ?? 0) + 1;
      }
    }
    return [
      Text('Familias del catálogo', style: theme.textTheme.titleMedium),
      const SizedBox(height: 4),
      Text(
        'Una familia en "Heredar" usa el destino de su familia madre (o el '
        'destino por defecto si no tiene). Los cambios se aplican a las '
        'comandas que lleguen después de guardar.',
        style: theme.textTheme.bodySmall,
      ),
      const SizedBox(height: 8),
      for (final (:familia, :nivel) in ordenarArbolFamilias(catalogo.familias))
        _FilaFamilia(
          key: Key('familia-${familia.codfamilia}'),
          familia: familia,
          nivel: nivel,
          articulos: articulos[familia.codfamilia] ?? 0,
          regla: borrador.reglaDe(familia.codfamilia),
          origen: borrador.origenDe(familia.codfamilia, madreDe: madreDe),
          nombreFamilia: (codfamilia) => nombres[codfamilia] ?? codfamilia,
          onChanged: (regla) =>
              _cambiar(borrador.conRegla(familia.codfamilia, regla)),
        ),
    ];
  }

  /// Reglas de familias que ya no existen en el catálogo (se borraron o se
  /// renombraron en el ERP): se muestran para poder quitarlas.
  List<Widget> _reglasHuerfanas(
    BuildContext context,
    CatalogSnapshot? catalogo,
    EnrutamientoComandas borrador,
  ) {
    final conocidas = {
      for (final f in catalogo?.familias ?? const <FamiliaCatalogo>[])
        f.codfamilia,
    };
    final huerfanas = [
      for (final MapEntry(key: codfamilia, value: destino)
          in borrador.porFamilia.entries)
        if (!conocidas.contains(codfamilia)) (codfamilia, destino),
    ]..sort((a, b) => a.$1.compareTo(b.$1));
    if (huerfanas.isEmpty) return const [];
    return [
      const SizedBox(height: 16),
      Text(
        catalogo == null
            ? 'Reglas guardadas'
            : 'Reglas de familias que no están en el catálogo',
        style: Theme.of(context).textTheme.titleMedium,
      ),
      for (final (codfamilia, destino) in huerfanas)
        ListTile(
          key: Key('regla-huerfana-$codfamilia'),
          leading: const Icon(Icons.label_off_outlined),
          title: Text(codfamilia),
          subtitle: Text('Va a ${nombreDestino(destino).toLowerCase()}'),
          trailing: IconButton(
            tooltip: 'Quitar la regla',
            icon: const Icon(Icons.delete_outline),
            onPressed: () => _cambiar(borrador.conRegla(codfamilia, null)),
          ),
        ),
    ];
  }

  Future<void> _guardar() async {
    final borrador = _borrador;
    if (borrador == null) return;
    setState(() => _guardando = true);
    // Si falla, la copia de trabajo se conserva para reintentar.
    await ejecutarAccion(
      context,
      () => ref
          .read(appSettingsProvider.notifier)
          .actualizar(
            (s) => s.copyWith(
              impresion: s.impresion.copyWith(enrutamiento: borrador),
            ),
          ),
      exito: 'Enrutamiento guardado',
    );
    if (mounted) setState(() => _guardando = false);
  }

  Future<void> _salirSinGuardar() async {
    final salir = await confirmar(
      context,
      titulo: 'Cambios sin guardar',
      mensaje: 'Si sales ahora se perderán los cambios del enrutamiento.',
      textoAceptar: 'Salir sin guardar',
      peligroso: true,
    );
    if (!salir || !mounted) return;
    // `pop` directo no consulta el `PopScope`.
    Navigator.of(context).pop();
  }
}

/// Impresoras de comandas configuradas y avisos de respaldo.
class _EstadoImpresoras extends StatelessWidget {
  const _EstadoImpresoras({
    required this.impresion,
    required this.enrutamiento,
  });

  final PrintingSettings impresion;
  final EnrutamientoComandas enrutamiento;

  static const String _avisoDesactivada =
      'La impresión de comandas está desactivada en Ajustes > Impresoras: '
      'no se imprimirá ninguna comanda.';
  static const String _avisoSinImpresoras =
      'No hay ninguna impresora de comandas: las comandas no se imprimirán.';
  static const String _avisoSinBarra =
      'No hay impresora de barra: lo de barra saldrá por la impresora de '
      'cocina, en un ticket aparte titulado BARRA.';
  static const String _avisoSinCocina =
      'No hay impresora de cocina: lo de cocina saldrá por la impresora de '
      'barra, en un ticket aparte titulado COCINA.';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cocina = impresion.cocina;
    final barra = impresion.barra;
    final avisos = <String>[
      if (!impresion.imprimirComandaCocina) _avisoDesactivada,
      if (cocina == null && barra == null) _avisoSinImpresoras,
      if (barra == null &&
          cocina != null &&
          enrutamiento.usa(DestinoPreparacion.barra))
        _avisoSinBarra,
      if (cocina == null &&
          barra != null &&
          enrutamiento.usa(DestinoPreparacion.cocina))
        _avisoSinCocina,
    ];
    return Card(
      key: const Key('enrutamiento-impresoras'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Impresoras de comandas', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            _filaImpresora(context, 'Cocina', cocina),
            _filaImpresora(context, 'Barra', barra),
            for (final aviso in avisos)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.warning_amber_rounded,
                      color: theme.colorScheme.error,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Expanded(child: Text(aviso)),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  static Widget _filaImpresora(
    BuildContext context,
    String puesto,
    PrinterEndpoint? endpoint,
  ) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Icon(
            endpoint == null ? Icons.print_disabled_outlined : Icons.print,
            size: 20,
            color: endpoint == null
                ? theme.colorScheme.outline
                : theme.colorScheme.primary,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              endpoint == null
                  ? '$puesto: sin impresora'
                  : '$puesto: ${endpoint.host}:${endpoint.port}',
            ),
          ),
        ],
      ),
    );
  }
}

/// Selector del destino por defecto.
class _PorDefecto extends StatelessWidget {
  const _PorDefecto({required this.valor, required this.onChanged});

  final DestinoPreparacion valor;
  final ValueChanged<DestinoPreparacion> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Destino por defecto', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'Para los artículos sin familia y las familias que heredan sin '
              'que ninguna familia madre tenga destino.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            SegmentedButton<DestinoPreparacion>(
              key: const Key('enrutamiento-defecto'),
              segments: [
                for (final destino in DestinoPreparacion.values)
                  ButtonSegment(
                    value: destino,
                    label: Text(nombreDestino(destino)),
                  ),
              ],
              selected: {valor},
              onSelectionChanged: (s) => onChanged(s.first),
            ),
          ],
        ),
      ),
    );
  }
}

/// Aviso cuando no hay familias que configurar.
class _SinFamilias extends StatelessWidget {
  const _SinFamilias({required this.hayCatalogo});

  final bool hayCatalogo;

  @override
  Widget build(BuildContext context) {
    return Card(
      key: const Key('enrutamiento-sin-catalogo'),
      child: ListTile(
        leading: const Icon(Icons.category_outlined),
        title: Text(
          hayCatalogo
              ? 'El catálogo no tiene familias'
              : 'No hay catálogo de FacturaScripts',
        ),
        subtitle: Text(
          hayCatalogo
              ? 'Todas las comandas van al destino por defecto. Asigna '
                    'familias a los productos en FacturaScripts para '
                    'separarlas entre cocina y barra.'
              : 'Sin catálogo no se pueden elegir destinos por familia: '
                    'todas las comandas van al destino por defecto. Configura '
                    'la conexión con FacturaScripts en Ajustes y espera a '
                    'que se descargue el catálogo.',
        ),
      ),
    );
  }
}

/// Una familia del árbol con su selector Cocina / Barra / Heredar.
class _FilaFamilia extends StatelessWidget {
  const _FilaFamilia({
    super.key,
    required this.familia,
    required this.nivel,
    required this.articulos,
    required this.regla,
    required this.origen,
    required this.nombreFamilia,
    required this.onChanged,
  });

  final FamiliaCatalogo familia;
  final int nivel;
  final int articulos;
  final DestinoPreparacion? regla;
  final ({DestinoPreparacion destino, String? familia}) origen;
  final String Function(String codfamilia) nombreFamilia;
  final ValueChanged<DestinoPreparacion?> onChanged;

  String get _efectivo {
    final destino = nombreDestino(origen.destino);
    if (regla != null) return 'Va a $destino';
    final desde = origen.familia;
    return desde == null
        ? 'Va a $destino (por defecto)'
        : 'Va a $destino (heredado de ${nombreFamilia(desde)})';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selector = SegmentedButton<_Opcion>(
      key: Key('selector-${familia.codfamilia}'),
      showSelectedIcon: false,
      segments: const [
        ButtonSegment(value: _Opcion.cocina, label: Text('Cocina')),
        ButtonSegment(value: _Opcion.barra, label: Text('Barra')),
        ButtonSegment(value: _Opcion.heredar, label: Text('Heredar')),
      ],
      selected: {_opcionDe(regla)},
      onSelectionChanged: (s) => onChanged(_reglaDe(s.first)),
    );
    final texto = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(familia.descripcion, style: theme.textTheme.titleSmall),
        Text(
          '${familia.codfamilia} · $articulos '
          '${articulos == 1 ? 'artículo' : 'artículos'}',
          style: theme.textTheme.bodySmall,
        ),
        Text(
          _efectivo,
          key: Key('efectivo-${familia.codfamilia}'),
          style: theme.textTheme.bodyMedium?.copyWith(
            color: origen.destino == DestinoPreparacion.barra
                ? theme.colorScheme.tertiary
                : theme.colorScheme.primary,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
    return Padding(
      padding: EdgeInsets.only(left: 24.0 * nivel, top: 4, bottom: 4),
      child: Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: LayoutBuilder(
            builder: (context, constraints) => constraints.maxWidth < 520
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [texto, const SizedBox(height: 8), selector],
                  )
                : Row(
                    children: [
                      if (nivel > 0)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: Icon(
                            Icons.subdirectory_arrow_right,
                            size: 20,
                            color: theme.colorScheme.outline,
                          ),
                        ),
                      Expanded(child: texto),
                      const SizedBox(width: 12),
                      selector,
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}
