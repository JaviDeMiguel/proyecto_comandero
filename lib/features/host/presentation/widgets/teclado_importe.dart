import 'package:flutter/material.dart';

import '../../../../core/money/money.dart';

/// Importe máximo tecleable (99.999,99 €).
const int kImporteMaximoCents = 9999999;

/// Aplica una pulsación del teclado a un importe en céntimos, al estilo de
/// las cajas registradoras: las cifras entran por la derecha (`1`,`2`,`5` →
/// `1,25 €`). Teclas: `0`..`9`, `00`, `borrar` (última cifra) y `C`.
int teclearImporte(int actualCents, String tecla) {
  switch (tecla) {
    case 'C':
      return 0;
    case 'borrar':
      return actualCents ~/ 10;
    case '00':
      final siguiente = actualCents * 100;
      return siguiente > kImporteMaximoCents ? actualCents : siguiente;
    default:
      final digito = int.tryParse(tecla);
      if (digito == null || digito < 0 || digito > 9 || tecla.length != 1) {
        throw ArgumentError.value(tecla, 'tecla', 'Tecla desconocida');
      }
      final siguiente = actualCents * 10 + digito;
      return siguiente > kImporteMaximoCents ? actualCents : siguiente;
  }
}

/// Teclado numérico táctil para importes. Cada tecla lleva la clave
/// `tecla-<tecla>` (`tecla-7`, `tecla-00`, `tecla-borrar`, `tecla-C`).
class TecladoImporte extends StatelessWidget {
  const TecladoImporte({
    super.key,
    required this.valorCents,
    required this.onChanged,
    this.alturaTecla = 56,
  });

  final int valorCents;
  final ValueChanged<int> onChanged;
  final double alturaTecla;

  static const List<List<String>> _filas = [
    ['7', '8', '9'],
    ['4', '5', '6'],
    ['1', '2', '3'],
    ['C', '0', '00'],
  ];

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final fila in _filas)
          Row(
            children: [
              for (final tecla in fila)
                Expanded(child: _tecla(context, tecla, Text(tecla))),
            ],
          ),
        Row(
          children: [
            Expanded(
              child: _tecla(
                context,
                'borrar',
                const Icon(Icons.backspace_outlined, semanticLabel: 'Borrar'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _tecla(BuildContext context, String tecla, Widget etiqueta) {
    return Padding(
      padding: const EdgeInsets.all(3),
      child: SizedBox(
        height: alturaTecla,
        child: FilledButton.tonal(
          key: Key('tecla-$tecla'),
          style: FilledButton.styleFrom(
            padding: EdgeInsets.zero,
            textStyle: Theme.of(context).textTheme.titleLarge,
          ),
          onPressed: () => onChanged(teclearImporte(valorCents, tecla)),
          child: etiqueta,
        ),
      ),
    );
  }
}

/// Diálogo para teclear un importe. Devuelve los céntimos o `null` si se
/// cancela. [minimoCents] desactiva "Aceptar" por debajo de ese valor.
Future<int?> pedirImporte(
  BuildContext context, {
  required String titulo,
  int inicialCents = 0,
  int minimoCents = 0,
  String textoAceptar = 'Aceptar',
}) {
  return showDialog<int>(
    context: context,
    builder: (context) => _ImporteDialog(
      titulo: titulo,
      inicialCents: inicialCents,
      minimoCents: minimoCents,
      textoAceptar: textoAceptar,
    ),
  );
}

class _ImporteDialog extends StatefulWidget {
  const _ImporteDialog({
    required this.titulo,
    required this.inicialCents,
    required this.minimoCents,
    required this.textoAceptar,
  });

  final String titulo;
  final int inicialCents;
  final int minimoCents;
  final String textoAceptar;

  @override
  State<_ImporteDialog> createState() => _ImporteDialogState();
}

class _ImporteDialogState extends State<_ImporteDialog> {
  late int _valor = widget.inicialCents;

  /// El importe es aún el propuesto: como en una caja registradora, la
  /// primera pulsación lo sustituye en lugar de añadirle cifras.
  late bool _sinTocar = widget.inicialCents != 0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final valido = _valor >= widget.minimoCents;
    return AlertDialog(
      title: Text(widget.titulo),
      content: SizedBox(
        width: 320,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_sinTocar)
                Text(
                  'Importe propuesto: teclea para sustituirlo',
                  key: const Key('importe-propuesto'),
                  textAlign: TextAlign.end,
                  style: theme.textTheme.bodySmall,
                ),
              Text(
                formatCents(_valor),
                key: const Key('importe-tecleado'),
                textAlign: TextAlign.end,
                style: theme.textTheme.headlineMedium?.copyWith(
                  color: _sinTocar ? theme.colorScheme.onSurfaceVariant : null,
                ),
              ),
              const SizedBox(height: 12),
              TecladoImporte(
                valorCents: _sinTocar ? 0 : _valor,
                onChanged: (v) => setState(() {
                  _valor = v;
                  _sinTocar = false;
                }),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          key: const Key('importe-aceptar'),
          onPressed: valido ? () => Navigator.of(context).pop(_valor) : null,
          child: Text(widget.textoAceptar),
        ),
      ],
    );
  }
}
