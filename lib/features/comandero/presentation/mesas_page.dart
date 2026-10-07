import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/errors/app_exception.dart';
import '../../../core/money/money.dart';
import '../../sala/domain/comanda.dart';
import '../../sala/domain/mesa.dart';
import '../domain/comandero_state.dart';
import 'comandero_carga.dart';
import 'comandero_gateway.dart';
import 'comandero_widgets.dart';
import 'conexion_page.dart';
import 'pedido_page.dart';
import 'providers.dart';

/// Estado visible de una mesa en la rejilla.
enum EstadoMesa {
  libre('Libre'),
  ocupada('Ocupada'),
  cuentaPedida('Cuenta pedida');

  const EstadoMesa(this.etiqueta);

  final String etiqueta;

  static EstadoMesa de(Comanda? comanda) => switch (comanda) {
    null => EstadoMesa.libre,
    Comanda(cuentaSolicitada: true) => EstadoMesa.cuentaPedida,
    _ => EstadoMesa.ocupada,
  };
}

/// Agrupa las mesas por zona conservando el orden en que aparece cada zona y
/// ordenando por [Mesa.orden] dentro de ella.
List<({String zona, List<Mesa> mesas})> mesasPorZona(List<Mesa> mesas) {
  final zonas = <String, List<Mesa>>{};
  for (final mesa in mesas) {
    zonas.putIfAbsent(mesa.zona, () => []).add(mesa);
  }
  return [
    for (final MapEntry(key: zona, value: lista) in zonas.entries)
      (zona: zona, mesas: [...lista]..sort((a, b) => a.orden - b.orden)),
  ];
}

/// Rejilla de mesas por zona con su estado e importe.
class MesasPage extends ConsumerWidget {
  const MesasPage({super.key, this.onAbrirAjustes});

  /// Se pasa a [ConexionPage] al abrirla desde aquí.
  final VoidCallback? onAbrirAjustes;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final gatewayAsync = ref.watch(comanderoControllerProvider);
    final gateway = gatewayAsync.value;
    if (gateway == null) return CargandoComandero(error: gatewayAsync.error);
    final state = ref.watch(comanderoStateProvider).value ?? gateway.state;
    final sala = state is Conectado ? state.sala : gateway.sala;
    final pendientes = pendientesDe(state, fallback: gateway.pendientes);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Mesas'),
        actions: [
          IndicadorConexion(state: state, pendientes: pendientes),
          IconButton(
            key: const Key('mesas.conexion'),
            tooltip: 'Conexión',
            icon: const Icon(Icons.settings_ethernet),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => ConexionPage(onAbrirAjustes: onAbrirAjustes),
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          AvisoSinConexion(state: state, pendientes: pendientes),
          Expanded(
            child: sala == null
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        'Todavía no se han recibido las mesas del host.',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  )
                : RefreshIndicator(
                    onRefresh: () => _refrescar(context, gateway),
                    child: _RejillaMesas(
                      mesas: sala.mesas,
                      comandaDe: sala.comandaDeMesa,
                      onTap: (mesa) => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => PedidoPage(mesaId: mesa.id),
                        ),
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Future<void> _refrescar(
    BuildContext context,
    ComanderoGateway gateway,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await gateway.refrescarSala();
    } on AppException catch (error) {
      mostrarMensaje(messenger, describirError(error), error: true);
    } on StateError catch (error) {
      mostrarMensaje(messenger, describirError(error), error: true);
    }
  }
}

class _RejillaMesas extends StatelessWidget {
  const _RejillaMesas({
    required this.mesas,
    required this.comandaDe,
    required this.onTap,
  });

  final List<Mesa> mesas;
  final Comanda? Function(String mesaId) comandaDe;
  final void Function(Mesa mesa) onTap;

  static const double _altoTarjeta = 140;

  @override
  Widget build(BuildContext context) {
    final zonas = mesasPorZona(mesas);
    if (zonas.isEmpty) {
      return ListView(
        children: const [
          Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'El host no tiene mesas configuradas.',
              textAlign: TextAlign.center,
            ),
          ),
        ],
      );
    }
    // La tarjeta crece con el tamaño de letra del sistema (accesibilidad);
    // 140 es su alto con la letra normal.
    final altoTarjeta = MediaQuery.textScalerOf(context)
        .scale(_altoTarjeta)
        .clamp(_altoTarjeta, _altoTarjeta * 2.4);
    return CustomScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        for (final zona in zonas) ...[
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            sliver: SliverToBoxAdapter(
              child: Text(
                zona.zona,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            sliver: SliverGrid.builder(
              gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 180,
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                mainAxisExtent: altoTarjeta,
              ),
              itemCount: zona.mesas.length,
              itemBuilder: (context, index) {
                final mesa = zona.mesas[index];
                return MesaTile(
                  mesa: mesa,
                  comanda: comandaDe(mesa.id),
                  onTap: () => onTap(mesa),
                );
              },
            ),
          ),
        ],
        const SliverToBoxAdapter(child: SizedBox(height: 24)),
      ],
    );
  }
}

/// Tarjeta de una mesa: nombre, estado, importe y carrito sin enviar.
class MesaTile extends ConsumerWidget {
  const MesaTile({
    super.key,
    required this.mesa,
    required this.comanda,
    required this.onTap,
  });

  final Mesa mesa;
  final Comanda? comanda;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final comanda = this.comanda;
    final estado = EstadoMesa.de(comanda);
    final carrito = ref.watch(pedidoProvider(mesa.id)).value;
    final enCarrito = carrito?.lineas.length ?? 0;
    final (fondo, texto) = switch (estado) {
      EstadoMesa.libre => (scheme.surfaceContainerHighest, scheme.onSurface),
      EstadoMesa.ocupada => (
        scheme.primaryContainer,
        scheme.onPrimaryContainer,
      ),
      EstadoMesa.cuentaPedida => (
        scheme.tertiaryContainer,
        scheme.onTertiaryContainer,
      ),
    };
    return Card(
      key: Key('mesa.${mesa.id}'),
      color: fondo,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      mesa.nombre,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium
                          ?.copyWith(color: texto, fontWeight: FontWeight.bold),
                    ),
                  ),
                  if (estado == EstadoMesa.cuentaPedida)
                    Icon(Icons.receipt_long, color: texto, size: 20),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                estado.etiqueta,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: texto),
              ),
              const Spacer(),
              if (comanda != null)
                Text(
                  formatCents(comanda.importeCents),
                  maxLines: 1,
                  style: Theme.of(context).textTheme.titleLarge
                      ?.copyWith(color: texto, fontWeight: FontWeight.bold),
                ),
              if (enCarrito > 0)
                Row(
                  children: [
                    Icon(Icons.shopping_cart, size: 16, color: texto),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        enCarrito == 1
                            ? '1 línea sin enviar'
                            : '$enCarrito líneas sin enviar',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: texto),
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}
