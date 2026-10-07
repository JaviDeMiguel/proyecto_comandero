import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proyecto_comandero/core/network/protocol/transport_messages.dart';
import 'package:proyecto_comandero/features/comandero/domain/comandero_config.dart';
import 'package:proyecto_comandero/features/comandero/domain/comandero_state.dart';
import 'package:proyecto_comandero/features/comandero/presentation/conexion_page.dart';
import 'package:proyecto_comandero/features/settings/presentation/settings_providers.dart';

import 'comandero_harness.dart';
import 'fake_comandero_gateway.dart';

void main() {
  testWidgets(
    'muestra los hosts descubiertos con nombre, IP y si piden código',
    (tester) async {
      final gateway = FakeComanderoGateway(
        state: SinHost(
          hostsEncontrados: [
            hostDescubierto(),
            hostDescubierto(
              hostId: 'host-2',
              hostName: 'Caja terraza',
              ip: '192.168.1.11',
              requiresPairing: true,
            ),
          ],
        ),
      );
      await montar(tester, const ConexionPage(), gateway: gateway);

      expect(find.text('Sin conexión'), findsWidgets);
      expect(find.text('Caja barra'), findsOneWidget);
      expect(find.text('192.168.1.10:4040'), findsOneWidget);
      expect(find.text('Caja terraza'), findsOneWidget);
      expect(find.text('192.168.1.11:4040'), findsOneWidget);
      expect(find.text('Requiere código'), findsOneWidget);
    },
  );

  testWidgets('"Buscar de nuevo" lanza la búsqueda y pinta lo encontrado', (
    tester,
  ) async {
    final gateway = FakeComanderoGateway(
      hostsDeLaRed: [hostDescubierto(hostName: 'Caja nueva')],
    );
    await montar(tester, const ConexionPage(), gateway: gateway);
    expect(find.textContaining('No se ha encontrado ningún host'), findsOne);

    await tester.tap(find.byKey(const Key('conexion.buscar')));
    await asentar(tester);

    expect(gateway.metodos(), contains('buscarHosts'));
    expect(find.text('Caja nueva'), findsOneWidget);
  });

  testWidgets('elegir un host sin código conecta y olvida el host manual', (
    tester,
  ) async {
    final host = hostDescubierto();
    final gateway = FakeComanderoGateway(
      state: SinHost(hostsEncontrados: [host]),
    );
    final repo = await montar(
      tester,
      const ConexionPage(),
      gateway: gateway,
      ajustes: ajustesPrueba(hostManual: '10.0.0.1:4040'),
    );

    await tester.tap(find.text('Caja barra'));
    await asentar(tester);

    final llamada = gateway.llamadas.last;
    expect(llamada.metodo, 'conectarDescubierto');
    expect(llamada.args, [host, null]);
    expect((await repo.load())!.red.hostManual, isNull);
    expect(find.textContaining('Conectando con Caja barra'), findsWidgets);
  });

  testWidgets('un host con código lo pide, lo guarda y conecta con él', (
    tester,
  ) async {
    final host = hostDescubierto(requiresPairing: true);
    final gateway = FakeComanderoGateway(
      state: SinHost(hostsEncontrados: [host]),
    );
    final repo = await montar(tester, const ConexionPage(), gateway: gateway);

    await tester.tap(find.text('Caja barra'));
    await tester.pumpAndSettle();
    expect(find.text('Código de Caja barra'), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('conexion.dialogoCodigo')),
      '4321',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Conectar').last);
    await asentar(tester);

    expect(gateway.llamadas.last.metodo, 'conectarDescubierto');
    expect(gateway.llamadas.last.args, [host, '4321']);
    expect((await repo.load())!.red.pairingCode, '4321');
  });

  testWidgets('la conexión manual normaliza, guarda y conecta', (tester) async {
    final gateway = FakeComanderoGateway();
    final repo = await montar(tester, const ConexionPage(), gateway: gateway);

    await tester.enterText(
      find.byKey(const Key('conexion.direccion')),
      '192.168.1.50',
    );
    await tester.enterText(find.byKey(const Key('conexion.codigo')), '9999');
    await tester.ensureVisible(
      find.byKey(const Key('conexion.conectarManual')),
    );
    await tester.tap(find.byKey(const Key('conexion.conectarManual')));
    await asentar(tester);

    expect(gateway.llamadas.last.metodo, 'conectarManual');
    expect(gateway.llamadas.last.args, ['192.168.1.50:4040', '9999']);
    final guardados = (await repo.load())!.red;
    expect(guardados.hostManual, '192.168.1.50:4040');
    expect(guardados.pairingCode, '9999');
  });

  testWidgets('una dirección manual inválida avisa y no conecta', (
    tester,
  ) async {
    final gateway = FakeComanderoGateway();
    final repo = await montar(tester, const ConexionPage(), gateway: gateway);

    await tester.enterText(
      find.byKey(const Key('conexion.direccion')),
      '1.2.3.4:99999',
    );
    await tester.ensureVisible(
      find.byKey(const Key('conexion.conectarManual')),
    );
    await tester.tap(find.byKey(const Key('conexion.conectarManual')));
    await asentar(tester);

    expect(find.textContaining('Dirección del host no válida'), findsOneWidget);
    expect(gateway.metodos(), isNot(contains('conectarManual')));
    expect((await repo.load())!.red.hostManual, isNull);
  });

  testWidgets('rechazo por código: explica, pide el código y reintenta', (
    tester,
  ) async {
    final gateway = FakeComanderoGateway(
      state: const Rechazado(
        codigo: RejectCodes.unauthorized,
        mensaje: 'Código incorrecto',
        host: kHostPrueba,
        pendientes: 1,
      ),
    );
    final repo = await montar(tester, const ConexionPage(), gateway: gateway);

    expect(find.text('Conexión rechazada'), findsOneWidget);
    expect(find.textContaining('código de emparejamiento'), findsWidgets);
    expect(find.textContaining('1 envío pendiente'), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('conexion.codigoRechazo')),
      '2468',
    );
    await tester.tap(find.byKey(const Key('conexion.reintentar')));
    await asentar(tester);

    expect(gateway.llamadas.last.metodo, 'conectar');
    expect(gateway.llamadas.last.args, [kHostPrueba, '2468']);
    expect((await repo.load())!.red.pairingCode, '2468');
  });

  testWidgets('reconectando muestra el intento y los envíos pendientes', (
    tester,
  ) async {
    final gateway = FakeComanderoGateway(
      state: const Reconectando(
        host: kHostPrueba,
        intento: 3,
        reintentoEn: Duration(seconds: 4),
        pendientes: 2,
      ),
    );
    await montar(tester, const ConexionPage(), gateway: gateway);

    expect(
      find.text('Reconectando con Caja barra (intento 3)…'),
      findsOneWidget,
    );
    expect(find.textContaining('4 segundos'), findsOneWidget);
    expect(find.textContaining('2 envíos pendientes'), findsOneWidget);
    expect(find.text('Dejar de intentarlo'), findsOneWidget);
  });

  testWidgets('desconectar pide confirmación y olvida el host manual', (
    tester,
  ) async {
    final gateway = FakeComanderoGateway(
      state: Conectado(host: kHostPrueba, sala: salaPrueba()),
    );
    final repo = await montar(
      tester,
      const ConexionPage(),
      gateway: gateway,
      ajustes: ajustesPrueba(hostManual: '192.168.1.10:4040'),
    );
    expect(find.text('Conectado a Caja barra'), findsOneWidget);

    await tester.tap(find.byKey(const Key('conexion.desconectar')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Desconectar'));
    await tester.pumpAndSettle();

    expect(gateway.metodos(), contains('desconectar'));
    expect((await repo.load())!.red.hostManual, isNull);
  });

  testWidgets('el botón de ajustes usa el callback si se proporciona', (
    tester,
  ) async {
    var abiertos = 0;
    await montar(
      tester,
      ConexionPage(onAbrirAjustes: () => abiertos++),
      gateway: FakeComanderoGateway(),
    );

    await tester.tap(find.byTooltip('Ajustes'));
    await asentar(tester);

    expect(abiertos, 1);
  });

  testWidgets('u1: el host manual cambiado en los ajustes con la página '
      'abierta se refleja en la dirección', (tester) async {
    final gateway = FakeComanderoGateway(
      config: const ComanderoConfig(
        deviceId: 'dev-1',
        deviceName: 'Móvil 1',
        hostManual: '10.0.0.2:4040',
      ),
    );
    await montar(
      tester,
      const ConexionPage(),
      gateway: gateway,
      ajustes: ajustesPrueba(hostManual: '10.0.0.2:4040'),
    );
    String direccion() => tester
        .widget<TextField>(find.byKey(const Key('conexion.direccion')))
        .controller!
        .text;
    expect(direccion(), '10.0.0.2:4040');

    final container = ProviderScope.containerOf(
      tester.element(find.byType(ConexionPage)),
    );
    await container
        .read(appSettingsProvider.notifier)
        .actualizar(
          (s) => s.copyWith(red: s.red.copyWith(hostManual: '10.0.0.9:4040')),
        );
    await asentar(tester);
    expect(direccion(), '10.0.0.9:4040');

    await container
        .read(appSettingsProvider.notifier)
        .actualizar(
          (s) => s.copyWith(red: s.red.copyWith(borrarHostManual: true)),
        );
    await asentar(tester);
    expect(direccion(), isEmpty);
  });
}
