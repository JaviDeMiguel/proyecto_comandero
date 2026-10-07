import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/isolates/reposicion/reposicion_models.dart';
import '../../../core/money/money.dart';
import 'providers.dart';
import 'widgets/host_feedback.dart';
import 'widgets/host_formatos.dart';

/// Reaprovisionamiento: última auditoría del almacén (roturas, pedidos
/// propuestos, referencias sin proveedor), auditar ahora y enviar pedidos.
class ReposicionPage extends ConsumerStatefulWidget {
  const ReposicionPage({super.key});

  @override
  ConsumerState<ReposicionPage> createState() => _ReposicionPageState();
}

class _ReposicionPageState extends ConsumerState<ReposicionPage> {
  bool _trabajando = false;

  @override
  Widget build(BuildContext context) {
    final servicio = ref.watch(reposicionServiceProvider);
    final runtime = ref.watch(hostRuntimeReadyProvider);
    final resultado = ref.watch(reposicionProvider).value;
    final cuando = servicio.ultimaAuditoriaEn;
    final theme = Theme.of(context);

    if (!servicio.disponible) {
      return Scaffold(
        appBar: AppBar(title: const Text('Reposición')),
        body: const MensajeCentrado(
          icono: Icons.storage,
          titulo: 'Reposición no disponible',
          detalle:
              'La auditoría de stock lee los niveles por MySQL directo. '
              'Configura la conexión MySQL en los ajustes del TPV.',
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Reposición')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              FilledButton.icon(
                key: const Key('auditar-ahora'),
                onPressed: _trabajando
                    ? null
                    : () => unawaited(_auditar(pedir: false)),
                icon: const Icon(Icons.fact_check_outlined),
                label: const Text('Auditar ahora'),
              ),
              FilledButton.tonalIcon(
                key: const Key('enviar-pedidos'),
                onPressed:
                    _trabajando ||
                        resultado == null ||
                        resultado.pedidos.isEmpty ||
                        !runtime.erpConfigurado
                    ? null
                    : () => unawaited(_enviarPedidos(resultado)),
                icon: const Icon(Icons.local_shipping_outlined),
                label: const Text('Enviar pedidos'),
              ),
              if (_trabajando)
                const SizedBox.square(
                  dimension: 24,
                  child: CircularProgressIndicator(strokeWidth: 3),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            [
              cuando == null
                  ? 'Aún no se ha auditado el almacén en esta sesión.'
                  : 'Última auditoría: ${formatFechaHora(cuando)}.',
              servicio.settings.automatica
                  ? 'Reposición automática activada.'
                  : 'Reposición automática desactivada: los pedidos se '
                        'envían a mano.',
              if (!runtime.erpConfigurado)
                'Sin ERP configurado: no se pueden crear pedidos.',
            ].join(' '),
            style: theme.textTheme.bodyMedium,
          ),
          if (resultado != null) ..._resultado(context, resultado),
        ],
      ),
    );
  }

  List<Widget> _resultado(BuildContext context, ReposicionResult r) {
    final theme = Theme.of(context);
    return [
      for (final aviso in r.avisos)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text('Aviso: $aviso'),
        ),
      const SizedBox(height: 16),
      Text(
        'Pedidos propuestos (${r.pedidos.length})',
        style: theme.textTheme.titleLarge,
      ),
      if (r.pedidos.isEmpty)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: Text('No hace falta pedir nada.'),
        ),
      for (final p in r.pedidos)
        Card(
          key: Key('pedido-${p.codproveedor}'),
          margin: const EdgeInsets.symmetric(vertical: 6),
          child: ExpansionTile(
            title: Text(p.nombreProveedor ?? p.codproveedor),
            subtitle: Text(
              '${p.lineas.length} referencias · estimado '
              '${formatCents(p.importeEstimadoCents)}',
            ),
            children: [
              for (final l in p.lineas)
                ListTile(
                  dense: true,
                  title: Text(l.descripcion ?? l.referencia),
                  subtitle: Text(l.referencia),
                  trailing: Text(
                    '${formatQuantity(l.cantidad)} × '
                    '${formatCents(centsFromDecimal(l.precioNeto))}',
                  ),
                ),
            ],
          ),
        ),
      const SizedBox(height: 16),
      Text('Roturas (${r.roturas.length})', style: theme.textTheme.titleLarge),
      for (final rotura in r.roturas) _filaRotura(context, rotura),
      if (r.sinProveedor.isNotEmpty) ...[
        const SizedBox(height: 16),
        Text(
          'Sin proveedor (${r.sinProveedor.length})',
          style: theme.textTheme.titleLarge?.copyWith(
            color: theme.colorScheme.error,
          ),
        ),
        const Text(
          'Estas referencias están bajo mínimo pero no tienen ninguna oferta '
          'de proveedor en FacturaScripts: pídelas a mano o da de alta el '
          'proveedor del producto.',
        ),
        for (final rotura in r.sinProveedor) _filaRotura(context, rotura),
      ],
    ];
  }

  Widget _filaRotura(BuildContext context, RoturaStock r) {
    return ListTile(
      key: Key('rotura-${r.referencia}'),
      leading: const Icon(Icons.warning_amber),
      title: Text(r.descripcion ?? r.referencia),
      subtitle: Text(
        '${r.referencia} · disponible ${formatQuantity(r.disponible)} · '
        'pendiente ${formatQuantity(r.pterecibir)} · mínimo '
        '${formatQuantity(r.stockmin)}',
      ),
      trailing: Text('Faltan ${formatQuantity(r.cantidadNecesaria)}'),
    );
  }

  Future<void> _auditar({required bool pedir}) async {
    setState(() => _trabajando = true);
    await ejecutarAccion(
      context,
      () => ref.read(reposicionServiceProvider).auditar(pedir: pedir),
      exito: pedir
          ? 'Pedidos encolados para enviarse a FacturaScripts'
          : 'Auditoría completada',
    );
    if (mounted) setState(() => _trabajando = false);
  }

  Future<void> _enviarPedidos(ReposicionResult r) async {
    final total = r.pedidos.fold<int>(0, (s, p) => s + p.importeEstimadoCents);
    final ok = await confirmar(
      context,
      titulo: 'Enviar pedidos a proveedor',
      mensaje:
          'Se volverá a auditar el almacén y se crearán en FacturaScripts los '
          'pedidos resultantes (ahora ${r.pedidos.length}, estimado '
          '${formatCents(total)}).',
      textoAceptar: 'Enviar',
    );
    if (!ok || !mounted) return;
    await _auditar(pedir: true);
  }
}
