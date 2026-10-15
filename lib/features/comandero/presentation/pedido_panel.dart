/// Panel del pedido del comandero: lo que falta por enviar (el carrito) y lo
/// enviado (la comanda de la mesa), agrupados por pase cuando procede, con
/// el estado de cada pase y su botón «MARCHAR».
library;

import 'package:flutter/material.dart';

import '../../../core/money/money.dart';
import '../../sala/domain/comanda.dart';
import '../../sala/domain/linea_comanda.dart';
import '../../sala/domain/pases.dart';
import '../domain/pedido_en_edicion.dart';

/// Rótulo de un pase: «Directo», «2. Segundos» o, si no está en la
/// configuración (o no la hay, con un host antiguo), «7. Pase 7».
String etiquetaPase(PasesConfig? pases, int? pase) {
  if (pase == null) return 'Directo';
  return pases?.etiqueta(pase) ?? '$pase. Pase $pase';
}

/// Grupo de líneas del carrito de un pase (`null` = directas).
typedef _GrupoCarrito = ({int? pase, List<LineaPedido> lineas});

/// Agrupa el carrito como `agruparPorPase` agrupa la comanda: primero las
/// directas y después los pases de menor a mayor, cada grupo en orden de
/// llegada y solo los que tienen líneas.
List<_GrupoCarrito> _agruparCarrito(List<LineaPedido> lineas) {
  final directas = [
    for (final linea in lineas)
      if (linea.pase == null) linea,
  ];
  final pases = {for (final linea in lineas) ?linea.pase}.toList()..sort();
  return [
    if (directas.isNotEmpty) (pase: null, lineas: directas),
    for (final pase in pases)
      (
        pase: pase,
        lineas: [
          for (final linea in lineas)
            if (linea.pase == pase) linea,
        ],
      ),
  ];
}

String _dos(int valor) => valor.toString().padLeft(2, '0');

/// Hora local «hh:mm» de una marca del host.
String _hora(DateTime cuando) {
  final local = cuando.toLocal();
  return '${_dos(local.hour)}:${_dos(local.minute)}';
}

/// Panel con el carrito («Sin enviar») y la comanda enviada («Enviado»).
///
/// Las dos secciones se agrupan por pase si [pases] está activo o si ya
/// tienen líneas con pase (el host desactivó los pases después de pedirlas):
/// así nunca queda una línea en espera sin su botón «MARCHAR». Con un host
/// antiguo no hay grupos y lo enviado se lista de lo más reciente a lo más
/// antiguo, como siempre.
///
/// En «Enviado», cada pase muestra su estado: «en espera» con el botón
/// «MARCHAR» (clave `pedido.marchar.<n>`) o «en marcha hh:mm» con el menú
/// (clave `pedido.paseMenu.<n>`) que ofrece «Marchar de nuevo» (clave
/// `pedido.marcharDeNuevo.<n>`). Un pase de [pasesMarchando] muestra un
/// indicador de progreso en lugar del botón.
class PanelPedido extends StatelessWidget {
  const PanelPedido({
    super.key,
    required this.comanda,
    required this.pedido,
    required this.onEditarLinea,
    required this.onQuitarLinea,
    required this.onAnularLinea,
    this.pases,
    this.pasesMarchando = const {},
    this.onMarcharPase,
  });

  final Comanda? comanda;
  final PedidoEnEdicion pedido;
  final void Function(LineaPedido linea) onEditarLinea;
  final void Function(LineaPedido linea) onQuitarLinea;
  final void Function(LineaComanda linea) onAnularLinea;

  /// Configuración de pases del host (`null` con un host antiguo).
  final PasesConfig? pases;

  /// Pases con una marcha esperando la respuesta del host.
  final Set<int> pasesMarchando;

  /// Marcha el pase, o lo vuelve a marchar con [repetir]; sin él no hay
  /// botones de marcha.
  final void Function(int pase, {required bool repetir})? onMarcharPase;

  @override
  Widget build(BuildContext context) {
    final comanda = this.comanda;
    final enviadas = comanda?.lineas ?? const <LineaComanda>[];
    final pasesActivos = pases?.activos ?? false;
    return ListView(
      key: const Key('pedido.panel'),
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        _Cabecera(
          titulo: 'Sin enviar',
          detalle: pedido.estaVacio ? null : formatCents(pedido.importeCents),
        ),
        if (pedido.estaVacio)
          const _Vacio('Toca un artículo de la carta para añadirlo.')
        else if (pasesActivos || pedido.lineas.any((l) => l.pase != null))
          for (final grupo in _agruparCarrito(pedido.lineas)) ...[
            _CabeceraPase(
              key: Key('carrito.pase.${grupo.pase ?? 'directo'}'),
              texto: etiquetaPase(pases, grupo.pase),
            ),
            for (final linea in grupo.lineas) _filaCarrito(linea),
          ]
        else
          for (final linea in pedido.lineas) _filaCarrito(linea),
        const Divider(),
        _Cabecera(
          titulo: 'Enviado',
          detalle: comanda == null ? null : formatCents(comanda.importeCents),
        ),
        if (comanda == null || enviadas.isEmpty)
          const _Vacio('La mesa no tiene nada pedido.')
        else if (pasesActivos || enviadas.any((l) => l.pase != null))
          for (final grupo in agruparPorPase(enviadas)) ...[
            _cabeceraEnviada(comanda, grupo),
            for (final linea in grupo.lineas) _filaEnviada(linea),
          ]
        else
          for (final linea in enviadas.reversed) _filaEnviada(linea),
      ],
    );
  }

  Widget _filaCarrito(LineaPedido linea) => _FilaCarrito(
    linea: linea,
    onEditar: onEditarLinea,
    onQuitar: onQuitarLinea,
  );

  Widget _filaEnviada(LineaComanda linea) =>
      _FilaEnviada(linea: linea, onAnular: onAnularLinea);

  /// Cabecera de un pase de lo enviado con su estado y su acción.
  Widget _cabeceraEnviada(Comanda comanda, GrupoPase grupo) {
    final pase = grupo.pase;
    if (pase == null) {
      return const _CabeceraPase(
        key: Key('comanda.pase.directo'),
        texto: 'Directo',
      );
    }
    final marcha = comanda.ultimaMarchaDe(pase);
    // Sin líneas activas el host rechaza la marcha (`pase_sin_lineas`).
    final activas = grupo.lineas.any((linea) => !linea.anulada);
    final estado = marcha != null
        ? 'en marcha ${_hora(marcha.cuando)}'
        : (activas ? 'en espera' : null);
    final etiqueta = etiquetaPase(pases, pase);
    return _CabeceraPase(
      key: Key('comanda.pase.$pase'),
      texto: estado == null ? etiqueta : '$etiqueta · $estado',
      enEspera: marcha == null && activas,
      accion: activas
          ? _accionPase(pase, marchado: marcha != null, etiqueta: etiqueta)
          : null,
    );
  }

  /// «MARCHAR» si el pase está en espera, el menú «Marchar de nuevo» si ya
  /// está en marcha y un indicador mientras su marcha espera respuesta.
  Widget? _accionPase(
    int pase, {
    required bool marchado,
    required String etiqueta,
  }) {
    final marchar = onMarcharPase;
    if (marchar == null) return null;
    if (pasesMarchando.contains(pase)) {
      return Padding(
        key: Key('pedido.marchando.$pase'),
        padding: const EdgeInsets.all(12),
        child: const SizedBox.square(
          dimension: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (!marchado) {
      return FilledButton.tonal(
        key: Key('pedido.marchar.$pase'),
        style: FilledButton.styleFrom(visualDensity: VisualDensity.compact),
        onPressed: () => marchar(pase, repetir: false),
        child: const Text('MARCHAR'),
      );
    }
    return PopupMenuButton<bool>(
      key: Key('pedido.paseMenu.$pase'),
      tooltip: 'Opciones de $etiqueta',
      onSelected: (_) => marchar(pase, repetir: true),
      itemBuilder: (_) => [
        PopupMenuItem<bool>(
          key: Key('pedido.marcharDeNuevo.$pase'),
          value: true,
          child: const Text('Marchar de nuevo'),
        ),
      ],
    );
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

/// Rótulo de un grupo de pase («2. Segundos · en espera») con su acción.
class _CabeceraPase extends StatelessWidget {
  const _CabeceraPase({
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

class _Vacio extends StatelessWidget {
  const _Vacio(this.texto);

  final String texto;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    child: Text(texto),
  );
}

/// Línea del carrito: tocarla la edita; mientras se envía no se puede tocar.
class _FilaCarrito extends StatelessWidget {
  const _FilaCarrito({
    required this.linea,
    required this.onEditar,
    required this.onQuitar,
  });

  final LineaPedido linea;
  final void Function(LineaPedido linea) onEditar;
  final void Function(LineaPedido linea) onQuitar;

  @override
  Widget build(BuildContext context) {
    return ListTile(
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
              onPressed: () => onQuitar(linea),
            ),
        ],
      ),
      onTap: linea.enviando ? null : () => onEditar(linea),
    );
  }
}

/// Línea de la comanda enviada, con su estado y el botón de anular.
class _FilaEnviada extends StatelessWidget {
  const _FilaEnviada({required this.linea, required this.onAnular});

  final LineaComanda linea;
  final void Function(LineaComanda linea) onAnular;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const tachado = TextStyle(decoration: TextDecoration.lineThrough);
    return ListTile(
      key: Key('comanda.linea.${linea.id}'),
      dense: true,
      leading: CircleAvatar(
        radius: 18,
        backgroundColor: linea.anulada
            ? theme.colorScheme.errorContainer
            : theme.colorScheme.secondaryContainer,
        child: Text(formatQuantity(linea.cantidad)),
      ),
      title: Text(linea.descripcion, style: linea.anulada ? tachado : null),
      subtitle: Text(_detalle(linea)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            formatCents(lineTotalCents(linea.pvpUnitarioCents, linea.cantidad)),
            style: linea.anulada ? tachado : null,
          ),
          if (!linea.anulada)
            IconButton(
              key: Key('comanda.anular.${linea.id}'),
              tooltip: 'Anular',
              icon: const Icon(Icons.block),
              onPressed: () => onAnular(linea),
            )
          else
            const SizedBox(width: 48),
        ],
      ),
    );
  }

  static String _detalle(LineaComanda linea) {
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
