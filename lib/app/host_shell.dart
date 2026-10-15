import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/host/application/host_runtime.dart';
import '../features/host/presentation/host_home_page.dart';
import '../features/host/presentation/providers.dart';
import '../features/sala/domain/comanda.dart';
import 'navigation.dart';
import 'platform/host_platform_hooks.dart';

/// Raíz del modo host (tablet).
///
/// Muestra el salón ([HostHomePage]) y, mientras el runtime del host está
/// en marcha, mantiene la pantalla encendida y el lock de multidifusión
/// Wi-Fi (descubrimiento UDP); los libera al salir del modo host.
class HostShell extends ConsumerStatefulWidget {
  const HostShell({super.key});

  @override
  ConsumerState<HostShell> createState() => _HostShellState();
}

class _HostShellState extends ConsumerState<HostShell> {
  late final HostPlatformHooks _hooks;

  @override
  void initState() {
    super.initState();
    _hooks = ref.read(hostPlatformHooksProvider);
    ref.listenManual<AsyncValue<HostRuntime>>(
      hostRuntimeProvider,
      (_, siguiente) => _activar(siguiente.hasValue && !siguiente.hasError),
      fireImmediately: true,
    );
  }

  bool _activo = false;

  void _activar(bool activar) {
    if (activar == _activo) return;
    _activo = activar;
    unawaited(activar ? _hooks.activar() : _hooks.liberar());
  }

  @override
  void dispose() {
    _activar(false);
    super.dispose();
  }

  Set<String> _mesasOcupadas() {
    if (!mounted) return const {};
    final comandas = ref.read(hostSnapshotProvider).value?.comandas;
    return {
      for (final comanda in comandas ?? const <Comanda>[]) comanda.mesaId,
    };
  }

  @override
  Widget build(BuildContext context) {
    return HostHomePage(
      onAbrirAjustes: () => unawaited(
        abrirAjustes(
          context,
          mesasOcupadas: _mesasOcupadas,
          onAbrirEnrutamiento: (contexto) =>
              unawaited(abrirEnrutamiento(contexto)),
          onAbrirTicketsYComandas: (contexto) =>
              unawaited(abrirTicketsYComandas(contexto)),
        ),
      ),
    );
  }
}
