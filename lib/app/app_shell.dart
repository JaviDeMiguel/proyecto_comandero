import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/errors/app_exception.dart';
import '../core/logging/app_logger.dart';
import '../features/comandero/presentation/comandero_home.dart';
import '../features/comandero/presentation/providers.dart';
import '../features/host/presentation/providers.dart';
import '../features/settings/application/settings_service.dart'
    show restablecerAjustesIlegibles;
import '../features/settings/domain/app_settings.dart';
import '../features/settings/presentation/settings_providers.dart';
import 'host_shell.dart';
import 'navigation.dart';
import 'role_selection_page.dart';

final Logger _log = appLogger('app.shell');

/// Raíz de la aplicación: decide qué mostrar según los ajustes.
///
/// * Cargando los ajustes: [PantallaArranque].
/// * Error al cargarlos: [ErrorAjustesPage] ("Reintentar" y "Restablecer
///   ajustes").
/// * Sin rol: [RoleSelectionPage].
/// * Host: [HostShell]. Comandero: [ComanderoHome].
///
/// Al cambiar de rol se libera el modo que se abandona (el runtime del host
/// con su servidor TCP, o el controlador del comandero con su sesión).
class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key});

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  @override
  void initState() {
    super.initState();
    ref.listenManual<DeviceRole?>(
      appSettingsProvider.select((ajustes) => ajustes.value?.rol),
      (anterior, siguiente) {
        if (anterior == siguiente || anterior == null) return;
        // Tras el frame: la pantalla del modo anterior ya está desmontada y
        // el proveedor, sin oyentes activos, no se reconstruye (Riverpod lo
        // pausa) hasta que se vuelva a ese modo.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _log.info('Cambio de modo: ${anterior.name} → ${siguiente?.name}');
          switch (anterior) {
            case DeviceRole.host:
              ref.invalidate(hostRuntimeProvider);
            case DeviceRole.comandero:
              ref.invalidate(comanderoControllerProvider);
          }
        });
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final ajustes = ref.watch(appSettingsProvider);
    return switch (ajustes) {
      AsyncData(:final value) => switch (value.rol) {
        null => const RoleSelectionPage(),
        DeviceRole.host => const HostShell(key: ValueKey('modo-host')),
        DeviceRole.comandero => _ComanderoShell(
          key: const ValueKey('modo-comandero'),
        ),
      },
      AsyncError(:final error) => ErrorAjustesPage(error: error),
      _ => const PantallaArranque(),
    };
  }
}

class _ComanderoShell extends StatelessWidget {
  const _ComanderoShell({super.key});

  @override
  Widget build(BuildContext context) =>
      ComanderoHome(onAbrirAjustes: () => unawaited(abrirAjustes(context)));
}

/// Pantalla mientras se cargan los ajustes.
class PantallaArranque extends StatelessWidget {
  const PantallaArranque({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: _Marca(
        children: [SizedBox(height: 24), CircularProgressIndicator()],
      ),
    );
  }
}

/// Los ajustes no se pudieron cargar (datos corruptos o almacenamiento no
/// disponible).
class ErrorAjustesPage extends ConsumerStatefulWidget {
  const ErrorAjustesPage({super.key, required this.error});

  final Object error;

  @override
  ConsumerState<ErrorAjustesPage> createState() => _ErrorAjustesPageState();
}

class _ErrorAjustesPageState extends ConsumerState<ErrorAjustesPage> {
  bool _ocupado = false;

  void _reintentar() => ref.invalidate(settingsRepositoryProvider);

  Future<void> _restablecer() async {
    final confirmado = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Restablecer ajustes'),
        content: const Text(
          'Se borrarán los ajustes guardados en este dispositivo (incluidos '
          'tokens y contraseñas) y tendrás que configurarlo de nuevo. Si se '
          'pueden leer, se conservan el identificador y el nombre del '
          'dispositivo, con los que el servidor lo reconoce. El diario del '
          'TPV (mesas abiertas y cola de sincronización) no se toca.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            key: const Key('confirmar-restablecer'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Restablecer'),
          ),
        ],
      ),
    );
    if (confirmado != true || !mounted) return;
    setState(() => _ocupado = true);
    try {
      final repositorio = await ref.read(settingsRepositoryProvider.future);
      final identidad = await restablecerAjustesIlegibles(repositorio);
      _log.info(
        identidad == null
            ? 'Ajustes restablecidos sin identidad legible: se generará otra'
            : 'Ajustes restablecidos conservando ${identidad.deviceId}',
      );
      ref.invalidate(settingsServiceProvider);
    } on Object catch (error, stackTrace) {
      _log.warning('No se pudieron restablecer los ajustes', error, stackTrace);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('No se pudieron restablecer: ${_texto(error)}'),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _ocupado = false);
    }
  }

  static String _texto(Object error) =>
      error is AppException ? error.message : '$error';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: _Marca(
        children: [
          const SizedBox(height: 24),
          Icon(Icons.error_outline, size: 40, color: theme.colorScheme.error),
          const SizedBox(height: 8),
          Text(
            'No se pudieron cargar los ajustes',
            textAlign: TextAlign.center,
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Text(
            _texto(widget.error),
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 24),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            alignment: WrapAlignment.center,
            children: [
              FilledButton.icon(
                key: const Key('ajustes-reintentar'),
                onPressed: _ocupado ? null : _reintentar,
                icon: const Icon(Icons.refresh),
                label: const Text('Reintentar'),
              ),
              OutlinedButton.icon(
                key: const Key('ajustes-restablecer'),
                onPressed: _ocupado ? null : () => unawaited(_restablecer()),
                icon: const Icon(Icons.restart_alt),
                label: const Text('Restablecer ajustes'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Logotipo y nombre de la aplicación, centrados, con contenido debajo.
class _Marca extends StatelessWidget {
  const _Marca({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.point_of_sale,
                  size: 72,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(height: 16),
                Text('TPV Comandero', style: theme.textTheme.headlineMedium),
                ...children,
              ],
            ),
          ),
        ),
      ),
    );
  }
}
