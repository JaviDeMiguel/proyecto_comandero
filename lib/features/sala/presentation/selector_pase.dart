/// Selector del pase (Directo, 1. Primeros, 2. Segundos…) para las líneas
/// nuevas de una comanda.
///
/// Lo comparten `MesaPage` (tablet) y `PedidoPage` (comandero): recibe la
/// configuración y el valor por parámetros y avisa del cambio por
/// [SelectorPase.onCambio]; no depende de Riverpod ni de la red. Con los
/// pases desactivados no pinta nada, así que quien lo coloca no necesita
/// comprobar `pases.activos`.
library;

import 'package:flutter/material.dart';

import '../domain/pases.dart';

/// Fila de chips con «Directo» (clave `pase-directo`) y un chip por pase
/// configurado (clave `pase-<n>`). Si [seleccionado] no está en la
/// configuración se añade su chip rotulado «n. Pase n», para que una línea
/// con un pase de otra configuración siga teniendo su chip marcado.
class SelectorPase extends StatelessWidget {
  const SelectorPase({
    super.key,
    required this.pases,
    required this.seleccionado,
    required this.onCambio,
    this.compacto = false,
  });

  /// Configuración de pases del host (del snapshot de sala o de los ajustes).
  final PasesConfig pases;

  /// Pase seleccionado (base 1) o `null` para «Directo».
  final int? seleccionado;

  /// Se llama con el pase elegido (`null` = directo) al tocar un chip, aunque
  /// sea el que ya estaba marcado.
  final ValueChanged<int?> onCambio;

  /// Chips más estrechos y solo con el nombre del pase, para el teléfono.
  final bool compacto;

  @override
  Widget build(BuildContext context) {
    if (!pases.activos) return const SizedBox.shrink();
    final actual = seleccionado;
    final fueraDeRango = actual != null && !pases.existe(actual)
        ? actual
        : null;
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Padding(
          padding: const EdgeInsets.only(right: 2),
          child: Text('Pase:', style: Theme.of(context).textTheme.labelLarge),
        ),
        _chip(null, 'Directo'),
        for (var n = 1; n <= pases.numPases; n++) _chip(n, _etiqueta(n)),
        if (fueraDeRango != null) _chip(fueraDeRango, _etiqueta(fueraDeRango)),
      ],
    );
  }

  String _etiqueta(int pase) =>
      compacto ? pases.nombreDe(pase) : pases.etiqueta(pase);

  Widget _chip(int? pase, String texto) => ChoiceChip(
    key: Key(pase == null ? 'pase-directo' : 'pase-$pase'),
    label: Text(texto),
    selected: pase == seleccionado,
    onSelected: (_) => onCambio(pase),
    visualDensity: compacto ? VisualDensity.compact : null,
    materialTapTargetSize: compacto ? MaterialTapTargetSize.shrinkWrap : null,
  );
}
