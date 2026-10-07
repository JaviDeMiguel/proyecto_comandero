import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/comandero_state.dart';
import 'comandero_carga.dart';
import 'comandero_gateway.dart';
import 'comandero_widgets.dart';
import 'conexion_page.dart';
import 'mesas_page.dart';
import 'providers.dart';

/// Pantalla raíz del modo comandero.
///
/// - Rechazado por el host: [ConexionPage] (hace falta acción del usuario).
/// - Con host objetivo y sala recibida (aunque se esté reconectando):
///   [MesasPage], para seguir tomando pedidos en cola.
/// - En cualquier otro caso: [ConexionPage].
///
/// Si el controlador se recrea (cambia la identidad del dispositivo) se
/// cierran las pantallas abiertas encima, que apuntaban al anterior.
class ComanderoHome extends ConsumerWidget {
  const ComanderoHome({super.key, this.onAbrirAjustes});

  final VoidCallback? onAbrirAjustes;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen<AsyncValue<ComanderoGateway>>(comanderoControllerProvider, (
      previous,
      next,
    ) {
      final anterior = previous?.value;
      final nuevo = next.value;
      if (anterior != null && nuevo != null && !identical(anterior, nuevo)) {
        Navigator.of(context).popUntil((route) => route.isFirst);
      }
    });
    ref.listen<AsyncValue<AvisoComandero>>(comanderoAvisosProvider, (_, next) {
      final aviso = next.value;
      if (aviso != null) {
        mostrarMensaje(ScaffoldMessenger.of(context), aviso.mensaje);
      }
    });
    final gatewayAsync = ref.watch(comanderoControllerProvider);
    final gateway = gatewayAsync.value;
    if (gateway == null || gatewayAsync.isLoading) {
      return CargandoComandero(error: gatewayAsync.error);
    }
    final state = ref.watch(comanderoStateProvider).value ?? gateway.state;
    final verMesas =
        state is! Rechazado && state.host != null && gateway.sala != null;
    return verMesas
        ? MesasPage(onAbrirAjustes: onAbrirAjustes)
        : ConexionPage(onAbrirAjustes: onAbrirAjustes);
  }
}
