import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/errors/app_exception.dart';
import '../features/settings/domain/app_settings.dart';
import '../features/settings/presentation/settings_providers.dart';

/// Primer arranque: elegir el papel del dispositivo en la red local.
///
/// La elección se guarda en los ajustes y el shell cambia de pantalla solo
/// (observa `appSettingsProvider`). Puede cambiarse después en Ajustes.
class RoleSelectionPage extends ConsumerStatefulWidget {
  const RoleSelectionPage({super.key});

  @override
  ConsumerState<RoleSelectionPage> createState() => _RoleSelectionPageState();
}

class _RoleSelectionPageState extends ConsumerState<RoleSelectionPage> {
  DeviceRole? _guardando;

  Future<void> _elegir(DeviceRole rol) async {
    if (_guardando != null) return;
    setState(() => _guardando = rol);
    try {
      await ref
          .read(appSettingsProvider.notifier)
          .actualizar((s) => s.copyWith(rol: rol));
    } on Object catch (error) {
      if (!mounted) return;
      final texto = error is AppException ? error.message : '$error';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('No se pudo guardar el modo: $texto'),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
    } finally {
      if (mounted) setState(() => _guardando = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final nombre = ref.watch(appSettingsProvider).value?.deviceName;
    final tarjetas = [
      _TarjetaRol(
        key: const Key('rol-host'),
        icono: Icons.point_of_sale,
        titulo: 'Servidor TPV (tablet)',
        descripcion:
            'Caja y cobro, impresión de tickets y comandas, sincronización '
            'con FacturaScripts y Cierre Z. Recibe los pedidos de los '
            'comanderos. Solo debe haber uno por local.',
        ocupado: _guardando == DeviceRole.host,
        habilitado: _guardando == null,
        onTap: () => unawaited(_elegir(DeviceRole.host)),
      ),
      _TarjetaRol(
        key: const Key('rol-comandero'),
        icono: Icons.phone_android,
        titulo: 'Comandero (móvil)',
        descripcion:
            'Toma de comandas en sala. Encuentra el servidor TPV en la red '
            'Wi-Fi y le envía los pedidos.',
        ocupado: _guardando == DeviceRole.comandero,
        habilitado: _guardando == null,
        onTap: () => unawaited(_elegir(DeviceRole.comandero)),
      ),
    ];

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 900),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Icon(
                    Icons.storefront,
                    size: 56,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '¿Cómo va a funcionar este dispositivo?',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineSmall,
                  ),
                  if (nombre != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      nombre,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                  const SizedBox(height: 24),
                  LayoutBuilder(
                    builder: (context, constraints) {
                      if (constraints.maxWidth < 600) {
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            tarjetas[0],
                            const SizedBox(height: 16),
                            tarjetas[1],
                          ],
                        );
                      }
                      return IntrinsicHeight(
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(child: tarjetas[0]),
                            const SizedBox(width: 16),
                            Expanded(child: tarjetas[1]),
                          ],
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Podrás cambiarlo más adelante en Ajustes.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TarjetaRol extends StatelessWidget {
  const _TarjetaRol({
    super.key,
    required this.icono,
    required this.titulo,
    required this.descripcion,
    required this.ocupado,
    required this.habilitado,
    required this.onTap,
  });

  final IconData icono;
  final String titulo;
  final String descripcion;
  final bool ocupado;
  final bool habilitado;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: habilitado ? onTap : null,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                height: 72,
                child: Center(
                  child: ocupado
                      ? const CircularProgressIndicator()
                      : Icon(icono, size: 72, color: theme.colorScheme.primary),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                titulo,
                textAlign: TextAlign.center,
                style: theme.textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              Text(
                descripcion,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
