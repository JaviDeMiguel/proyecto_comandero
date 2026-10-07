import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proyecto_comandero/app/theme.dart';
import 'package:proyecto_comandero/core/errors/app_exception.dart';
import 'package:proyecto_comandero/core/network/protocol/transport_messages.dart';
import 'package:proyecto_comandero/features/comandero/data/in_memory_comandero_cache_repository.dart';
import 'package:proyecto_comandero/features/comandero/domain/comandero_state.dart';
import 'package:proyecto_comandero/features/comandero/presentation/comandero_home.dart';
import 'package:proyecto_comandero/features/comandero/presentation/conexion_page.dart';
import 'package:proyecto_comandero/features/comandero/presentation/mesas_page.dart';
import 'package:proyecto_comandero/features/comandero/presentation/providers.dart';
import 'package:proyecto_comandero/features/settings/data/in_memory_settings_repository.dart';
import 'package:proyecto_comandero/features/settings/presentation/settings_providers.dart';

import 'comandero_harness.dart';
import 'fake_comandero_gateway.dart';

void main() {
  testWidgets('pasa de conexión a mesas y vuelve según el estado', (
    tester,
  ) async {
    final gateway = FakeComanderoGateway();
    await montar(tester, const ComanderoHome(), gateway: gateway);
    expect(find.byType(ConexionPage), findsOneWidget);

    gateway.emitir(const Conectando(host: kHostPrueba));
    await asentar(tester);
    expect(find.byType(ConexionPage), findsOneWidget);

    gateway.emitir(
      Conectado(
        host: kHostPrueba,
        sala: salaPrueba(),
        catalogo: kCatalogoPrueba,
      ),
    );
    await asentar(tester);
    expect(find.byType(MesasPage), findsOneWidget);

    // Perder la conexión no saca al camarero de las mesas.
    gateway.perderConexion();
    await asentar(tester);
    expect(find.byType(MesasPage), findsOneWidget);

    gateway.emitir(
      const Rechazado(
        codigo: RejectCodes.unauthorized,
        mensaje: 'Código incorrecto',
        host: kHostPrueba,
      ),
    );
    await asentar(tester);
    expect(find.byType(ConexionPage), findsOneWidget);
    expect(find.text('Conexión rechazada'), findsOneWidget);
  });

  testWidgets('los avisos del controlador se muestran al camarero', (
    tester,
  ) async {
    final gateway = FakeComanderoGateway(
      state: Conectado(
        host: kHostPrueba,
        sala: salaPrueba(),
        catalogo: kCatalogoPrueba,
      ),
    );
    await montar(tester, const ComanderoHome(), gateway: gateway);
    expect(find.byType(MesasPage), findsOneWidget);

    gateway.emitirAviso(
      const AvisoComandero(
        mesaId: 'm1',
        mensaje: 'El host ya tenía 2 líneas de Mesa 1 con otros datos',
        lineaIds: ['l1', 'l2'],
      ),
    );
    await asentar(tester);
    expect(
      find.text('El host ya tenía 2 líneas de Mesa 1 con otros datos'),
      findsOneWidget,
    );
  });

  testWidgets('con la carta desactualizada se avisa sin bloquear', (
    tester,
  ) async {
    final gateway = FakeComanderoGateway(
      state: Conectado(
        host: kHostPrueba,
        sala: salaPrueba(),
        catalogo: kCatalogoPrueba,
      ),
    );
    await montar(tester, const ComanderoHome(), gateway: gateway);
    expect(find.byKey(const Key('comandero.avisoCatalogo')), findsNothing);

    gateway.emitir(
      Conectado(
        host: kHostPrueba,
        sala: salaPrueba(),
        catalogo: kCatalogoPrueba,
        catalogoDesactualizado: true,
      ),
    );
    await asentar(tester);
    expect(find.byKey(const Key('comandero.avisoCatalogo')), findsOneWidget);
    expect(find.byKey(const Key('comandero.avisoSinConexion')), findsNothing);
    expect(find.byType(MesasPage), findsOneWidget);
  });

  testWidgets('u2: al recrear el controlador los carritos pasan al nuevo y '
      'se avisa de los envíos que han vuelto al carrito', (tester) async {
    await tester.binding.setSurfaceSize(kTelefono);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final creados = <FakeComanderoGateway>[];
    addTearDown(() async {
      for (final gateway in creados) {
        await gateway.dispose();
      }
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsRepositoryProvider.overrideWith(
            (ref) => InMemorySettingsRepository(initial: ajustesPrueba()),
          ),
          comanderoCacheProvider.overrideWith(
            (ref) => InMemoryComanderoCacheRepository(),
          ),
          comanderoGatewayFactoryProvider.overrideWithValue((config, cache) {
            final gateway = FakeComanderoGateway(
              config: config,
              state: Conectado(
                host: kHostPrueba,
                sala: salaPrueba(),
                catalogo: kCatalogoPrueba,
              ),
            );
            creados.add(gateway);
            return gateway;
          }),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const ComanderoHome(),
        ),
      ),
    );
    await asentar(tester);
    expect(find.byType(MesasPage), findsOneWidget);
    final primero = creados.single;
    primero
      ..anadir('m1', kCatalogoPrueba.porReferencia('CANA')!)
      ..anadir('m2', kCatalogoPrueba.porReferencia('CAFE')!)
      ..perderConexion();
    final fallo = expectLater(
      primero.enviar('m2'),
      throwsA(isA<NetworkException>()),
    );
    await asentar(tester);

    final container = ProviderScope.containerOf(
      tester.element(find.byType(ComanderoHome)),
    );
    await container
        .read(appSettingsProvider.notifier)
        .actualizar((s) => s.copyWith(deviceName: 'Terraza'));
    await asentar(tester);
    await fallo;

    expect(creados, hasLength(2));
    final segundo = creados.last;
    expect(segundo.config.deviceName, 'Terraza');
    expect(segundo.pedido('m1').lineas, hasLength(1));
    expect(segundo.pedido('m2').lineas.single.posiblementeTransmitida, isTrue);
    expect(find.byType(MesasPage), findsOneWidget);
    expect(find.textContaining('vuelto al carrito'), findsOneWidget);
  });
}
