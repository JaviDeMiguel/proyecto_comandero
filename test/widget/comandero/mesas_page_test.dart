import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proyecto_comandero/core/money/money.dart';
import 'package:proyecto_comandero/features/comandero/domain/comandero_state.dart';
import 'package:proyecto_comandero/features/comandero/presentation/mesas_page.dart';
import 'package:proyecto_comandero/features/comandero/presentation/pedido_page.dart';
import 'package:proyecto_comandero/features/sala/domain/comanda.dart';
import 'package:proyecto_comandero/features/sala/domain/mesa.dart';

import 'comandero_harness.dart';
import 'fake_comandero_gateway.dart';

void main() {
  final comandaM1 = Comanda(
    id: 'c1',
    mesaId: 'm1',
    abiertaEn: kAhora,
    lineas: [lineaPrueba('a', 'CANA', cantidad: 2), lineaPrueba('b', 'PAELLA')],
  );
  final comandaM2 = Comanda(
    id: 'c2',
    mesaId: 'm2',
    abiertaEn: kAhora,
    lineas: [lineaPrueba('c', 'CAFE')],
    cuentaSolicitada: true,
  );

  Finder enMesa(String mesaId, Finder finder) =>
      find.descendant(of: find.byKey(Key('mesa.$mesaId')), matching: finder);

  testWidgets('pinta las mesas por zona con su estado e importe', (
    tester,
  ) async {
    final gateway = FakeComanderoGateway(
      state: Conectado(
        host: kHostPrueba,
        sala: salaPrueba(comandas: [comandaM1, comandaM2]),
        catalogo: kCatalogoPrueba,
      ),
    );
    await montar(tester, const MesasPage(), gateway: gateway);

    expect(find.text('Salón'), findsOneWidget);
    expect(find.text('Barra'), findsWidgets); // zona y nombre de la mesa
    expect(enMesa('m1', find.text('Ocupada')), findsOneWidget);
    expect(
      enMesa('m1', find.text(formatCents(comandaM1.importeCents))),
      findsOneWidget,
    );
    expect(enMesa('m2', find.text('Cuenta pedida')), findsOneWidget);
    expect(enMesa('b1', find.text('Libre')), findsOneWidget);
    expect(find.text('En línea'), findsOneWidget);
    expect(find.byKey(const Key('comandero.avisoSinConexion')), findsNothing);
  });

  testWidgets('refleja los cambios de sala que llegan del host', (
    tester,
  ) async {
    final gateway = FakeComanderoGateway(
      state: Conectado(host: kHostPrueba, sala: salaPrueba()),
    );
    await montar(tester, const MesasPage(), gateway: gateway);
    expect(enMesa('m1', find.text('Libre')), findsOneWidget);

    gateway.emitir(
      Conectado(
        host: kHostPrueba,
        sala: salaPrueba(comandas: [comandaM1]),
      ),
    );
    await asentar(tester);

    expect(enMesa('m1', find.text('Ocupada')), findsOneWidget);
  });

  testWidgets('sin conexión avisa y muestra los envíos pendientes', (
    tester,
  ) async {
    final gateway = FakeComanderoGateway(
      state: Conectado(host: kHostPrueba, sala: salaPrueba()),
    );
    await montar(tester, const MesasPage(), gateway: gateway);

    gateway.emitir(
      const Reconectando(
        host: kHostPrueba,
        intento: 2,
        reintentoEn: Duration(seconds: 1),
        pendientes: 2,
      ),
    );
    await asentar(tester);

    expect(find.byKey(const Key('comandero.avisoSinConexion')), findsOneWidget);
    expect(find.textContaining('2 envíos pendientes'), findsOneWidget);
    expect(find.byKey(const Key('comandero.pendientes')), findsOneWidget);
    // La sala se conserva para seguir trabajando.
    expect(find.byKey(const Key('mesa.m1')), findsOneWidget);
  });

  testWidgets('las líneas sin enviar del carrito se ven en la mesa', (
    tester,
  ) async {
    final gateway = FakeComanderoGateway(
      state: Conectado(host: kHostPrueba, sala: salaPrueba()),
    );
    await montar(tester, const MesasPage(), gateway: gateway);

    gateway.anadir('m2', kCatalogoPrueba.porReferencia('CAFE')!);
    await asentar(tester);

    expect(enMesa('m2', find.text('1 línea sin enviar')), findsOneWidget);
  });

  testWidgets('tocar una mesa abre su pedido', (tester) async {
    final gateway = FakeComanderoGateway(
      state: Conectado(
        host: kHostPrueba,
        sala: salaPrueba(),
        catalogo: kCatalogoPrueba,
      ),
    );
    await montar(tester, const MesasPage(), gateway: gateway);

    await tester.tap(find.byKey(const Key('mesa.m2')));
    await tester.pumpAndSettle();

    expect(find.byType(PedidoPage), findsOneWidget);
    expect(find.widgetWithText(AppBar, 'Mesa 2'), findsOneWidget);
  });

  for (final escala in [1.3, 1.5, 2.0]) {
    testWidgets('u6: con letra del sistema al ${(escala * 100).round()} % '
        'la tarjeta de mesa no desborda', (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = escala;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final gateway = FakeComanderoGateway(
        state: Conectado(
          host: kHostPrueba,
          sala: salaPrueba(comandas: [comandaM1, comandaM2]),
          catalogo: kCatalogoPrueba,
        ),
      );
      gateway.anadir('m2', kCatalogoPrueba.porReferencia('CANA')!);
      await montar(
        tester,
        const MesasPage(),
        gateway: gateway,
        size: const Size(360, 640),
      );

      expect(tester.takeException(), isNull);
      expect(enMesa('m2', find.text('1 línea sin enviar')), findsOneWidget);
      expect(enMesa('m2', find.text('Cuenta pedida')), findsOneWidget);
    });
  }

  test('mesasPorZona agrupa en orden de aparición y ordena por orden', () {
    final zonas = mesasPorZona(const [
      Mesa(id: 't2', nombre: 'T2', zona: 'Terraza', orden: 2),
      Mesa(id: 's1', nombre: 'S1', orden: 1),
      Mesa(id: 't1', nombre: 'T1', zona: 'Terraza', orden: 1),
    ]);

    expect([for (final z in zonas) z.zona], ['Terraza', 'Salón']);
    expect([for (final m in zonas.first.mesas) m.id], ['t1', 't2']);
  });
}
