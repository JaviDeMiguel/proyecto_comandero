import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:proyecto_comandero/core/errors/app_exception.dart';
import 'package:proyecto_comandero/core/facturascripts/catalog/catalog_models.dart';
import 'package:proyecto_comandero/core/network/discovery/discovery.dart';
import 'package:proyecto_comandero/core/network/protocol/message.dart';
import 'package:proyecto_comandero/core/network/protocol/transport_messages.dart';
import 'package:proyecto_comandero/core/network/tcp/tcp_comandero_client.dart';
import 'package:proyecto_comandero/core/network/tcp/tcp_host_server.dart';
import 'package:proyecto_comandero/features/host/application/host_network_service.dart';
import 'package:proyecto_comandero/features/sala/domain/ticket.dart';
import 'package:proyecto_comandero/features/sala/protocol/sala_messages.dart';
import 'package:test/test.dart';

import '../../core/network/tcp/test_support.dart';
import 'support/host_test_support.dart';

const HostServerOptions _serverOptions = HostServerOptions(
  handshakeTimeout: Duration(seconds: 1),
  heartbeatInterval: Duration(milliseconds: 50),
  idleTimeout: Duration(milliseconds: 500),
  closeTimeout: Duration(milliseconds: 100),
);

const ClientOptions _clientOptions = ClientOptions(
  connectTimeout: Duration(seconds: 1),
  handshakeTimeout: Duration(seconds: 1),
  requestTimeout: Duration(seconds: 2),
  reconnectBaseDelay: Duration(milliseconds: 10),
  reconnectMaxDelay: Duration(milliseconds: 50),
  closeTimeout: Duration(milliseconds: 100),
);

void main() {
  late SalaFixture f;
  late HostNetworkService red;
  final clients = <TcpComanderoClient>[];

  HostNetworkConfig config({String? pairingCode, bool discovery = true}) =>
      HostNetworkConfig(
        hostId: 'host-1',
        hostName: 'Barra principal',
        tcpPort: 0,
        discoveryPort: 0,
        pairingCode: pairingCode,
        bindAddress: InternetAddress.loopbackIPv4,
        discoveryEnabled: discovery,
        serverOptions: _serverOptions,
      );

  setUp(() async {
    f = await SalaFixture.create();
    red = HostNetworkService(
      sala: f.sala,
      catalog: f.catalog,
      alerts: f.alerts,
      config: config(),
    );
    await red.start();
  });

  tearDown(() async {
    for (final client in clients) {
      await client.dispose();
    }
    clients.clear();
    await red.dispose();
    await f.dispose();
  });

  HostEndpoint endpoint() =>
      HostEndpoint(host: '127.0.0.1', port: red.tcpPort!);

  Future<TcpComanderoClient> conectar(
    String deviceId, {
    String? pairing,
  }) async {
    final client = TcpComanderoClient(
      identity: ClientIdentity(
        deviceId: deviceId,
        deviceName: 'Móvil $deviceId',
      ),
      options: ClientOptions(
        connectTimeout: _clientOptions.connectTimeout,
        handshakeTimeout: _clientOptions.handshakeTimeout,
        requestTimeout: _clientOptions.requestTimeout,
        reconnectBaseDelay: _clientOptions.reconnectBaseDelay,
        reconnectMaxDelay: _clientOptions.reconnectMaxDelay,
        closeTimeout: _clientOptions.closeTimeout,
        pairingCode: pairing,
      ),
      random: Random(1),
    );
    clients.add(client);
    final connected = client.states.firstWhere((s) => s is Connected);
    client.connect(endpoint());
    await connected.timeout(kWait);
    return client;
  }

  test(
    'arranca con puertos efímeros y se anuncia por UDP en loopback',
    () async {
      expect(red.isRunning, isTrue);
      expect(red.tcpPort, greaterThan(0));
      expect(red.discoveryPort, greaterThan(0));

      final hosts = await UdpDiscoveryScanner(random: Random(7)).scan(
        DiscoveryScanOptions(
          timeout: const Duration(seconds: 3),
          probes: 2,
          probeInterval: const Duration(milliseconds: 50),
          targets: [
            DiscoveryTarget(
              address: InternetAddress.loopbackIPv4,
              port: red.discoveryPort!,
            ),
          ],
        ),
      );
      final host = hosts.firstWhere((h) => h.hostId == 'host-1');
      expect(host.hostName, 'Barra principal');
      expect(host.tcpPort, red.tcpPort);
      expect(host.requiresPairing, isFalse);
    },
  );

  test(
    'snapshot, catálogo, submit, anular, cuenta y evento salaChanged',
    () async {
      final a = await conectar('a');
      final b = await conectar('b');
      final eventosB = Inbox<ProtocolMessage>(b.messages);
      addTearDown(eventosB.cancel);

      final snapshot = SalaSnapshot.fromJson(
        (await a.request(SalaMessageTypes.salaSnapshotGet, {})).payload,
      );
      expect(snapshot.mesas, mesasPrueba);
      expect(snapshot.comandas, isEmpty);
      expect(snapshot.catalogoVersion, f.catalog.version);

      final catalogo = CatalogSnapshot.fromJson(
        (await a.request(SalaMessageTypes.catalogoGet, {})).payload,
      );
      expect(catalogo, catalogoPrueba());

      final submit = await a.request(
        SalaMessageTypes.comandaSubmit,
        ComandaSubmitPayload(
          mesaId: 'm1',
          lineas: [linea('l1', 'CANA', 2), linea('l2', 'PAELLA', 1)],
          camarero: 'Ana',
        ).toJson(),
        reliable: true,
      );
      expect(submit.type, TransportMessageTypes.ack);
      final result = ComandaSubmitResult.fromJson(submit.payload);
      expect(result.lineasNuevas, 2);
      expect(result.comanda.camarero, 'Ana');

      final cambio = await eventosB.next(what: 'sala.changed en b');
      expect(cambio.type, SalaMessageTypes.salaChanged);
      final evento = SalaChangedEvent.fromJson(cambio.payload);
      expect(evento.mesaId, 'm1');
      expect(evento.comanda, result.comanda);

      final anular = ComandaResult.fromJson(
        (await a.request(
          SalaMessageTypes.lineaAnular,
          const LineaAnularPayload(mesaId: 'm1', lineaId: 'l2').toJson(),
          reliable: true,
        )).payload,
      );
      expect(anular.comanda.lineaPorId('l2')!.anulada, isTrue);
      expect(
        anular.comanda.lineaPorId('l2')!.motivoAnulacion,
        contains('Móvil a'),
      );
      expect(
        SalaChangedEvent.fromJson((await eventosB.next()).payload).comanda,
        anular.comanda,
      );

      final cuenta = ComandaResult.fromJson(
        (await b.request(
          SalaMessageTypes.mesaCuenta,
          const MesaCuentaPayload(mesaId: 'm1', solicitada: true).toJson(),
        )).payload,
      );
      expect(cuenta.comanda.cuentaSolicitada, isTrue);
      // El evento también llega al comandero que lo provocó.
      expect(
        SalaChangedEvent.fromJson((await eventosB.next()).payload)
            .comanda!
            .cuentaSolicitada,
        isTrue,
      );
      expect(red.sessions.map((s) => s.deviceId), containsAll(['a', 'b']));

      // El host cobra: los comanderos ven la mesa libre.
      await f.sala.cobrar('m1', MetodoPago.tarjeta);
      final libre = SalaChangedEvent.fromJson((await eventosB.next()).payload);
      expect(libre.mesaId, 'm1');
      expect(libre.comanda, isNull);
    },
  );

  test(
    'errores de negocio y de formato viajan como error no reintentable',
    () async {
      final a = await conectar('a');
      await expectLater(
        a.request(
          SalaMessageTypes.comandaSubmit,
          ComandaSubmitPayload(
            mesaId: 'zz',
            lineas: [linea('l1', 'CANA', 1)],
          ).toJson(),
        ),
        throwsA(
          isA<RemoteRequestException>()
              .having((e) => e.code, 'code', SalaErrorCodes.mesaDesconocida)
              .having((e) => e.retryable, 'retryable', isFalse),
        ),
      );
      await expectLater(
        a.request(SalaMessageTypes.comandaSubmit, {'mesaId': 'm1'}),
        throwsA(
          isA<RemoteRequestException>().having(
            (e) => e.code,
            'code',
            ErrorCodes.validation,
          ),
        ),
      );
      await expectLater(
        a.request('sala.inventado', {}),
        throwsA(
          isA<RemoteRequestException>().having(
            (e) => e.code,
            'code',
            ErrorCodes.unknownType,
          ),
        ),
      );
    },
  );

  test('sin catálogo el comandero recibe un error reintentable', () async {
    final sinCatalogo = await SalaFixture.create(conCatalogo: false);
    final red2 = HostNetworkService(
      sala: sinCatalogo.sala,
      catalog: sinCatalogo.catalog,
      alerts: sinCatalogo.alerts,
      config: config(discovery: false),
    );
    await red2.start();
    addTearDown(() async {
      await red2.dispose();
      await sinCatalogo.dispose();
    });
    expect(red2.discoveryPort, isNull);
    final client = TcpComanderoClient(
      identity: const ClientIdentity(deviceId: 'c', deviceName: 'C'),
      options: _clientOptions,
    );
    clients.add(client);
    final connected = client.states.firstWhere((s) => s is Connected);
    client.connect(HostEndpoint(host: '127.0.0.1', port: red2.tcpPort!));
    await connected.timeout(kWait);
    await expectLater(
      client.request(SalaMessageTypes.catalogoGet, {}),
      throwsA(
        isA<RemoteRequestException>()
            .having((e) => e.code, 'code', 'catalogo_no_disponible')
            .having((e) => e.retryable, 'retryable', isTrue),
      ),
    );
  });

  test(
    'submit fiable: la retransmisión tras una desconexión no duplica',
    () async {
      final a = await conectar('a');
      final states = Inbox<ClientConnectionState>(a.states);
      addTearDown(states.cancel);

      // Se expulsa al comandero justo después de enviar: el host procesa la
      // petición pero la respuesta no llega; el cliente retransmite al volver.
      final pending = a.request(
        SalaMessageTypes.comandaSubmit,
        ComandaSubmitPayload(
          mesaId: 'm1',
          lineas: [linea('l1', 'CANA', 3)],
        ).toJson(),
        reliable: true,
      );
      await red.disconnect('a');
      await states.nextWhere((s) => s is Connected, what: 'reconexión');
      final reply = await pending.timeout(kWait);
      expect(reply.type, TransportMessageTypes.ack);
      final result = ComandaSubmitResult.fromJson(reply.payload);
      expect(result.comanda.lineas, hasLength(1));

      // Segundo envío de la misma línea (otra petición): duplicada, no nueva.
      final again = ComandaSubmitResult.fromJson(
        (await a.request(
          SalaMessageTypes.comandaSubmit,
          ComandaSubmitPayload(
            mesaId: 'm1',
            lineas: [linea('l1', 'CANA', 3)],
          ).toJson(),
          reliable: true,
        )).payload,
      );
      expect(again.lineasNuevas, 0);
      expect(again.lineasDuplicadas, 1);
      expect(f.sala.comandaDeMesa('m1')!.lineas, hasLength(1));
    },
  );

  test('código de emparejamiento: rechaza sin código y se anuncia', () async {
    await red.applyConfig(config(pairingCode: '1234'));
    expect(red.isRunning, isTrue);
    final hosts = await UdpDiscoveryScanner(random: Random(3)).scan(
      DiscoveryScanOptions(
        timeout: const Duration(seconds: 2),
        probes: 2,
        probeInterval: const Duration(milliseconds: 50),
        targets: [
          DiscoveryTarget(
            address: InternetAddress.loopbackIPv4,
            port: red.discoveryPort!,
          ),
        ],
      ),
    );
    expect(hosts.single.requiresPairing, isTrue);

    final malo = TcpComanderoClient(
      identity: const ClientIdentity(deviceId: 'x', deviceName: 'X'),
      options: _clientOptions,
    );
    clients.add(malo);
    final rejected = malo.states.firstWhere((s) => s is Rejected);
    malo.connect(endpoint());
    expect(((await rejected.timeout(kWait)) as Rejected).code, 'unauthorized');

    final bueno = await conectar('y', pairing: '1234');
    expect(bueno.state, isA<Connected>());
  });

  test('stop despide a los comanderos y libera los puertos', () async {
    final a = await conectar('a');
    final states = Inbox<ClientConnectionState>(a.states);
    addTearDown(states.cancel);
    final tcp = red.tcpPort!;
    await red.stop();
    expect(red.isRunning, isFalse);
    expect(red.sessions, isEmpty);
    await states.nextWhere((s) => s is Reconnecting, what: 'bye del host');
    expect(await isPortFree(tcp), isTrue);
    await red.start();
    expect(red.isRunning, isTrue);
  });
}
