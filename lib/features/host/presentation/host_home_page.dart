import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/money/money.dart';
import '../../../core/network/tcp/tcp_host_server.dart' show ClientSessionInfo;
import '../../cierre_z/presentation/cierre_z_page.dart';
import '../../escandallos/presentation/escandallos_page.dart';
import '../../sala/domain/comanda.dart';
import '../../sala/domain/mesa.dart';
import '../../settings/presentation/settings_providers.dart';
import '../application/host_runtime.dart';
import '../application/sync_outbox.dart';
import '../domain/host_snapshot.dart';
import '../domain/operational_alert.dart';
import 'enrutamiento_page.dart';
import 'host_settings_mapper.dart';
import 'mesa_page.dart';
import 'providers.dart';
import 'reposicion_page.dart';
import 'sync_queue_page.dart';
import 'widgets/host_feedback.dart';
import 'widgets/host_formatos.dart';

/// Pantalla principal del host: estado del servidor y de la sincronización,
/// avisos y el salón de mesas agrupado por zona.
class HostHomePage extends ConsumerWidget {
  const HostHomePage({super.key, this.onAbrirAjustes});

  /// Abre la pantalla de ajustes (la aporta el shell de la aplicación).
  final VoidCallback? onAbrirAjustes;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final runtime = ref.watch(hostRuntimeProvider);
    return switch (runtime) {
      AsyncData(:final value) => _HostHomeView(
        runtime: value,
        onAbrirAjustes: onAbrirAjustes,
      ),
      AsyncError(:final error) => Scaffold(
        appBar: AppBar(title: const Text('TPV')),
        body: MensajeCentrado(
          icono: Icons.error_outline,
          titulo: 'No se pudo arrancar el TPV',
          detalle: mensajeDeError(error),
          accion: Wrap(
            spacing: 12,
            runSpacing: 8,
            alignment: WrapAlignment.center,
            children: [
              FilledButton.icon(
                onPressed: () => ref.invalidate(hostRuntimeProvider),
                icon: const Icon(Icons.refresh),
                label: const Text('Reintentar'),
              ),
              if (onAbrirAjustes != null)
                OutlinedButton.icon(
                  onPressed: onAbrirAjustes,
                  icon: const Icon(Icons.settings),
                  label: const Text('Ajustes'),
                ),
            ],
          ),
        ),
      ),
      _ => const Scaffold(
        body: MensajeCentrado(
          icono: Icons.point_of_sale,
          titulo: 'Arrancando el TPV…',
          accion: CircularProgressIndicator(),
        ),
      ),
    };
  }
}

class _HostHomeView extends ConsumerWidget {
  const _HostHomeView({required this.runtime, this.onAbrirAjustes});

  final HostRuntime runtime;
  final VoidCallback? onAbrirAjustes;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ajustes = ref.watch(appSettingsProvider).value;
    final nombre = ajustes == null
        ? runtime.settings.nombreTpv
        : hostSettingsFromApp(ajustes).nombreTpv;
    final snapshot = ref.watch(hostSnapshotProvider).value;
    final alertas = ref.watch(alertasProvider).value ?? const [];
    final avisos = alertas.where((a) => a.nivel != AlertaNivel.info).length;

    return Scaffold(
      appBar: AppBar(
        title: Text(nombre, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            key: const Key('accion-alertas'),
            tooltip: 'Avisos',
            onPressed: () => _mostrarAlertas(context, alertas),
            icon: Badge.count(
              count: avisos,
              isLabelVisible: avisos > 0,
              child: const Icon(Icons.notifications_outlined),
            ),
          ),
          IconButton(
            key: const Key('accion-cierre-z'),
            tooltip: 'Caja y Cierre Z',
            onPressed: () => _abrir(context, const CierreZPage()),
            icon: const Icon(Icons.point_of_sale),
          ),
          IconButton(
            key: const Key('accion-escandallos'),
            tooltip: 'Escandallos',
            onPressed: () => _abrir(context, const EscandallosPage()),
            icon: const Icon(Icons.menu_book_outlined),
          ),
          IconButton(
            key: const Key('accion-reposicion'),
            tooltip: 'Reposición',
            onPressed: () => _abrir(context, const ReposicionPage()),
            icon: const Icon(Icons.inventory_2_outlined),
          ),
          IconButton(
            key: const Key('accion-enrutamiento'),
            tooltip: 'Enrutamiento de comandas',
            onPressed: () => _abrir(context, const EnrutamientoPage()),
            icon: const Icon(Icons.alt_route),
          ),
          if (onAbrirAjustes != null)
            IconButton(
              key: const Key('accion-ajustes'),
              tooltip: 'Ajustes',
              onPressed: onAbrirAjustes,
              icon: const Icon(Icons.settings_outlined),
            ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(52),
          child: _BarraEstado(runtime: runtime, snapshot: snapshot),
        ),
      ),
      body: snapshot == null
          ? const Center(child: CircularProgressIndicator())
          : _Salon(snapshot: snapshot),
    );
  }

  static void _abrir(BuildContext context, Widget pagina) {
    unawaited(
      Navigator.of(context)
          .push(MaterialPageRoute<void>(builder: (_) => pagina)),
    );
  }

  static void _mostrarAlertas(
    BuildContext context,
    List<OperationalAlert> alertas,
  ) {
    unawaited(
      showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (context) => _AlertasSheet(alertas: alertas.reversed.toList()),
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// Barra de estado

class _BarraEstado extends ConsumerWidget {
  const _BarraEstado({required this.runtime, required this.snapshot});

  final HostRuntime runtime;
  final HostSnapshot? snapshot;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sesiones = ref.watch(sesionesProvider).value ?? const [];
    final status = ref.watch(syncStatusProvider);
    final turno = snapshot?.cierreAbierto;
    final tickets = snapshot?.ticketsTurno.length ?? 0;

    return SizedBox(
      height: 52,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        children: [
          _servidorChip(context, sesiones),
          const SizedBox(width: 8),
          if (status != null) ...[
            _SyncChip(status: status),
            const SizedBox(width: 8),
          ],
          _EstadoChip(
            icono: Icons.schedule,
            texto: turno == null
                ? 'Sin turno · $tickets tickets'
                : 'Turno ${formatHora(turno.abiertoEn)} · $tickets tickets',
          ),
          const SizedBox(width: 8),
          _EstadoChip(
            icono: runtime.erpConfigurado ? Icons.cloud_done : Icons.cloud_off,
            texto: runtime.erpConfigurado ? 'ERP' : 'Sin ERP',
            aviso: !runtime.erpConfigurado,
          ),
          const SizedBox(width: 8),
          _EstadoChip(
            icono: runtime.mysqlConfigurado ? Icons.storage : Icons.block,
            texto: runtime.mysqlConfigurado ? 'Stock' : 'Sin stock',
            aviso: !runtime.mysqlConfigurado,
          ),
          const SizedBox(width: 8),
          _EstadoChip(
            icono: runtime.impresoraConfigurada
                ? Icons.print
                : Icons.print_disabled,
            texto: runtime.impresoraConfigurada ? 'Impresora' : 'Sin impresora',
            aviso: !runtime.impresoraConfigurada,
          ),
        ],
      ),
    );
  }

  Widget _servidorChip(BuildContext context, List<ClientSessionInfo> sesiones) {
    final activo = runtime.network.isRunning;
    final puerto = runtime.network.tcpPort;
    final n = sesiones.length;
    return ActionChip(
      key: const Key('servidor-chip'),
      avatar: Icon(activo ? Icons.wifi_tethering : Icons.portable_wifi_off),
      label: Text(
        activo
            ? 'Servidor :${puerto ?? '-'} · $n '
                  '${n == 1 ? 'comandero' : 'comanderos'}'
            : 'Servidor detenido',
      ),
      onPressed: () => unawaited(
        showModalBottomSheet<void>(
          context: context,
          showDragHandle: true,
          builder: (context) => _SesionesSheet(sesiones: sesiones),
        ),
      ),
    );
  }
}

class _SyncChip extends StatelessWidget {
  const _SyncChip({required this.status});

  final SyncOutboxStatus status;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (IconData icono, String texto, Color? fondo) = switch (status) {
      SyncOutboxStatus(pausada: true) => (
        Icons.pause_circle,
        'Sincronización en pausa',
        scheme.errorContainer,
      ),
      SyncOutboxStatus(:final enError) when enError > 0 => (
        Icons.error,
        '$enError con error',
        scheme.errorContainer,
      ),
      SyncOutboxStatus(:final bloqueados) when bloqueados > 0 => (
        Icons.lock_clock,
        '$bloqueados bloqueados',
        scheme.errorContainer,
      ),
      SyncOutboxStatus(:final pendientes) when pendientes > 0 => (
        Icons.sync,
        '$pendientes pendientes',
        scheme.secondaryContainer,
      ),
      _ => (Icons.cloud_done, 'Sincronizado', null),
    };
    return ActionChip(
      key: const Key('sync-chip'),
      avatar: Icon(icono),
      label: Text(texto),
      backgroundColor: fondo,
      onPressed: () => unawaited(
        Navigator.of(
          context,
        ).push(MaterialPageRoute<void>(builder: (_) => const SyncQueuePage())),
      ),
    );
  }
}

class _EstadoChip extends StatelessWidget {
  const _EstadoChip({
    required this.icono,
    required this.texto,
    this.aviso = false,
  });

  final IconData icono;
  final String texto;
  final bool aviso;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Chip(
      avatar: Icon(icono, color: aviso ? scheme.error : null),
      label: Text(texto),
    );
  }
}

class _SesionesSheet extends StatelessWidget {
  const _SesionesSheet({required this.sesiones});

  final List<ClientSessionInfo> sesiones;

  @override
  Widget build(BuildContext context) {
    if (sesiones.isEmpty) {
      return const SizedBox(
        height: 200,
        child: MensajeCentrado(
          icono: Icons.phone_android,
          titulo: 'No hay comanderos conectados',
        ),
      );
    }
    return ListView(
      shrinkWrap: true,
      children: [
        for (final s in sesiones)
          ListTile(
            leading: const Icon(Icons.phone_android),
            title: Text(s.deviceName),
            subtitle: Text(
              '${s.remoteAddress} · conectado a las '
              '${formatHora(s.connectedAt)}',
            ),
          ),
      ],
    );
  }
}

class _AlertasSheet extends StatelessWidget {
  const _AlertasSheet({required this.alertas});

  /// Del más nuevo al más antiguo.
  final List<OperationalAlert> alertas;

  @override
  Widget build(BuildContext context) {
    if (alertas.isEmpty) {
      return const SizedBox(
        height: 200,
        child: MensajeCentrado(
          icono: Icons.notifications_none,
          titulo: 'Sin avisos',
        ),
      );
    }
    final scheme = Theme.of(context).colorScheme;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      maxChildSize: 0.95,
      builder: (context, controller) => ListView.builder(
        controller: controller,
        itemCount: alertas.length,
        itemBuilder: (context, i) {
          final a = alertas[i];
          final (icono, color) = switch (a.nivel) {
            AlertaNivel.info => (Icons.info_outline, scheme.primary),
            AlertaNivel.aviso => (Icons.warning_amber, scheme.tertiary),
            AlertaNivel.error => (Icons.error_outline, scheme.error),
          };
          return ListTile(
            leading: Icon(icono, color: color),
            title: Text(a.titulo),
            subtitle: Text(
              [
                formatFechaHora(a.cuando),
                if (a.origen != null) a.origen!,
                if (a.detalle != null) a.detalle!,
              ].join(' · '),
            ),
          );
        },
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// Salón

/// Estado visual de una mesa.
enum EstadoMesa { libre, ocupada, cuenta }

EstadoMesa estadoDeMesa(Comanda? comanda) => switch (comanda) {
  null => EstadoMesa.libre,
  Comanda(cuentaSolicitada: true) => EstadoMesa.cuenta,
  _ => EstadoMesa.ocupada,
};

class _Salon extends ConsumerStatefulWidget {
  const _Salon({required this.snapshot});

  final HostSnapshot snapshot;

  @override
  ConsumerState<_Salon> createState() => _SalonState();
}

class _SalonState extends ConsumerState<_Salon> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    // Refresca "tiempo abierta" cada 30 s.
    _ticker = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = widget.snapshot;
    final ahora = ref.watch(relojProvider)();
    final zonas = <String, List<Mesa>>{};
    for (final mesa in snapshot.mesas) {
      zonas.putIfAbsent(mesa.zona, () => []).add(mesa);
    }
    for (final mesas in zonas.values) {
      mesas.sort((a, b) {
        final c = a.orden.compareTo(b.orden);
        return c != 0 ? c : a.nombre.compareTo(b.nombre);
      });
    }
    if (zonas.isEmpty) {
      return const MensajeCentrado(
        icono: Icons.table_restaurant,
        titulo: 'No hay mesas configuradas',
        detalle: 'Añade mesas desde los ajustes del TPV.',
      );
    }
    final ocupadas = snapshot.comandas.length;
    final importeSala = snapshot.comandas.fold<int>(
      0,
      (total, c) => total + c.importeCents,
    );
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Text(
              '$ocupadas de ${snapshot.mesas.length} mesas ocupadas · '
              '${formatCents(importeSala)} en sala',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        ),
        for (final MapEntry(key: zona, value: mesas) in zonas.entries) ...[
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(zona, style: Theme.of(context).textTheme.titleLarge),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            sliver: SliverGrid.builder(
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 200,
                mainAxisExtent: 128,
                crossAxisSpacing: 12,
                mainAxisSpacing: 12,
              ),
              itemCount: mesas.length,
              itemBuilder: (context, i) {
                final mesa = mesas[i];
                return MesaTile(
                  mesa: mesa,
                  comanda: snapshot.comandaDeMesa(mesa.id),
                  ahora: ahora,
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

/// Mesa del salón: color y etiqueta por estado, importe y tiempo abierta.
class MesaTile extends StatelessWidget {
  const MesaTile({
    super.key,
    required this.mesa,
    required this.comanda,
    required this.ahora,
  });

  final Mesa mesa;
  final Comanda? comanda;
  final DateTime ahora;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final estado = estadoDeMesa(comanda);
    final (
      Color fondo,
      Color texto,
      String etiqueta,
      IconData icono,
    ) = switch (estado) {
      EstadoMesa.libre => (
        scheme.surfaceContainerHighest,
        scheme.onSurface,
        'Libre',
        Icons.event_seat_outlined,
      ),
      EstadoMesa.ocupada => (
        scheme.primaryContainer,
        scheme.onPrimaryContainer,
        'Ocupada',
        Icons.restaurant,
      ),
      EstadoMesa.cuenta => (
        scheme.tertiaryContainer,
        scheme.onTertiaryContainer,
        'Cuenta',
        Icons.receipt_long,
      ),
    };
    final c = comanda;
    return Material(
      key: Key('mesa-${mesa.id}'),
      color: fondo,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => unawaited(
          Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => MesaPage(mesaId: mesa.id)),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: DefaultTextStyle.merge(
            style: TextStyle(color: texto),
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
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: texto,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    Icon(icono, color: texto, size: 20),
                  ],
                ),
                const SizedBox(height: 2),
                Text(etiqueta, style: theme.textTheme.labelMedium),
                const Spacer(),
                if (c != null) ...[
                  Text(
                    formatCents(c.importeCents),
                    key: Key('importe-mesa-${mesa.id}'),
                    style: theme.textTheme.titleLarge?.copyWith(color: texto),
                  ),
                  Text(
                    '${formatDuracion(ahora.difference(c.abiertaEn))} · '
                    '${c.lineasActivas.length} líneas',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(color: texto),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
