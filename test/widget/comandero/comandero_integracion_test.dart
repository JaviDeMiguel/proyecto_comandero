/// Las pantallas del comandero con el [ComanderoController] REAL contra un
/// [TcpHostServer] real en loopback ([FakeSalaHost]).
///
/// La red es E/S real: se alterna `tester.runAsync` (deja correr el bucle de
/// eventos de verdad) con `tester.pump` (avanza el reloj simulado de la
/// prueba, donde viven los temporizadores del cliente) hasta que se cumple
/// la condición esperada.
library;

import 'dart:async';
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
import 'package:proyecto_comandero/features/sala/domain/pases.dart';
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

/// Texto del primer [Text] bajo la clave (el rótulo de una cabecera o de un
/// chip).
String textoDe(WidgetTester tester, String clave) => tester
    .widget<Text>(
      find
          .descendant(of: find.byKey(Key(clave)), matching: find.byType(Text))
          .first,
    )
    .data!;

/// La aplicación del comandero con el controlador REAL, que se conecta a
/// [host] como host manual guardado en los ajustes. Cada controlador creado
/// se añade a [gateways] para liberarlo al final.
Widget appComandero(FakeSalaHost host, List<ComanderoGateway> gateways) =>
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
      child: MaterialApp(theme: AppTheme.light(), home: const ComanderoHome()),
    );

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
    await tester.pumpWidget(appComandero(host, gateways));

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
    // Un host antiguo no publica pases: no hay selector.
    expect(find.byKey(const Key('pedido.pases')), findsNothing);
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

  testWidgets('pide con pases y comensales, marcha y al reconectar no '
      'duplica la marcha', (tester) async {
    // Teléfono alto: todos los grupos del pedido caben sin desplazar.
    await tester.binding.setSurfaceSize(const Size(420, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    const pases = PasesConfig();

    final antiguo = (await tester.runAsync(
      () async => FakeSalaHost(tcpPort: await freeTcpPort(), pases: pases),
    ))!;
    await tester.runAsync(antiguo.start);
    var host = antiguo;
    final gateways = <ComanderoGateway>[];
    await tester.pumpWidget(appComandero(host, gateways));

    // 1. La carta de la mesa libre ofrece los pases del host.
    await esperar(
      tester,
      () => hay(find.byKey(const Key('mesa.m1'))),
      que: 'mesas cargadas',
    );
    await tester.tap(find.byKey(const Key('mesa.m1')));
    await esperar(
      tester,
      () => hay(find.byKey(const Key('pase-2'))),
      que: 'selector de pase',
    );
    await tester.pump(const Duration(milliseconds: 600));

    // 2. Comensales con la mesa libre: todavía no sale nada hacia el host.
    await tester.tap(find.byKey(const Key('pedido.comensales')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byKey(const Key('comensales-4')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(host.submits, isEmpty);
    expect(textoDe(tester, 'pedido.comensales'), '4');

    // 3. Caña directa, Paella de primero y Café de segundo en un envío, que
    //    lleva también los comensales.
    await tester.tap(find.byKey(const Key('articulo.CANA')));
    await tester.pump();
    // Los pases van en una fila que se desplaza si no caben a lo ancho.
    await tester.ensureVisible(find.byKey(const Key('pase-1')));
    await tester.tap(find.byKey(const Key('pase-1')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('articulo.PAELLA')));
    await tester.pump();
    await tester.ensureVisible(find.byKey(const Key('pase-2')));
    await tester.tap(find.byKey(const Key('pase-2')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('articulo.CAFE')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('pedido.enviar')));
    await esperar(
      tester,
      () =>
          host.comandas['m1']?.lineas.length == 3 &&
          hay(find.byKey(const Key('pedido.marchar.2'))),
      que: 'comanda con pases aceptada',
    );
    final submit = host.submits.single;
    expect(submit.lineas.map((l) => (l.referencia, l.pase)), [
      ('CANA', null),
      ('PAELLA', 1),
      ('CAFE', 2),
    ]);
    expect(submit.comensales, 4);
    final comanda = host.comandas['m1']!;
    expect(comanda.comensales, 4);
    // El host marcha solo el primer pase al enviar (`marcharAlEnviar`).
    expect(comanda.marchas.map((m) => (m.pase, m.automatica)), [(1, true)]);
    expect(
      textoDe(tester, 'comanda.pase.1'),
      startsWith('1. Primeros · en marcha'),
    );
    expect(textoDe(tester, 'comanda.pase.2'), '2. Segundos · en espera');
    expect(textoDe(tester, 'pedido.comensales'), '4');

    // 4. El host registra la marcha del segundo pase, pero su respuesta no
    //    llega...
    final retener = antiguo.retenerMarchar = Completer<void>();
    await tester.tap(find.byKey(const Key('pedido.marchar.2')));
    await esperar(
      tester,
      () => antiguo.marchas.isNotEmpty,
      que: 'el host registra la marcha',
    );
    expect(find.byKey(const Key('pedido.marchando.2')), findsOneWidget);
    final enviada = antiguo.marchasRecibidas.single;

    // ... y se reinicia: pierde la caché de respuestas del transporte pero
    // conserva el diario (la comanda con la marcha).
    final diario = Map.of(antiguo.comandas);
    await tester.runAsync(antiguo.server.stop);
    retener.complete();
    await esperar(
      tester,
      () => hay(find.byKey(const Key('comandero.avisoSinConexion'))),
      que: 'aviso de sin conexión',
    );
    // La marcha sigue pendiente: no se ofrece otro «MARCHAR».
    expect(find.byKey(const Key('pedido.marchar.2')), findsNothing);
    host = (await tester.runAsync(() async {
      final nuevo = FakeSalaHost(tcpPort: antiguo.tcpPort, pases: pases)
        ..comandas.addAll(diario);
      await nuevo.start();
      return nuevo;
    }))!;

    // 5. Al reconectar, la cola retransmite la misma marcha (mismo
    //    marchaId) y el host la reconoce por su diario: no la repite.
    await esperar(
      tester,
      () =>
          hay(find.text('Marchados los Segundos')) &&
          !hay(find.byKey(const Key('pedido.marchando.2'))),
      que: 'marcha confirmada tras reconectar',
    );
    final retransmitida = host.marchasRecibidas.single;
    expect(retransmitida.marchaId, enviada.marchaId);
    expect(retransmitida.comandaId, comanda.id);
    expect(
      host.marchas,
      isEmpty,
      reason: 'ya estaba en el diario: ni se repite ni se reimprime',
    );
    expect(host.comandas['m1']!.marchas.map((m) => m.pase), [1, 2]);
    expect(
      textoDe(tester, 'comanda.pase.2'),
      startsWith('2. Segundos · en marcha'),
    );
    expect(find.byKey(const Key('pedido.paseMenu.2')), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      for (final gateway in gateways) {
        await gateway.dispose();
      }
      await host.dispose();
      await antiguo.dispose();
    });
  });
}
