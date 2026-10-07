import 'package:flutter/material.dart';

import '../../../core/errors/app_exception.dart';
import '../../../core/network/protocol/transport_messages.dart';
import '../domain/comandero_exceptions.dart';
import '../domain/comandero_state.dart';

/// Texto apto para la interfaz a partir de un error.
String describirError(Object error) => switch (error) {
  ComanderoSalaException(:final message) => message,
  SinConexionException(:final message) => message,
  AppException(:final message) => message,
  StateError() => 'El comandero se está reiniciando; inténtalo de nuevo',
  _ => error.toString(),
};

/// Explicación de un rechazo del host según su código.
String explicarRechazo(String codigo, String mensaje) => switch (codigo) {
  RejectCodes.unauthorized =>
    'El host exige un código de emparejamiento y el de este comandero no es '
        'válido o falta. Pídelo en la caja e introdúcelo abajo.',
  RejectCodes.unsupportedVersion =>
    'La versión de este comandero no es compatible con la del host. '
        'Actualiza la aplicación.',
  RejectCodes.serverFull =>
    'El host no admite más comanderos conectados. Desconecta otro '
        'dispositivo y vuelve a intentarlo.',
  ByeReasons.replaced =>
    'Otro dispositivo con la misma identidad se ha conectado al host.',
  _ => mensaje,
};

/// Etiqueta corta del estado de la conexión.
String etiquetaEstado(ComanderoState state) => switch (state) {
  SinHost() => 'Sin conexión',
  Buscando() => 'Buscando host…',
  Conectando(:final host) => 'Conectando con ${host.etiqueta}…',
  Conectado(:final host) => 'Conectado a ${host.etiqueta}',
  Reconectando(:final host, :final intento) =>
    'Reconectando con ${host.etiqueta} (intento $intento)…',
  Rechazado() => 'Conexión rechazada',
};

/// Peticiones fiables pendientes que refleja el estado (0 si no aplica).
int pendientesDe(ComanderoState state, {int fallback = 0}) => switch (state) {
  Conectado(:final pendientes) => pendientes,
  Reconectando(:final pendientes) => pendientes,
  Rechazado(:final pendientes) => pendientes,
  _ => fallback,
};

/// Indicador compacto de la conexión para la barra superior: punto de color,
/// texto y, si los hay, envíos pendientes.
class IndicadorConexion extends StatelessWidget {
  const IndicadorConexion({
    super.key,
    required this.state,
    this.pendientes = 0,
  });

  final ComanderoState state;
  final int pendientes;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (color, icono) = switch (state) {
      Conectado() => (Colors.green.shade600, Icons.wifi),
      Conectando() || Buscando() => (scheme.tertiary, Icons.wifi_find),
      Reconectando() => (Colors.orange.shade700, Icons.wifi_off),
      SinHost() || Rechazado() => (scheme.error, Icons.wifi_off),
    };
    final texto = switch (state) {
      Conectado() => 'En línea',
      Conectando() || Buscando() => 'Conectando',
      Reconectando() => 'Sin conexión',
      SinHost() => 'Sin host',
      Rechazado() => 'Rechazado',
    };
    return Semantics(
      label:
          '${etiquetaEstado(state)}'
          '${pendientes > 0 ? ', $pendientes envíos pendientes' : ''}',
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icono, color: color, size: 20),
          const SizedBox(width: 4),
          Text(texto, style: TextStyle(color: color)),
          if (pendientes > 0) ...[
            const SizedBox(width: 8),
            Badge(
              key: const Key('comandero.pendientes'),
              label: Text('$pendientes'),
              backgroundColor: Colors.orange.shade700,
              child: const Icon(Icons.schedule_send, size: 20),
            ),
          ],
        ],
      ),
    );
  }
}

/// Franja de aviso cuando no hay sesión con el host: explica que los envíos
/// quedan en cola. No ocupa espacio si se está conectado.
class AvisoSinConexion extends StatelessWidget {
  const AvisoSinConexion({
    super.key,
    required this.state,
    required this.pendientes,
  });

  final ComanderoState state;
  final int pendientes;

  @override
  Widget build(BuildContext context) {
    final state = this.state;
    if (state is Conectado) {
      return state.catalogoDesactualizado
          ? const _AvisoCatalogoDesactualizado()
          : const SizedBox.shrink();
    }
    final scheme = Theme.of(context).colorScheme;
    final enCola = pendientes == 0
        ? 'Lo que envíes quedará en cola y saldrá al reconectar.'
        : pendientes == 1
        ? '1 envío pendiente: saldrá al reconectar.'
        : '$pendientes envíos pendientes: saldrán al reconectar.';
    return Material(
      key: const Key('comandero.avisoSinConexion'),
      color: scheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            Icon(Icons.cloud_off, color: scheme.onErrorContainer),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                '${etiquetaEstado(state)}. $enCola',
                style: TextStyle(color: scheme.onErrorContainer),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Franja de aviso cuando, conectado, la carta no está al día (el host avisó
/// de un catálogo nuevo y aún no se ha podido descargar).
class _AvisoCatalogoDesactualizado extends StatelessWidget {
  const _AvisoCatalogoDesactualizado();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      key: const Key('comandero.avisoCatalogo'),
      color: scheme.tertiaryContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            Icon(Icons.sync_problem, color: scheme.onTertiaryContainer),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'La carta ha cambiado en el host y aún no se ha podido '
                'descargar: precios y artículos pueden no estar al día. '
                'Reintentando…',
                style: TextStyle(color: scheme.onTertiaryContainer),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Muestra un mensaje breve en la parte inferior, con una [accion]
/// opcional (p. ej. "Deshacer").
void mostrarMensaje(
  ScaffoldMessengerState messenger,
  String texto, {
  bool error = false,
  SnackBarAction? accion,
}) {
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(texto),
        behavior: SnackBarBehavior.floating,
        backgroundColor: error ? Colors.red.shade700 : null,
        action: accion,
        // Con acción, que se cierre sola aunque haya un botón que pulsar.
        persist: accion == null ? null : false,
        duration: accion == null
            ? const Duration(milliseconds: 4000)
            : const Duration(seconds: 6),
      ),
    );
}
