import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../settings/presentation/settings_providers.dart';
import 'comandero_widgets.dart';
import 'providers.dart';

/// Pantalla mientras se prepara el controlador del comandero (ajustes y
/// caché) o si no se pudo preparar, con opción de reintentar.
class CargandoComandero extends ConsumerWidget {
  const CargandoComandero({super.key, this.error});

  final Object? error;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final error = this.error;
    return Scaffold(
      appBar: AppBar(title: const Text('Comandero')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: error == null
              ? const Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 16),
                    Text('Preparando el comandero…'),
                  ],
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.error_outline,
                      size: 48,
                      color: Theme.of(context).colorScheme.error,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'No se pudo preparar el comandero',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    Text(describirError(error), textAlign: TextAlign.center),
                    const SizedBox(height: 24),
                    FilledButton.icon(
                      onPressed: () {
                        ref
                          ..invalidate(settingsRepositoryProvider)
                          ..invalidate(comanderoCacheProvider)
                          ..invalidate(comanderoControllerProvider);
                      },
                      icon: const Icon(Icons.refresh),
                      label: const Text('Reintentar'),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}
