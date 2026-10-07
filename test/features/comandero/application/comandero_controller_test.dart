import 'dart:async';
import 'dart:math';

import 'package:proyecto_comandero/core/errors/app_exception.dart';
import 'package:proyecto_comandero/core/facturascripts/catalog/catalog_models.dart';
import 'package:proyecto_comandero/core/network/discovery/udp_discovery_scanner.dart';
import 'package:proyecto_comandero/core/network/protocol/transport_messages.dart';
import 'package:proyecto_comandero/core/network/tcp/tcp_comandero_client.dart';
import 'package:proyecto_comandero/features/comandero/application/comandero_controller.dart';
import 'package:proyecto_comandero/features/comandero/data/in_memory_comandero_cache_repository.dart';
import 'package:proyecto_comandero/features/comandero/domain/comandero_cache_repository.dart';
import 'package:proyecto_comandero/features/comandero/domain/comandero_config.dart';
import 'package:proyecto_comandero/features/comandero/domain/comandero_exceptions.dart';
import 'package:proyecto_comandero/features/comandero/domain/comandero_state.dart';
import 'package:proyecto_comandero/features/comandero/domain/pedido_en_edicion.dart';
import 'package:proyecto_comandero/features/comandero/domain/traspaso_comandero.dart';
import 'package:proyecto_comandero/features/sala/domain/comanda.dart';
import 'package:proyecto_comandero/features/sala/domain/enrutamiento_comandas.dart';
import 'package:proyecto_comandero/features/sala/domain/linea_comanda.dart';
import 'package:proyecto_comandero/features/sala/protocol/sala_messages.dart';
import 'package:test/test.dart';

import '../fake_sala_host.dart';

void main() {
  late FakeSalaHost host;
  late InMemoryComanderoCacheRepository cache;
  final controllers = <ComanderoController>[];
  var idSeq = 0;

  const config = ComanderoConfig(
    deviceId: 'movil-1',
    deviceName: 'Comandero 1',
    appVersion: '1.0.0',
    destinoPorFamilia: {'BEB': DestinoPreparacion.barra},
  );

  ComanderoController newController({
    ComanderoConfig config = config,
    ComanderoCacheRepository? cacheOverride,
    DiscoveryScanOptions? scanOptions,
    Duration reintentoCatalogo = const Duration(milliseconds: 50),
  }) {
    final controller = ComanderoController(
      config: config,
      cache: cacheOverride ?? cache,
      clientOptions: kClientOptions,
      scanOptions: scanOptions ?? host.scanOptions,
      reintentoCargaSala: const Duration(milliseconds: 50),
      reintentoCatalogo: reintentoCatalogo,
      newId: () => 'linea-${++idSeq}',
      clientFactory: (identity, options, rediscover) => TcpComanderoClient(
        identity: identity,
        options: options,
        rediscover: rediscover,
        random: Random(7),
      ),
    );
    controllers.add(controller);
    return controller;
  }

  Future<Conectado> waitConectado(ComanderoController c) =>
      waitState<Conectado>(c.states, c.state, (_) => true, what: 'Conectado');

  setUp(() async {
    idSeq = 0;
    cache = InMemoryComanderoCacheRepository();
    host = FakeSalaHost(tcpPort: await freeTcpPort());
    await host.start();
  });

  tearDown(() async {
    for (final controller in controllers) {
      await controller.dispose();
    }
    controllers.clear();
    await host.dispose();
  });

  test('descubre el host por UDP, conecta y carga sala y catálogo', () async {
    final controller = newController();
    final estados = <ComanderoState>[];
    final sub = controller.states.listen(estados.add);
    addTearDown(sub.cancel);

    expect(controller.state, isA<SinHost>());
    final hosts = await controller.buscarHosts();
    expect(hosts, hasLength(1));
    expect(hosts.single.hostId, 'host-1');
    expect(hosts.single.tcpPort, host.tcpPort);
    expect(estados.first, isA<Buscando>());
    expect((estados.whereType<Buscando>().last).hosts.single.hostName, 'Barra');
    expect(controller.state, isA<SinHost>());
    expect((controller.state as SinHost).hostsEncontrados, hasLength(1));

    controller.conectarDescubierto(hosts.single);
    expect(controller.state, isA<Conectando>());

    final conectado = await waitConectado(controller);
    expect(conectado.host.hostId, 'host-1');
    expect(conectado.host.hostName, 'Barra');
    expect(conectado.host.endpoint, host.endpoint);
    expect(conectado.sala.mesas.map((m) => m.id), ['m1', 'm2', 'b1']);
    expect(conectado.sala.catalogoVersion, 'v1');
    expect(conectado.catalogo, kCatalogoPrueba);
    expect(conectado.pendientes, 0);
    expect(controller.mesas, hasLength(3));
    expect(controller.comandaDe('m1'), isNull);

    // El catálogo quedó en la caché con su versión.
    expect(cache.catalogo?.version, 'v1');
    expect(cache.catalogo?.catalogo, kCatalogoPrueba);
    expect(host.requests, [
      SalaMessageTypes.salaSnapshotGet,
      SalaMessageTypes.catalogoGet,
    ]);
  });

  test(
    'con catálogo cacheado de la misma versión no vuelve a pedirlo',
    () async {
      cache = InMemoryComanderoCacheRepository(
        inicial: CatalogoCacheado(
          version: 'v1',
          catalogo: kCatalogoPrueba,
          guardadoEn: DateTime.utc(2026, 10, 6),
        ),
      );
      final controller = newController();
      controller.conectar(HostObjetivo(endpoint: host.endpoint));
      final conectado = await waitConectado(controller);
      expect(conectado.catalogo, kCatalogoPrueba);
      expect(host.requests, [SalaMessageTypes.salaSnapshotGet]);
      expect(cache.guardados, 0);
    },
  );

  test('conectarManual acepta ip:puerto y rechaza texto inválido', () async {
    final controller = newController();
    expect(
      () => controller.conectarManual('host:abc'),
      throwsA(isA<ValidationException>()),
    );
    expect(
      () => controller.conectarManual(''),
      throwsA(isA<ValidationException>()),
    );
    controller.conectarManual('127.0.0.1:${host.tcpPort}');
    final conectado = await waitConectado(controller);
    expect(conectado.host.endpoint, host.endpoint);
    // El welcome rellena la identidad del host manual.
    expect(conectado.host.hostName, 'Barra');
  });

  test('carrito: añadir, cambiar, quitar e importes', () async {
    final controller = newController();
    final cambios = <PedidoEnEdicion>[];
    final sub = controller.pedidosCambiados.listen(cambios.add);
    addTearDown(sub.cancel);
    final cana = kCatalogoPrueba.porReferencia('CANA')!;
    final paella = kCatalogoPrueba.porReferencia('PAELLA')!;

    expect(controller.pedido('m1').estaVacio, isTrue);
    controller.anadir('m1', cana, cantidad: 2);
    controller.anadir('m1', cana);
    controller.anadir('m1', paella, nota: 'sin marisco');
    var pedido = controller.pedido('m1');
    expect(pedido.lineas.map((l) => l.id), ['linea-1', 'linea-2']);
    expect(pedido.lineas.first.cantidad, 3);
    expect(pedido.importeCents, 3 * 200 + 1200);

    pedido = controller.cambiarCantidad('m1', 'linea-1', 1);
    expect(pedido.importeCents, 200 + 1200);
    pedido = controller.quitar('m1', 'linea-2');
    expect(pedido.importeCents, 200);
    expect(controller.pedido('m2').estaVacio, isTrue);
    await Future<void>.delayed(Duration.zero); // entrega del stream asíncrono
    expect(cambios, hasLength(5));
    expect(cambios.every((p) => p.mesaId == 'm1'), isTrue);

    expect(
      () => controller.anadirReferencia('m1', 'CAFE'),
      throwsA(isA<ValidationException>()),
      reason: 'sin catálogo cargado no se puede añadir por referencia',
    );
    expect(
      () => controller.cambiarCantidad('m1', 'linea-1', 0),
      throwsA(isA<ValidationException>()),
    );
  });

  test('enviar: líneas con precios congelados y ack aplicado', () async {
    final controller = newController();
    controller.conectar(HostObjetivo(endpoint: host.endpoint));
    await waitConectado(controller);

    controller.anadirReferencia('m1', 'CANA', cantidad: 2);
    controller.anadirReferencia('m1', 'PAELLA', nota: 'poco hecha');
    final estados = <ComanderoState>[];
    final sub = controller.states.listen(estados.add);
    addTearDown(sub.cancel);

    final result = await controller.enviar(
      'm1',
      camarero: 'Ana',
      comensales: 2,
    );
    expect(result.lineasNuevas, 2);
    expect(result.lineasDuplicadas, 0);
    expect(result.comanda.mesaId, 'm1');
    expect(result.comanda.camarero, 'Ana');
    expect(result.comanda.comensales, 2);

    final lineas = result.comanda.lineas;
    expect(lineas.map((l) => l.id), ['linea-1', 'linea-2']);
    final cana = lineas[0];
    expect(cana.referencia, 'CANA');
    expect(cana.cantidad, 2);
    expect(cana.pvpUnitarioCents, 200);
    expect(cana.pvpUnitarioNeto, 1.81818);
    expect(cana.ivaBp, 1000);
    expect(cana.codimpuesto, 'IVA10');
    expect(cana.destino, DestinoPreparacion.barra, reason: 'familia BEB');
    expect(cana.camarero, 'Ana');
    final paella = lineas[1];
    expect(paella.destino, DestinoPreparacion.cocina);
    expect(paella.nota, 'poco hecha');
    expect(paella.pvpUnitarioCents, 1200);
    expect(result.comanda.importeCents, 400 + 1200);

    // El carrito se vacía y la comanda local refleja el ack.
    expect(controller.pedido('m1').estaVacio, isTrue);
    expect(controller.comandaDe('m1'), result.comanda);
    expect(controller.pendientes, 0);
    // Los estados llegan por un stream asíncrono: se espera al definitivo.
    final ultimo = await waitState<Conectado>(
      controller.states,
      controller.state,
      (s) => s.pendientes == 0 && s.sala.comandaDeMesa('m1') == result.comanda,
      what: 'Conectado con la comanda confirmada',
    );
    expect(ultimo.sala.comandaDeMesa('m1'), result.comanda);
    expect(
      estados.whereType<Conectado>().any((s) => s.pendientes == 1),
      isTrue,
    );

    // Un segundo envío sin líneas nuevas no tiene sentido.
    await expectLater(
      controller.enviar('m1'),
      throwsA(isA<ValidationException>()),
    );
  });

  test('el enrutamiento que publica el host manda sobre el de la '
      'configuración local', () async {
    // Local: bebidas a barra. Host: platos a barra y bebidas a cocina.
    const delHost = EnrutamientoComandas(
      porFamilia: {
        'PLA': DestinoPreparacion.barra,
        'BEB': DestinoPreparacion.cocina,
      },
    );
    host.enrutamiento = delHost;
    final controller = newController();
    expect(controller.enrutamiento, config.enrutamiento, reason: 'sin sala');
    expect(controller.destinoDe('BEB'), DestinoPreparacion.barra);

    controller.conectar(HostObjetivo(endpoint: host.endpoint));
    final conectado = await waitConectado(controller);
    expect(conectado.sala.enrutamiento, delHost);
    expect(controller.enrutamiento, delHost);
    expect(controller.destinoDe('BEB'), DestinoPreparacion.cocina);
    expect(controller.destinoDe('PLA'), DestinoPreparacion.barra);
    expect(controller.destinoDe(null), DestinoPreparacion.cocina);

    controller.anadirReferencia('m1', 'CANA');
    controller.anadirReferencia('m1', 'PAELLA');
    final result = await controller.enviar('m1');
    final destinos = {
      for (final linea in result.comanda.lineas)
        linea.referencia: linea.destino,
    };
    expect(destinos, {
      'CANA': DestinoPreparacion.cocina,
      'PAELLA': DestinoPreparacion.barra,
    });
    // Actualizar la comanda local tras el ack conserva el enrutamiento.
    expect(controller.sala!.enrutamiento, delHost);
  });

  test('con un host que no publica enrutamiento se usa el local', () async {
    final controller = newController();
    controller.conectar(HostObjetivo(endpoint: host.endpoint));
    final conectado = await waitConectado(controller);
    expect(conectado.sala.enrutamiento, isNull);
    expect(controller.enrutamiento, config.enrutamiento);
    expect(controller.destinoDe('BEB'), DestinoPreparacion.barra);
  });

  test(
    'enviar sin conexión queda pendiente y se entrega al reconectar',
    () async {
      final controller = newController();
      controller.conectar(HostObjetivo(endpoint: host.endpoint));
      await waitConectado(controller);
      controller.anadirReferencia('m1', 'CANA');

      await host.server.stop();
      await waitState<Reconectando>(
        controller.states,
        controller.state,
        (_) => true,
        what: 'Reconectando',
      );

      final envio = controller.enviar('m1');
      // Mientras no hay host: pendiente en la cola fiable y carrito conservado.
      expect(controller.pendientes, 1);
      final pedido = controller.pedido('m1');
      expect(pedido.enEnvio.single.id, 'linea-1');
      expect(pedido.pendientesDeEnviar, isEmpty);
      expect(
        () => controller.quitar('m1', 'linea-1'),
        throwsA(isA<ValidationException>()),
      );
      await waitState<Reconectando>(
        controller.states,
        controller.state,
        (s) => s.pendientes == 1,
        what: 'Reconectando con 1 pendiente',
      );
      // Un segundo "enviar" no duplica la línea en vuelo.
      await expectLater(
        controller.enviar('m1'),
        throwsA(isA<ValidationException>()),
      );

      await host.server.start();
      final result = await envio.timeout(kWait);
      expect(result.lineasNuevas, 1);
      expect(result.comanda.lineas.single.id, 'linea-1');
      expect(controller.pedido('m1').estaVacio, isTrue);
      expect(controller.comandaDe('m1')!.lineas.single.referencia, 'CANA');
      final conectado = await waitState<Conectado>(
        controller.states,
        controller.state,
        (s) => s.pendientes == 0 && s.sala.comandaDeMesa('m1') != null,
        what: 'Conectado con la comanda y sin pendientes',
      );
      expect(conectado.host.endpoint, host.endpoint);
      expect(host.comandas['m1']!.lineas, hasLength(1));
    },
  );

  test('desconectar devuelve al carrito las líneas en vuelo', () async {
    final controller = newController();
    controller.conectar(HostObjetivo(endpoint: host.endpoint));
    await waitConectado(controller);
    controller.anadirReferencia('m2', 'CAFE');
    await host.server.stop();
    await waitState<Reconectando>(
      controller.states,
      controller.state,
      (_) => true,
    );
    final envio = controller.enviar('m2');
    expect(controller.pendientes, 1);

    await controller.desconectar();
    await expectLater(envio, throwsA(isA<NetworkException>()));
    expect(controller.state, isA<SinHost>());
    expect(controller.pendientes, 0);
    expect(controller.pedido('m2').pendientesDeEnviar.single.id, 'linea-1');
    expect(controller.mesas, isEmpty);
  });

  test('sala.changed actualiza la comanda de la mesa (y la libera)', () async {
    final controller = newController();
    controller.conectar(HostObjetivo(endpoint: host.endpoint));
    await waitConectado(controller);

    final comanda = Comanda(
      id: 'c-ext',
      mesaId: 'm2',
      abiertaEn: DateTime.utc(2026, 10, 7, 12),
      lineas: [
        LineaComanda(
          id: 'x1',
          referencia: 'CAFE',
          descripcion: 'Café',
          cantidad: 1,
          pvpUnitarioCents: 121,
          pvpUnitarioNeto: 1,
          ivaBp: 2100,
          codimpuesto: 'IVA21',
          creadaEn: DateTime.utc(2026, 10, 7, 12),
        ),
      ],
      cuentaSolicitada: true,
    );
    expect(host.emitirSalaChanged('m2', comanda), 1);
    final conOcupada = await waitState<Conectado>(
      controller.states,
      controller.state,
      (s) => s.sala.comandaDeMesa('m2') != null,
      what: 'la mesa m2 ocupada',
    );
    expect(conOcupada.sala.comandaDeMesa('m2'), comanda);
    expect(controller.comandaDe('m2')!.cuentaSolicitada, isTrue);

    expect(host.emitirSalaChanged('m2', null), 1);
    await waitState<Conectado>(
      controller.states,
      controller.state,
      (s) => s.sala.comandaDeMesa('m2') == null,
      what: 'la mesa m2 libre',
    );
    expect(controller.comandaDe('m2'), isNull);
  });

  test('catalogo.changed recarga el catálogo y lo cachea', () async {
    final controller = newController();
    controller.conectar(HostObjetivo(endpoint: host.endpoint));
    await waitConectado(controller);

    final nuevo = CatalogSnapshot(
      familias: kCatalogoPrueba.familias,
      impuestos: kCatalogoPrueba.impuestos,
      articulos: kCatalogoPrueba.articulos.take(2).toList(),
      avisos: const ['catálogo recortado'],
      obtenidoEn: DateTime.utc(2026, 10, 7, 10),
    );
    expect(host.cambiarCatalogo(nuevo, 'v2'), 1);
    final conectado = await waitState<Conectado>(
      controller.states,
      controller.state,
      (s) => s.catalogo == nuevo,
      what: 'el catálogo v2',
    );
    expect(conectado.catalogo!.articulos, hasLength(2));
    expect(cache.catalogo?.version, 'v2');
    expect(controller.catalogo, nuevo);
  });

  test(
    'anularLinea y pedirCuenta actualizan la comanda; errores tipados',
    () async {
      final controller = newController();
      controller.conectar(HostObjetivo(endpoint: host.endpoint));
      await waitConectado(controller);
      controller.anadirReferencia('m1', 'CANA', cantidad: 2);
      controller.anadirReferencia('m1', 'CAFE');
      final enviado = await controller.enviar('m1');
      expect(enviado.comanda.importeCents, 400 + 121);

      final anulada = await controller.anularLinea(
        'm1',
        'linea-1',
        motivo: 'error del camarero',
      );
      expect(anulada.lineaPorId('linea-1')!.anulada, isTrue);
      expect(
        anulada.lineaPorId('linea-1')!.motivoAnulacion,
        'error del camarero',
      );
      expect(anulada.importeCents, 121);
      expect(controller.comandaDe('m1'), anulada);

      final conCuenta = await controller.pedirCuenta('m1');
      expect(conCuenta.cuentaSolicitada, isTrue);
      expect(controller.comandaDe('m1')!.cuentaSolicitada, isTrue);
      final sinCuenta = await controller.pedirCuenta('m1', solicitada: false);
      expect(sinCuenta.cuentaSolicitada, isFalse);

      // Errores del host → excepciones tipadas; el estado sigue Conectado.
      await expectLater(
        controller.anularLinea('m1', 'no-existe'),
        throwsA(
          isA<ComanderoSalaException>()
              .having((e) => e.lineaDesconocida, 'lineaDesconocida', isTrue)
              .having((e) => e.mesaId, 'mesaId', 'm1')
              .having((e) => e.retryable, 'retryable', isFalse),
        ),
      );
      await expectLater(
        controller.pedirCuenta('m2'),
        throwsA(
          isA<ComanderoSalaException>().having(
            (e) => e.mesaSinComanda,
            'mesaSinComanda',
            isTrue,
          ),
        ),
      );
      controller.anadirReferencia('zz', 'CANA');
      await expectLater(
        controller.enviar('zz'),
        throwsA(
          isA<ComanderoSalaException>().having(
            (e) => e.mesaDesconocida,
            'mesaDesconocida',
            isTrue,
          ),
        ),
      );
      // La línea rechazada vuelve a ser editable.
      expect(controller.pedido('zz').pendientesDeEnviar, hasLength(1));
      expect(controller.state, isA<Conectado>());
      expect(controller.pendientes, 0);
    },
  );

  test(
    'sin host objetivo, pedirCuenta y enviar fallan con SinConexionException',
    () async {
      final controller = newController();
      await expectLater(
        controller.pedirCuenta('m1'),
        throwsA(isA<SinConexionException>()),
      );
      controller.anadir('m1', kCatalogoPrueba.porReferencia('CANA')!);
      await expectLater(
        controller.enviar('m1'),
        throwsA(isA<SinConexionException>()),
      );
      // La línea sigue editable y nada quedó en cola.
      expect(controller.pedido('m1').pendientesDeEnviar, hasLength(1));
      expect(controller.pendientes, 0);
    },
  );

  test(
    'rechazo por código de emparejamiento → Rechazado; con el código conecta',
    () async {
      await host.dispose();
      host = FakeSalaHost(tcpPort: await freeTcpPort(), pairingCode: '1234');
      await host.start();

      final controller = newController();
      final hosts = await controller.buscarHosts();
      expect(hosts.single.requiresPairing, isTrue);
      // iniciar() no conecta solo a un host con emparejamiento sin código.
      expect(await controller.iniciar(), isFalse);

      controller.conectarDescubierto(hosts.single);
      final rechazado = await waitState<Rechazado>(
        controller.states,
        controller.state,
        (_) => true,
        what: 'Rechazado',
      );
      expect(rechazado.codigo, RejectCodes.unauthorized);
      expect(rechazado.host?.hostId, 'host-1');

      controller.conectarDescubierto(hosts.single, pairingCode: '1234');
      final conectado = await waitConectado(controller);
      expect(conectado.sala.mesas, hasLength(3));
      expect(controller.config.pairingCode, '1234');
    },
  );

  test('iniciar con host manual configurado conecta directamente', () async {
    final controller = newController(
      config: config.copyWith(hostManual: () => '127.0.0.1:${host.tcpPort}'),
    );
    expect(await controller.iniciar(), isTrue);
    await waitConectado(controller);
  });

  test('iniciar sin host manual descubre y conecta si hay uno solo', () async {
    final controller = newController();
    expect(await controller.iniciar(), isTrue);
    final conectado = await waitConectado(controller);
    expect(conectado.host.hostId, 'host-1');
  });

  /// Espera (sondeando) a que se cumpla [condicion].
  Future<void> esperarQue(bool Function() condicion, String que) async {
    final limite = DateTime.now().add(kWait);
    while (!condicion()) {
      if (DateTime.now().isAfter(limite)) {
        throw TimeoutException('No se cumplió: $que');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  group('h3: líneas que pudieron llegar al host', () {
    /// Envía una caña cuyo `ack` se pierde: el host la registra y el
    /// comandero se desconecta antes de recibir la respuesta.
    Future<ComanderoController> enviarSinAck() async {
      final controller = newController();
      controller.conectar(HostObjetivo(endpoint: host.endpoint));
      await waitConectado(controller);
      controller.anadirReferencia('m1', 'CANA');
      final retener = host.retenerSubmit = Completer<void>();
      final envio = controller.enviar('m1');
      await esperarQue(
        () => host.comandas['m1']?.lineaPorId('linea-1') != null,
        'el host registra la línea',
      );
      final fallo = expectLater(envio, throwsA(isA<NetworkException>()));
      await controller.desconectar();
      await fallo;
      host.retenerSubmit = null;
      retener.complete();
      final linea = controller.pedido('m1').lineaPorId('linea-1')!;
      expect(linea.posiblementeTransmitida, isTrue);
      expect(linea.enviando, isFalse);
      return controller;
    }

    test(
      'h3: al reconectar se quitan del carrito las que el host ya tiene',
      () async {
        final controller = await enviarSinAck();
        controller.conectar(HostObjetivo(endpoint: host.endpoint));
        await waitConectado(controller);
        expect(controller.pedido('m1').estaVacio, isTrue);
        expect(host.comandas['m1']!.lineas, hasLength(1));
      },
    );

    test(
      'h3: editar una posiblemente transmitida genera un id nuevo y avisa',
      () async {
        final controller = await enviarSinAck();
        final avisos = <AvisoComandero>[];
        final sub = controller.avisos.listen(avisos.add);
        addTearDown(sub.cancel);

        final editado = controller.cambiarCantidad('m1', 'linea-1', 3);
        final nueva = editado.lineas.single;
        expect(nueva.id, isNot('linea-1'));
        expect(nueva.reemplazaA, 'linea-1');
        expect(nueva.cantidad, 3);
        expect(nueva.posiblementeTransmitida, isFalse);

        controller.conectar(HostObjetivo(endpoint: host.endpoint));
        await waitConectado(controller);
        // La edición sigue en el carrito y se avisa del posible duplicado.
        expect(controller.pedido('m1').lineas.single.id, nueva.id);
        await esperarQue(() => avisos.isNotEmpty, 'aviso al reconectar');
        expect(avisos.first.mesaId, 'm1');
        expect(avisos.first.lineaIds, ['linea-1']);

        final result = await controller.enviar('m1');
        expect(result.lineasNuevas, 1, reason: 'la edición no se descarta');
        expect(host.comandas['m1']!.lineaPorId(nueva.id)!.cantidad, 3);
        expect(controller.pedido('m1').estaVacio, isTrue);
        await esperarQue(() => avisos.length >= 2, 'aviso tras el envío');
      },
    );

    test('h3: lineasDuplicadas con otra cantidad se avisa', () async {
      final controller = newController();
      controller.conectar(HostObjetivo(endpoint: host.endpoint));
      await waitConectado(controller);
      final avisos = <AvisoComandero>[];
      final sub = controller.avisos.listen(avisos.add);
      addTearDown(sub.cancel);

      controller.anadirReferencia('m1', 'CANA', cantidad: 2);
      // El host ya conoce esa línea (mismo id) con otra cantidad.
      host.comandas['m1'] = Comanda(
        id: 'c-previa',
        mesaId: 'm1',
        abiertaEn: DateTime.utc(2026, 10, 7, 12),
        lineas: [
          LineaComanda(
            id: 'linea-1',
            referencia: 'CANA',
            descripcion: 'Caña',
            cantidad: 1,
            pvpUnitarioCents: 200,
            pvpUnitarioNeto: 1.81818,
            ivaBp: 1000,
            codimpuesto: 'IVA10',
            creadaEn: DateTime.utc(2026, 10, 7, 12),
          ),
        ],
      );
      final result = await controller.enviar('m1');
      expect(result.lineasDuplicadas, 1);
      expect(result.lineasNuevas, 0);
      expect(controller.pedido('m1').estaVacio, isTrue);
      await esperarQue(() => avisos.isNotEmpty, 'aviso de duplicadas');
      expect(avisos.single.lineaIds, ['linea-1']);
      expect(avisos.single.mensaje, contains('otra cantidad'));
    });
  });

  test('h4: si falla la carga del catálogo se reintenta con backoff', () async {
    final unArticulo = CatalogSnapshot(
      familias: kCatalogoPrueba.familias,
      impuestos: kCatalogoPrueba.impuestos,
      articulos: kCatalogoPrueba.articulos.take(1).toList(),
      avisos: const [],
      obtenidoEn: DateTime.utc(2026, 10, 6),
    );
    cache = InMemoryComanderoCacheRepository(
      inicial: CatalogoCacheado(
        version: 'v1',
        catalogo: unArticulo,
        guardadoEn: DateTime.utc(2026, 10, 6),
      ),
    );
    host.catalogoVersion = 'v2';
    host.fallosCatalogo = 2;
    final controller = newController();
    controller.conectar(HostObjetivo(endpoint: host.endpoint));

    final desfasado = await waitConectado(controller);
    expect(desfasado.catalogo, unArticulo);
    expect(desfasado.catalogoDesactualizado, isTrue);

    final alDia = await waitState<Conectado>(
      controller.states,
      controller.state,
      (s) => !s.catalogoDesactualizado,
      what: 'Conectado con el catálogo v2',
    );
    expect(alDia.catalogo, kCatalogoPrueba);
    expect(controller.catalogoDesactualizado, isFalse);
    expect(cache.catalogo?.version, 'v2');
    expect(
      host.requests.where((r) => r == SalaMessageTypes.catalogoGet),
      hasLength(3),
    );
  });

  test(
    'h4: el reintento del catálogo se cancela al perder la sesión',
    () async {
      host.fallosCatalogo = 100;
      final controller = newController(
        reintentoCatalogo: const Duration(milliseconds: 300),
      );
      controller.conectar(HostObjetivo(endpoint: host.endpoint));
      final conectado = await waitConectado(controller);
      expect(conectado.catalogo, isNull);
      expect(conectado.catalogoDesactualizado, isTrue);
      await controller.desconectar();
      await Future<void>.delayed(const Duration(milliseconds: 700));
      expect(
        host.requests.where((r) => r == SalaMessageTypes.catalogoGet),
        hasLength(1),
      );
    },
  );

  test(
    'h5: conectar al mismo host ya conectado no se queda en Conectando',
    () async {
      final controller = newController();
      controller.conectar(HostObjetivo(endpoint: host.endpoint));
      await waitConectado(controller);
      controller.conectar(HostObjetivo(endpoint: host.endpoint));
      expect(controller.state, isA<Conectado>());
      controller.conectarManual('127.0.0.1:${host.tcpPort}');
      expect(controller.state, isA<Conectado>());
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(controller.state, isA<Conectado>());
    },
  );

  test('h6: un ack con payload inesperado no bloquea las líneas', () async {
    final controller = newController();
    controller.conectar(HostObjetivo(endpoint: host.endpoint));
    await waitConectado(controller);
    controller.anadirReferencia('m1', 'CANA');
    host.respuestaSubmit = const {};

    await expectLater(
      controller.enviar('m1'),
      throwsA(isA<ProtocolException>()),
    );
    expect(controller.pedido('m1').estaVacio, isTrue);
    expect(controller.pendientes, 0);
    // Se refresca la sala para mostrar la comanda real del host.
    await waitState<Conectado>(
      controller.states,
      controller.state,
      (s) => s.sala.comandaDeMesa('m1') != null,
      what: 'la comanda real tras refrescar',
    );
    expect(controller.comandaDe('m1')!.lineas.single.id, 'linea-1');
  });

  group('u1: actualizarConexion', () {
    test(
      'con un código nuevo reconecta si el host lo había rechazado',
      () async {
        await host.dispose();
        host = FakeSalaHost(tcpPort: await freeTcpPort(), pairingCode: '1234');
        await host.start();
        final controller = newController(
          config: config.copyWith(pairingCode: () => '1111'),
        );
        controller.conectar(HostObjetivo(endpoint: host.endpoint));
        await waitState<Rechazado>(
          controller.states,
          controller.state,
          (_) => true,
          what: 'Rechazado',
        );

        controller.actualizarConexion(pairingCode: '1234', hostManual: null);
        await waitConectado(controller);
        expect(controller.config.pairingCode, '1234');
      },
    );

    test('con un host manual nuevo conecta con él', () async {
      final controller = newController(
        config: config.copyWith(hostManual: () => '10.255.255.1:4040'),
      );
      controller.actualizarConexion(
        pairingCode: null,
        hostManual: '127.0.0.1:${host.tcpPort}',
      );
      final conectado = await waitConectado(controller);
      expect(conectado.host.endpoint, host.endpoint);
      expect(controller.config.hostManual, '127.0.0.1:${host.tcpPort}');
    });

    test('sin cambios, o con sesión abierta, no reconecta', () async {
      final controller = newController(
        config: config.copyWith(hostManual: () => '127.0.0.1:${host.tcpPort}'),
      );
      expect(await controller.iniciar(), isTrue);
      await waitConectado(controller);
      final estados = <ComanderoState>[];
      final sub = controller.states.listen(estados.add);
      addTearDown(sub.cancel);

      controller.actualizarConexion(
        pairingCode: '  ',
        hostManual: '127.0.0.1:${host.tcpPort}',
      );
      // Código nuevo con sesión abierta: se guarda para la próxima conexión.
      controller.actualizarConexion(
        pairingCode: '9999',
        hostManual: '127.0.0.1:${host.tcpPort}',
      );
      // Borrar el host manual no corta la sesión.
      controller.actualizarConexion(pairingCode: '9999', hostManual: '');
      // Un host manual inválido se ignora.
      controller.actualizarConexion(pairingCode: '9999', hostManual: 'x:abc');
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(estados, isEmpty);
      expect(controller.state, isA<Conectado>());
      expect(controller.config.pairingCode, '9999');
      expect(controller.config.hostManual, 'x:abc');
    });
  });

  test('u3: editarLinea cambia cantidad y nota de una línea devuelta tras '
      'un corte', () async {
    final controller = newController();
    controller.conectar(HostObjetivo(endpoint: host.endpoint));
    await waitConectado(controller);
    controller.anadirReferencia('m2', 'CAFE');
    await host.server.stop();
    await waitState<Reconectando>(
      controller.states,
      controller.state,
      (_) => true,
    );
    final envio = controller.enviar('m2');
    await controller.desconectar();
    await expectLater(envio, throwsA(isA<NetworkException>()));
    expect(controller.pedido('m2').lineas.single.posiblementeTransmitida, true);

    final pedido = controller.editarLinea(
      'm2',
      'linea-1',
      cantidad: 2,
      nota: 'Sin gluten',
    );
    final linea = pedido.lineas.single;
    expect(linea.id, 'linea-2');
    expect(linea.reemplazaA, 'linea-1');
    expect(linea.cantidad, 2);
    expect(linea.nota, 'Sin gluten');
  });

  test('u2: cerrarParaTraspaso devuelve los envíos en cola al carrito y '
      'otro controlador los importa', () async {
    final controller = newController();
    controller.conectar(HostObjetivo(endpoint: host.endpoint));
    await waitConectado(controller);
    controller
      ..anadirReferencia('m1', 'CANA')
      ..anadirReferencia('m2', 'CAFE');
    await host.server.stop();
    await waitState<Reconectando>(
      controller.states,
      controller.state,
      (_) => true,
    );
    final envio = controller.enviar('m2');
    final fallo = expectLater(envio, throwsA(isA<NetworkException>()));

    final traspaso = await controller.cerrarParaTraspaso();
    await fallo;
    expect(
      traspaso.pedidos.map((p) => p.mesaId),
      unorderedEquals(['m1', 'm2']),
    );
    expect(traspaso.lineas, 2);
    expect(traspaso.lineasDevueltas, 1);
    expect(traspaso.peticionesPerdidas, 0);
    final devuelta = traspaso.pedidos
        .singleWhere((p) => p.mesaId == 'm2')
        .lineas
        .single;
    expect(devuelta.enviando, isFalse);
    expect(devuelta.posiblementeTransmitida, isTrue);
    expect(() => controller.pedido('m1'), returnsNormally);
    expect(() => controller.anadirReferencia('m1', 'CANA'), throwsStateError);
    expect(await controller.cerrarParaTraspaso(), const TraspasoComandero());

    final nuevo = newController();
    expect(nuevo.importarPedidos(traspaso.pedidos), 2);
    expect(nuevo.pedido('m1').lineas.single.articulo.referencia, 'CANA');
    expect(nuevo.pedido('m2').lineas.single.posiblementeTransmitida, isTrue);
    // Importar de nuevo no duplica.
    expect(nuevo.importarPedidos(traspaso.pedidos), 0);
    expect(nuevo.exportarPedidos(), hasLength(2));
  });

  test('dispose limpio: cierra streams y no emite más', () async {
    final controller = newController();
    controller.conectar(HostObjetivo(endpoint: host.endpoint));
    await waitConectado(controller);
    final done = controller.states.toList();
    await controller.dispose();
    expect(await done.timeout(kWait), isEmpty);
    expect(() => controller.pedido('m1'), returnsNormally);
    expect(() => controller.anadirReferencia('m1', 'CANA'), throwsStateError);
    await controller.dispose(); // idempotente
    controllers.remove(controller);
    // El host ve caer la sesión del comandero.
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(host.server.sessions, isEmpty);
  });
}
