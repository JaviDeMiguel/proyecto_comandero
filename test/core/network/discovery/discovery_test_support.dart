import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:proyecto_comandero/core/network/discovery/discovery_protocol.dart';
import 'package:proyecto_comandero/core/network/discovery/udp_discovery_responder.dart';
import 'package:proyecto_comandero/core/network/discovery/udp_discovery_scanner.dart';
import 'package:test/test.dart';

final InternetAddress loopback = InternetAddress.loopbackIPv4;

/// Tope de las esperas de eventos: holgado porque solo se agota si algo falla.
const Duration kEventTimeout = Duration(seconds: 10);

Uint8List jsonBytes(Object? json) => utf8.encode(jsonEncode(json));

/// Espera a que [condition] se cumpla, comprobándola cada pocos milisegundos.
Future<void> waitUntil(
  bool Function() condition, {
  required String reason,
  Duration timeout = kEventTimeout,
}) async {
  final watch = Stopwatch()..start();
  while (!condition()) {
    if (watch.elapsed > timeout) fail('Tiempo agotado esperando: $reason');
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

/// Opciones de escaneo dirigidas a puertos de loopback.
///
/// El timeout por defecto es largo a propósito: los tests que esperan un host
/// cortan con `first`/`take`, de modo que solo se agota si el host no aparece.
DiscoveryScanOptions loopbackScan(
  Iterable<int> ports, {
  Duration timeout = kEventTimeout,
  int probes = 1,
  Duration probeInterval = const Duration(milliseconds: 20),
}) => DiscoveryScanOptions(
  timeout: timeout,
  probes: probes,
  probeInterval: probeInterval,
  targets: [
    for (final port in ports) DiscoveryTarget(address: loopback, port: port),
  ],
);

/// Respondedor en `127.0.0.1` con puerto efímero, detenido al acabar el test.
Future<UdpDiscoveryResponder> startResponder({
  HostAnnouncement Function()? announcement,
  int maxResponsesPerSource = 1000,
  Duration rateLimitWindow = const Duration(seconds: 1),
  Duration Function()? monotonicClock,
}) async {
  final responder = UdpDiscoveryResponder(
    announcement:
        announcement ??
        () => const HostAnnouncement(
          hostId: 'host-1',
          hostName: 'Barra',
          tcpPort: 4040,
        ),
    port: 0,
    bindAddress: loopback,
    maxResponsesPerSource: maxResponsesPerSource,
    rateLimitWindow: rateLimitWindow,
    monotonicClock: monotonicClock,
  );
  addTearDown(responder.stop);
  await responder.start();
  return responder;
}

/// Comprueba que nadie tiene abierto el puerto UDP [port]: enlazarlo sin
/// `reuseAddress` solo funciona si está libre.
Future<void> expectUdpPortFree(int port, {InternetAddress? address}) async {
  final socket = await RawDatagramSocket.bind(
    address ?? loopback,
    port,
    reuseAddress: false,
  );
  socket.close();
}

/// Socket UDP crudo con cola de datagramas recibidos: hace de comandero o de
/// host falso sin pasar por el código bajo prueba.
final class RawPeer {
  RawPeer._(this._socket) {
    _socket.writeEventsEnabled = false;
    _socket.listen(
      (event) {
        if (event == RawSocketEvent.write) {
          _writable?.complete();
          _writable = null;
          return;
        }
        if (event != RawSocketEvent.read) return;
        while (true) {
          final datagram = _socket.receive();
          if (datagram == null) break;
          received++;
          final handler = onDatagram;
          if (handler != null) {
            handler(datagram);
          } else if (_waiters.isNotEmpty) {
            _waiters.removeFirst().complete(datagram);
          } else {
            _queue.add(datagram);
          }
        }
      },
      onError: (Object error) => errors.add(error),
      onDone: _closed.complete,
    );
  }

  /// Abre el socket y programa su cierre al terminar el test.
  static Future<RawPeer> bind({
    InternetAddress? address,
    int port = 0,
    bool reuseAddress = true,
  }) async {
    final socket = await RawDatagramSocket.bind(
      address ?? loopback,
      port,
      reuseAddress: reuseAddress,
    );
    final peer = RawPeer._(socket);
    addTearDown(peer.close);
    return peer;
  }

  final RawDatagramSocket _socket;
  final Queue<Datagram> _queue = Queue();
  final Queue<Completer<Datagram>> _waiters = Queue();
  final Completer<void> _closed = Completer<void>();
  Completer<void>? _writable;

  /// Errores del socket (no debería haber ninguno).
  final List<Object> errors = [];

  /// Datagramas recibidos en total.
  int received = 0;

  /// Si se asigna, recibe los datagramas en lugar de encolarlos.
  void Function(Datagram datagram)? onDatagram;

  int get port => _socket.port;

  /// Datagramas recibidos y aún no consumidos con [next].
  int get pending => _queue.length;

  /// Envía un datagrama. En Windows `send` devuelve 0 mientras el envío
  /// anterior del socket sigue en vuelo, así que se espera al evento `write`
  /// y se reintenta hasta que salga.
  Future<void> send(
    List<int> bytes,
    int port, {
    InternetAddress? address,
  }) async {
    while (true) {
      final sent = _socket.send(bytes, address ?? loopback, port);
      if (sent == bytes.length) return;
      expect(sent, 0, reason: 'envío UDP parcial');
      final writable = _writable ??= Completer<void>();
      _socket.writeEventsEnabled = true;
      await writable.future.timeout(
        kEventTimeout,
        onTimeout: () => fail('El socket UDP no volvió a admitir envíos'),
      );
    }
  }

  /// Envía varios datagramas en orden.
  Future<void> sendAll(
    Iterable<List<int>> datagrams,
    int port, {
    InternetAddress? address,
  }) async {
    for (final bytes in datagrams) {
      await send(bytes, port, address: address);
    }
  }

  /// Siguiente datagrama recibido (espera si aún no ha llegado).
  Future<Datagram> next({Duration timeout = kEventTimeout}) {
    if (_queue.isNotEmpty) return Future.value(_queue.removeFirst());
    final waiter = Completer<Datagram>();
    _waiters.add(waiter);
    return waiter.future.timeout(
      timeout,
      onTimeout: () {
        _waiters.remove(waiter);
        fail('No llegó ningún datagrama en $timeout');
      },
    );
  }

  /// Envía una sonda y devuelve la respuesta ya analizada.
  Future<DiscoveryResponse?> probe(int port, {required String nonce}) async {
    await send(DiscoveryProbe(nonce: nonce).toBytes(), port);
    return DiscoveryResponse.tryParse((await next()).data);
  }

  Future<void> close() {
    _socket.close();
    return _closed.future;
  }
}
