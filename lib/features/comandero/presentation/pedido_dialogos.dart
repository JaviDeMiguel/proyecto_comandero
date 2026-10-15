/// Diálogos de la toma de pedido del comandero: el detalle de una línea
/// (cantidad, nota y pase) y la anulación de una línea enviada.
library;

import 'package:flutter/material.dart';

import '../../../core/money/money.dart';
import '../../sala/domain/linea_comanda.dart';
import '../../sala/domain/pases.dart';
import '../../sala/presentation/selector_pase.dart';

/// Resultado de [DialogoDetalleLinea]: la cantidad, la nota, si hay que
/// quitar la línea y el pase elegido (`null` = directo). Sin selector de pase
/// el pase es el de partida.
typedef DetalleLinea = ({
  double cantidad,
  String? nota,
  bool quitar,
  int? pase,
});

/// Edita la cantidad, la nota y el pase de una línea del carrito (o de un
/// artículo antes de añadirlo).
///
/// El selector de pase (clave `detalle.pase`, con los chips `pase-directo` y
/// `pase-<n>`) solo aparece si [pases] está activo; si no, el resultado
/// conserva [pase] tal cual.
class DialogoDetalleLinea extends StatefulWidget {
  const DialogoDetalleLinea({
    super.key,
    required this.titulo,
    required this.cantidad,
    this.nota,
    this.pases,
    this.pase,
    this.permiteQuitar = false,
    this.textoConfirmar = 'Guardar',
  });

  final String titulo;
  final double cantidad;
  final String? nota;

  /// Configuración de pases del host (`null` con un host antiguo).
  final PasesConfig? pases;

  /// Pase de partida: el de la línea o el pase activo de la carta.
  final int? pase;
  final bool permiteQuitar;
  final String textoConfirmar;

  @override
  State<DialogoDetalleLinea> createState() => _DialogoDetalleLineaState();
}

class _DialogoDetalleLineaState extends State<DialogoDetalleLinea> {
  late double _cantidad = widget.cantidad;
  late int? _pase = widget.pase;
  late final TextEditingController _nota = TextEditingController(
    text: widget.nota ?? '',
  );

  @override
  void dispose() {
    _nota.dispose();
    super.dispose();
  }

  void _cerrar({required bool quitar}) {
    final nota = _nota.text.trim();
    Navigator.of(context).pop<DetalleLinea>((
      cantidad: _cantidad,
      nota: quitar || nota.isEmpty ? null : nota,
      quitar: quitar,
      pase: _pase,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pases = widget.pases;
    // `scrollable`: con el teclado abierto en un teléfono el contenido se
    // desplaza en lugar de desbordarse.
    return AlertDialog(
      scrollable: true,
      title: Text(widget.titulo),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton.filledTonal(
                key: const Key('detalle.menos'),
                iconSize: 32,
                tooltip: 'Una menos',
                onPressed: _cantidad > 1
                    ? () => setState(() => _cantidad -= 1)
                    : null,
                icon: const Icon(Icons.remove),
              ),
              SizedBox(
                width: 72,
                child: Text(
                  formatQuantity(_cantidad),
                  key: const Key('detalle.cantidad'),
                  textAlign: TextAlign.center,
                  style: theme.textTheme.headlineMedium,
                ),
              ),
              IconButton.filledTonal(
                key: const Key('detalle.mas'),
                iconSize: 32,
                tooltip: 'Una más',
                onPressed: () => setState(() => _cantidad += 1),
                icon: const Icon(Icons.add),
              ),
            ],
          ),
          if (pases != null && pases.activos) ...[
            const SizedBox(height: 16),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: SelectorPase(
                key: const Key('detalle.pase'),
                pases: pases,
                seleccionado: _pase,
                onCambio: (pase) => setState(() => _pase = pase),
                compacto: true,
              ),
            ),
          ],
          const SizedBox(height: 16),
          TextField(
            key: const Key('detalle.nota'),
            controller: _nota,
            maxLength: 120,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'Nota para cocina',
              hintText: 'Sin cebolla, muy hecho…',
            ),
          ),
        ],
      ),
      actions: [
        if (widget.permiteQuitar)
          TextButton(
            onPressed: () => _cerrar(quitar: true),
            child: const Text('Quitar'),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          key: const Key('detalle.confirmar'),
          onPressed: () => _cerrar(quitar: false),
          child: Text(widget.textoConfirmar),
        ),
      ],
    );
  }
}

/// Pide el motivo de la anulación de una línea enviada. Devuelve el motivo
/// (vacío si no se indica) o `null` si se cancela.
class DialogoAnular extends StatefulWidget {
  const DialogoAnular({super.key, required this.linea});

  final LineaComanda linea;

  @override
  State<DialogoAnular> createState() => _DialogoAnularState();
}

class _DialogoAnularState extends State<DialogoAnular> {
  static const List<String> _motivos = [
    'Error al pedir',
    'El cliente lo cancela',
    'Agotado',
    'Invitación',
  ];

  final TextEditingController _motivo = TextEditingController();

  @override
  void dispose() {
    _motivo.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final linea = widget.linea;
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text(
        'Anular ${formatQuantity(linea.cantidad)} × ${linea.descripcion}',
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final motivo in _motivos)
                ActionChip(
                  label: Text(motivo),
                  onPressed: () => setState(() => _motivo.text = motivo),
                ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('anular.motivo'),
            controller: _motivo,
            maxLength: 100,
            decoration: const InputDecoration(labelText: 'Motivo'),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          key: const Key('anular.confirmar'),
          style: FilledButton.styleFrom(
            backgroundColor: scheme.error,
            foregroundColor: scheme.onError,
          ),
          onPressed: () => Navigator.of(context).pop(_motivo.text.trim()),
          child: const Text('Anular'),
        ),
      ],
    );
  }
}
