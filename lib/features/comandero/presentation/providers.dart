/// Proveedores Riverpod de la aplicación del comandero (móvil).
///
/// En tests se sustituye el controlador completo por un doble:
/// ```dart
/// ProviderScope(
///   overrides: [
///     comanderoControllerProvider.overrideWith((ref) async => fake),
///   ],
///   child: ...,
/// )
/// ```
/// o se mantiene el controlador real cambiando cómo se construye
/// ([comanderoGatewayFactoryProvider]) y la caché ([comanderoCacheProvider]).
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../../core/errors/app_exception.dart';
import '../../../core/logging/app_logger.dart';
import '../../settings/domain/app_settings.dart';
import '../../settings/presentation/settings_providers.dart';
import '../application/comandero_controller.dart';
import '../data/file_comandero_cache_repository.dart';
import '../data/in_memory_comandero_cache_repository.dart';
import '../domain/comandero_cache_repository.dart';
import '../domain/comandero_config.dart';
import '../domain/comandero_state.dart';
import '../domain/pedido_en_edicion.dart';
import '../domain/traspaso_comandero.dart';
import 'comandero_config_mapper.dart';
import 'comandero_gateway.dart';

final Logger _log = appLogger('comandero.presentation');

/// Sin reintentos automáticos de Riverpod: los fallos de arranque los
/// resuelve el usuario desde la interfaz.
Duration? _sinReintentos(int retryCount, Object error) => null;

/// Construye el controlador del comandero a partir de su configuración.
typedef ComanderoGatewayFactory = ComanderoGateway Function(
  ComanderoConfig config,
  ComanderoCacheRepository? cache,
);

/// Fábrica del controlador: por defecto el [ComanderoController] real con el
/// escáner UDP y el cliente TCP de producción.
final comanderoGatewayFactoryProvider = Provider<ComanderoGatewayFactory>(
  (ref) =>
      (config, cache) => ControllerComanderoGateway(
        ComanderoController(config: config, cache: cache),
      ),
);

/// Caché del catálogo en el almacenamiento de la aplicación. Si el sistema
/// no ofrece directorio, se usa una caché en memoria (el comandero funciona
/// igual, solo que sin catálogo al arrancar sin red).
final comanderoCacheProvider = FutureProvider<ComanderoCacheRepository>((
  ref,
) async {
  try {
    final base = await getApplicationSupportDirectory();
    return FileComanderoCacheRepository(
      Directory('${base.path}${Platform.pathSeparator}comandero'),
    );
  } on Object catch (error, stackTrace) {
    _log.warning(
      'Sin directorio para la caché del comandero; se usa memoria',
      error,
      stackTrace,
    );
    return InMemoryComanderoCacheRepository();
  }
}, retry: _sinReintentos);

/// Controlador del comandero construido con los ajustes vigentes.
///
/// Solo existe con el rol [DeviceRole.comandero]: con otro rol (o sin rol)
/// falla con [ConfigException] sin crear nada (ni descubrimiento UDP ni
/// sesión TCP).
///
/// Se recrea si cambia la identidad del dispositivo (id, nombre o puerto de
/// descubrimiento). El controlador anterior se cierra para traspaso
/// ([ComanderoGateway.cerrarParaTraspaso]): sus envíos en cola vuelven al
/// carrito y los carritos de todas las mesas pasan al nuevo; si algo no se
/// pudo traspasar, [comanderoAvisosProvider] avisa al camarero.
///
/// El código de emparejamiento y el host manual no lo recrean: al cambiar en
/// los ajustes se aplican al controlador vivo
/// ([ComanderoGateway.actualizarConexion]), que reconecta si hace falta. Al
/// crearse arranca la conexión ([ComanderoGateway.iniciar]).
final comanderoControllerProvider = FutureProvider<ComanderoGateway>((
  ref,
) async {
  final rol = ref.watch(appSettingsProvider.selectAsync((s) => s.rol));
  final identidad = ref.watch(
    appSettingsProvider.selectAsync(
      (s) => identidadComandero(comanderoConfigFromApp(s)),
    ),
  );
  final factory = ref.watch(comanderoGatewayFactoryProvider);
  final traspasos = ref.watch(_traspasoComanderoProvider);
  if (await rol != DeviceRole.comandero) {
    throw const ConfigException(
      'Este dispositivo no está configurado como comandero: elige el modo '
      'Comandero en los ajustes',
    );
  }
  final cacheFuture = ref.watch(comanderoCacheProvider.future);
  await identidad;
  final cache = await cacheFuture;
  final settings = await ref.read(appSettingsProvider.future);
  final traspaso = await traspasos.recoger();
  if (!ref.mounted) {
    throw StateError('Proveedor del comandero liberado durante la carga');
  }
  final gateway = factory(comanderoConfigFromApp(settings), cache);
  traspasos.entregar(gateway, traspaso);
  ref.onDispose(() => traspasos.cerrar(gateway));
  ref.listen<({String? pairingCode, String? hostManual})?>(
    appSettingsProvider.select((ajustes) {
      final red = ajustes.value?.red;
      return red == null
          ? null
          : (pairingCode: red.pairingCode, hostManual: red.hostManual);
    }),
    (anterior, siguiente) {
      if (siguiente == null || siguiente == anterior) return;
      try {
        gateway.actualizarConexion(
          pairingCode: siguiente.pairingCode,
          hostManual: siguiente.hostManual,
        );
      } on StateError {
        // Liberado: el proveedor se está reconstruyendo.
      }
    },
  );
  unawaited(_arrancar(gateway));
  return gateway;
}, retry: _sinReintentos);

/// Traspaso de carritos entre el controlador que se libera y el siguiente.
final _traspasoComanderoProvider = Provider<_TraspasoEntreControladores>(
  (ref) => _TraspasoEntreControladores(),
);

final class _TraspasoEntreControladores {
  /// Cierre en curso del último controlador liberado.
  Future<TraspasoComandero>? _pendiente;

  /// Aviso para el camarero sobre el traspaso al controlador [_destino].
  ComanderoGateway? _destino;
  AvisoComandero? _aviso;

  /// Cierra [gateway] guardando lo que entrega para el siguiente.
  void cerrar(ComanderoGateway gateway) {
    if (identical(_destino, gateway)) {
      _destino = null;
      _aviso = null;
    }
    _pendiente = gateway.cerrarParaTraspaso().catchError((
      Object error,
      StackTrace stackTrace,
    ) {
      _log.warning('Error al cerrar el comandero', error, stackTrace);
      return const TraspasoComandero();
    });
  }

  /// Lo que entregó el controlador anterior, si lo hubo.
  Future<TraspasoComandero?> recoger() async {
    final pendiente = _pendiente;
    if (pendiente == null) return null;
    _pendiente = null;
    return pendiente;
  }

  /// Importa en [gateway] los carritos de [traspaso] y prepara el aviso.
  void entregar(ComanderoGateway gateway, TraspasoComandero? traspaso) {
    if (traspaso == null || traspaso.estaVacio) return;
    var importadas = 0;
    var fallo = false;
    try {
      importadas = gateway.importarPedidos(traspaso.pedidos);
    } on Object catch (error, stackTrace) {
      fallo = true;
      _log.warning('No se pudieron traspasar los carritos', error, stackTrace);
    }
    _log.info(
      'Comandero recreado: $importadas línea(s) de carrito traspasadas',
    );
    final perdidas =
        'No se pudieron recuperar los pedidos sin enviar '
        '(${traspaso.lineas} línea(s)): vuelve a marcarlos';
    final devueltas =
        '${traspaso.lineasDevueltas} línea(s) que se estaban enviando han '
        'vuelto al carrito: revísalas y vuelve a enviarlas';
    final anulaciones =
        '${traspaso.peticionesPerdidas} anulación(es) sin confirmar se han '
        'cancelado: repítelas';
    final partes = [
      if (fallo) perdidas,
      if (!fallo && traspaso.lineasDevueltas > 0) devueltas,
      if (traspaso.peticionesPerdidas > 0) anulaciones,
    ];
    if (partes.isEmpty) return;
    _destino = gateway;
    _aviso = AvisoComandero(
      mesaId: '',
      mensaje: 'Se reinició la conexión. ${partes.join('. ')}.',
    );
  }

  /// Aviso pendiente para [gateway] (una sola vez).
  AvisoComandero? tomarAviso(ComanderoGateway gateway) {
    if (!identical(_destino, gateway)) return null;
    final aviso = _aviso;
    _destino = null;
    _aviso = null;
    return aviso;
  }
}

Future<void> _arrancar(ComanderoGateway gateway) async {
  try {
    await gateway.iniciar();
  } on AppException catch (error) {
    // El estado (SinHost con error) ya lo refleja para la interfaz.
    _log.info('Arranque del comandero sin conexión: ${error.message}');
  } on StateError {
    // Liberado antes de terminar la búsqueda.
  }
}

/// Estado del comandero: el actual y después cada cambio.
final comanderoStateProvider = StreamProvider<ComanderoState>((ref) async* {
  final gateway = await ref.watch(comanderoControllerProvider.future);
  yield* actualYCambios(() => gateway.state, gateway.states);
});

/// Avisos puntuales del controlador para el camarero (se muestran como
/// mensajes breves en `ComanderoHome`).
final comanderoAvisosProvider = StreamProvider<AvisoComandero>((ref) async* {
  final gateway = await ref.watch(comanderoControllerProvider.future);
  final traspaso = ref.read(_traspasoComanderoProvider).tomarAviso(gateway);
  if (traspaso != null) yield traspaso;
  yield* gateway.avisos;
});

/// Carrito de una mesa: el actual y después cada cambio.
final pedidoProvider = StreamProvider.family<PedidoEnEdicion, String>((
  ref,
  mesaId,
) async* {
  final gateway = await ref.watch(comanderoControllerProvider.future);
  yield* actualYCambios(
    () => gateway.pedido(mesaId),
    gateway.pedidosCambiados.where((pedido) => pedido.mesaId == mesaId),
  );
});

/// Stream que emite `actual()` y después los eventos de [cambios], sin
/// perder ninguno: se suscribe a [cambios] antes de leer el valor actual.
Stream<T> actualYCambios<T>(T Function() actual, Stream<T> cambios) {
  StreamSubscription<T>? subscription;
  late final StreamController<T> controller;
  controller = StreamController<T>(
    onListen: () {
      subscription = cambios.listen(
        controller.add,
        onError: controller.addError,
        onDone: controller.close,
      );
      controller.add(actual());
    },
    onPause: () => subscription?.pause(),
    onResume: () => subscription?.resume(),
    onCancel: () => subscription?.cancel(),
  );
  return controller.stream;
}

/// Guarda en los ajustes los datos de conexión introducidos por el usuario.
///
/// Devuelve `null` si se guardaron o el mensaje del error si no (la conexión
/// puede seguir adelante aunque no se guarden). [hostManual] debe venir ya
/// normalizado (ver [normalizarHostManual]).
Future<String?> guardarDatosConexion(
  WidgetRef ref, {
  String? pairingCode,
  bool borrarPairingCode = false,
  String? hostManual,
  bool borrarHostManual = false,
}) async {
  try {
    await ref
        .read(appSettingsProvider.notifier)
        .actualizar(
          (AppSettings s) => s.copyWith(
            red: s.red.copyWith(
              pairingCode: pairingCode,
              borrarPairingCode: borrarPairingCode,
              hostManual: hostManual,
              borrarHostManual: borrarHostManual,
            ),
          ),
        );
    return null;
  } on AppException catch (error) {
    _log.warning('No se pudieron guardar los datos de conexión', error);
    return error.message;
  } on StateError catch (error) {
    return error.message;
  }
}
