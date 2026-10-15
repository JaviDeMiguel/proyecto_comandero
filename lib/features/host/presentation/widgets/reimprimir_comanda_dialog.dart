/// Diálogo «Reimprimir comanda» de la tablet (§5.10, §7.5): puestos, alcance
/// y motivo de la reimpresión, y la acción que la encola.
library;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../sala/domain/comanda.dart';
import '../../../sala/domain/linea_comanda.dart';
import '../../../sala/domain/mesa.dart';
import '../../application/impresion/mapeo_documentos.dart'
    show AlcanceReimpresion, MotivoReimpresion, lineasAReimprimir;
import '../impresion_providers.dart';
import '../providers.dart';
import 'host_feedback.dart';

/// Lo elegido en el diálogo de reimprimir.
typedef SeleccionReimpresion = ({
  Set<DestinoPreparacion> destinos,
  AlcanceReimpresion alcance,
  MotivoReimpresion motivo,
});

/// Abre [ReimprimirComandaDialog] sobre [comanda]. Devuelve lo elegido o
/// `null` si se cancela.
Future<SeleccionReimpresion?> pedirReimpresion(
  BuildContext context, {
  required Comanda comanda,
}) => showDialog<SeleccionReimpresion>(
  context: context,
  builder: (_) => ReimprimirComandaDialog(comanda: comanda),
);

/// Pide qué reimprimir de [comanda] y lo reimprime en la mesa (§5.10), sin
/// escribir nada en el diario.
///
/// Al confirmar vuelve a leer la comanda: si la mesa ya no tiene, avisa «La
/// mesa ya no tiene comanda»; si lo que se iba a reimprimir cambió con el
/// diálogo abierto (un envío nuevo, una anulación…), avisa en lugar de
/// imprimir algo distinto de lo que se mostró. En los dos casos no imprime.
Future<void> reimprimirComandaDeMesa(
  BuildContext context,
  WidgetRef ref, {
  required Mesa mesa,
  required Comanda comanda,
}) async {
  final eleccion = await pedirReimpresion(context, comanda: comanda);
  if (eleccion == null || !context.mounted) return;
  final actual = ref.read(salaServiceProvider).comandaDeMesa(mesa.id);
  if (actual == null) {
    mostrarMensaje(context, 'La mesa ya no tiene comanda', error: true);
    return;
  }
  if (!listEquals(
    _lineasElegidas(comanda, eleccion),
    _lineasElegidas(actual, eleccion),
  )) {
    mostrarMensaje(
      context,
      'La comanda ha cambiado mientras elegías: vuelve a abrir «Reimprimir '
      'comanda» para ver lo que se reimprimirá',
      error: true,
    );
    return;
  }
  await ejecutarAccion(
    context,
    () => ref
        .read(printingServiceProvider)
        .reimprimirComanda(
          mesa,
          actual,
          destinos: eleccion.destinos,
          alcance: eleccion.alcance,
          motivo: eleccion.motivo,
          dispositivo: ref.read(nombreTpvProvider),
        ),
    exito: 'Comanda enviada a imprimir: ${eleccion.motivo.banda}',
  );
}

/// Líneas que se reimprimirían de [comanda] con la [eleccion].
List<LineaComanda> _lineasElegidas(
  Comanda comanda,
  SeleccionReimpresion eleccion,
) => [
  for (final l in lineasAReimprimir(comanda, eleccion.alcance))
    if (eleccion.destinos.contains(l.destino)) l,
];

/// Elige qué reimprimir de [comanda]:
///
/// - el alcance, «Todo» (clave `reimprimir-alcance-todo`, por defecto) o
///   «Último envío» (`reimprimir-alcance-ultimo`);
/// - los puestos (`reimprimir-puesto-cocina`, `reimprimir-puesto-barra`):
///   solo los que tienen líneas en el alcance, todos marcados al principio;
/// - el motivo, sin valor por defecto: «No salió / se perdió»
///   (`reimprimir-motivo-nosalio`, imprime «REIMPRESIÓN · PREPARAR») o
///   «Copia para el puesto» (`reimprimir-motivo-copia`, imprime «COPIA · NO
///   PREPARAR»).
///
/// «Reimprimir» (`reimprimir-aceptar`) está desactivado hasta que hay un
/// motivo y al menos un puesto; devuelve un [SeleccionReimpresion].
class ReimprimirComandaDialog extends StatefulWidget {
  const ReimprimirComandaDialog({super.key, required this.comanda});

  final Comanda comanda;

  @override
  State<ReimprimirComandaDialog> createState() =>
      _ReimprimirComandaDialogState();
}

class _ReimprimirComandaDialogState extends State<ReimprimirComandaDialog> {
  AlcanceReimpresion _alcance = AlcanceReimpresion.todo;

  /// Puestos que se han desmarcado: los demás puestos con líneas en el
  /// alcance se reimprimen (así, al cambiar de alcance, un puesto nuevo
  /// aparece marcado).
  final Set<DestinoPreparacion> _desmarcados = {};
  MotivoReimpresion? _motivo;

  /// Líneas del alcance por puesto, en el orden de [DestinoPreparacion].
  Map<DestinoPreparacion, int> get _lineasPorPuesto {
    final lineas = lineasAReimprimir(widget.comanda, _alcance);
    return {
      for (final destino in DestinoPreparacion.values)
        if (lineas.where((l) => l.destino == destino).length case final n
            when n > 0)
          destino: n,
    };
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final porPuesto = _lineasPorPuesto;
    final destinos = {
      for (final destino in porPuesto.keys)
        if (!_desmarcados.contains(destino)) destino,
    };
    final motivo = _motivo;
    final puede = motivo != null && destinos.isNotEmpty;
    return AlertDialog(
      scrollable: true,
      title: const Text('Reimprimir comanda'),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Qué', style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _chipAlcance(AlcanceReimpresion.todo, 'Todo', 'todo'),
                _chipAlcance(
                  AlcanceReimpresion.ultimoEnvio,
                  'Último envío',
                  'ultimo',
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text('Puestos', style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            if (porPuesto.isEmpty)
              const Text('No hay líneas que reimprimir en este alcance.')
            else
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final MapEntry(key: destino, value: n)
                      in porPuesto.entries)
                    FilterChip(
                      key: Key('reimprimir-puesto-${destino.name}'),
                      label: Text('${_nombrePuesto(destino)} ($n)'),
                      selected: destinos.contains(destino),
                      onSelected: (marcado) => setState(() {
                        if (marcado) {
                          _desmarcados.remove(destino);
                        } else {
                          _desmarcados.add(destino);
                        }
                      }),
                    ),
                ],
              ),
            const SizedBox(height: 16),
            Text('Motivo', style: theme.textTheme.titleSmall),
            for (final (m, clave) in const [
              (MotivoReimpresion.noSalio, 'nosalio'),
              (MotivoReimpresion.copia, 'copia'),
            ])
              ListTile(
                key: Key('reimprimir-motivo-$clave'),
                contentPadding: EdgeInsets.zero,
                selected: motivo == m,
                leading: Icon(
                  motivo == m
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                ),
                title: Text(m.etiqueta),
                subtitle: Text('Imprime «${m.banda}»'),
                onTap: () => setState(() => _motivo = m),
              ),
            if (motivo == null)
              Text(
                'Elige el motivo para que el puesto sepa si debe prepararlo.',
                style: theme.textTheme.bodySmall,
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
        FilledButton.icon(
          key: const Key('reimprimir-aceptar'),
          onPressed: puede
              ? () => Navigator.of(
                  context,
                ).pop((destinos: destinos, alcance: _alcance, motivo: motivo))
              : null,
          icon: const Icon(Icons.print),
          label: const Text('Reimprimir'),
        ),
      ],
    );
  }

  Widget _chipAlcance(AlcanceReimpresion alcance, String texto, String clave) =>
      ChoiceChip(
        key: Key('reimprimir-alcance-$clave'),
        label: Text(texto),
        selected: _alcance == alcance,
        onSelected: (_) => setState(() => _alcance = alcance),
      );

  static String _nombrePuesto(DestinoPreparacion destino) => switch (destino) {
    DestinoPreparacion.cocina => 'Cocina',
    DestinoPreparacion.barra => 'Barra',
  };
}
