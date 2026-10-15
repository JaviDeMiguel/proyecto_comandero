/// Diálogo compartido para fijar los comensales de una mesa: rejilla de
/// acceso rápido de 1 a [comensalesRejilla] (un toque elige y cierra) y campo
/// libre de 1 a [comensalesMaximo] con teclado numérico.
///
/// Lo usan `MesaPage` (tablet) y `PedidoPage` (comandero). No depende de
/// Riverpod: devuelve el número y quien lo abre decide qué hacer con él
/// (`fijarComensales` con comanda, o guardarlo para el primer envío).
library;

import 'package:flutter/material.dart';

/// Máximo que admite el campo libre.
const int comensalesMaximo = 99;

/// Último número de la rejilla de acceso rápido.
const int comensalesRejilla = 12;

/// Uno o dos dígitos y nada más: los que tiene [comensalesMaximo] (99).
final RegExp _unoODosDigitos = RegExp(r'^\d{1,2}$');

/// Entero de 1 a [comensalesMaximo] escrito en [texto], sin contar los
/// espacios de los extremos; `null` si está vacío, no son uno o dos dígitos
/// (signos como `+5` o `-3`, hexadecimales como `0x63`, decimales) o se sale
/// del rango (0). `int.tryParse` por sí sola aceptaría el signo y el prefijo
/// `0x`.
int? parsearComensales(String texto) {
  final limpio = texto.trim();
  if (!_unoODosDigitos.hasMatch(limpio)) return null;
  final valor = int.parse(limpio);
  return valor >= 1 && valor <= comensalesMaximo ? valor : null;
}

/// Abre el diálogo. Devuelve el número elegido o `null` si se cancela.
/// [inicial] rellena el campo y resalta su tecla; se ignora si no está entre
/// 1 y [comensalesMaximo].
Future<int?> pedirComensales(BuildContext context, {int? inicial}) {
  return showDialog<int>(
    context: context,
    builder: (_) => _ComensalesDialog(inicial: inicial),
  );
}

class _ComensalesDialog extends StatefulWidget {
  const _ComensalesDialog({required this.inicial});

  final int? inicial;

  @override
  State<_ComensalesDialog> createState() => _ComensalesDialogState();
}

class _ComensalesDialogState extends State<_ComensalesDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: switch (widget.inicial) {
      final int valor when valor >= 1 && valor <= comensalesMaximo => '$valor',
      _ => '',
    },
  );

  @override
  void initState() {
    super.initState();
    _controller.addListener(_alCambiarTexto);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _alCambiarTexto() => setState(() {});

  void _aceptar(int valor) => Navigator.of(context).pop(valor);

  void _aceptarCampo() {
    final valor = parsearComensales(_controller.text);
    if (valor != null) _aceptar(valor);
  }

  /// Mensaje bajo el campo: solo cuando hay texto y no vale.
  String? _error(String texto) {
    if (texto.trim().isEmpty || parsearComensales(texto) != null) return null;
    return 'Indica un número entre 1 y $comensalesMaximo';
  }

  @override
  Widget build(BuildContext context) {
    final texto = _controller.text;
    final valor = parsearComensales(texto);
    // `scrollable`: con el teclado abierto en un teléfono el contenido se
    // desplaza en lugar de desbordarse.
    return AlertDialog(
      scrollable: true,
      title: const Text('Comensales'),
      content: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Rejilla(resaltado: valor, onElegir: _aceptar),
            const SizedBox(height: 12),
            TextField(
              key: const Key('comensales-campo'),
              controller: _controller,
              keyboardType: TextInputType.number,
              textInputAction: TextInputAction.done,
              maxLength: 3,
              decoration: InputDecoration(
                labelText: 'Otro número',
                hintText: '1 a $comensalesMaximo',
                counterText: '',
                errorText: _error(texto),
                border: const OutlineInputBorder(),
              ),
              onSubmitted: (_) => _aceptarCampo(),
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
          key: const Key('comensales-aceptar'),
          onPressed: valor == null ? null : () => _aceptar(valor),
          child: const Text('Aceptar'),
        ),
      ],
    );
  }
}

/// Teclas de 1 a [comensalesRejilla] (clave `comensales-<n>`); la que
/// coincide con [resaltado] se pinta rellena, el resto con borde.
class _Rejilla extends StatelessWidget {
  const _Rejilla({required this.resaltado, required this.onElegir});

  final int? resaltado;
  final ValueChanged<int> onElegir;

  static const int _columnas = 4;
  static const double _altoTecla = 48;

  @override
  Widget build(BuildContext context) {
    final estilo = Theme.of(context).textTheme.titleMedium;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (
          var primero = 1;
          primero <= comensalesRejilla;
          primero += _columnas
        )
          Row(
            children: [
              for (var n = primero; n < primero + _columnas; n++)
                Expanded(child: _tecla(n, estilo)),
            ],
          ),
      ],
    );
  }

  Widget _tecla(int n, TextStyle? estilo) {
    final clave = Key('comensales-$n');
    final etiqueta = Text('$n');
    void elegir() => onElegir(n);
    return Padding(
      padding: const EdgeInsets.all(3),
      child: SizedBox(
        height: _altoTecla,
        child: n == resaltado
            ? FilledButton(
                key: clave,
                style: FilledButton.styleFrom(
                  padding: EdgeInsets.zero,
                  textStyle: estilo,
                ),
                onPressed: elegir,
                child: etiqueta,
              )
            : OutlinedButton(
                key: clave,
                style: OutlinedButton.styleFrom(
                  padding: EdgeInsets.zero,
                  textStyle: estilo,
                ),
                onPressed: elegir,
                child: etiqueta,
              ),
      ),
    );
  }
}
