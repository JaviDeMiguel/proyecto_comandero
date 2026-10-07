import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../../errors/app_exception.dart';
import '../../logging/app_logger.dart';
import 'discovery_protocol.dart';

/// Destino de una sonda: dirección IPv4 (normalmente de broadcast) y puerto.
///
/// El puerto forma parte del destino para poder probar contra respondedores
/// en puertos efímeros.
@immutable
final class DiscoveryTarget {
  /// Lanza [RangeError] si [port] no está entre 1 y 65535.
  DiscoveryTarget({required this.address, this.port = kDiscoveryPort}) {
    RangeError.checkValueInInterval(port, 1, 65535, 'port');
  }

  /// Broadcast limitado `255.255.255.255`: llega a todos los equipos del
  /// segmento sin necesidad de conocer la máscara de red.
  factory DiscoveryTarget.limitedBroadcast({int port = kDiscoveryPort}) =>
      DiscoveryTarget(address: InternetAddress('255.255.255.255'), port: port);

  final InternetAddress address;
  final int port;

  @override
  bool operator ==(Object other) =>
      other is DiscoveryTarget &&
      other.address.address == address.address &&
      other.port == port;

  @override
  int get hashCode => Object.hash(address.address, port);

  @override
  String toString() => '${address.address}:$port';
}

/// Host encontrado en la red local.
@immutable
final class DiscoveredHost {
  const DiscoveredHost({
    required this.hostId,
    required this.hostName,
    required this.address,
    required this.tcpPort,
    required this.requiresPairing,
    required this.roundTrip,
  });

  final String hostId;
  final String hostName;

  /// Dirección de origen de la respuesta: la que hay que usar para abrir la
  /// sesión TCP, porque es la única que consta alcanzable desde este equipo.
  final InternetAddress address;

  /// Puerto TCP del servidor del host.
  final int tcpPort;

  /// El host pedirá código de emparejamiento en el `hello`.
  final bool requiresPairing;

  /// Tiempo desde la primera sonda hasta la respuesta. Todas las sondas llevan
  /// el mismo nonce, así que no se sabe a cuál responde el host: es una cota
  /// superior de la latencia (incluye los reintentos si se perdió la primera),
  /// útil para ordenar hosts, no para medir la red.
  final Duration roundTrip;

  @override
  String toString() =>
      'DiscoveredHost($hostName [$hostId] ${address.address}:$tcpPort'
      '${requiresPairing ? ', emparejamiento' : ''}, '
      '${roundTrip.inMilliseconds} ms)';
}

/// Parámetros de un escaneo.
@immutable
final class DiscoveryScanOptions {
  const DiscoveryScanOptions({
    this.timeout = const Duration(seconds: 2),
    this.probes = 3,
    this.probeInterval = const Duration(milliseconds: 300),
    this.targets,
  });

  /// Tiempo total de escucha desde la primera sonda.
  final Duration timeout;

  /// Número de sondas por destino. UDP no garantiza la entrega y el broadcast
  /// por Wi-Fi se pierde con facilidad, de ahí la repetición.
  final int probes;

  /// Separación entre sondas.
  final Duration probeInterval;

  /// Destinos de las sondas; `null` usa
  /// [UdpDiscoveryScanner.defaultTargets].
  final List<DiscoveryTarget>? targets;
}

/// Lado comandero del descubrimiento: emite sondas por broadcast y recoge las
/// respuestas unicast de los hosts.
///
/// Cada escaneo es independiente (nonce y sockets propios), de modo que una
/// misma instancia admite escaneos consecutivos o simultáneos.
final class UdpDiscoveryScanner {
  /// [random] genera los nonces; por defecto es criptográficamente seguro
  /// (ver [DiscoveryProbe.random]).
  UdpDiscoveryScanner({this._random});

  static final Logger _log = appLogger('network.discovery.scanner');

  final Random? _random;

  /// Busca hosts y emite cada uno **una vez** (por `hostId`) en cuanto
  /// responde. El stream se cierra al vencer `options.timeout`; cancelar la
  /// suscripción detiene el escaneo y el `Future` de `cancel()` se completa
  /// cuando los sockets ya están cerrados.
  ///
  /// El escaneo empieza al escuchar el stream (suscripción única).
  ///
  /// Errores, siempre como evento de error del stream seguido de su cierre:
  /// [NetworkException] si no se puede abrir ningún socket o si el envío falla
  /// en **todos** los destinos antes de encontrar ningún host (lo habitual sin
  /// Wi-Fi: así la interfaz puede distinguir «sin red» de «ningún host»). El
  /// fallo de un destino concreto solo se registra.
  ///
  /// Lanza [ArgumentError] de inmediato si [options] no tiene sentido.
  Stream<DiscoveredHost> discover([
    DiscoveryScanOptions options = const DiscoveryScanOptions(),
  ]) {
    if (options.timeout <= Duration.zero) {
      throw ArgumentError.value(options.timeout, 'timeout', 'debe ser > 0');
    }
    if (options.probes < 1) {
      throw ArgumentError.value(options.probes, 'probes', 'debe ser >= 1');
    }
    if (options.probeInterval < Duration.zero) {
      throw ArgumentError.value(
        options.probeInterval,
        'probeInterval',
        'no puede ser negativo',
      );
    }
    return _ScanSession(options, DiscoveryProbe.random(_random), _log).stream;
  }

  /// Como [discover], pero espera al final del escaneo y devuelve todos los
  /// hosts en orden de respuesta. Sin respuestas devuelve una lista vacía
  /// tras `options.timeout`.
  Future<List<DiscoveredHost>> scan([
    DiscoveryScanOptions options = const DiscoveryScanOptions(),
  ]) => discover(options).toList();

  /// Destinos automáticos: `255.255.255.255` más el broadcast dirigido de cada
  /// interfaz IPv4 que no sea loopback ni link-local, sin duplicados.
  ///
  /// El broadcast limitado es el que exige la especificación, pero el sistema
  /// lo emite solo por una interfaz (la de la ruta por defecto) y algunos
  /// routers y móviles con varias interfaces activas (Wi-Fi + datos, VPN) lo
  /// descartan; el dirigido (`a.b.c.255`) sale por la interfaz de esa subred.
  ///
  /// `dart:io` no expone la máscara de red, así que se asume `/24`, que es lo
  /// habitual en redes de hostelería. En una subred más amplia el dirigido
  /// calculado puede no ser el real; entonces queda el broadcast limitado.
  static Future<List<DiscoveryTarget>> defaultTargets({
    int port = kDiscoveryPort,
  }) async {
    var addresses = const <InternetAddress>[];
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
      );
      addresses = [for (final interface in interfaces) ...interface.addresses];
    } catch (error) {
      // Sin permiso o sin soporte para enumerar interfaces: basta con el
      // broadcast limitado.
      _log.warning('No se pudieron enumerar las interfaces de red: $error');
    }
    return targetsForAddresses(addresses, port: port);
  }

  /// Parte pura de [defaultTargets]: deriva los destinos de las direcciones
  /// locales [addresses]. Las que no son IPv4, las de loopback (`127/8`) y las
  /// link-local (`169.254/16`) se ignoran.
  static List<DiscoveryTarget> targetsForAddresses(
    Iterable<InternetAddress> addresses, {
    int port = kDiscoveryPort,
  }) {
    final targets = <DiscoveryTarget>{
      DiscoveryTarget.limitedBroadcast(port: port),
    };
    for (final address in addresses) {
      if (address.type != InternetAddressType.IPv4) continue;
      final raw = address.rawAddress;
      if (raw.length != 4) continue;
      final isLoopback = raw[0] == 127;
      final isLinkLocal = raw[0] == 169 && raw[1] == 254;
      if (isLoopback || isLinkLocal || raw[0] == 0) continue;
      targets.add(
        DiscoveryTarget(
          address: InternetAddress.fromRawAddress(
            Uint8List.fromList([raw[0], raw[1], raw[2], 255]),
            type: InternetAddressType.IPv4,
          ),
          port: port,
        ),
      );
    }
    return targets.toList(growable: false);
  }
}

/// Socket dedicado a un destino.
final class _TargetLink {
  _TargetLink(this.target, this.socket);

  final DiscoveryTarget target;
  final RawDatagramSocket socket;

  /// Se completa cuando el sistema confirma el cierre del socket.
  final Completer<void> closed = Completer<void>();

  Object? error;

  /// Hay una sonda que el socket no admitió y se reenviará en el evento
  /// `write` (ver [_ScanSession._sendProbe]).
  bool probePending = false;

  bool get isClosed => closed.isCompleted;
}

/// Un escaneo en curso: sus sockets, temporizadores y el stream de resultados.
///
/// **Un socket por destino, no uno compartido.** `dart:io` cierra un socket
/// UDP ante cualquier error, y un envío fallido (red inalcanzable, sin
/// permiso de broadcast, dirección de otra familia) cuenta como tal. Con un
/// único socket, el fallo de un destino dejaría sordo el escaneo entero; con
/// uno por destino solo se pierde ese destino.
final class _ScanSession {
  _ScanSession(this._options, this._probe, this._log) {
    _controller = StreamController<DiscoveredHost>(
      onListen: () => unawaited(_start()),
      onCancel: _shutdown,
    );
  }

  /// Margen para que el sistema operativo confirme el cierre de los sockets.
  static const Duration _closeGrace = Duration(seconds: 1);

  final DiscoveryScanOptions _options;
  final DiscoveryProbe _probe;
  final Logger _log;

  late final StreamController<DiscoveredHost> _controller;
  late final Uint8List _probeBytes = _probe.toBytes();

  final List<_TargetLink> _links = [];
  final Set<String> _seenHostIds = {};
  final Stopwatch _sinceFirstProbe = Stopwatch();

  Timer? _probeTimer;
  Timer? _timeoutTimer;
  int _roundsSent = 0;
  bool _finished = false;
  Future<void>? _shutdownFuture;

  Stream<DiscoveredHost> get stream => _controller.stream;

  Future<void> _start() async {
    try {
      final targets =
          (_options.targets ?? await UdpDiscoveryScanner.defaultTargets())
              .toSet();
      if (_finished) return;
      if (targets.isEmpty) {
        _log.warning('Escaneo de descubrimiento sin destinos');
        _complete();
        return;
      }

      Object? openError;
      for (final target in targets) {
        try {
          final socket = await _openSocket();
          if (_finished) {
            socket.close();
            return;
          }
          _attach(target, socket);
        } on SocketException catch (error) {
          if (_finished) return;
          openError = error;
          _log.warning('No se pudo abrir un socket UDP para $target: $error');
        }
      }
      if (_links.isEmpty) {
        _complete(
          NetworkException(
            'No se pudo abrir el socket UDP de descubrimiento',
            cause: openError,
          ),
        );
        return;
      }

      _sinceFirstProbe.start();
      _timeoutTimer = Timer(_options.timeout, _complete);
      _sendRound();
      if (_options.probes > 1) {
        _probeTimer = Timer.periodic(
          _options.probeInterval,
          (_) => _sendRound(),
        );
      }
    } catch (error, stackTrace) {
      _log.severe('Fallo inesperado en el escaneo', error, stackTrace);
      _complete(
        NetworkException('Fallo en el escaneo de descubrimiento', cause: error),
      );
    }
  }

  /// Puerto efímero en todas las interfaces. Sin `reuseAddress`: nadie más
  /// debe poder enlazarse al puerto por el que esperamos las respuestas.
  static Future<RawDatagramSocket> _openSocket() async {
    final socket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      0,
      reuseAddress: false,
    );
    try {
      // Sin SO_BROADCAST el sistema rechaza los envíos a direcciones de
      // broadcast.
      socket.broadcastEnabled = true;
      socket.writeEventsEnabled = false;
    } on SocketException {
      socket.close();
      rethrow;
    } on OSError catch (error) {
      socket.close();
      throw SocketException('No se pudo activar el broadcast', osError: error);
    }
    return socket;
  }

  void _attach(DiscoveryTarget target, RawDatagramSocket socket) {
    final link = _TargetLink(target, socket);
    _links.add(link);
    socket.listen(
      (event) {
        if (event == RawSocketEvent.read) {
          _drain(link);
        } else if (event == RawSocketEvent.write && link.probePending) {
          _sendProbe(link);
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        link.error = error;
        if (_finished) return;
        _log.warning('Fallo de red con el destino $target: $error');
      },
      onDone: () {
        link.closed.complete();
        _onLinkClosed();
      },
    );
  }

  void _sendRound() {
    if (_finished) return;
    _roundsSent++;
    if (_roundsSent >= _options.probes) _probeTimer?.cancel();
    for (final link in _links) {
      if (!link.isClosed) _sendProbe(link);
    }
  }

  /// Envía la sonda por el socket de [link]. En Windows `send` devuelve 0 si
  /// el envío anterior de ese socket sigue en vuelo; entonces se deja la sonda
  /// pendiente y se reintenta en el evento `write`, para no perder una ronda
  /// entera por una carrera con el sistema.
  void _sendProbe(_TargetLink link) {
    final int sent;
    try {
      // Un envío fallido no lanza: dart:io lo notifica por el stream del
      // socket y lo cierra (lo recogen `onError` y `onDone`).
      sent = link.socket.send(
        _probeBytes,
        link.target.address,
        link.target.port,
      );
    } catch (error) {
      link.probePending = false;
      _log.warning('No se pudo enviar la sonda a ${link.target}: $error');
      return;
    }
    if (sent == _probeBytes.length) {
      link.probePending = false;
      return;
    }
    link.probePending = true;
    link.socket.writeEventsEnabled = true;
  }

  void _drain(_TargetLink link) {
    // Un evento `read` puede cubrir varios datagramas: hay que vaciar la cola.
    while (!_finished) {
      final datagram = link.socket.receive();
      if (datagram == null) return;
      _onDatagram(datagram);
    }
  }

  void _onDatagram(Datagram datagram) {
    final response = DiscoveryResponse.tryParse(datagram.data);
    // El nonce descarta respuestas a escaneos anteriores o de otros
    // comanderos, y las inyectadas por quien no ha visto la sonda.
    if (response == null || response.nonce != _probe.nonce) return;
    if (!_seenHostIds.add(response.hostId)) return;
    _controller.add(
      DiscoveredHost(
        hostId: response.hostId,
        hostName: response.hostName,
        address: datagram.address,
        tcpPort: response.tcpPort,
        requiresPairing: response.requiresPairing,
        roundTrip: _sinceFirstProbe.elapsed,
      ),
    );
  }

  /// Un socket solo se cierra antes de tiempo por un error. Si ya no queda
  /// ninguno abierto no puede llegar nada más: se termina sin esperar al
  /// timeout, con error si además no se encontró ningún host.
  void _onLinkClosed() {
    if (_finished || _links.any((link) => !link.isClosed)) return;
    if (_seenHostIds.isNotEmpty) {
      _complete();
      return;
    }
    final cause = _links.map((link) => link.error).nonNulls.firstOrNull;
    _complete(
      NetworkException(
        'No se pudo enviar ninguna sonda de descubrimiento: '
        'comprueba la conexión Wi-Fi',
        cause: cause,
      ),
    );
  }

  /// Fin natural del escaneo (timeout, sin sockets o error): cierra el stream
  /// cuando los sockets ya están liberados.
  void _complete([NetworkException? error]) {
    if (_finished) return;
    unawaited(
      _shutdown().whenComplete(() {
        if (error != null) _controller.addError(error);
        return _controller.close();
      }),
    );
  }

  /// Libera sockets y temporizadores. Nunca falla. También es el `onCancel`
  /// del stream, de modo que `await subscription.cancel()` garantiza que no
  /// queda nada abierto.
  Future<void> _shutdown() => _shutdownFuture ??= _releaseResources();

  Future<void> _releaseResources() async {
    _finished = true;
    _probeTimer?.cancel();
    _timeoutTimer?.cancel();
    _sinceFirstProbe.stop();
    if (_links.isEmpty) return;
    for (final link in _links) {
      link.socket.close();
    }
    await Future.wait([for (final link in _links) link.closed.future])
        .timeout(_closeGrace, onTimeout: () => const []);
  }
}
