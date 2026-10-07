import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/sync_outbox.dart';
import '../domain/sync_job.dart';
import 'providers.dart';
import 'widgets/host_feedback.dart';
import 'widgets/host_formatos.dart';

/// Etiqueta visible del estado de un trabajo.
String etiquetaEstadoJob(SyncJob job) => switch (job.estado) {
  SyncJobEstado.pendiente =>
    job.proximoIntentoEn == null ? 'Pendiente' : 'Reintento programado',
  SyncJobEstado.enCurso => 'Enviando…',
  SyncJobEstado.hecho => 'Hecho',
  SyncJobEstado.error => 'Error',
  SyncJobEstado.bloqueado => 'En pausa',
};

/// Cola de sincronización con el ERP y MySQL: estado de cada trabajo, errores
/// y acciones (reintentar, descartar, reanudar tras una pausa).
class SyncQueuePage extends ConsumerStatefulWidget {
  const SyncQueuePage({super.key});

  @override
  ConsumerState<SyncQueuePage> createState() => _SyncQueuePageState();
}

class _SyncQueuePageState extends ConsumerState<SyncQueuePage> {
  bool _verHechos = false;

  @override
  Widget build(BuildContext context) {
    final snapshot = ref.watch(hostSnapshotProvider).value;
    final status = ref.watch(syncStatusProvider);
    final cola = snapshot?.cola ?? const <SyncJob>[];
    final activos = [
      for (final j in cola)
        if (j.estado != SyncJobEstado.hecho) j,
    ];
    final hechos = [
      for (final j in cola.reversed)
        if (j.estado == SyncJobEstado.hecho) j,
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Text('Sincronización'),
        actions: [
          IconButton(
            tooltip: _verHechos ? 'Ocultar completados' : 'Ver completados',
            onPressed: () => setState(() => _verHechos = !_verHechos),
            icon: Icon(_verHechos ? Icons.visibility_off : Icons.history),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          if (status != null) _Resumen(status: status),
          if (activos.isEmpty)
            const Padding(
              padding: EdgeInsets.all(32),
              child: MensajeCentrado(
                icono: Icons.cloud_done_outlined,
                titulo: 'No hay trabajos pendientes',
                detalle:
                    'Las facturas, descuentos de stock, pedidos y asientos '
                    'se han enviado.',
              ),
            ),
          for (final job in activos) _JobTile(job: job),
          if (_verHechos) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Text(
                'Completados (${hechos.length})',
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            for (final job in hechos) _JobTile(job: job),
          ],
        ],
      ),
    );
  }
}

class _Resumen extends ConsumerWidget {
  const _Resumen({required this.status});

  final SyncOutboxStatus status;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final ultimoExito = status.ultimoExito;
    final proximo = status.proximoIntentoEn;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (status.pausada)
          MaterialBanner(
            key: const Key('banner-pausa'),
            backgroundColor: theme.colorScheme.errorContainer,
            leading: const Icon(Icons.pause_circle),
            content: Text(
              'La sincronización está en pausa'
              '${status.motivoPausa == null ? '' : ': ${status.motivoPausa}'}'
              '.\nRevisa la configuración (token del ERP, credenciales de '
              'MySQL) antes de reanudar: repetir credenciales inválidas puede '
              'bloquear la IP en FacturaScripts.',
            ),
            actions: [
              FilledButton.icon(
                key: const Key('reanudar-cola'),
                // A través del runtime: además de la cola, rearma el
                // cortafuegos del cliente del ERP tras un fallo de credenciales.
                onPressed: () => unawaited(
                  ejecutarAccion(
                    context,
                    () => ref
                        .read(hostRuntimeReadyProvider)
                        .reanudarSincronizacion(),
                    exito: 'Sincronización reanudada',
                  ),
                ),
                icon: const Icon(Icons.play_arrow),
                label: const Text('Reanudar'),
              ),
            ],
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Wrap(
            spacing: 24,
            runSpacing: 8,
            children: [
              _dato(context, 'Pendientes', '${status.pendientes}'),
              _dato(context, 'Con error', '${status.enError}'),
              _dato(context, 'En pausa', '${status.bloqueados}'),
              _dato(
                context,
                'Último envío correcto',
                ultimoExito == null ? '—' : formatFechaHora(ultimoExito),
              ),
              if (proximo != null)
                _dato(context, 'Próximo reintento', formatHora(proximo)),
            ],
          ),
        ),
        const Divider(),
      ],
    );
  }

  Widget _dato(BuildContext context, String etiqueta, String valor) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(etiqueta, style: theme.textTheme.labelMedium),
        Text(valor, style: theme.textTheme.titleMedium),
      ],
    );
  }
}

class _JobTile extends ConsumerWidget {
  const _JobTile({required this.job});

  final SyncJob job;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final (icono, color) = switch (job.estado) {
      SyncJobEstado.pendiente => (Icons.schedule, scheme.secondary),
      SyncJobEstado.enCurso => (Icons.sync, scheme.primary),
      SyncJobEstado.hecho => (Icons.check_circle, scheme.primary),
      SyncJobEstado.error => (Icons.error, scheme.error),
      SyncJobEstado.bloqueado => (Icons.pause_circle, scheme.error),
    };
    final detalles = [
      '${etiquetaEstadoJob(job)} · creado ${formatFechaHora(job.creadoEn)}',
      if (job.intentos > 0) '${job.intentos} intentos',
      if (job.proximoIntentoEn != null)
        'próximo a las ${formatHora(job.proximoIntentoEn!)}',
      if (job.terminadoEn != null)
        'terminado ${formatFechaHora(job.terminadoEn!)}',
    ].join(' · ');
    final error = job.ultimoError;
    final puedeReintentar =
        job.estado == SyncJobEstado.error ||
        (job.estado == SyncJobEstado.pendiente && job.proximoIntentoEn != null);
    final puedeDescartar =
        job.estado != SyncJobEstado.enCurso &&
        job.estado != SyncJobEstado.hecho;

    return Card(
      key: Key('job-${job.id}'),
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icono, color: color),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    job.descripcion,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(detalles, style: Theme.of(context).textTheme.bodySmall),
            if (error != null && job.estado != SyncJobEstado.hecho) ...[
              const SizedBox(height: 8),
              Text(error, style: TextStyle(color: scheme.error)),
            ],
            for (final aviso in job.avisos)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('Aviso: $aviso'),
              ),
            if (puedeReintentar || puedeDescartar)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    if (puedeReintentar)
                      FilledButton.icon(
                        key: Key('reintentar-${job.id}'),
                        onPressed: () => unawaited(
                          ejecutarAccion(
                            context,
                            () =>
                                ref.read(syncOutboxProvider).reintentar(job.id),
                            exito: 'Reintento solicitado',
                          ),
                        ),
                        icon: const Icon(Icons.refresh),
                        label: Text(
                          job.estado == SyncJobEstado.error
                              ? 'Reintentar'
                              : 'Reintentar ahora',
                        ),
                      ),
                    if (puedeDescartar)
                      OutlinedButton.icon(
                        key: Key('descartar-${job.id}'),
                        onPressed: () => unawaited(_descartar(context, ref)),
                        icon: const Icon(Icons.delete_outline),
                        label: const Text('Descartar'),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _descartar(BuildContext context, WidgetRef ref) async {
    final aviso = switch (job.tipo) {
      SyncJobTipo.factura =>
        'El ticket se quedará SIN factura en FacturaScripts. Hazlo solo si '
            'ya la creaste a mano.',
      SyncJobTipo.descuentoStock =>
        'El stock de las materias primas no se descontará.',
      SyncJobTipo.pedidoProveedor => 'El pedido al proveedor no se creará.',
      SyncJobTipo.asientoZ => 'El asiento del Cierre Z no se contabilizará.',
    };
    final ok = await confirmar(
      context,
      titulo: 'Descartar "${job.descripcion}"',
      mensaje: '$aviso Esta acción no se puede deshacer.',
      textoAceptar: 'Descartar',
      peligroso: true,
    );
    if (!ok || !context.mounted) return;
    await ejecutarAccion(context, () async {
      final hecho = await ref.read(syncOutboxProvider).descartar(job.id);
      if (!hecho) {
        throw StateError('El trabajo se está ejecutando; inténtalo después');
      }
    }, exito: 'Trabajo descartado');
  }
}
