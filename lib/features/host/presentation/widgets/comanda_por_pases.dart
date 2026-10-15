/// Comanda de la mesa en la tablet agrupada por pase, con el estado de cada
/// pase y su botón «Marchar» (§7.5), y las piezas que comparte con la lista
/// «Sin enviar» de `MesaPage`: la cabecera de pase, el menú «Pase» de cada
/// fila y el agrupador.
library;

import 'package:flutter/material.dart';

import '../../../../core/money/money.dart';
import '../../../sala/domain/comanda.dart';
import '../../../sala/domain/linea_comanda.dart';
import '../../../sala/domain/pases.dart';
import 'host_formatos.dart';

/// Elementos de un pase (`null` = directos).
typedef GrupoDePase<T> = ({int? pase, List<T> elementos});

/// Agrupa [elementos] por pase como `agruparPorPase` agrupa la comanda:
/// primero los directos y después los pases de menor a mayor, cada grupo en
/// orden de llegada y solo los que tienen elementos.
List<GrupoDePase<T>> agruparPorPaseDe<T>(
  Iterable<T> elementos,
  int? Function(T elemento) paseDe,
) {
  final directos = [
    for (final e in elementos)
      if (paseDe(e) == null) e,
  ];
  final pases = {for (final e in elementos) ?paseDe(e)}.toList()..sort();
  return [
    if (directos.isNotEmpty) (pase: null, elementos: directos),
    for (final pase in pases)
      (
        pase: pase,
        elementos: [
          for (final e in elementos)
            if (paseDe(e) == pase) e,
        ],
      ),
  ];
}

/// Aviso tras marchar el [pase]: «Marchados los Segundos» («Marchados de
/// nuevo los Segundos» con [repetir]); un pase fuera de la configuración,
/// «Pase 7 marchado» («Pase 7 marchado de nuevo»).
String mensajeMarcha(PasesConfig pases, int pase, {required bool repetir}) {
  final nombre = pases.nombreDe(pase);
  final deNuevo = repetir ? ' de nuevo' : '';
  return pases.existe(pase)
      ? 'Marchados$deNuevo los $nombre'
      : '$nombre marchado$deNuevo';
}

/// Rótulo de un grupo de pase («2. Segundos · en espera») con su acción.
class CabeceraPase extends StatelessWidget {
  const CabeceraPase({
    super.key,
    required this.texto,
    this.enEspera = false,
    this.accion,
  });

  final String texto;

  /// Pase con líneas esperando a que lo marchen: se resalta.
  final bool enEspera;
  final Widget? accion;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 8, 0),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 40),
        child: Row(
          children: [
            Expanded(
              child: Text(
                texto,
                style: theme.textTheme.labelLarge?.copyWith(
                  color: enEspera ? scheme.tertiary : scheme.primary,
                ),
              ),
            ),
            ?accion,
          ],
        ),
      ),
    );
  }
}

/// Menú «Pase» de una fila sin enviar: cambia su pase a «Directo» o a uno de
/// la configuración (también ofrece el pase actual si está fuera de ella).
class MenuPase extends StatelessWidget {
  const MenuPase({
    super.key,
    required this.pases,
    required this.pase,
    required this.onCambio,
    this.habilitado = true,
  });

  final PasesConfig pases;

  /// Pase actual de la fila (`null` = directo).
  final int? pase;

  /// Recibe el pase elegido (`null` = directo).
  final ValueChanged<int?> onCambio;
  final bool habilitado;

  /// Valor del menú para «Directo» (los pases empiezan en 1).
  static const int _directo = 0;

  @override
  Widget build(BuildContext context) {
    final actual = pase;
    final opciones = <int>[
      _directo,
      for (var n = 1; n <= pases.numPases; n++) n,
      if (actual != null && !pases.existe(actual)) actual,
    ];
    return PopupMenuButton<int>(
      tooltip: 'Pase: ${pases.etiqueta(actual)}',
      enabled: habilitado,
      icon: const Icon(Icons.low_priority),
      initialValue: actual ?? _directo,
      onSelected: (valor) => onCambio(valor == _directo ? null : valor),
      itemBuilder: (_) => [
        for (final n in opciones)
          PopupMenuItem<int>(
            key: Key('menu-pase-${n == _directo ? 'directo' : n}'),
            value: n,
            child: Text(pases.etiqueta(n == _directo ? null : n)),
          ),
      ],
    );
  }
}

/// Comanda enviada de la mesa.
///
/// Se agrupa por pase si [pases] está activo **o** si la comanda ya tiene
/// líneas con pase (los pases se desactivaron después de pedirlas), para que
/// nunca quede una línea en espera sin su botón «Marchar» (D2.6, D2.8). Sin
/// grupos, las líneas van en orden de llegada.
///
/// Cabeceras: «Directo» (clave `comanda-pase-directo`) y, por pase
/// (`comanda-pase-<n>`), «n. Nombre · en espera» con el botón «Marchar»
/// (`marchar-<n>`) o «n. Nombre · en marcha hh:mm» con el menú
/// (`pase-menu-<n>`) que ofrece «Marchar de nuevo» (`marchar-de-nuevo-<n>`).
/// Un pase de [pasesMarchando] muestra un indicador (`marchando-<n>`) en
/// lugar del botón. Cada línea lleva la clave `linea-<id>` y su botón de
/// anular `anular-<id>`.
class ComandaPorPases extends StatelessWidget {
  const ComandaPorPases({
    super.key,
    required this.comanda,
    required this.pases,
    required this.onAnular,
    this.onMarchar,
    this.pasesMarchando = const {},
  });

  final Comanda comanda;
  final PasesConfig pases;
  final ValueChanged<LineaComanda> onAnular;

  /// Marcha el pase, o lo vuelve a marchar con [repetir]; sin él no hay
  /// botones de marcha.
  final void Function(int pase, {required bool repetir})? onMarchar;

  /// Pases con una marcha esperando respuesta.
  final Set<int> pasesMarchando;

  /// La comanda se muestra agrupada por pase.
  static bool agrupa(PasesConfig pases, Iterable<LineaComanda> lineas) =>
      pases.activos || lineas.any((l) => l.pase != null);

  @override
  Widget build(BuildContext context) {
    final lineas = comanda.lineas;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (agrupa(pases, lineas))
          for (final grupo in agruparPorPase(lineas)) ...[
            _cabecera(grupo),
            for (final l in grupo.lineas)
              _FilaLinea(linea: l, onAnular: onAnular),
          ]
        else
          for (final l in lineas) _FilaLinea(linea: l, onAnular: onAnular),
      ],
    );
  }

  Widget _cabecera(GrupoPase grupo) {
    final pase = grupo.pase;
    if (pase == null) {
      return const CabeceraPase(
        key: Key('comanda-pase-directo'),
        texto: 'Directo',
      );
    }
    final marcha = comanda.ultimaMarchaDe(pase);
    // Sin líneas activas el host rechaza la marcha (`pase_sin_lineas`).
    final activas = grupo.lineas.any((l) => !l.anulada);
    final estado = marcha != null
        ? 'en marcha ${formatHora(marcha.cuando)}'
        : (activas ? 'en espera' : null);
    final etiqueta = pases.etiqueta(pase);
    return CabeceraPase(
      key: Key('comanda-pase-$pase'),
      texto: estado == null ? etiqueta : '$etiqueta · $estado',
      enEspera: marcha == null && activas,
      accion: activas
          ? _accion(pase, marchado: marcha != null, etiqueta: etiqueta)
          : null,
    );
  }

  /// «Marchar» si el pase está en espera, el menú «Marchar de nuevo» si ya
  /// está en marcha y un indicador mientras su marcha espera respuesta.
  Widget? _accion(
    int pase, {
    required bool marchado,
    required String etiqueta,
  }) {
    final marchar = onMarchar;
    if (marchar == null) return null;
    if (pasesMarchando.contains(pase)) {
      return Padding(
        key: Key('marchando-$pase'),
        padding: const EdgeInsets.all(12),
        child: SizedBox.square(
          dimension: 20,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            semanticsLabel: 'Marchando $etiqueta',
          ),
        ),
      );
    }
    if (!marchado) {
      return Tooltip(
        message: 'Marchar $etiqueta',
        child: FilledButton.tonalIcon(
          key: Key('marchar-$pase'),
          onPressed: () => marchar(pase, repetir: false),
          icon: const Icon(Icons.play_arrow),
          label: const Text('Marchar'),
        ),
      );
    }
    return PopupMenuButton<bool>(
      key: Key('pase-menu-$pase'),
      tooltip: 'Opciones de $etiqueta',
      onSelected: (_) => marchar(pase, repetir: true),
      itemBuilder: (_) => [
        PopupMenuItem<bool>(
          key: Key('marchar-de-nuevo-$pase'),
          value: true,
          child: const Text('Marchar de nuevo'),
        ),
      ],
    );
  }
}

/// Línea enviada: cantidad, descripción, nota y estado, importe y el botón
/// de anular (tachada si está anulada).
class _FilaLinea extends StatelessWidget {
  const _FilaLinea({required this.linea, required this.onAnular});

  final LineaComanda linea;
  final ValueChanged<LineaComanda> onAnular;

  @override
  Widget build(BuildContext context) {
    final l = linea;
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
              onPressed: () => onAnular(l),
              icon: const Icon(Icons.cancel_outlined),
            ),
        ],
      ),
    );
  }
}

/// Fila de «Sin enviar»: cantidad con «una menos» / «una más», descripción y
/// nota, importe, el menú «Pase» (clave `pase-pendiente-<referencia>`, solo
/// con los pases activos o si la fila ya tiene pase) y el botón de nota. La
/// fila lleva la clave `pendiente-<referencia>`; quien la coloque le da su
/// propia [key] para distinguir dos filas del mismo artículo.
class FilaPendiente extends StatelessWidget {
  const FilaPendiente({
    super.key,
    required this.referencia,
    required this.descripcion,
    required this.cantidad,
    required this.importeCents,
    required this.pases,
    required this.onCantidad,
    required this.onPase,
    required this.onNota,
    this.nota,
    this.pase,
    this.habilitada = true,
  });

  final String referencia;
  final String descripcion;
  final double cantidad;
  final int importeCents;
  final PasesConfig pases;

  /// Suma [delta] (1 o -1) a la cantidad.
  final ValueChanged<int> onCantidad;

  /// Cambia el pase de la fila (`null` = directo).
  final ValueChanged<int?> onPase;
  final VoidCallback onNota;
  final String? nota;
  final int? pase;

  /// Falsa mientras se envía: la fila no se puede tocar.
  final bool habilitada;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      key: Key('pendiente-$referencia'),
      contentPadding: const EdgeInsets.only(left: 8, right: 8),
      leading: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: 'Una menos',
            onPressed: habilitada ? () => onCantidad(-1) : null,
            icon: const Icon(Icons.remove_circle_outline),
          ),
          Text(
            formatQuantity(cantidad),
            style: Theme.of(context).textTheme.titleMedium,
          ),
          IconButton(
            tooltip: 'Una más',
            onPressed: habilitada ? () => onCantidad(1) : null,
            icon: const Icon(Icons.add_circle_outline),
          ),
        ],
      ),
      title: Text(descripcion),
      subtitle: nota == null ? null : Text(nota!),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(formatCents(importeCents)),
          if (pases.activos || pase != null)
            MenuPase(
              key: Key('pase-pendiente-$referencia'),
              pases: pases,
              pase: pase,
              habilitado: habilitada,
              onCambio: onPase,
            ),
          IconButton(
            tooltip: 'Nota para cocina',
            onPressed: habilitada ? onNota : null,
            icon: const Icon(Icons.edit_note),
          ),
        ],
      ),
    );
  }
}
