/// Las pantallas del comandero con el [ComanderoController] REAL contra un
/// [TcpHostServer] real en loopback ([FakeSalaHost]).
///
/// La red es E/S real: se alterna `tester.runAsync` (deja correr el bucle de
/// eventos de verdad) con `tester.pump` (avanza el reloj simulado de la
/// prueba, donde viven los temporizadores del cliente) hasta que se cumple
/// la condición esperada.
library;

import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proyecto_comandero/app/theme.dart';
import 'package:proyecto_comandero/core/network/tcp/tcp_comandero_client.dart';
import 'package:proyecto_comandero/features/comandero/application/comandero_controller.dart';
import 'package:proyecto_comandero/features/comandero/data/in_memory_comandero_cache_repository.dart';
import 'package:proyecto_comandero/features/comandero/presentation/comandero_gateway.dart';
import 'package:proyecto_comandero/features/comandero/presentation/comandero_home.dart';
import 'package:proyecto_comandero/features/comandero/presentation/mesas_page.dart';
import 'package:proyecto_comandero/features/comandero/presentation/pedido_page.dart';
import 'package:proyecto_comandero/features/comandero/presentation/providers.dart';
import 'package:proyecto_comandero/features/settings/data/in_memory_settings_repository.dart';
import 'package:proyecto_comandero/features/settings/presentation/settings_providers.dart';

import '../../features/comandero/fake_sala_host.dart';
import 'comandero_harness.dart';

/// Alterna E/S real y frames hasta que [condicion] se cumple.
Future<void> esperar(
  WidgetTester tester,
  bool Function() condicion, {
  required String que,
}) async {
  final limite = DateTime.now().add(kWait);
  while (!condicion()) {
    if (DateTime.now().isAfter(limite)) {
      fail('No se cumplió a tiempo: $que');
    }
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 15)),
    );
    await tester.pump(const Duration(milliseconds: 30));
  }
  await tester.pump();
}

bool hay(Finder finder) => finder.evaluate().isNotEmpty;

void main() {
  testWidgets('conecta, envía una comanda y encola sin conexión hasta '
      'reconectar', (tester) async {
    await tester.binding.setSurfaceSize(kTelefono);
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final host = (await tester.runAsync(
      () async => FakeSalaHost(tcpPort: await freeTcpPort()),
    ))!;
    await tester.runAsync(host.start);

    final gateways = <ComanderoGateway>[];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsRepositoryProvider.overrideWith(
            (ref) => InMemorySettingsRepository(
              initial: ajustesPrueba(hostManual: '127.0.0.1:${host.tcpPort}'),
            ),
          ),
          comanderoCacheProvider.overrideWith(
            (ref) => InMemoryComanderoCacheRepository(),
          ),
          comanderoGatewayFactoryProvider.overrideWithValue((config, cache) {
            final gateway = ControllerComanderoGateway(
              ComanderoController(
                config: config,
                cache: cache,
                clientOptions: kClientOptions,
                scanOptions: host.scanOptions,
                reintentoCargaSala: const Duration(milliseconds: 50),
                clientFactory: (identity, options, rediscover) =>
                    TcpComanderoClient(
                      identity: identity,
                      options: options,
                      rediscover: rediscover,
                      random: Random(7),
                    ),
              ),
            );
            gateways.add(gateway);
            return gateway;
          }),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const ComanderoHome(),
        ),
      ),
    );

    // 1. Arranque: host manual guardado -> conexión -> mesas.
    await esperar(
      tester,
      () =>
          hay(find.byType(MesasPage)) && hay(find.byKey(const Key('mesa.m1'))),
      que: 'mesas cargadas',
    );
    expect(find.text('En línea'), findsOneWidget);

    // 2. Toma de pedido y envío con conexión.
    await tester.tap(find.byKey(const Key('mesa.m1')));
    await esperar(
      tester,
      () => hay(find.byKey(const Key('articulo.CANA'))),
      que: 'carta visible',
    );
    // Fin de la transición de la ruta antes de tocar nada.
    await tester.pump(const Duration(milliseconds: 600));
    await tester.tap(find.byKey(const Key('articulo.CANA')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('pedido.enviar')));
    await esperar(
      tester,
      () =>
          host.comandas['m1']?.lineas.length == 1 &&
          hay(find.textContaining('Enviada 1 línea')),
      que: 'comanda aceptada por el host',
    );
    final enviada = host.comandas['m1']!.lineas.single;
    expect(enviada.referencia, 'CANA');
    expect(find.byKey(Key('comanda.linea.${enviada.id}')), findsOneWidget);

    // 3. Se cae el host: el envío queda en cola y se ve como pendiente.
    await tester.runAsync(host.stop);
    await esperar(
      tester,
      () => hay(find.byKey(const Key('comandero.avisoSinConexion'))),
      que: 'aviso de sin conexión',
    );
    expect(find.byType(PedidoPage), findsOneWidget);
    await tester.tap(find.byKey(const Key('articulo.PAELLA')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('pedido.enviar')));
    await esperar(
      tester,
      () => hay(find.byKey(const Key('comandero.pendientes'))),
      que: 'envío pendiente visible',
    );
    expect(find.text('Enviando…'), findsOneWidget);
    expect(host.comandas['m1']!.lineas, hasLength(1));

    // 4. Vuelve el host: la cola sale sola y la comanda se actualiza.
    await tester.runAsync(host.start);
    await esperar(
      tester,
      () =>
          host.comandas['m1']?.lineas.length == 2 &&
          !hay(find.byKey(const Key('comandero.pendientes'))) &&
          !hay(find.text('Enviando…')) &&
          // La cola sale tras el `welcome`; el aviso, al recargar la sala.
          !hay(find.byKey(const Key('comandero.avisoSinConexion'))),
      que: 'cola enviada al reconectar',
    );
    expect(find.text('En línea'), findsOneWidget);
    expect(host.comandas['m1']!.lineas.map((l) => l.referencia), [
      'CANA',
      'PAELLA',
    ]);

    // Cierre ordenado: desmontar libera el controlador (cierra la sesión).
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      for (final gateway in gateways) {
        await gateway.dispose();
      }
      await host.dispose();
    });
  });
}
