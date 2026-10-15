import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proyecto_comandero/core/errors/app_exception.dart';
import 'package:proyecto_comandero/features/comandero/data/in_memory_comandero_cache_repository.dart';
import 'package:proyecto_comandero/features/comandero/domain/comandero_config.dart';
import 'package:proyecto_comandero/features/comandero/domain/comandero_state.dart';
import 'package:proyecto_comandero/features/comandero/domain/pedido_en_edicion.dart';
import 'package:proyecto_comandero/features/comandero/domain/traspaso_comandero.dart';
import 'package:proyecto_comandero/features/comandero/presentation/providers.dart';
import 'package:proyecto_comandero/features/sala/domain/comanda.dart';
import 'package:proyecto_comandero/features/sala/domain/pases.dart';
import 'package:proyecto_comandero/features/settings/data/in_memory_settings_repository.dart';
import 'package:proyecto_comandero/features/settings/domain/app_settings.dart';
import 'package:proyecto_comandero/features/settings/presentation/settings_providers.dart';

import 'comandero_harness.dart';
import 'fake_comandero_gateway.dart';

void main() {
  late List<FakeComanderoGateway> creados;
  late ProviderContainer container;

  setUp(() {
    creados = [];
    container = ProviderContainer(
      overrides: [
        settingsRepositoryProvider.overrideWith(
          (ref) => InMemorySettingsRepository(
            initial: ajustesPrueba(
              pairingCode: '1111',
              hostManual: '10.0.0.2:4040',
            ),
          ),
        ),
        comanderoCacheProvider.overrideWith(
          (ref) => InMemoryComanderoCacheRepository(),
        ),
        comanderoGatewayFactoryProvider.overrideWithValue((config, cache) {
          final gateway = FakeComanderoGateway(config: config);
          creados.add(gateway);
          return gateway;
        }),
      ],
    );
    addTearDown(() async {
      container.dispose();
      for (final gateway in creados) {
        await gateway.dispose();
      }
    });
  });

  test(
    'construye el controlador con los ajustes y arranca la conexión',
    () async {
      final sub = container.listen(comanderoControllerProvider, (_, _) {});
      addTearDown(sub.close);

      final gateway = await container.read(comanderoControllerProvider.future);
      await pumpEventQueue();

      expect(gateway, same(creados.single));
      expect(
        gateway.config,
        const ComanderoConfig(
          deviceId: 'dev-1',
          deviceName: 'Móvil 1',
          pairingCode: '1111',
          hostManual: '10.0.0.2:4040',
        ),
      );
      expect(creados.single.metodos(), ['iniciar']);
    },
  );

  test('guardar código u host manual no recrea el controlador', () async {
    final sub = container.listen(comanderoControllerProvider, (_, _) {});
    addTearDown(sub.close);
    final primero = await container.read(comanderoControllerProvider.future);

    await container
        .read(appSettingsProvider.notifier)
        .actualizar(
          (s) => s.copyWith(
            red: s.red.copyWith(pairingCode: '2222', borrarHostManual: true),
          ),
        );
    await pumpEventQueue();

    expect(
      await container.read(comanderoControllerProvider.future),
      same(primero),
    );
    expect(creados, hasLength(1));
  });

  test(
    'cambiar la identidad recrea el controlador y libera el anterior',
    () async {
      final sub = container.listen(comanderoControllerProvider, (_, _) {});
      addTearDown(sub.close);
      final primero = await container.read(
        comanderoControllerProvider.future,
      ) as FakeComanderoGateway;

      await container
          .read(appSettingsProvider.notifier)
          .actualizar((s) => s.copyWith(deviceName: 'Terraza'));
      await pumpEventQueue();
      final segundo = await container.read(comanderoControllerProvider.future);
      await pumpEventQueue();

      expect(segundo, isNot(same(primero)));
      expect(segundo.config.deviceName, 'Terraza');
      expect(primero.disposed, isTrue);
    },
  );

  test('u1: el código y el host manual guardados en Ajustes llegan al '
      'controlador vivo y reconectan', () async {
    final sub = container.listen(comanderoControllerProvider, (_, _) {});
    addTearDown(sub.close);
    final gateway = await container.read(
      comanderoControllerProvider.future,
    ) as FakeComanderoGateway;
    await pumpEventQueue();
    gateway.emitir(
      const Rechazado(
        codigo: 'unauthorized',
        mensaje: 'Código incorrecto',
        host: kHostPrueba,
      ),
    );

    await container
        .read(appSettingsProvider.notifier)
        .actualizar(
          (s) => s.copyWith(red: s.red.copyWith(pairingCode: '2222')),
        );
    await pumpEventQueue();

    expect(
      await container.read(comanderoControllerProvider.future),
      same(gateway),
    );
    expect(gateway.config.pairingCode, '2222');
    expect(gateway.llamadas.last.metodo, 'conectar');
    expect(gateway.llamadas.last.args.first, kHostPrueba);

    await container
        .read(appSettingsProvider.notifier)
        .actualizar(
          (s) => s.copyWith(red: s.red.copyWith(hostManual: '10.0.0.9:4040')),
        );
    await pumpEventQueue();

    expect(gateway.config.hostManual, '10.0.0.9:4040');
    expect(gateway.state.host?.endpoint.toString(), '10.0.0.9:4040');
    expect(creados, hasLength(1));
  });

  test('u2: recrear el controlador traspasa los carritos y los envíos '
      'pendientes y avisa al camarero', () async {
    final avisos = <AvisoComandero>[];
    final subAvisos = container.listen(
      comanderoAvisosProvider,
      (_, next) => next.whenData(avisos.add),
    );
    addTearDown(subAvisos.close);
    final primero = await container.read(
      comanderoControllerProvider.future,
    ) as FakeComanderoGateway;
    await pumpEventQueue();
    primero
      ..anadir('m1', kCatalogoPrueba.porReferencia('CANA')!, nota: 'Fría')
      ..anadir('m2', kCatalogoPrueba.porReferencia('CAFE')!)
      ..emitir(Conectando(host: kHostPrueba))
      ..perderConexion();
    final envio = primero.enviar('m2');
    final fallo = expectLater(envio, throwsA(isA<NetworkException>()));
    expect(primero.pendientes, 1);

    await container
        .read(appSettingsProvider.notifier)
        .actualizar((s) => s.copyWith(deviceName: 'Terraza'));
    await pumpEventQueue();
    final segundo = await container.read(comanderoControllerProvider.future);
    await pumpEventQueue();
    await fallo;

    expect(segundo, isNot(same(primero)));
    expect(primero.disposed, isTrue);
    expect(primero.metodos(), contains('cerrarParaTraspaso'));
    final m1 = segundo.pedido('m1').lineas.single;
    expect(m1.articulo.referencia, 'CANA');
    expect(m1.nota, 'Fría');
    final m2 = segundo.pedido('m2').lineas.single;
    expect(m2.articulo.referencia, 'CAFE');
    expect(m2.enviando, isFalse);
    expect(m2.posiblementeTransmitida, isTrue);
    expect(avisos, hasLength(1));
    expect(avisos.single.mensaje, contains('1 línea(s)'));
    expect(avisos.single.mensaje, contains('vuelto al carrito'));
  });

  test('u2: sin envíos pendientes el traspaso no avisa', () async {
    final avisos = <AvisoComandero>[];
    final subAvisos = container.listen(
      comanderoAvisosProvider,
      (_, next) => next.whenData(avisos.add),
    );
    addTearDown(subAvisos.close);
    final primero = await container.read(comanderoControllerProvider.future);
    primero.anadir('m1', kCatalogoPrueba.porReferencia('CANA')!);

    await container
        .read(appSettingsProvider.notifier)
        .actualizar((s) => s.copyWith(deviceName: 'Terraza'));
    await pumpEventQueue();
    final segundo = await container.read(comanderoControllerProvider.future);
    await pumpEventQueue();

    expect(segundo.pedido('m1').lineas, hasLength(1));
    expect(avisos, isEmpty);
  });

  test('u2: las anulaciones que no se pueden traspasar se avisan', () async {
    final avisos = <AvisoComandero>[];
    final subAvisos = container.listen(
      comanderoAvisosProvider,
      (_, next) => next.whenData(avisos.add),
    );
    addTearDown(subAvisos.close);
    final primero = await container.read(
      comanderoControllerProvider.future,
    ) as FakeComanderoGateway;
    primero.anulacionesEnCola = 2;

    await container
        .read(appSettingsProvider.notifier)
        .actualizar((s) => s.copyWith(deviceName: 'Terraza'));
    await pumpEventQueue();
    await container.read(comanderoControllerProvider.future);
    await pumpEventQueue();

    expect(
      avisos.single.mensaje,
      contains(
        '2 petición(es) sin confirmar (anulaciones o marchas) se han '
        'cancelado: repítelas',
      ),
    );
  });

  test('u2: una marcha en cola sin conexión cuenta con las anulaciones en el '
      'aviso del traspaso', () async {
    final avisos = <AvisoComandero>[];
    final subAvisos = container.listen(
      comanderoAvisosProvider,
      (_, next) => next.whenData(avisos.add),
    );
    addTearDown(subAvisos.close);
    final primero = await container.read(
      comanderoControllerProvider.future,
    ) as FakeComanderoGateway;
    primero
      ..anulacionesEnCola = 1
      ..emitir(
        Conectado(
          host: kHostPrueba,
          sala: salaPrueba(
            comandas: [
              Comanda(
                id: 'c1',
                mesaId: 'm1',
                abiertaEn: kAhora,
                lineas: [lineaPrueba('x1', 'PAELLA', pase: 2)],
              ),
            ],
            pases: const PasesConfig(),
          ),
        ),
      )
      ..perderConexion();
    // La marcha queda en cola y el traspaso la cancela: no se puede pasar
    // al controlador nuevo.
    final marcha = expectLater(
      primero.marcharPase('m1', 2),
      throwsA(isA<NetworkException>()),
    );
    expect(primero.pendientes, 1);

    await container
        .read(appSettingsProvider.notifier)
        .actualizar((s) => s.copyWith(deviceName: 'Terraza'));
    await pumpEventQueue();
    await container.read(comanderoControllerProvider.future);
    await pumpEventQueue();
    await marcha;

    expect(avisos, hasLength(1));
    expect(
      avisos.single.mensaje,
      contains('2 petición(es) sin confirmar (anulaciones o marchas)'),
    );
    expect(avisos.single.mensaje, isNot(contains('anulación(es)')));
  });

  test('u2: el aviso pendiente de un controlador que se libera antes de '
      'mostrarlo se descarta', () async {
    final sub = container.listen(comanderoControllerProvider, (_, _) {});
    addTearDown(sub.close);
    final primero = await container.read(
      comanderoControllerProvider.future,
    ) as FakeComanderoGateway;
    primero.anulacionesEnCola = 1;
    final ajustes = container.read(appSettingsProvider.notifier);

    // El segundo recibe el aviso, pero nadie lo muestra antes de recrearlo.
    await ajustes.actualizar((s) => s.copyWith(deviceName: 'Terraza'));
    await pumpEventQueue();
    final segundo = await container.read(comanderoControllerProvider.future);
    await pumpEventQueue();
    await ajustes.actualizar((s) => s.copyWith(deviceName: 'Barra'));
    await pumpEventQueue();
    final tercero = await container.read(comanderoControllerProvider.future);
    await pumpEventQueue();
    expect(creados, [primero, segundo, tercero]);

    final avisos = <AvisoComandero>[];
    final subAvisos = container.listen(
      comanderoAvisosProvider,
      (_, next) => next.whenData(avisos.add),
    );
    addTearDown(subAvisos.close);
    await pumpEventQueue();
    expect(avisos, isEmpty);
  });

  test('u2: TraspasoComandero compara por valor y cuenta las líneas y las '
      'peticiones perdidas', () {
    final pedido = PedidoEnEdicion.vacio(
      'm1',
    ).conArticulo(kCatalogoPrueba.porReferencia('CANA')!, nuevoId: () => 'l1');
    final traspaso = TraspasoComandero(
      pedidos: [pedido],
      lineasDevueltas: 1,
      peticionesPerdidas: 2,
    );

    expect(
      traspaso,
      TraspasoComandero(
        pedidos: [pedido],
        lineasDevueltas: 1,
        peticionesPerdidas: 2,
      ),
    );
    expect(
      traspaso,
      isNot(TraspasoComandero(pedidos: [pedido], lineasDevueltas: 1)),
    );
    expect(traspaso.lineas, 1);
    expect(traspaso.estaVacio, isFalse);
    // Una marcha o una anulación perdida también hay que avisarla.
    expect(const TraspasoComandero(peticionesPerdidas: 1).estaVacio, isFalse);
    expect(const TraspasoComandero().estaVacio, isTrue);
  });

  test('u3: con un rol distinto de comandero no crea el controlador', () async {
    final otro = ProviderContainer(
      overrides: [
        settingsRepositoryProvider.overrideWith(
          (ref) => InMemorySettingsRepository(
            initial: ajustesPrueba().copyWith(rol: DeviceRole.host),
          ),
        ),
        comanderoCacheProvider.overrideWith(
          (ref) => InMemoryComanderoCacheRepository(),
        ),
        comanderoGatewayFactoryProvider.overrideWithValue((config, cache) {
          final gateway = FakeComanderoGateway(config: config);
          creados.add(gateway);
          return gateway;
        }),
      ],
    );
    addTearDown(otro.dispose);
    final sub = otro.listen(comanderoControllerProvider, (_, _) {});
    addTearDown(sub.close);

    await expectLater(
      otro.read(comanderoControllerProvider.future),
      throwsA(
        isA<ConfigException>().having(
          (e) => e.message,
          'message',
          contains('comandero'),
        ),
      ),
    );
    expect(creados, isEmpty);

    // Al elegir el modo comandero sí se crea y arranca.
    await otro
        .read(appSettingsProvider.notifier)
        .actualizar((s) => s.copyWith(rol: DeviceRole.comandero));
    await pumpEventQueue();
    final gateway = await otro.read(comanderoControllerProvider.future);
    await pumpEventQueue();
    expect(gateway, same(creados.single));
    expect(creados.single.metodos(), ['iniciar']);
  });

  test('comanderoStateProvider da el estado actual y sus cambios', () async {
    final estados = <ComanderoState>[];
    final sub = container.listen(
      comanderoStateProvider,
      (_, next) => next.whenData(estados.add),
    );
    addTearDown(sub.close);
    final gateway = await container.read(
      comanderoControllerProvider.future,
    ) as FakeComanderoGateway;
    await pumpEventQueue();

    gateway.emitir(const Conectando(host: kHostPrueba));
    await pumpEventQueue();

    expect(estados, [const SinHost(), const Conectando(host: kHostPrueba)]);
  });

  test('pedidoProvider solo refleja el carrito de su mesa', () async {
    final pedidos = <PedidoEnEdicion>[];
    final sub = container.listen(
      pedidoProvider('m1'),
      (_, next) => next.whenData(pedidos.add),
    );
    addTearDown(sub.close);
    final gateway = await container.read(
      comanderoControllerProvider.future,
    ) as FakeComanderoGateway;
    await pumpEventQueue();

    gateway.anadir('m2', kCatalogoPrueba.porReferencia('CANA')!);
    gateway.anadir('m1', kCatalogoPrueba.porReferencia('CAFE')!);
    await pumpEventQueue();

    expect(pedidos, hasLength(2));
    expect(pedidos.first.estaVacio, isTrue);
    expect(pedidos.last.lineas.single.articulo.referencia, 'CAFE');
  });

  test('actualYCambios no pierde eventos y libera la suscripción', () async {
    final cambios = StreamController<int>.broadcast();
    addTearDown(cambios.close);
    var actual = 1;

    final recibidos = <int>[];
    final sub = actualYCambios(
      () => actual,
      cambios.stream,
    ).listen(recibidos.add);
    actual = 2;
    cambios.add(3);
    await pumpEventQueue();
    await sub.cancel();

    expect(recibidos, [1, 3]);
    expect(cambios.hasListener, isFalse);
  });

  test('marchasEnCursoProvider sigue cada marcha de su mesa hasta que '
      'termina, bien o con error', () async {
    final bien = Completer<Comanda>();
    final mal = Completer<Comanda>();
    container.read(marchasEnCursoProvider('m1').notifier)
      ..seguir(2, bien.future)
      ..seguir(3, mal.future);

    expect(container.read(marchasEnCursoProvider('m1')), {2, 3});
    expect(container.read(marchasEnCursoProvider('m2')), isEmpty);

    bien.complete(Comanda(id: 'c1', mesaId: 'm1', abiertaEn: kAhora));
    await pumpEventQueue();
    expect(container.read(marchasEnCursoProvider('m1')), {3});

    mal.completeError(const NetworkException('Conexión cerrada'));
    await pumpEventQueue();
    expect(container.read(marchasEnCursoProvider('m1')), isEmpty);
  });

  test('marchasEnCursoProvider conserva las marchas sin nadie que lo '
      'escuche', () async {
    final marcha = Completer<Comanda>();
    final sub = container.listen(marchasEnCursoProvider('m1'), (_, _) {});
    container
        .read(marchasEnCursoProvider('m1').notifier)
        .seguir(2, marcha.future);
    // La página de la mesa se cierra: deja de escucharlo.
    sub.close();
    await pumpEventQueue();

    expect(container.read(marchasEnCursoProvider('m1')), {2});
    marcha.complete(Comanda(id: 'c1', mesaId: 'm1', abiertaEn: kAhora));
    await pumpEventQueue();
    expect(container.read(marchasEnCursoProvider('m1')), isEmpty);
  });

  test('marchasEnCursoProvider no falla si la marcha termina con el '
      'contenedor ya liberado', () async {
    final otro = ProviderContainer();
    final marcha = Completer<Comanda>();
    otro.read(marchasEnCursoProvider('m1').notifier).seguir(1, marcha.future);
    otro.dispose();

    marcha.completeError(const NetworkException('Conexión cerrada'));
    await pumpEventQueue();
  });
}
