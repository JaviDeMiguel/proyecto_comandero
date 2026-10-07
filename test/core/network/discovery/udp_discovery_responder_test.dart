import 'dart:io';

import 'package:proyecto_comandero/core/errors/app_exception.dart';
import 'package:proyecto_comandero/core/network/discovery/discovery_protocol.dart';
import 'package:proyecto_comandero/core/network/discovery/udp_discovery_responder.dart';
import 'package:test/test.dart';

import 'discovery_test_support.dart';

const String _nonce = 'abcdef0123456789';

void main() {
  group('UdpDiscoveryResponder', () {
    test('responde por unicast al origen con el eco del nonce', () async {
      final responder = await startResponder();
      final peer = await RawPeer.bind();

      await peer.send(
        const DiscoveryProbe(nonce: _nonce).toBytes(),
        responder.port,
      );
      final datagram = await peer.next();

      expect(datagram.address, loopback);
      expect(datagram.port, responder.port);
      expect(
        DiscoveryResponse.tryParse(datagram.data),
        const DiscoveryResponse(
          nonce: _nonce,
          hostId: 'host-1',
          hostName: 'Barra',
          tcpPort: 4040,
        ),
      );
      expect(responder.probesAnswered, 1);
      expect(peer.errors, isEmpty);
    });

    test('consulta el anuncio en cada respuesta', () async {
      var announcement = const HostAnnouncement(
        hostId: 'host-1',
        hostName: 'Barra',
        tcpPort: 4040,
      );
      final responder = await startResponder(announcement: () => announcement);
      final peer = await RawPeer.bind();

      final first = await peer.probe(responder.port, nonce: _nonce);
      expect(first?.hostName, 'Barra');
      expect(first?.tcpPort, 4040);
      expect(first?.requiresPairing, isFalse);

      announcement = const HostAnnouncement(
        hostId: 'host-1',
        hostName: 'Terraza',
        tcpPort: 4141,
        requiresPairing: true,
      );
      final second = await peer.probe(responder.port, nonce: _nonce);
      expect(second?.hostName, 'Terraza');
      expect(second?.tcpPort, 4141);
      expect(second?.requiresPairing, isTrue);
    });

    test(
      'recorta un nombre de host demasiado largo en vez de callarse',
      () async {
        final responder = await startResponder(
          announcement: () => HostAnnouncement(
            hostId: 'host-1',
            hostName: '  ${'n' * (kMaxDiscoveryHostNameLength + 20)}  ',
            tcpPort: 4040,
          ),
        );
        final peer = await RawPeer.bind();

        final response = await peer.probe(responder.port, nonce: _nonce);
        expect(response?.hostName, 'n' * kMaxDiscoveryHostNameLength);
      },
    );

    test('no responde si el anuncio es inválido, pero sigue vivo', () async {
      var tcpPort = 0;
      final responder = await startResponder(
        announcement: () => HostAnnouncement(
          hostId: 'host-1',
          hostName: 'Barra',
          tcpPort: tcpPort,
        ),
      );
      final peer = await RawPeer.bind();

      await peer.send(
        const DiscoveryProbe(nonce: _nonce).toBytes(),
        responder.port,
      );
      await waitUntil(
        () => responder.announcementFailures == 1,
        reason: 'registrar el anuncio inválido',
      );
      expect(responder.isRunning, isTrue);
      expect(responder.probesAnswered, 0);

      tcpPort = 4040;
      final response = await peer.probe(responder.port, nonce: _nonce);
      expect(response?.tcpPort, 4040);
      expect(responder.probesAnswered, 1);
      expect(peer.pending, 0);
    });

    test('ignora datagramas basura y sigue respondiendo', () async {
      final responder = await startResponder();
      final peer = await RawPeer.bind();

      final garbage = <List<int>>[
        const [0x00, 0xFF, 0x13, 0x37, 0x80],
        jsonBytes({'type': 'ssdp:alive', 'usn': 'uuid:x'}),
        jsonBytes({
          'magic': kDiscoveryMagic,
          'v': kDiscoveryVersion + 1,
          'kind': 'probe',
          'nonce': _nonce,
        }),
        jsonBytes({
          'magic': kDiscoveryMagic,
          'v': kDiscoveryVersion,
          'kind': 'probe',
          'nonce': _nonce,
          'relleno': 'x' * (kMaxDiscoveryDatagramBytes * 3),
        }),
        // Una respuesta no es una sonda: un host no debe contestar a otro.
        const DiscoveryResponse(
          nonce: _nonce,
          hostId: 'otro',
          hostName: 'Otro',
          tcpPort: 4040,
        ).toBytes(),
      ];
      for (final bytes in garbage) {
        await peer.send(bytes, responder.port);
      }
      await waitUntil(
        () => responder.datagramsIgnored == garbage.length,
        reason: 'descartar ${garbage.length} datagramas basura',
      );

      final response = await peer.probe(responder.port, nonce: _nonce);
      expect(response?.nonce, _nonce);
      expect(responder.probesAnswered, 1);
      expect(peer.pending, 0, reason: 'la basura no genera respuestas');
      expect(responder.isRunning, isTrue);
    });

    test('responde a una ráfaga de sondas sin perder ninguna', () async {
      // Varias sondas en el mismo evento `read` obligan a encadenar envíos;
      // en Windows el socket solo admite uno en vuelo, así que esto ejercita
      // la cola de salida.
      final responder = await startResponder();
      final peer = await RawPeer.bind();
      const burst = 40;

      for (var i = 0; i < burst; i++) {
        await peer.send(
          DiscoveryProbe(nonce: i.toRadixString(16).padLeft(4, '0')).toBytes(),
          responder.port,
        );
      }

      final nonces = <String>{};
      for (var i = 0; i < burst; i++) {
        final response = DiscoveryResponse.tryParse((await peer.next()).data);
        nonces.add(response!.nonce);
      }
      expect(nonces, hasLength(burst));
      expect(responder.probesAnswered, burst);
      expect(responder.responsesDropped, 0);
    });

    test('limita las respuestas por IP de origen y las reanuda al vencer la '
        'ventana', () async {
      var now = Duration.zero;
      final responder = await startResponder(
        maxResponsesPerSource: 2,
        rateLimitWindow: const Duration(seconds: 1),
        monotonicClock: () => now,
      );
      final peer = await RawPeer.bind();

      for (var i = 0; i < 5; i++) {
        await peer.send(
          const DiscoveryProbe(nonce: _nonce).toBytes(),
          responder.port,
        );
      }
      await waitUntil(
        () => responder.probesRateLimited == 3,
        reason: 'descartar las sondas por encima del límite',
      );
      expect(responder.probesAnswered, 2);
      await peer.next();
      await peer.next();
      expect(peer.pending, 0);

      // Dentro de la misma ventana se sigue descartando.
      now = const Duration(milliseconds: 999);
      await peer.send(
        const DiscoveryProbe(nonce: _nonce).toBytes(),
        responder.port,
      );
      await waitUntil(
        () => responder.probesRateLimited == 4,
        reason: 'descartar la sonda dentro de la ventana',
      );
      expect(peer.pending, 0);

      // Al vencer la ventana vuelve a responder.
      now = const Duration(milliseconds: 1000);
      final response = await peer.probe(responder.port, nonce: _nonce);
      expect(response?.nonce, _nonce);
      expect(responder.probesAnswered, 3);
    });

    test('el límite es por IP: otro origen no queda afectado', () async {
      // Ambos peers salen de 127.0.0.1, así que para distinguir orígenes se
      // usa otra dirección de loopback (Windows y Linux enrutan todo 127/8).
      final responder = await startResponder(maxResponsesPerSource: 1);
      final peerA = await RawPeer.bind();
      final RawPeer peerB;
      try {
        peerB = await RawPeer.bind(address: InternetAddress('127.0.0.2'));
      } on SocketException {
        markTestSkipped('Esta plataforma no expone 127.0.0.2');
        return;
      }

      expect(await peerA.probe(responder.port, nonce: _nonce), isNotNull);
      await peerA.send(
        const DiscoveryProbe(nonce: _nonce).toBytes(),
        responder.port,
      );
      await waitUntil(
        () => responder.probesRateLimited == 1,
        reason: 'limitar al primer origen',
      );

      await peerB.send(
        const DiscoveryProbe(nonce: _nonce).toBytes(),
        responder.port,
        address: loopback,
      );
      final response = DiscoveryResponse.tryParse((await peerB.next()).data);
      expect(response?.nonce, _nonce);
      expect(peerA.pending, 0);
    });

    test('rechaza parámetros sin sentido', () {
      HostAnnouncement announce() =>
          const HostAnnouncement(hostId: 'h', hostName: 'n', tcpPort: 1);
      expect(
        () => UdpDiscoveryResponder(announcement: announce, port: 70000),
        throwsRangeError,
      );
      expect(
        () => UdpDiscoveryResponder(
          announcement: announce,
          maxResponsesPerSource: 0,
        ),
        throwsArgumentError,
      );
      expect(
        () => UdpDiscoveryResponder(
          announcement: announce,
          rateLimitWindow: Duration.zero,
        ),
        throwsArgumentError,
      );
    });

    group('ciclo de vida', () {
      test('antes de start no está en marcha y port es el configurado', () {
        final responder = UdpDiscoveryResponder(
          announcement: () =>
              const HostAnnouncement(hostId: 'h', hostName: 'n', tcpPort: 1),
          port: 0,
          bindAddress: loopback,
        );
        expect(responder.isRunning, isFalse);
        expect(responder.port, 0);
      });

      test('start asigna un puerto real y stop lo libera', () async {
        final responder = await startResponder();
        final port = responder.port;
        expect(responder.isRunning, isTrue);
        expect(port, greaterThan(0));

        await responder.stop();
        expect(responder.isRunning, isFalse);
        expect(responder.port, 0, reason: 'vuelve al puerto configurado');
        await expectUdpPortFree(port);
      });

      test('stop es idempotente y se puede volver a arrancar', () async {
        final responder = await startResponder();
        await responder.stop();
        await responder.stop();
        expect(responder.isRunning, isFalse);

        await responder.start();
        expect(responder.isRunning, isTrue);
        final peer = await RawPeer.bind();
        expect(await peer.probe(responder.port, nonce: _nonce), isNotNull);
      });

      test('start dos veces no abre un segundo socket', () async {
        final responder = await startResponder();
        final port = responder.port;

        await responder.start();
        expect(responder.port, port);
        expect(responder.isRunning, isTrue);

        await responder.stop();
        await expectUdpPortFree(port);
      });

      test('start concurrente comparte el mismo arranque', () async {
        final responder = UdpDiscoveryResponder(
          announcement: () =>
              const HostAnnouncement(hostId: 'h', hostName: 'n', tcpPort: 1),
          port: 0,
          bindAddress: loopback,
        );
        addTearDown(responder.stop);

        final first = responder.start();
        final second = responder.start();
        expect(identical(first, second), isTrue);
        await Future.wait([first, second]);
        expect(responder.isRunning, isTrue);
      });

      test('stop durante el arranque deja el socket cerrado', () async {
        final responder = UdpDiscoveryResponder(
          announcement: () =>
              const HostAnnouncement(hostId: 'h', hostName: 'n', tcpPort: 1),
          port: 0,
          bindAddress: loopback,
        );
        final starting = responder.start();
        await responder.stop();
        await starting;
        expect(responder.isRunning, isFalse);
      });

      test(
        'un puerto ocupado sin reuseAddress produce NetworkException',
        () async {
          final holder = await RawPeer.bind(reuseAddress: false);
          final responder = UdpDiscoveryResponder(
            announcement: () =>
                const HostAnnouncement(hostId: 'h', hostName: 'n', tcpPort: 1),
            port: holder.port,
            bindAddress: loopback,
            reuseAddress: false,
          );
          addTearDown(responder.stop);

          await expectLater(
            responder.start(),
            throwsA(
              isA<NetworkException>()
                  .having((e) => e.cause, 'cause', isA<SocketException>())
                  .having(
                    (e) => e.message,
                    'message',
                    contains('${holder.port}'),
                  ),
            ),
          );
          expect(responder.isRunning, isFalse);

          // Tras el fallo se puede reintentar: con el puerto ya libre arranca.
          await holder.close();
          await responder.start();
          expect(responder.isRunning, isTrue);
          expect(responder.port, holder.port);
        },
      );

      test('con reuseAddress (por defecto) comparte un puerto ya enlazado con '
          'reuseAddress', () async {
        // Comportamiento documentado en el constructor: ambos sockets conviven
        // y solo uno de ellos recibe cada sonda unicast.
        final holder = await RawPeer.bind();
        final responder = UdpDiscoveryResponder(
          announcement: () =>
              const HostAnnouncement(hostId: 'h', hostName: 'n', tcpPort: 1),
          port: holder.port,
          bindAddress: loopback,
        );
        addTearDown(responder.stop);

        await responder.start();
        expect(responder.isRunning, isTrue);
        expect(responder.port, holder.port);
      });
    });
  });
}
