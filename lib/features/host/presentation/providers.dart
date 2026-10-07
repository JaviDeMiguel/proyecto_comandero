/// Proveedores Riverpod del host (tablet).
///
/// [hostRuntimeProvider] construye un único [HostRuntime] con los ajustes
/// vigentes, lo arranca y lo cierra al desecharse. Los cambios posteriores de
/// ajustes se aplican en caliente con [HostRuntime.applySettings]. El resto de
/// proveedores derivan de él; las pantallas nunca crean servicios.
///
/// En tests se sustituyen la fábrica, el arranque y el runner:
/// ```dart
/// ProviderScope(
///   overrides: [
///     settingsRepositoryProvider.overrideWith(
///       (ref) => InMemorySettingsRepository(initial: ajustes),
///     ),
///     isolateRunnerProvider.overrideWithValue(const InlineIsolateRunner()),
///     hostRuntimeFactoryProvider.overrideWithValue(
///       (ref, settings) => HostRuntime.create(
///         settings: settings,
///         stateRepo: InMemoryHostStateRepository(),
///         runner: ref.read(isolateRunnerProvider),
///         discoveryEnabled: false,
///       ),
///     ),
///     hostAutoStartProvider.overrideWithValue(false),
///   ],
///   child: ...,
/// )
/// ```
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../../core/errors/app_exception.dart';
import '../../../core/facturascripts/catalog/catalog_models.dart';
import '../../../core/isolates/isolate_runner.dart';
import '../../../core/isolates/reposicion/reposicion_models.dart';
import '../../../core/logging/app_logger.dart';
import '../../../core/network/tcp/tcp_host_server.dart' show ClientSessionInfo;
import '../../settings/domain/app_settings.dart';
import '../../settings/presentation/settings_providers.dart';
import '../application/billing_service.dart';
import '../application/catalog_service.dart';
import '../application/cierre_z_service.dart';
import '../application/host_runtime.dart';
import '../application/printing_service.dart';
import '../application/reposicion_service.dart';
import '../application/sala_service.dart';
import '../application/sync_outbox.dart';
import '../data/file_host_state_repository.dart';
import '../domain/host_settings.dart';
import '../domain/host_snapshot.dart';
import '../domain/operational_alert.dart';
import 'host_settings_mapper.dart';

final Logger _log = appLogger('host.ui');

/// Sin reintentos automáticos: un fallo al construir el runtime (directorio
/// de datos inaccesible, diario corrupto) lo resuelve el usuario.
Duration? _sinReintentos(int retryCount, Object error) => null;

/// Ejecutor de los motores pesados (ESC/POS, escandallos, cierre...).
final isolateRunnerProvider = Provider<IsolateRunner>(
  (ref) => const SpawningIsolateRunner(),
);

/// Construye (sin arrancar) el runtime del host con unos ajustes.
typedef HostRuntimeFactory = Future<HostRuntime> Function(
  Ref ref,
  HostSettings settings,
);

/// Fábrica de producción: diario JSON en el directorio de soporte de la
/// aplicación (`path_provider`).
Future<HostRuntime> crearHostRuntimePorDefecto(
  Ref ref,
  HostSettings settings,
) async {
  final Directory directorio;
  try {
    directorio = await getApplicationSupportDirectory();
  } on Exception catch (error) {
    throw ConfigException(
      'No se pudo localizar el directorio de datos del TPV',
      cause: error,
    );
  }
  return HostRuntime.create(
    settings: settings,
    stateRepo: FileHostStateRepository(directorio),
    runner: ref.read(isolateRunnerProvider),
  );
}

final hostRuntimeFactoryProvider = Provider<HostRuntimeFactory>(
  (ref) => crearHostRuntimePorDefecto,
);

/// Arrancar la red y la cola al construir el runtime (en tests, `false`).
final hostAutoStartProvider = Provider<bool>((ref) => true);

/// Runtime del host, construido una sola vez con los ajustes vigentes.
final hostRuntimeProvider =
    AsyncNotifierProvider<HostRuntimeNotifier, HostRuntime>(
      HostRuntimeNotifier.new,
      retry: _sinReintentos,
    );

final class HostRuntimeNotifier extends AsyncNotifier<HostRuntime> {
  /// Cierre en curso del runtime anterior (nulo si ya terminó). Riverpod
  /// reutiliza la instancia del notifier al reconstruir el proveedor, así que
  /// el runtime nuevo espera a que el anterior libere sus puertos (TCP y UDP)
  /// antes de crearse.
  Future<void>? _cierreAnterior;

  /// Tiempo máximo que el runtime nuevo espera a que el anterior se cierre.
  static const Duration _esperaCierre = Duration(seconds: 10);

  @override
  Future<HostRuntime> build() async {
    // El rol se observa: si deja de ser host, el proveedor se reconstruye,
    // cierra el runtime en marcha y no crea otro.
    final rol = await ref.watch(
      appSettingsProvider.selectAsync((ajustes) => ajustes.rol),
    );
    if (rol != DeviceRole.host) {
      throw ConfigException(
        'Este dispositivo no está configurado como host '
        '(modo: ${rol?.name ?? 'sin elegir'})',
      );
    }
    // `read`: un cambio de ajustes no reconstruye el runtime (perdería las
    // sesiones abiertas); se aplica en caliente desde el `listen` de abajo.
    final ajustes = await ref.read(appSettingsProvider.future);
    final fabrica = ref.read(hostRuntimeFactoryProvider);
    final arrancar = ref.read(hostAutoStartProvider);
    final cierre = _cierreAnterior;
    if (cierre != null) {
      await cierre.timeout(
        _esperaCierre,
        onTimeout: () => _log.warning(
          'El runtime anterior no terminó de cerrarse; se crea el nuevo',
        ),
      );
    }
    if (!ref.mounted) {
      throw StateError('El proveedor del host se desechó durante el arranque');
    }
    final runtime = await fabrica(ref, hostSettingsFromApp(ajustes));
    if (!ref.mounted) {
      await runtime.dispose();
      throw StateError('El proveedor del host se desechó durante el arranque');
    }
    // Estado propio de este runtime: uno ya desechado no bloquea al que lo
    // sustituye aunque compartan la instancia del notifier.
    final control = _ControlRuntime(runtime);
    ref.onDispose(() {
      late final Future<void> cerrando;
      cerrando = control.cerrar().whenComplete(() {
        if (identical(_cierreAnterior, cerrando)) _cierreAnterior = null;
      });
      _cierreAnterior = cerrando;
    });
    ref.listen(appSettingsProvider, (_, siguiente) {
      final nuevos = siguiente.value;
      if (nuevos != null && nuevos.rol == DeviceRole.host) {
        control.aplicar(hostSettingsFromApp(nuevos));
      }
    });
    if (arrancar) await runtime.start();
    return runtime;
  }
}

/// Aplicación en serie de ajustes y cierre de un único [HostRuntime].
final class _ControlRuntime {
  _ControlRuntime(this.runtime);

  final HostRuntime runtime;
  Future<void> _aplicando = Future<void>.value();
  bool _cerrado = false;

  /// Aplica ajustes en serie (un `applySettings` cada vez).
  void aplicar(HostSettings nuevos) {
    _aplicando = _aplicando.then((_) async {
      if (_cerrado || runtime.settings == nuevos) return;
      try {
        await runtime.applySettings(nuevos);
      } on AppException catch (error, stackTrace) {
        _log.warning('No se pudieron aplicar los ajustes', error, stackTrace);
        runtime.alerts.error(
          'No se pudieron aplicar los ajustes',
          detalle: error.message,
          origen: 'ajustes',
        );
      }
    });
  }

  /// Cierra el runtime tras el último cambio de ajustes. Nunca falla.
  Future<void> cerrar() async {
    _cerrado = true;
    try {
      await _aplicando;
      await runtime.dispose();
    } on Object catch (error, stackTrace) {
      _log.warning('Error al cerrar el runtime del host', error, stackTrace);
    }
  }
}

/// Runtime ya construido. Solo para pantallas que se muestran después de
/// que [hostRuntimeProvider] tenga valor (lanza [StateError] si no).
final hostRuntimeReadyProvider = Provider<HostRuntime>(
  (ref) => ref.watch(hostRuntimeProvider).requireValue,
);

final salaServiceProvider = Provider<SalaService>(
  (ref) => ref.watch(hostRuntimeReadyProvider).sala,
);
final syncOutboxProvider = Provider<SyncOutbox>(
  (ref) => ref.watch(hostRuntimeReadyProvider).outbox,
);
final catalogServiceProvider = Provider<CatalogService>(
  (ref) => ref.watch(hostRuntimeReadyProvider).catalog,
);
final billingServiceProvider = Provider<BillingService>(
  (ref) => ref.watch(hostRuntimeReadyProvider).billing,
);
final printingServiceProvider = Provider<PrintingService>(
  (ref) => ref.watch(hostRuntimeReadyProvider).printing,
);
final cierreZServiceProvider = Provider<CierreZService>(
  (ref) => ref.watch(hostRuntimeReadyProvider).cierreZ,
);
final reposicionServiceProvider = Provider<ReposicionService>(
  (ref) => ref.watch(hostRuntimeReadyProvider).reposicion,
);

/// Foto del diario del host (mesas, comandas, turno, cola...), viva.
final hostSnapshotProvider = StreamProvider<HostSnapshot>((ref) async* {
  final runtime = await ref.watch(hostRuntimeProvider.future);
  yield runtime.store.snapshot;
  yield* runtime.store.changes;
});

/// Catálogo vigente (nulo hasta la primera descarga).
final catalogoProvider = Provider<CatalogSnapshot?>(
  (ref) => ref.watch(hostSnapshotProvider).value?.catalogo,
);

/// Eventos de estado de la cola (pausa, reanudación, backoff).
final _outboxEventosProvider = StreamProvider<SyncOutboxStatus>((ref) async* {
  final runtime = await ref.watch(hostRuntimeProvider.future);
  yield runtime.outbox.estado;
  yield* runtime.outbox.status;
});

/// Estado resumido de la cola de sincronización. Se recalcula con cada
/// cambio del diario y con cada evento de la cola.
final syncStatusProvider = Provider<SyncOutboxStatus?>((ref) {
  final runtime = ref.watch(hostRuntimeProvider).value;
  if (runtime == null) return null;
  ref
    ..watch(hostSnapshotProvider)
    ..watch(_outboxEventosProvider);
  return runtime.outbox.estado;
});

/// Avisos operativos recientes (del más antiguo al más nuevo).
final alertasProvider = StreamProvider<List<OperationalAlert>>((ref) async* {
  final runtime = await ref.watch(hostRuntimeProvider.future);
  yield runtime.alerts.recientes;
  await for (final _ in runtime.alerts.stream) {
    yield runtime.alerts.recientes;
  }
});

/// Comanderos conectados.
final sesionesProvider = StreamProvider<List<ClientSessionInfo>>((ref) async* {
  final runtime = await ref.watch(hostRuntimeProvider.future);
  yield runtime.network.sessions;
  await for (final _ in runtime.network.sessionEvents) {
    yield runtime.network.sessions;
  }
});

/// Última auditoría de reposición (nula si aún no se hizo ninguna).
final reposicionProvider = StreamProvider<ReposicionResult?>((ref) async* {
  final runtime = await ref.watch(hostRuntimeProvider.future);
  yield runtime.reposicion.ultimaAuditoria;
  yield* runtime.reposicion.auditorias;
});

/// Fondo de caja que se propone al abrir el turno (ajustes de la app).
final fondoCajaPropuestoProvider = Provider<int>(
  (ref) => ref.watch(appSettingsProvider).value?.fondoCajaCents ?? 0,
);

/// Reloj de la interfaz (tiempo que lleva abierta una mesa).
final relojProvider = Provider<DateTime Function()>((ref) => DateTime.now);
