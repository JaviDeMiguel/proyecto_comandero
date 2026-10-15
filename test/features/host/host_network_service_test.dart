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
import 'package:proyecto_comandero/features/sala/domain/enrutamiento_comandas.dart';
import 'package:proyecto_comandero/features/sala/domain/linea_comanda.dart';
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

  /// `comanda.submit` fiable desde [cliente], como lo manda el comandero.
  Future<ComandaSubmitResult> enviar(
    TcpComanderoClient cliente,
    ComandaSubmitPayload payload,
  ) async => ComandaSubmitResult.fromJson(
    (await cliente.request(
      SalaMessageTypes.comandaSubmit,
      payload.toJson(),
      reliable: true,
    )).payload,
  );

  /// `comanda.pase.marchar` fiable desde [cliente], como lo manda el
  /// comandero.
  Future<ComandaResult> marchar(
    TcpComanderoClient cliente,
    MarcharPasePayload payload,
  ) async => ComandaResult.fromJson(
    (await cliente.request(
      SalaMessageTypes.paseMarchar,
      payload.toJson(),
      reliable: true,
    )).payload,
  );

  /// Error del host con [code] que el comandero no debe reintentar.
  Matcher errorNoReintentable(String code) => throwsA(
    isA<RemoteRequestException>()
        .having((e) => e.code, 'code', code)
        .having((e) => e.retryable, 'retryable', isFalse),
  );

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

  test('comanda.submit sin camarero usa el nombre del dispositivo y con él '
      'lo respeta', () async {
    final a = await conectar('a');
    final b = await conectar('b');

    // Sin camarero: el nombre del dispositivo de la sesión, en la comanda y
    // en cada línea del envío.
    final sinCamarero = await enviar(a, submit('m1', [linea('l1', 'CANA', 1)]));
    expect(sinCamarero.lineasNuevas, 1);
    expect(sinCamarero.comanda.camarero, 'Móvil a');
    expect(sinCamarero.comanda.lineaPorId('l1')!.camarero, 'Móvil a');

    // Con camarero: se respeta.
    final conCamarero = await enviar(
      b,
      submit('m2', [linea('l2', 'CAFE', 1)], camarero: 'Ana'),
    );
    expect(conCamarero.comanda.camarero, 'Ana');
    expect(conCamarero.comanda.lineaPorId('l2')!.camarero, 'Ana');

    // Otro dispositivo envía a la mesa de 'a': la línea lleva el camarero de
    // su envío y la comanda conserva al primero.
    final segundo = await enviar(b, submit('m1', [linea('l3', 'AGUA', 1)]));
    expect(segundo.comanda.camarero, 'Móvil a');
    expect(segundo.comanda.lineaPorId('l3')!.camarero, 'Móvil b');

    // Un camarero en blanco cuenta como ausente.
    final enBlanco = await enviar(
      a,
      submit('m2', [linea('l4', 'CANA', 1)], camarero: '  '),
    );
    expect(enBlanco.comanda.camarero, 'Ana');
    expect(enBlanco.comanda.lineaPorId('l4')!.camarero, 'Móvil a');
    expect(f.sala.comandaDeMesa('m2'), enBlanco.comanda);
  });

  test('configurarEnrutamiento difunde enrutamiento.changed y el snapshot '
      'siguiente lleva las reglas nuevas', () async {
    final a = await conectar('a');
    final eventos = Inbox<ProtocolMessage>(a.messages);
    addTearDown(eventos.cancel);

    const nuevas = EnrutamientoComandas(
      porFamilia: {'PLA': DestinoPreparacion.barra},
    );
    f.sala.configurarEnrutamiento(nuevas);
    final aviso = await eventos.next(what: 'enrutamiento.changed');
    expect(aviso.type, SalaMessageTypes.enrutamientoChanged);
    expect(aviso.payload, isEmpty);

    final snapshot = SalaSnapshot.fromJson(
      (await a.request(SalaMessageTypes.salaSnapshotGet, {})).payload,
    );
    expect(snapshot.enrutamiento, f.sala.enrutamientoEfectivo);
    expect(snapshot.enrutamiento!.porFamilia['PLA'], DestinoPreparacion.barra);
  });

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

  group('comanda.pase.marchar', () {
    test('se enruta a la sala y responde ComandaResult; sin camarero (o en '
        'blanco) marcha el dispositivo y con él se respeta', () async {
      final a = await conectar('a');
      final b = await conectar('b');
      final eventosB = Inbox<ProtocolMessage>(b.messages);
      addTearDown(eventosB.cancel);

      final abierta = (await enviar(
        a,
        submit('m1', [
          linea('l1', 'CANA', 2, pase: 1),
          linea('l2', 'PAELLA', 1, pase: 2),
        ]),
      )).comanda;
      // «Marchar al enviar» (por defecto): el 1.º sale marchado solo.
      expect(abierta.pasesMarchados, {1});
      await eventosB.next(what: 'sala.changed del envío');

      final marchada = await marchar(
        a,
        MarcharPasePayload(
          mesaId: 'm1',
          pase: 2,
          marchaId: 'marcha-1',
          comandaId: abierta.id,
        ),
      );
      expect(marchada.comanda.id, abierta.id);
      expect(marchada.comanda, f.sala.comandaDeMesa('m1'));
      final marcha = marchada.comanda.marchaPorId('marcha-1')!;
      expect(marcha.pase, 2);
      expect(marcha.camarero, 'Móvil a');
      expect(marcha.automatica, isFalse);
      expect(marcha.repetida, isFalse);
      // El otro comandero recibe la comanda con la marcha.
      final evento = SalaChangedEvent.fromJson(
        (await eventosB.next(what: 'sala.changed de la marcha')).payload,
      );
      expect(evento.mesaId, 'm1');
      expect(evento.comanda, marchada.comanda);

      // Con camarero se respeta; el pase ya marchado sale «repetido».
      final otra = await marchar(
        b,
        MarcharPasePayload(
          mesaId: 'm1',
          pase: 2,
          marchaId: 'marcha-2',
          comandaId: abierta.id,
          camarero: 'Ana',
        ),
      );
      final repetida = otra.comanda.marchaPorId('marcha-2')!;
      expect(repetida.camarero, 'Ana');
      expect(repetida.repetida, isTrue);

      // La misma pulsación en otra petición (otro id de mensaje, mismo
      // marchaId) no marcha otra vez.
      final retransmitida = await marchar(
        a,
        MarcharPasePayload(
          mesaId: 'm1',
          pase: 2,
          marchaId: 'marcha-1',
          comandaId: abierta.id,
        ),
      );
      expect(retransmitida.comanda, otra.comanda);
      expect(f.sala.comandaDeMesa('m1')!.marchas.map((m) => m.pase), [1, 2, 2]);

      // Un camarero en blanco cuenta como ausente: marcha el nombre del
      // dispositivo que la manda.
      final enBlanco = await marchar(
        b,
        MarcharPasePayload(
          mesaId: 'm1',
          pase: 1,
          marchaId: 'marcha-3',
          comandaId: abierta.id,
          camarero: '  ',
        ),
      );
      expect(enBlanco.comanda.marchaPorId('marcha-3')!.camarero, 'Móvil b');
      expect(f.sala.comandaDeMesa('m1'), enBlanco.comanda);
    });

    test('los errores de sala viajan como error no reintentable', () async {
      final a = await conectar('a');
      MarcharPasePayload pulsacion(String mesaId, int pase, {String? id}) =>
          MarcharPasePayload(
            mesaId: mesaId,
            pase: pase,
            marchaId: 'm-$mesaId-$pase',
            comandaId: id,
          );

      await expectLater(
        marchar(a, pulsacion('zz', 1)),
        errorNoReintentable(SalaErrorCodes.mesaDesconocida),
      );
      await expectLater(
        marchar(a, pulsacion('m1', 1)),
        errorNoReintentable(SalaErrorCodes.mesaSinComanda),
      );
      final abierta = (await enviar(
        a,
        submit('m1', [linea('l1', 'PAELLA', 1, pase: 2)]),
      )).comanda;
      // Postres existe en la configuración pero no tiene líneas.
      await expectLater(
        marchar(a, pulsacion('m1', 3, id: abierta.id)),
        errorNoReintentable(SalaErrorCodes.paseSinLineas),
      );
      // El pase 7 no existe y no tiene líneas.
      await expectLater(
        marchar(a, pulsacion('m1', 7, id: abierta.id)),
        errorNoReintentable(SalaErrorCodes.paseNoValido),
      );
      // La comanda que ve el comandero ya se cerró (se cobró y se reabrió).
      await expectLater(
        marchar(a, pulsacion('m1', 2, id: 'comanda-cobrada')),
        throwsA(
          isA<RemoteRequestException>()
              .having((e) => e.code, 'code', SalaErrorCodes.mesaSinComanda)
              .having((e) => e.message, 'message', contains('ya se cerró'))
              .having((e) => e.retryable, 'retryable', isFalse),
        ),
      );
      expect(
        f.sala.comandaDeMesa('m1')!.marchas.where((m) => !m.automatica),
        isEmpty,
      );
    });

    test('un payload mal formado da validation y un tipo desconocido sigue '
        'dando unknown_type', () async {
      final a = await conectar('a');
      await enviar(a, submit('m1', [linea('l1', 'PAELLA', 1, pase: 2)]));
      final malos = <String, Map<String, Object?>>{
        'sin marchaId': {'mesaId': 'm1', 'pase': 2},
        'sin mesa': {'pase': 2, 'marchaId': 'x'},
        'pase 0': {'mesaId': 'm1', 'pase': 0, 'marchaId': 'x'},
        'pase de texto': {'mesaId': 'm1', 'pase': '2', 'marchaId': 'x'},
        'marchaId vacío': {'mesaId': 'm1', 'pase': 2, 'marchaId': ''},
        'marchaId de 65': {
          'mesaId': 'm1',
          'pase': 2,
          'marchaId': 'x' * (MarcharPasePayload.maxLongitudMarchaId + 1),
        },
      };
      for (final MapEntry(key: caso, value: payload) in malos.entries) {
        await expectLater(
          a.request(SalaMessageTypes.paseMarchar, payload, reliable: true),
          errorNoReintentable(ErrorCodes.validation),
          reason: caso,
        );
      }
      // Solo la marcha automática del envío: ninguna petición marchó nada.
      expect(f.sala.comandaDeMesa('m1')!.marchas.map((m) => m.automatica), [
        true,
      ]);
      await expectLater(
        a.request('comanda.pase.inventado', {}),
        errorNoReintentable(ErrorCodes.unknownType),
      );
    });
  });
}
