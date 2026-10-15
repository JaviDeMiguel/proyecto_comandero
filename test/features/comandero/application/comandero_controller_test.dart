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
import 'package:proyecto_comandero/features/comandero/presentation/comandero_gateway.dart';
import 'package:proyecto_comandero/features/sala/domain/comanda.dart';
import 'package:proyecto_comandero/features/sala/domain/enrutamiento_comandas.dart';
import 'package:proyecto_comandero/features/sala/domain/linea_comanda.dart';
import 'package:proyecto_comandero/features/sala/domain/pases.dart';
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

  test('buscarHosts emite Buscando en la misma llamada', () async {
    final controller = newController();
    final busqueda = controller.buscarHosts();
    expect(
      controller.state,
      isA<Buscando>(),
      reason: 'sin destinos que calcular no hay ninguna espera antes',
    );
    expect(await busqueda, hasLength(1));
    expect(controller.state, isA<SinHost>());
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

  test('los destinos del ERP del catálogo se aplican con el enrutamiento '
      'local y no cambian el efectivo que publica el host', () async {
    // ERP: platos a barra y bebidas a cocina.
    final conErp = CatalogSnapshot(
      familias: const [
        FamiliaCatalogo(
          codfamilia: 'BEB',
          descripcion: 'Bebidas',
          destino: 'cocina',
        ),
        FamiliaCatalogo(
          codfamilia: 'PLA',
          descripcion: 'Platos',
          destino: 'barra',
        ),
      ],
      impuestos: kCatalogoPrueba.impuestos,
      articulos: kCatalogoPrueba.articulos,
      avisos: const [],
      obtenidoEn: kCatalogoPrueba.obtenidoEn,
    );
    host.catalogo = conErp;
    final controller = newController();
    controller.conectar(HostObjetivo(endpoint: host.endpoint));
    final conectado = await waitConectado(controller);
    expect(conectado.catalogo, conErp);
    expect(conectado.sala.enrutamiento, isNull, reason: 'host antiguo');
    // Local: bebidas a barra (regla del TPV, manda sobre el ERP).
    expect(controller.destinoDe('BEB'), DestinoPreparacion.barra);
    expect(controller.destinoDe('PLA'), DestinoPreparacion.barra);

    // Host nuevo: publica su enrutamiento efectivo (reglas + ERP).
    const reglasHost = EnrutamientoComandas(
      porFamilia: {'PLA': DestinoPreparacion.cocina},
    );
    final efectivo = reglasHost.conDestinosErp(conErp.familias);
    expect(efectivo.porFamilia, {
      'BEB': DestinoPreparacion.cocina,
      'PLA': DestinoPreparacion.cocina,
    });
    host.enrutamiento = efectivo;
    final otro = newController();
    otro.conectar(HostObjetivo(endpoint: host.endpoint));
    await waitConectado(otro);
    expect(otro.enrutamiento, efectivo);
    expect(otro.destinoDe('BEB'), DestinoPreparacion.cocina);
    expect(otro.destinoDe('PLA'), DestinoPreparacion.cocina);
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

  group('r1: enrutamiento del snapshot al día', () {
    // CER (Cervezas) cuelga de BEB; la caña es de CER. El destino de CER
    // viene del ERP (`familias.tpv_destino`); el TPV no tiene reglas.
    CatalogSnapshot catalogoConCer(String destinoCer) => CatalogSnapshot(
      familias: [
        const FamiliaCatalogo(codfamilia: 'BEB', descripcion: 'Bebidas'),
        FamiliaCatalogo(
          codfamilia: 'CER',
          descripcion: 'Cervezas',
          madre: 'BEB',
          destino: destinoCer,
        ),
        const FamiliaCatalogo(codfamilia: 'PLA', descripcion: 'Platos'),
      ],
      impuestos: kCatalogoPrueba.impuestos,
      articulos: [
        for (final a in kCatalogoPrueba.articulos)
          a.referencia == 'CANA'
              ? ArticuloCatalogo(
                  referencia: a.referencia,
                  idproducto: a.idproducto,
                  idvariante: a.idvariante,
                  descripcion: a.descripcion,
                  codfamilia: 'CER',
                  codimpuesto: a.codimpuesto,
                  ivaBp: a.ivaBp,
                  precioNeto: a.precioNeto,
                  pvpCents: a.pvpCents,
                  nostock: a.nostock,
                )
              : a,
      ],
      avisos: const [],
      obtenidoEn: kCatalogoPrueba.obtenidoEn,
    );

    /// Lo que calcula el host real: reglas del TPV + ERP de SU catálogo.
    DestinoPreparacion destinoHost(
      EnrutamientoComandas reglas,
      CatalogSnapshot catalogo,
      String codfamilia,
    ) => reglas.destinoDe(
      codfamilia,
      madreDe: EnrutamientoComandas.jerarquia(catalogo.familias),
      erp: EnrutamientoComandas.destinosErp(catalogo.familias),
    );

    test('tras catalogo.changed con otro tpv_destino, el comandero pide el '
        'snapshot y calcula el mismo destino que el host', () async {
      const reglasTpv = EnrutamientoComandas();
      final v1 = catalogoConCer('barra');
      final v2 = catalogoConCer('cocina');
      host.catalogo = v1;
      host.enrutamiento = reglasTpv.conDestinosErp(v1.familias);
      expect(host.enrutamiento!.porFamilia, {'CER': DestinoPreparacion.barra});

      final controller = newController();
      controller.conectar(HostObjetivo(endpoint: host.endpoint));
      await waitConectado(controller);
      expect(controller.destinoDe('CER'), DestinoPreparacion.barra);
      host.requests.clear();

      // El host refresca el catálogo (CER pasa a cocina) y publica el
      // enrutamiento efectivo de la versión nueva.
      host.enrutamiento = reglasTpv.conDestinosErp(v2.familias);
      expect(host.cambiarCatalogo(v2, 'v2'), 1);
      final conectado = await waitState<Conectado>(
        controller.states,
        controller.state,
        (s) => s.catalogo == v2 && s.sala.catalogoVersion == 'v2',
        what: 'catálogo v2 y snapshot de la v2',
      );
      expect(host.requests, [
        SalaMessageTypes.catalogoGet,
        SalaMessageTypes.salaSnapshotGet,
      ]);
      expect(conectado.sala.enrutamiento, host.enrutamiento);
      expect(destinoHost(reglasTpv, v2, 'CER'), DestinoPreparacion.cocina);
      expect(
        controller.destinoDe('CER'),
        destinoHost(reglasTpv, v2, 'CER'),
        reason: 'la regla aplanada CER→barra de la v1 ya no tapa al ERP',
      );

      // Lo que el comandero envía (el host simulado no lo recalcula).
      controller.anadirReferencia('m1', 'CANA');
      final result = await controller.enviar('m1');
      expect(result.comanda.lineas.single.destino, DestinoPreparacion.cocina);
    });

    test('recargar el catálogo de la misma versión que el snapshot no '
        'vuelve a pedir la sala', () async {
      final controller = newController(
        reintentoCatalogo: const Duration(milliseconds: 20),
      );
      host.fallosCatalogo = 1; // el primer catalogo.get falla y se reintenta
      controller.conectar(HostObjetivo(endpoint: host.endpoint));
      await waitState<Conectado>(
        controller.states,
        controller.state,
        (s) => s.catalogo != null && !s.catalogoDesactualizado,
        what: 'catálogo cargado tras el reintento',
      );
      // Margen para que una petición de sala de más llegase al host.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(host.requests, [
        SalaMessageTypes.salaSnapshotGet,
        SalaMessageTypes.catalogoGet,
        SalaMessageTypes.catalogoGet,
      ], reason: 'el snapshot ya era de la versión cargada');
    });

    test('enrutamiento.changed vuelve a pedir el snapshot con las reglas '
        'nuevas del TPV', () async {
      final controller = newController();
      controller.conectar(HostObjetivo(endpoint: host.endpoint));
      await waitConectado(controller);
      expect(controller.destinoDe('PLA'), DestinoPreparacion.cocina);

      const nuevas = EnrutamientoComandas(
        porFamilia: {'PLA': DestinoPreparacion.barra},
      );
      expect(host.cambiarEnrutamiento(nuevas), 1);
      final conectado = await waitState<Conectado>(
        controller.states,
        controller.state,
        (s) => s.sala.enrutamiento == nuevas,
        what: 'snapshot con el enrutamiento nuevo',
      );
      expect(conectado.sala.enrutamiento, nuevas);
      expect(controller.destinoDe('PLA'), DestinoPreparacion.barra);
      expect(
        host.requests.where((r) => r == SalaMessageTypes.salaSnapshotGet),
        hasLength(2),
      );
    });
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

  group('WP-10: pases y comensales', () {
    const pasesHost = PasesConfig(
      nombres: ['Entrantes', 'Principales', 'Postres'],
      marcharAlEnviar: false,
    );

    /// Conecta y deja en el host una paella del pase 2 en la mesa m1.
    Future<ComanderoController> conPaellaEnPase2() async {
      final controller = newController();
      controller.conectar(HostObjetivo(endpoint: host.endpoint));
      await waitConectado(controller);
      controller.anadirReferencia('m1', 'PAELLA', pase: 2);
      final result = await controller.enviar('m1', camarero: 'Ana');
      expect(result.comanda.lineas.single.pase, 2);
      expect(result.comanda.lineas.single.envio, 1);
      expect(result.comanda.marchas, isEmpty);
      return controller;
    }

    test('lee pases del snapshot y los actualiza con '
        'enrutamiento.changed', () async {
      host.pases = pasesHost;
      final controller = newController();
      expect(controller.pases, isNull, reason: 'sin snapshot aún');
      controller.conectar(HostObjetivo(endpoint: host.endpoint));
      final conectado = await waitConectado(controller);
      expect(conectado.sala.pases, pasesHost);
      expect(controller.pases, pasesHost);
      expect(controller.pases!.activos, isTrue);
      expect(controller.pases!.nombreDe(2), 'Principales');

      // El host desactiva los pases: llega por el mismo evento que el
      // enrutamiento y el comandero vuelve a pedir el snapshot.
      expect(host.cambiarPases(const PasesConfig(activos: false)), 1);
      await waitState<Conectado>(
        controller.states,
        controller.state,
        (s) => s.sala.pases?.activos == false,
        what: 'snapshot con los pases desactivados',
      );
      expect(controller.pases, const PasesConfig(activos: false));

      // Un host antiguo no publica pases.
      expect(host.cambiarPases(null), 1);
      await waitState<Conectado>(
        controller.states,
        controller.state,
        (s) => s.sala.pases == null,
        what: 'snapshot sin pases',
      );
      expect(controller.pases, isNull);
    });

    test('anadir y editarLinea llevan el pase del carrito', () async {
      final controller = newController();
      final cana = kCatalogoPrueba.porReferencia('CANA')!;
      controller.anadir('m1', cana, pase: 1);
      controller.anadir('m1', cana, pase: 1);
      controller.anadir('m1', cana, pase: 2);
      var pedido = controller.pedido('m1');
      expect(pedido.lineas.map((l) => l.pase), [1, 2]);
      expect(pedido.lineas.first.cantidad, 2);

      pedido = controller.editarLinea(
        'm1',
        'linea-1',
        cantidad: 3,
        nota: 'fría',
        pase: () => 3,
      );
      expect(pedido.lineaPorId('linea-1')!.pase, 3);
      expect(pedido.lineaPorId('linea-1')!.cantidad, 3);
      pedido = controller.editarLinea(
        'm1',
        'linea-1',
        cantidad: 3,
        nota: 'fría',
        pase: () => null,
      );
      expect(pedido.lineaPorId('linea-1')!.pase, isNull);
      pedido = controller.editarLinea('m1', 'linea-1', cantidad: 1, nota: null);
      expect(pedido.lineaPorId('linea-1')!.pase, isNull);
      expect(
        () => controller.anadir('m1', cana, pase: 0),
        throwsA(isA<ValidationException>()),
      );
    });

    test('marcharPase manda una petición fiable con comandaId y actualiza '
        'la comanda', () async {
      host.pases = pasesHost;
      final controller = await conPaellaEnPase2();
      final comandaId = host.comandas['m1']!.id;

      final comanda = await controller.marcharPase('m1', 2);
      final payload = host.marchasRecibidas.single;
      expect(payload.mesaId, 'm1');
      expect(payload.pase, 2);
      expect(payload.comandaId, comandaId);
      expect(payload.marchaId, isNotEmpty);
      expect(
        payload.camarero,
        isNull,
        reason: 'el host pone el nombre del dispositivo',
      );
      expect(host.requests.last, SalaMessageTypes.paseMarchar);

      final marcha = comanda.marchas.single;
      expect(marcha.id, payload.marchaId);
      expect(marcha.pase, 2);
      expect(marcha.camarero, 'Comandero 1');
      expect(marcha.repetida, isFalse);
      expect(marcha.automatica, isFalse);
      expect(controller.comandaDe('m1'), comanda);
      expect(controller.pendientes, 0);

      // Otra pulsación es otra petición: marchaId nuevo y marcha repetida.
      final repetida = await controller.marcharPase('m1', 2);
      expect(host.marchasRecibidas, hasLength(2));
      expect(host.marchasRecibidas.last.marchaId, isNot(payload.marchaId));
      expect(repetida.marchas, hasLength(2));
      expect(repetida.marchas.last.repetida, isTrue);
      expect(host.marchas, hasLength(2));
    });

    test('marcharPase: la retransmisión tras reconectar lleva el mismo '
        'marchaId y el host registra una sola marcha', () async {
      host.pases = pasesHost;
      final controller = await conPaellaEnPase2();

      // El host registra la marcha pero su ack no llega: la petición sigue
      // en la cola fiable del comandero.
      final retener = host.retenerMarchar = Completer<void>();
      final marchando = controller.marcharPase('m1', 2);
      await esperarQue(
        () => host.marchas.isNotEmpty,
        'el host registra la marcha',
      );
      expect(controller.pendientes, 1);
      final enviado = host.marchasRecibidas.single;
      expect(host.comandas['m1']!.marchaPorId(enviado.marchaId), isNotNull);

      // El host se reinicia: pierde la caché de respuestas del transporte
      // pero conserva el diario (la comanda con la marcha).
      final antiguo = host;
      addTearDown(antiguo.dispose);
      final diario = Map.of(antiguo.comandas);
      await antiguo.server.stop();
      retener.complete();
      await waitState<Reconectando>(
        controller.states,
        controller.state,
        (_) => true,
        what: 'Reconectando',
      );
      host = FakeSalaHost(tcpPort: antiguo.tcpPort, pases: pasesHost)
        ..comandas.addAll(diario);
      await host.start();

      // La cola fiable retransmite el mismo mensaje: el payload (y por tanto
      // el marchaId) es idéntico y el host reconoce la marcha del diario.
      final comanda = await marchando.timeout(kWait);
      final retransmitido = host.marchasRecibidas.single;
      expect(retransmitido, enviado);
      expect(retransmitido.marchaId, enviado.marchaId);
      expect(retransmitido.comandaId, diario['m1']!.id);
      expect(
        host.marchas,
        isEmpty,
        reason: 'ya estaba en el diario: ni se repite ni se reimprime',
      );
      expect(host.comandas['m1']!.marchas, hasLength(1));
      expect(comanda.marchas.single.id, enviado.marchaId);
      expect(controller.comandaDe('m1')!.marchas.single.id, enviado.marchaId);
      await waitState<Conectado>(
        controller.states,
        controller.state,
        (s) => s.pendientes == 0,
        what: 'Conectado sin pendientes',
      );
    });

    test('los rechazos del host al marchar llegan tipados y con la '
        'mesa', () async {
      host.pases = pasesHost;
      final controller = await conPaellaEnPase2();
      await expectLater(
        controller.marcharPase('m1', 1),
        throwsA(
          isA<ComanderoSalaException>()
              .having((e) => e.paseSinLineas, 'paseSinLineas', isTrue)
              .having((e) => e.paseNoValido, 'paseNoValido', isFalse)
              .having((e) => e.mesaId, 'mesaId', 'm1')
              .having((e) => e.retryable, 'retryable', isFalse)
              .having((e) => e.message, 'message', contains('Entrantes')),
        ),
      );
      await expectLater(
        controller.marcharPase('m1', 9),
        throwsA(
          isA<ComanderoSalaException>()
              .having((e) => e.paseNoValido, 'paseNoValido', isTrue)
              .having((e) => e.mesaId, 'mesaId', 'm1'),
        ),
      );
      await expectLater(
        controller.marcharPase('m1', 0),
        throwsA(isA<ValidationException>()),
      );
      expect(host.marchasRecibidas, hasLength(2));

      // Sin comanda a la vista no se manda nada (iría sin comandaId).
      await expectLater(
        controller.marcharPase('m2', 1),
        throwsA(
          isA<ComanderoSalaException>()
              .having((e) => e.mesaSinComanda, 'mesaSinComanda', isTrue)
              .having((e) => e.mesaId, 'mesaId', 'm2'),
        ),
      );
      expect(host.marchasRecibidas, hasLength(2));

      // La mesa se cobró y se volvió a abrir sin que el comandero lo viera:
      // aunque la comanda nueva tenga líneas de ese pase, el host no la
      // marcha con el comandaId de la anterior.
      final vista = controller.comandaDe('m1')!;
      host.comandas['m1'] = Comanda(
        id: 'c-nueva',
        mesaId: 'm1',
        abiertaEn: DateTime.utc(2026, 10, 7, 12),
        lineas: vista.lineas,
      );
      await expectLater(
        controller.marcharPase('m1', 2),
        throwsA(
          isA<ComanderoSalaException>()
              .having((e) => e.mesaSinComanda, 'mesaSinComanda', isTrue)
              .having((e) => e.mesaId, 'mesaId', 'm1'),
        ),
      );
      expect(host.marchasRecibidas.last.comandaId, vista.id);
      expect(host.comandas['m1']!.marchas, isEmpty);
      expect(host.marchas, isEmpty);
      expect(controller.comandaDe('m1')!.marchas, isEmpty);
      expect(controller.pendientes, 0);
    });

    test('unknown_type con un host antiguo: excepción tipada no reintentable '
        'y sin pases en el snapshot', () async {
      host.tiposNoAdmitidos.add(SalaMessageTypes.paseMarchar);
      final controller = newController();
      controller.conectar(HostObjetivo(endpoint: host.endpoint));
      await waitConectado(controller);
      expect(controller.pases, isNull, reason: 'el snapshot no trae pases');
      controller.anadirReferencia('m1', 'PAELLA', pase: 2);
      final result = await controller.enviar('m1');
      expect(
        result.comanda.lineas.single.pase,
        isNull,
        reason: 'un host sin pases descarta el pase',
      );

      await expectLater(
        controller.marcharPase('m1', 2),
        throwsA(
          allOf(
            isA<RemoteRequestException>()
                .having((e) => e.code, 'code', ErrorCodes.unknownType)
                .having((e) => e.retryable, 'retryable', isFalse),
            isNot(isA<ComanderoSalaException>()),
          ),
        ),
      );
      expect(host.marchasRecibidas, isEmpty);
      expect(controller.comandaDe('m1')!.marchas, isEmpty);
      expect(controller.pendientes, 0);
    });

    test('fijarComensales manda un submit vacío con comandaId y la comanda '
        'vuelve con los comensales', () async {
      host.pases = pasesHost;
      final controller = await conPaellaEnPase2();
      final antes = host.comandas['m1']!;
      expect(antes.comensales, isNull);

      final comanda = await controller.fijarComensales('m1', 4);
      expect(comanda.id, antes.id);
      expect(comanda.comensales, 4);
      expect(comanda.camarero, 'Ana', reason: 'conserva al primer camarero');
      expect(comanda.lineas.map((l) => l.id), ['linea-1']);
      expect(comanda.lineas.single.envio, 1, reason: 'no consume nº de envío');
      final submit = host.submits.last;
      expect(host.submits, hasLength(2));
      expect(submit.mesaId, 'm1');
      expect(submit.lineas, isEmpty);
      expect(submit.comensales, 4);
      expect(submit.comandaId, antes.id);
      expect(controller.comandaDe('m1'), comanda);
      expect(host.comandas['m1']!.comensales, 4);
      expect(controller.pendientes, 0);

      // Sin comanda abierta no se manda nada: el valor va en el primer envío.
      await expectLater(
        controller.fijarComensales('m2', 2),
        throwsA(
          isA<ComanderoSalaException>()
              .having((e) => e.mesaSinComanda, 'mesaSinComanda', isTrue)
              .having((e) => e.mesaId, 'mesaId', 'm2'),
        ),
      );
      await expectLater(
        controller.fijarComensales('m1', 0),
        throwsA(isA<ValidationException>()),
      );
      await expectLater(
        controller.fijarComensales('m1', 100),
        throwsA(isA<ValidationException>()),
      );
      expect(host.submits, hasLength(2));

      // El submit vacío no consumió nº de envío: el siguiente pedido es el 2.
      controller.anadirReferencia('m1', 'CANA');
      final siguiente = await controller.enviar('m1');
      expect(siguiente.comanda.lineas.last.referencia, 'CANA');
      expect(siguiente.comanda.lineas.last.envio, 2);
      expect(siguiente.comanda.comensales, 4);

      // Si la comanda que ve el comandero ya no es la abierta (se cobró y
      // se volvió a abrir), el host no aplica nada y devuelve la actual: el
      // comandero avisa y pide el snapshot en vez de fiarse de ella.
      final reabierta = Comanda(
        id: 'c-nueva',
        mesaId: 'm1',
        abiertaEn: DateTime.utc(2026, 10, 7, 12),
        comensales: 2,
      );
      host.comandas['m1'] = reabierta;
      final cerrada = throwsA(
        isA<ComanderoSalaException>()
            .having((e) => e.mesaSinComanda, 'mesaSinComanda', isTrue)
            .having((e) => e.mesaId, 'mesaId', 'm1'),
      );
      await expectLater(controller.fijarComensales('m1', 6), cerrada);
      expect(host.submits.last.comandaId, antes.id);
      expect(host.comandas['m1'], reabierta, reason: 'el host no la toca');
      await waitState<Conectado>(
        controller.states,
        controller.state,
        (s) => s.sala.comandaDeMesa('m1')?.id == 'c-nueva',
        what: 'snapshot con la comanda reabierta',
      );
      expect(controller.comandaDe('m1'), reabierta);

      // Con la mesa ya libre en el host, el envío vacío no la abre y el
      // comandero tampoco muestra la comanda vacía que le devuelve.
      host.comandas.remove('m1');
      await expectLater(controller.fijarComensales('m1', 3), cerrada);
      expect(host.submits.last.comandaId, 'c-nueva');
      expect(host.comandas, isNot(contains('m1')));
      await waitState<Conectado>(
        controller.states,
        controller.state,
        (s) => s.sala.comandaDeMesa('m1') == null,
        what: 'snapshot con la mesa libre',
      );
      expect(controller.comandaDe('m1'), isNull);
    });

    test('sin host objetivo (sin conectar o tras desconectar), marcharPase y '
        'fijarComensales fallan con SinConexionException', () async {
      final sinHost = throwsA(
        isA<SinConexionException>().having(
          (e) => e.message,
          'message',
          'No hay ningún host configurado; conecta antes de enviar',
        ),
      );
      final sinConectar = newController();
      await expectLater(sinConectar.marcharPase('m1', 1), sinHost);
      await expectLater(sinConectar.fijarComensales('m1', 2), sinHost);
      // El mismo rechazo que una anulación sin host.
      await expectLater(sinConectar.anularLinea('m1', 'linea-1'), sinHost);
      // La validación de los argumentos va antes que la del host.
      await expectLater(
        sinConectar.marcharPase('m1', 0),
        throwsA(isA<ValidationException>()),
      );
      await expectLater(
        sinConectar.fijarComensales('m1', 0),
        throwsA(isA<ValidationException>()),
      );

      host.pases = pasesHost;
      final controller = await conPaellaEnPase2();
      await controller.desconectar();
      await expectLater(controller.marcharPase('m1', 2), sinHost);
      await expectLater(controller.fijarComensales('m1', 4), sinHost);
      expect(host.marchasRecibidas, isEmpty);
      expect(host.submits, hasLength(1), reason: 'solo el envío de la paella');
      expect(controller.pendientes, 0);
    });

    test('un envío sobre la comanda abierta conserva al primer camarero y '
        'aplica los comensales', () async {
      host.pases = pasesHost;
      final controller = await conPaellaEnPase2();

      controller.anadirReferencia('m1', 'CANA');
      final result = await controller.enviar(
        'm1',
        camarero: 'Luis',
        comensales: 3,
      );
      final comanda = result.comanda;
      expect(comanda.camarero, 'Ana', reason: 'el primer camarero se queda');
      expect(comanda.comensales, 3);
      final paella = comanda.lineas.firstWhere((l) => l.referencia == 'PAELLA');
      final cana = comanda.lineas.firstWhere((l) => l.referencia == 'CANA');
      expect(paella.camarero, 'Ana');
      expect(cana.camarero, 'Luis', reason: 'cada línea, el de su envío');
      expect(cana.envio, 2);
      expect(cana.pase, isNull);
      expect(host.comandas['m1'], comanda);

      // Sin comensales en el envío se conservan los de la comanda.
      controller.anadirReferencia('m1', 'CAFE');
      final otro = await controller.enviar('m1');
      expect(otro.comanda.comensales, 3);
      expect(otro.comanda.camarero, 'Ana');
      expect(otro.comanda.lineas.last.envio, 3);
    });

    test('cerrarParaTraspaso cuenta las marchas en cola en '
        'peticionesPerdidas', () async {
      host.pases = pasesHost;
      final controller = await conPaellaEnPase2();
      await host.server.stop();
      await waitState<Reconectando>(
        controller.states,
        controller.state,
        (_) => true,
        what: 'Reconectando',
      );

      final marcha = controller.marcharPase('m1', 2);
      final anulacion = controller.anularLinea('m1', 'linea-1', motivo: 'no');
      expect(controller.pendientes, 2);
      final fallos = Future.wait<void>([
        expectLater(marcha, throwsA(isA<NetworkException>())),
        expectLater(anulacion, throwsA(isA<NetworkException>())),
      ]);
      final traspaso = await controller.cerrarParaTraspaso();
      await fallos;
      expect(traspaso.peticionesPerdidas, 2);
      expect(traspaso.lineasDevueltas, 0);
      expect(host.marchas, isEmpty);
    });

    test('ControllerComanderoGateway delega en el controlador, también el '
        'pase, las marchas y los comensales', () async {
      host.pases = pasesHost;
      final controller = newController();
      final ComanderoGateway gateway = ControllerComanderoGateway(controller);
      final cambios = <PedidoEnEdicion>[];
      final subs = [
        gateway.pedidosCambiados.listen(cambios.add),
        gateway.avisos.listen((_) {}),
      ];
      addTearDown(() async {
        for (final sub in subs) {
          await sub.cancel();
        }
      });
      Future<Conectado> conectado() => waitState<Conectado>(
        gateway.states,
        gateway.state,
        (_) => true,
        what: 'Conectado',
      );
      expect(gateway.config, controller.config);
      expect(gateway.state, isA<SinHost>());
      expect(gateway.pases, isNull);

      final hosts = await gateway.buscarHosts();
      gateway.conectarDescubierto(hosts.single);
      await conectado();
      expect(gateway.sala, same(controller.sala));
      expect(gateway.catalogo, kCatalogoPrueba);
      expect(gateway.pases, pasesHost);

      // Carrito, con el pase de cada línea.
      final paella = kCatalogoPrueba.porReferencia('PAELLA')!;
      final cana = kCatalogoPrueba.porReferencia('CANA')!;
      gateway.anadir('m1', paella, pase: 2);
      expect(gateway.pedido('m1').lineaPorId('linea-1')!.pase, 2);
      gateway.anadir('m1', cana, cantidad: 2, nota: 'fría');
      gateway.cambiarCantidad('m1', 'linea-2', 3);
      gateway.cambiarNota('m1', 'linea-2', 'muy fría');
      gateway.editarLinea(
        'm1',
        'linea-1',
        cantidad: 1,
        nota: 'mixta',
        pase: () => 1,
      );
      final pedido = gateway.pedido('m1');
      expect(pedido, controller.pedido('m1'));
      expect(pedido.lineaPorId('linea-1')!.pase, 1);
      expect(pedido.lineaPorId('linea-1')!.nota, 'mixta');
      expect(pedido.lineaPorId('linea-2')!.cantidad, 3);
      expect(pedido.lineaPorId('linea-2')!.nota, 'muy fría');
      await Future<void>.delayed(Duration.zero); // el broadcast es asíncrono
      expect(cambios.last, pedido);
      final copia = gateway.exportarPedidos();
      expect(gateway.quitar('m1', 'linea-2').lineas, hasLength(1));
      expect(gateway.importarPedidos(copia), 1);
      expect(gateway.vaciar('m2').estaVacio, isTrue);

      // Peticiones al host.
      final enviado = await gateway.enviar(
        'm1',
        camarero: 'Ana',
        comensales: 2,
      );
      expect(enviado.lineasNuevas, 2);
      expect(gateway.pendientes, 0);
      final marchada = await gateway.marcharPase('m1', 1);
      expect(marchada.marchas.single.pase, 1);
      expect(host.marchasRecibidas.single.comandaId, enviado.comanda.id);
      final conComensales = await gateway.fijarComensales('m1', 5);
      expect(conComensales.comensales, 5);
      final anulada = await gateway.anularLinea(
        'm1',
        'linea-2',
        motivo: 'repetida',
      );
      expect(anulada.lineaPorId('linea-2')!.estado, EstadoLinea.anulada);
      final cuenta = await gateway.pedirCuenta('m1');
      expect(cuenta.cuentaSolicitada, isTrue);
      await gateway.refrescarSala();
      expect(gateway.sala!.comandaDeMesa('m1')!.comensales, 5);

      // Conexión: ajustes sin cambios, desconectar y volver a conectar.
      gateway.actualizarConexion(pairingCode: null, hostManual: null);
      await gateway.desconectar();
      expect(gateway.state, isA<SinHost>());
      gateway.conectarManual('127.0.0.1:${host.tcpPort}');
      await conectado();
      gateway.conectar(HostObjetivo(endpoint: host.endpoint));
      expect(gateway.state, isA<Conectado>(), reason: 'mismo host: no corta');
      final traspaso = await gateway.cerrarParaTraspaso();
      expect(traspaso.peticionesPerdidas, 0);
      expect(traspaso.pedidos, isEmpty);
    });

    test('ControllerComanderoGateway: iniciar conecta y dispose libera el '
        'controlador', () async {
      final controller = newController();
      final gateway = ControllerComanderoGateway(controller);
      expect(await gateway.iniciar(), isTrue);
      await waitConectado(controller);
      await gateway.dispose();
      expect(
        () => gateway.anadir('m1', kCatalogoPrueba.porReferencia('CANA')!),
        throwsStateError,
      );
    });
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
