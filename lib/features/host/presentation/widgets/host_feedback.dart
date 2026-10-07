import 'package:flutter/material.dart';

import '../../../../core/errors/app_exception.dart';

/// Texto para el usuario de un error: el mensaje de las excepciones tipadas
/// o una frase genérica para el resto (nunca una traza).
String mensajeDeError(Object error) => switch (error) {
  AppException(:final message) => message,
  StateError(:final message) => message,
  _ => 'Error inesperado: $error',
};

void mostrarMensaje(
  BuildContext context,
  String texto, {
  bool error = false,
  Duration duracion = const Duration(seconds: 4),
}) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  final scheme = Theme.of(context).colorScheme;
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(
          texto,
          style: error ? TextStyle(color: scheme.onErrorContainer) : null,
        ),
        backgroundColor: error ? scheme.errorContainer : null,
        behavior: SnackBarBehavior.floating,
        duration: duracion,
      ),
    );
}

/// Ejecuta [accion] mostrando [exito] al terminar o el error traducido si
/// falla. Devuelve `true` si terminó bien. Los errores no tipados se
/// muestran igualmente: la interfaz nunca deja escapar una excepción.
Future<bool> ejecutarAccion(
  BuildContext context,
  Future<void> Function() accion, {
  String? exito,
}) async {
  try {
    await accion();
    if (exito != null && context.mounted) mostrarMensaje(context, exito);
    return true;
  } on Object catch (error) {
    if (context.mounted) {
      mostrarMensaje(context, mensajeDeError(error), error: true);
    }
    return false;
  }
}

/// Diálogo de confirmación; devuelve `true` solo si se acepta.
Future<bool> confirmar(
  BuildContext context, {
  required String titulo,
  required String mensaje,
  String textoAceptar = 'Aceptar',
  bool peligroso = false,
}) async {
  final resultado = await showDialog<bool>(
    context: context,
    builder: (context) {
      final scheme = Theme.of(context).colorScheme;
      return AlertDialog(
        title: Text(titulo),
        content: Text(mensaje),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            key: const Key('confirmar-aceptar'),
            style: peligroso
                ? FilledButton.styleFrom(
                    backgroundColor: scheme.error,
                    foregroundColor: scheme.onError,
                  )
                : null,
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(textoAceptar),
          ),
        ],
      );
    },
  );
  return resultado ?? false;
}

/// Mensaje centrado para estados vacíos o de error.
class MensajeCentrado extends StatelessWidget {
  const MensajeCentrado({
    super.key,
    required this.icono,
    required this.titulo,
    this.detalle,
    this.accion,
  });

  final IconData icono;
  final String titulo;
  final String? detalle;
  final Widget? accion;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icono, size: 56, color: theme.colorScheme.outline),
              const SizedBox(height: 12),
              Text(
                titulo,
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium,
              ),
              if (detalle != null) ...[
                const SizedBox(height: 8),
                Text(
                  detalle!,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium,
                ),
              ],
              if (accion != null) ...[const SizedBox(height: 16), accion!],
            ],
          ),
        ),
      ),
    );
  }
}
