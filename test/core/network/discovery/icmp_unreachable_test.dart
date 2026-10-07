import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:proyecto_comandero/core/network/discovery/discovery.dart';
import 'package:test/test.dart';

final InternetAddress loopback = InternetAddress.loopbackIPv4;

Future<void> waitUntil(
  bool Function() condition, {
  required String reason,
  Duration timeout = const Duration(seconds: 5),
}) async {
  final watch = Stopwatch()..start();
  while (!condition()) {
    if (watch.elapsed > timeout) fail('Tiempo agotado esperando: $reason');
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

Future<int> closedLoopbackPort() async {
  final socket = await RawDatagramSocket.bind(loopback, 0);
  final port = socket.port;
  socket.close();
  return port;
}

void main() {
  test('el respondedor sobrevive a responder a un puerto ya cerrado '
      '(ICMP port unreachable) y sigue respondiendo de inmediato', () async {
    final responder = UdpDiscoveryResponder(
      announcement: () =>
          const HostAnnouncement(hostId: 'h', hostName: 'n', tcpPort: 4040),
      port: 0,
      bindAddress: loopback,
    );
    addTearDown(responder.stop);
    await responder.start();

    // Comandero que sondea y cierra su socket antes de que llegue la
    // respuesta (p. ej. cancela el escaneo): la respuesta del host va a un
    // puerto cerrado y el SO genera ICMP port unreachable.
    final transient = await RawDatagramSocket.bind(loopback, 0);
    transient.send(
      const DiscoveryProbe(nonce: 'aaaa').toBytes(),
      loopback,
      responder.port,
    );
    transient.close();

    await waitUntil(
      () => responder.probesAnswered == 1,
      reason: 'responder a la sonda del comandero efímero',
    );

    // Un segundo comandero sondea poco después: debe obtener respuesta sin
    // que el respondedor haya dejado de escuchar.
    final peer = await RawDatagramSocket.bind(loopback, 0);
    addTearDown(peer.close);
    final answered = Completer<Datagram>();
    final errors = <Object>[];
    peer.listen((event) {
      if (event != RawSocketEvent.read) return;
      final d = peer.receive();
      if (d != null && !answered.isCompleted) answered.complete(d);
    }, onError: errors.add);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final wasRunning = responder.isRunning;
    peer.send(
      const DiscoveryProbe(nonce: 'bbbb').toBytes(),
      loopback,
      responder.port,
    );
    final reply = await answered.future.timeout(
      const Duration(milliseconds: 700),
      onTimeout: () => fail(
        'El respondedor no contestó en 700 ms tras responder a un puerto '
        'cerrado (isRunning antes de la 2ª sonda: $wasRunning, '
        'ahora: ${responder.isRunning})',
      ),
    );
    expect(DiscoveryResponse.tryParse(reply.data)?.nonce, 'bbbb');
    expect(wasRunning, isTrue, reason: 'no debe haberse cerrado el socket');
  });

  test('escanear un único destino con el puerto cerrado devuelve lista '
      'vacía tras el timeout (no NetworkException)', () async {
    final scanner = UdpDiscoveryScanner(random: Random(1));
    final closed = await closedLoopbackPort();
    final watch = Stopwatch()..start();

    final hosts = await scanner.scan(
      DiscoveryScanOptions(
        timeout: const Duration(milliseconds: 400),
        probes: 2,
        probeInterval: const Duration(milliseconds: 30),
        targets: [DiscoveryTarget(address: loopback, port: closed)],
      ),
    );

    expect(hosts, isEmpty);
    expect(
      watch.elapsed,
      greaterThanOrEqualTo(const Duration(milliseconds: 400)),
    );
  });

  test(
    'con un destino cerrado y otro silencioso, el escaneo sigue '
    'escuchando el silencioso hasta el timeout (respuesta tardía aceptada)',
    () async {
      final scanner = UdpDiscoveryScanner(random: Random(2));
      final closed = await closedLoopbackPort();
      // Host "lento": responde 150 ms después de recibir la sonda.
      final slow = await RawDatagramSocket.bind(loopback, 0);
      addTearDown(slow.close);
      slow.listen((event) {
        if (event != RawSocketEvent.read) return;
        final d = slow.receive();
        if (d == null) return;
        final probe = DiscoveryProbe.tryParse(d.data);
        if (probe == null) return;
        Timer(const Duration(milliseconds: 150), () {
          slow.send(
            DiscoveryResponse(
              nonce: probe.nonce,
              hostId: 'lento',
              hostName: 'Lento',
              tcpPort: 4040,
            ).toBytes(),
            d.address,
            d.port,
          );
        });
      });

      final hosts = await scanner.scan(
        DiscoveryScanOptions(
          timeout: const Duration(milliseconds: 600),
          probes: 1,
          targets: [
            DiscoveryTarget(address: loopback, port: closed),
            DiscoveryTarget(address: loopback, port: slow.port),
          ],
        ),
      );

      expect(hosts.map((h) => h.hostId), ['lento']);
    },
  );
}
