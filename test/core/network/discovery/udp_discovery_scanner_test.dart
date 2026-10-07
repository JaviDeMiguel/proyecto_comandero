import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:proyecto_comandero/core/network/discovery/discovery_protocol.dart';
import 'package:proyecto_comandero/core/network/discovery/udp_discovery_responder.dart';
import 'package:proyecto_comandero/core/network/discovery/udp_discovery_scanner.dart';
import 'package:test/test.dart';

import 'discovery_test_support.dart';

/// Puerto de loopback en el que nadie escucha ni escuchará durante el test.
///
/// Se reserva un socket y se cierra: el sistema no reasigna un puerto efímero
/// recién liberado mientras queden otros libres.
Future<int> closedLoopbackPort() async {
  final socket = await RawDatagramSocket.bind(loopback, 0);
  final port = socket.port;
  socket.close();
  return port;
}

void main() {
  late UdpDiscoveryScanner scanner;

  setUp(() {
    scanner = UdpDiscoveryScanner(random: Random(7));
  });

  group('UdpDiscoveryScanner', () {
    test('descubre el host con todos sus campos', () async {
      final responder = await startResponder(
        announcement: () => const HostAnnouncement(
          hostId: 'host-barra',
          hostName: 'Barra principal',
          tcpPort: 4040,
          requiresPairing: true,
        ),
      );

      final hosts = await scanner.scan(
        loopbackScan([
          responder.port,
        ], timeout: const Duration(milliseconds: 300)),
      );

      expect(hosts, hasLength(1));
      final host = hosts.single;
      expect(host.hostId, 'host-barra');
      expect(host.hostName, 'Barra principal');
      expect(host.address, loopback);
      expect(host.tcpPort, 4040);
      expect(host.requiresPairing, isTrue);
      expect(host.roundTrip, greaterThanOrEqualTo(Duration.zero));
      expect(host.roundTrip, lessThan(const Duration(milliseconds: 300)));
      expect(host.toString(), contains('host-barra'));
    });

    test(
      'discover emite el host en cuanto responde, sin esperar al timeout',
      () async {
        final responder = await startResponder();
        final watch = Stopwatch()..start();

        final host = await scanner
            .discover(loopbackScan([responder.port]))
            .first
            .timeout(kEventTimeout);

        expect(host.hostId, 'host-1');
        expect(
          watch.elapsed,
          lessThan(const Duration(seconds: 5)),
          reason: 'no debe agotar el timeout de ${kEventTimeout.inSeconds} s',
        );
      },
    );

    test(
      'el anuncio se consulta en cada respuesta: cambia entre escaneos',
      () async {
        var name = 'Barra';
        final responder = await startResponder(
          announcement: () =>
              HostAnnouncement(hostId: 'host-1', hostName: name, tcpPort: 4040),
        );
        final options = loopbackScan([responder.port]);

        final first = await scanner.discover(options).first;
        expect(first.hostName, 'Barra');
        expect(first.requiresPairing, isFalse);

        name = 'Terraza';
        final second = await scanner.discover(options).first;
        expect(second.hostName, 'Terraza');
      },
    );

    test(
      'varios hosts en destinos distintos -> un resultado por host',
      () async {
        final barra = await startResponder(
          announcement: () => const HostAnnouncement(
            hostId: 'host-barra',
            hostName: 'Barra',
            tcpPort: 4040,
          ),
        );
        final cocina = await startResponder(
          announcement: () => const HostAnnouncement(
            hostId: 'host-cocina',
            hostName: 'Cocina',
            tcpPort: 4050,
          ),
        );

        final hosts = await scanner
            .discover(loopbackScan([barra.port, cocina.port]))
            .take(2)
            .toList();

        expect(
          {for (final host in hosts) host.hostId: host.tcpPort},
          {'host-barra': 4040, 'host-cocina': 4050},
        );
      },
    );

    test(
      'el mismo host respondiendo a varias sondas -> un solo resultado',
      () async {
        final responder = await startResponder();

        final hosts = await scanner.scan(
          loopbackScan(
            [responder.port],
            timeout: const Duration(milliseconds: 400),
            probes: 3,
            probeInterval: const Duration(milliseconds: 30),
          ),
        );

        expect(hosts, hasLength(1));
        expect(
          responder.probesAnswered,
          3,
          reason: 'todas las sondas llegaron y fueron respondidas',
        );
      },
    );

    test('el mismo host visto por dos destinos -> un solo resultado', () async {
      // Dos destinos distintos (dos sockets del escáner) hacia el mismo
      // respondedor: el broadcast limitado y el dirigido suelen alcanzar al
      // mismo host en la red real.
      final responder = await startResponder();
      final options = DiscoveryScanOptions(
        timeout: const Duration(milliseconds: 400),
        probes: 1,
        targets: [
          DiscoveryTarget(address: loopback, port: responder.port),
          DiscoveryTarget(
            address: InternetAddress('127.0.0.1'),
            port: responder.port,
          ),
        ],
      );

      final hosts = await scanner.scan(options);
      expect(hosts, hasLength(1));
    });

    test(
      'todas las sondas llevan el mismo nonce y son sondas válidas',
      () async {
        final peer = await RawPeer.bind();

        final subscription = scanner
            .discover(
              loopbackScan(
                [peer.port],
                probes: 3,
                probeInterval: const Duration(milliseconds: 20),
              ),
            )
            .listen((_) {});
        addTearDown(subscription.cancel);

        final probes = [
          for (var i = 0; i < 3; i++)
            DiscoveryProbe.tryParse((await peer.next()).data),
        ];
        expect(probes, everyElement(isNotNull));
        expect({for (final probe in probes) probe!.nonce}, hasLength(1));
        expect(probes.first!.nonce, matches(RegExp(r'^[0-9a-f]{16}$')));
        await subscription.cancel();
      },
    );

    test('ignora respuestas con otro nonce o mal formadas', () async {
      final real = await startResponder();
      final fake = await RawPeer.bind();
      fake.onDatagram = (datagram) {
        final probe = DiscoveryProbe.tryParse(datagram.data);
        expect(probe, isNotNull);
        final wrongNonce = DiscoveryResponse(
          nonce: probe!.nonce == 'ffffffffffffffff'
              ? '0000000000000000'
              : 'ffffffffffffffff',
          hostId: 'impostor-nonce',
          hostName: 'Impostor',
          tcpPort: 4040,
        ).toBytes();
        final malformed = jsonBytes({
          'magic': kDiscoveryMagic,
          'v': kDiscoveryVersion,
          'kind': 'response',
          'nonce': probe.nonce,
          'hostId': 'impostor-malformado',
          'hostName': 'Impostor',
          'tcpPort': '4040',
          'requiresPairing': false,
        });
        final otherKind = DiscoveryProbe(nonce: probe.nonce).toBytes();
        unawaited(
          fake.sendAll(
            [wrongNonce, malformed, otherKind],
            datagram.port,
            address: datagram.address,
          ),
        );
      };

      final hosts = await scanner.scan(
        loopbackScan([
          fake.port,
          real.port,
        ], timeout: const Duration(milliseconds: 400)),
      );

      expect(fake.received, 1, reason: 'el impostor recibió la sonda');
      expect(hosts.map((host) => host.hostId), ['host-1']);
    });

    test('sin respondedores: lista vacía al vencer el timeout', () async {
      final silent = await RawPeer.bind();
      const timeout = Duration(milliseconds: 300);
      final watch = Stopwatch()..start();

      final hosts = await scanner.scan(
        loopbackScan([silent.port], timeout: timeout),
      );

      expect(hosts, isEmpty);
      expect(watch.elapsed, greaterThanOrEqualTo(timeout));
      expect(watch.elapsed, lessThan(const Duration(seconds: 3)));
      expect(silent.received, 1);
    });

    test(
      'un destino cerrado (ICMP puerto inalcanzable) no rompe el escaneo',
      () async {
        final responder = await startResponder();
        final closed = await closedLoopbackPort();

        final hosts = await scanner.scan(
          loopbackScan(
            [closed, responder.port],
            timeout: const Duration(milliseconds: 400),
            probes: 2,
            probeInterval: const Duration(milliseconds: 30),
          ),
        );

        expect(hosts.map((host) => host.hostId), ['host-1']);
      },
    );

    test(
      'cancelar discover antes del timeout cierra el socket y no emite más',
      () async {
        final silent = await RawPeer.bind();
        final events = <Object>[];
        var done = false;

        final subscription = scanner
            .discover(loopbackScan([silent.port]))
            .listen(events.add, onError: events.add, onDone: () => done = true);

        final probe = await silent.next();
        expect(DiscoveryProbe.tryParse(probe.data), isNotNull);
        final scannerPort = probe.port;

        await subscription.cancel();

        // El socket del escáner estaba en anyIPv4:puerto; si se liberó, se
        // puede volver a enlazar en exclusiva.
        await expectUdpPortFree(scannerPort, address: InternetAddress.anyIPv4);

        // Una respuesta tardía no llega a ningún sitio ni provoca errores.
        await silent.send(
          DiscoveryResponse(
            nonce: DiscoveryProbe.tryParse(probe.data)!.nonce,
            hostId: 'tarde',
            hostName: 'Tarde',
            tcpPort: 4040,
          ).toBytes(),
          scannerPort,
        );
        expect(events, isEmpty);
        expect(
          done,
          isFalse,
          reason: 'cancelar no cierra el stream con onDone',
        );
      },
    );

    test('scan agrega lo que emite discover', () async {
      final responder = await startResponder();
      final options = loopbackScan([
        responder.port,
      ], timeout: const Duration(milliseconds: 300));

      final streamed = await scanner.discover(options).toList();
      final scanned = await scanner.scan(options);

      expect(scanned.map((h) => h.hostId), streamed.map((h) => h.hostId));
    });

    test('rechaza opciones sin sentido antes de abrir nada', () {
      expect(
        () => scanner.discover(
          const DiscoveryScanOptions(timeout: Duration.zero),
        ),
        throwsArgumentError,
      );
      expect(
        () => scanner.discover(const DiscoveryScanOptions(probes: 0)),
        throwsArgumentError,
      );
      expect(
        () => scanner.discover(
          const DiscoveryScanOptions(probeInterval: Duration(milliseconds: -1)),
        ),
        throwsArgumentError,
      );
      expect(
        () => DiscoveryTarget(address: loopback, port: 0),
        throwsRangeError,
      );
    });

    test(
      'con una lista de destinos vacía termina sin resultados ni error',
      () async {
        final hosts = await scanner.scan(
          const DiscoveryScanOptions(targets: []),
        );
        expect(hosts, isEmpty);
      },
    );
  });

  group('destinos automáticos', () {
    test(
      'defaultTargets incluye 255.255.255.255 y no tiene duplicados',
      () async {
        final targets = await UdpDiscoveryScanner.defaultTargets(port: 50000);

        expect(
          targets,
          contains(DiscoveryTarget.limitedBroadcast(port: 50000)),
        );
        expect(targets.toSet(), hasLength(targets.length));
        for (final target in targets) {
          expect(target.port, 50000);
          expect(target.address.type, InternetAddressType.IPv4);
          expect(target.address.rawAddress.last, 255);
        }
      },
    );

    test(
      'targetsForAddresses deriva el broadcast /24 y filtra lo que no toca',
      () {
        final targets = UdpDiscoveryScanner.targetsForAddresses([
          InternetAddress('192.168.1.23'),
          InternetAddress('192.168.1.99'), // misma subred: un solo destino
          InternetAddress('10.0.7.4'),
          InternetAddress('127.0.0.1'), // loopback
          InternetAddress('169.254.3.3'), // link-local
          InternetAddress('0.0.0.0'),
          InternetAddress('fe80::1'), // IPv6
        ], port: 4041);

        expect(targets.map((t) => t.toString()), [
          '255.255.255.255:4041',
          '192.168.1.255:4041',
          '10.0.7.255:4041',
        ]);
      },
    );

    test('DiscoveryTarget compara por dirección y puerto', () {
      final a = DiscoveryTarget(
        address: InternetAddress('10.0.0.255'),
        port: 1,
      );
      final b = DiscoveryTarget(
        address: InternetAddress('10.0.0.255'),
        port: 1,
      );
      final c = DiscoveryTarget(
        address: InternetAddress('10.0.0.255'),
        port: 2,
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(c));
    });
  });

  group('broadcast real', () {
    // Sale por la interfaz de la ruta por defecto y depende del cortafuegos y
    // de la red de la máquina: solo se ejecuta bajo demanda.
    final enabled = Platform.environment['TPV_TEST_BROADCAST'] == '1';

    test('255.255.255.255 alcanza a un respondedor en anyIPv4', () async {
      final responder = UdpDiscoveryResponder(
        announcement: () => const HostAnnouncement(
          hostId: 'host-broadcast',
          hostName: 'Broadcast',
          tcpPort: 4040,
        ),
        port: 0,
      );
      addTearDown(responder.stop);
      await responder.start();

      final hosts = await scanner.scan(
        DiscoveryScanOptions(
          timeout: const Duration(seconds: 2),
          probes: 3,
          probeInterval: const Duration(milliseconds: 200),
          targets: [DiscoveryTarget.limitedBroadcast(port: responder.port)],
        ),
      );

      expect(hosts.map((host) => host.hostId), ['host-broadcast']);
    }, skip: enabled ? false : 'Define TPV_TEST_BROADCAST=1 para ejecutarlo');
  });
}
