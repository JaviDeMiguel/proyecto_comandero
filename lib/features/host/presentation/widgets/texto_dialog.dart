import 'package:flutter/material.dart';

/// Pide un texto corto con sugerencias rápidas. Devuelve `null` si se
/// cancela y la cadena recortada (posiblemente vacía) si se acepta.
///
/// El campo lleva la clave `texto-dialogo` y el botón de aceptar
/// `texto-aceptar`.
Future<String?> pedirTexto(
  BuildContext context, {
  required String titulo,
  String etiqueta = 'Texto',
  String? inicial,
  String textoAceptar = 'Aceptar',
  List<String> sugerencias = const [],
}) {
  return showDialog<String>(
    context: context,
    builder: (context) => _TextoDialog(
      titulo: titulo,
      etiqueta: etiqueta,
      inicial: inicial,
      textoAceptar: textoAceptar,
      sugerencias: sugerencias,
    ),
  );
}

class _TextoDialog extends StatefulWidget {
  const _TextoDialog({
    required this.titulo,
    required this.etiqueta,
    required this.inicial,
    required this.textoAceptar,
    required this.sugerencias,
  });

  final String titulo;
  final String etiqueta;
  final String? inicial;
  final String textoAceptar;
  final List<String> sugerencias;

  @override
  State<_TextoDialog> createState() => _TextoDialogState();
}

class _TextoDialogState extends State<_TextoDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.inicial,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // `scrollable`: con el teclado abierto en un teléfono el contenido se
    // desplaza en lugar de desbordarse.
    return AlertDialog(
      scrollable: true,
      title: Text(widget.titulo),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const Key('texto-dialogo'),
              controller: _controller,
              autofocus: true,
              maxLength: 100,
              decoration: InputDecoration(
                labelText: widget.etiqueta,
                border: const OutlineInputBorder(),
              ),
              onSubmitted: (v) => Navigator.of(context).pop(v.trim()),
            ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final s in widget.sugerencias)
                  ActionChip(
                    label: Text(s),
                    onPressed: () => setState(() => _controller.text = s),
                  ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          key: const Key('texto-aceptar'),
          onPressed: () => Navigator.of(context).pop(_controller.text.trim()),
          child: Text(widget.textoAceptar),
        ),
      ],
    );
  }
}
