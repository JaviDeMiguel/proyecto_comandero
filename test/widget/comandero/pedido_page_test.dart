import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proyecto_comandero/core/money/money.dart';
import 'package:proyecto_comandero/features/comandero/domain/comandero_state.dart';
import 'package:proyecto_comandero/features/comandero/domain/pedido_en_edicion.dart';
import 'package:proyecto_comandero/features/comandero/presentation/pedido_page.dart';
import 'package:proyecto_comandero/features/sala/domain/comanda.dart';

import 'comandero_harness.dart';
import 'fake_comandero_gateway.dart';

void main() {
  final cana = kCatalogoPrueba.porReferencia('CANA')!;
  final paella = kCatalogoPrueba.porReferencia('PAELLA')!;

  FakeComanderoGateway conectado({List<Comanda> comandas = const []}) =>
      FakeComanderoGateway(
        state: Conectado(
          host: kHostPrueba,
          sala: salaPrueba(comandas: comandas),
          catalogo: kCatalogoPrueba,
        ),
      );

  Finder enPanel(Finder finder) => find.descendant(
    of: find.byKey(const Key('pedido.panel')),
    matching: finder,
  );

  Future<void> tocarArticulo(WidgetTester tester, String referencia) async {
    await tester.tap(find.byKey(Key('articulo.$referencia')));
    await asentar(tester);
  }

  testWidgets('tocar un artículo lo añade al carrito y suma el total', (
    tester,
  ) async {
    final gateway = conectado();
    await montar(tester, const PedidoPage(mesaId: 'm1'), gateway: gateway);
    expect(find.widgetWithText(AppBar, 'Mesa 1'), findsOneWidget);
    expect(find.text('Nada por enviar'), findsOneWidget);

    await tocarArticulo(tester, 'CANA');
    await tocarArticulo(tester, 'CANA');
    await tocarArticulo(tester, 'PAELLA');

    final pedido = gateway.pedido('m1');
    expect(pedido.lineas, hasLength(2));
    expect(pedido.lineas.first.cantidad, 2);
    final total = cana.pvpCents * 2 + paella.pvpCents;
    expect(
      tester.widget<Text>(find.byKey(const Key('pedido.total'))).data,
      formatCents(total),
    );
    expect(enPanel(find.text('Caña')), findsOneWidget);
    expect(find.text('3 uds. por enviar'), findsOneWidget);
  });

  testWidgets('ENVIAR manda el carrito y la comanda pasa a "Enviado"', (
    tester,
  ) async {
    final gateway = conectado();
    await montar(tester, const PedidoPage(mesaId: 'm1'), gateway: gateway);
    await tocarArticulo(tester, 'PAELLA');

    await tester.tap(find.byKey(const Key('pedido.enviar')));
    await asentar(tester);

    expect(gateway.metodos(), contains('enviar'));
    expect(gateway.pedido('m1').estaVacio, isTrue);
    final comanda = gateway.sala!.comandaDeMesa('m1')!;
    expect(comanda.lineas.single.referencia, 'PAELLA');
    expect(
      find.byKey(Key('comanda.linea.${comanda.lineas.single.id}')),
      findsOneWidget,
    );
    expect(find.text('Enviada 1 línea a cocina'), findsOneWidget);
    expect(find.text('Nada por enviar'), findsOneWidget);
    expect(
      tester
          .widget<ButtonStyleButton>(find.byKey(const Key('pedido.enviar')))
          .onPressed,
      isNull,
    );
  });

  testWidgets('sin conexión el envío queda pendiente y sale al reconectar', (
    tester,
  ) async {
    final gateway = conectado();
    await montar(tester, const PedidoPage(mesaId: 'm1'), gateway: gateway);
    gateway.perderConexion();
    await asentar(tester);
    expect(find.byKey(const Key('comandero.avisoSinConexion')), findsOneWidget);

    await tocarArticulo(tester, 'CANA');
    await tester.tap(find.byKey(const Key('pedido.enviar')));
    await asentar(tester);

    expect(
      find.text(
        'Sin conexión: el pedido queda pendiente y se enviará al reconectar',
      ),
      findsOneWidget,
    );
    expect(enPanel(find.text('Enviando…')), findsOneWidget);
    expect(find.textContaining('1 envío pendiente'), findsOneWidget);
    expect(find.byKey(const Key('comandero.pendientes')), findsOneWidget);
    expect(gateway.sala?.comandaDeMesa('m1'), isNull);

    gateway.reconectar();
    await asentar(tester);
    // El aviso anterior se oculta con animación antes de mostrar el nuevo.
    await tester.pump(const Duration(milliseconds: 500));

    expect(enPanel(find.text('Enviando…')), findsNothing);
    expect(gateway.sala!.comandaDeMesa('m1')!.lineas, hasLength(1));
    expect(find.byKey(const Key('comandero.avisoSinConexion')), findsNothing);
    expect(find.byKey(const Key('comandero.pendientes')), findsNothing);
    expect(find.text('Enviada 1 línea a cocina'), findsOneWidget);
  });

  testWidgets('mantener pulsado permite fijar cantidad y nota', (tester) async {
    final gateway = conectado();
    await montar(tester, const PedidoPage(mesaId: 'm1'), gateway: gateway);

    await tester.longPress(find.byKey(const Key('articulo.PAELLA')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('detalle.mas')));
    await tester.tap(find.byKey(const Key('detalle.mas')));
    await tester.pump();
    expect(
      tester.widget<Text>(find.byKey(const Key('detalle.cantidad'))).data,
      '3',
    );
    await tester.enterText(find.byKey(const Key('detalle.nota')), 'Poco hecha');
    await tester.tap(find.byKey(const Key('detalle.confirmar')));
    await tester.pumpAndSettle();

    final linea = gateway.pedido('m1').lineas.single;
    expect(linea.cantidad, 3);
    expect(linea.nota, 'Poco hecha');
    expect(enPanel(find.text('Poco hecha')), findsOneWidget);
  });

  testWidgets('tocar una línea del carrito la edita', (tester) async {
    final gateway = conectado();
    await montar(tester, const PedidoPage(mesaId: 'm1'), gateway: gateway);
    await tocarArticulo(tester, 'CANA');
    final linea = gateway.pedido('m1').lineas.single;

    await tester.tap(find.byKey(Key('carrito.linea.${linea.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('detalle.mas')));
    await tester.tap(find.byKey(const Key('detalle.confirmar')));
    await tester.pumpAndSettle();

    expect(gateway.pedido('m1').lineas.single.cantidad, 2);
  });

  testWidgets('las familias filtran la carta y la búsqueda ignora tildes', (
    tester,
  ) async {
    await montar(tester, const PedidoPage(mesaId: 'm1'), gateway: conectado());
    expect(find.byKey(const Key('articulo.CANA')), findsOneWidget);
    expect(find.byKey(const Key('articulo.PAELLA')), findsOneWidget);
    expect(find.byKey(const Key('articulo.BLOQ')), findsNothing);

    await tester.tap(find.byKey(const Key('familia.PLA')));
    await asentar(tester);
    expect(find.byKey(const Key('articulo.CANA')), findsNothing);
    expect(find.byKey(const Key('articulo.PAELLA')), findsOneWidget);

    await tester.tap(find.byKey(const Key('familia.todas')));
    await tester.enterText(find.byKey(const Key('pedido.buscar')), 'CAFE');
    await asentar(tester);
    expect(find.byKey(const Key('articulo.CAFE')), findsOneWidget);
    expect(find.byKey(const Key('articulo.CANA')), findsNothing);
  });

  testWidgets('anular una línea enviada pide motivo y la tacha', (
    tester,
  ) async {
    final linea = lineaPrueba('x1', 'PAELLA');
    final gateway = conectado(
      comandas: [
        Comanda(id: 'c1', mesaId: 'm1', abiertaEn: kAhora, lineas: [linea]),
      ],
    );
    await montar(tester, const PedidoPage(mesaId: 'm1'), gateway: gateway);

    await tester.tap(find.byKey(const Key('comanda.anular.x1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Agotado'));
    await tester.pump();
    await tester.tap(find.byKey(const Key('anular.confirmar')));
    await tester.pumpAndSettle();

    expect(gateway.llamadas.last.metodo, 'anularLinea');
    expect(gateway.llamadas.last.args, ['m1', 'x1', 'Agotado']);
    expect(enPanel(find.text('Anulada: Agotado')), findsOneWidget);
    expect(find.byKey(const Key('comanda.anular.x1')), findsNothing);
  });

  testWidgets('"Pedir cuenta" la marca en la comanda', (tester) async {
    final gateway = conectado(
      comandas: [
        Comanda(
          id: 'c1',
          mesaId: 'm1',
          abiertaEn: kAhora,
          lineas: [lineaPrueba('x1', 'CAFE')],
        ),
      ],
    );
    await montar(tester, const PedidoPage(mesaId: 'm1'), gateway: gateway);

    await tester.tap(find.byKey(const Key('pedido.cuenta')));
    await asentar(tester);

    expect(gateway.sala!.comandaDeMesa('m1')!.cuentaSolicitada, isTrue);
    expect(find.text('Cuenta pedida a caja'), findsOneWidget);
    expect(find.byTooltip('Quitar petición de cuenta'), findsOneWidget);
  });

  testWidgets('en pantalla ancha el pedido y la carta van lado a lado', (
    tester,
  ) async {
    await montar(
      tester,
      const PedidoPage(mesaId: 'm1'),
      gateway: conectado(),
      size: const Size(1100, 800),
    );

    final panel = tester.getRect(find.byKey(const Key('pedido.panel')));
    final carta = tester.getRect(find.byKey(const Key('pedido.carta')));
    expect(panel.right, lessThanOrEqualTo(carta.left));
  });

  testWidgets('u3: cambiar a la vez cantidad y nota de una línea devuelta '
      'tras un corte conserva la nota', (tester) async {
    final gateway = conectado();
    gateway.importarPedidos([
      PedidoEnEdicion.vacio('m1')
          .conArticulo(cana, nuevoId: () => 'orig')
          .marcandoEnvio({'orig'}, enviando: true),
    ]);
    expect(gateway.pedido('m1').lineas.single.posiblementeTransmitida, isTrue);
    await montar(tester, const PedidoPage(mesaId: 'm1'), gateway: gateway);

    await tester.tap(find.byKey(const Key('carrito.linea.orig')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('detalle.mas')));
    await tester.enterText(find.byKey(const Key('detalle.nota')), 'Sin gluten');
    await tester.tap(find.byKey(const Key('detalle.confirmar')));
    await tester.pumpAndSettle();

    final linea = gateway.pedido('m1').lineas.single;
    expect(linea.cantidad, 2);
    expect(linea.nota, 'Sin gluten');
    expect(linea.id, isNot('orig'));
    expect(linea.reemplazaA, 'orig');
    expect(enPanel(find.text('Sin gluten')), findsOneWidget);
    expect(find.textContaining('No hay línea'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('u3: si la línea cambió mientras se editaba se explica sin '
      'ids técnicos', (tester) async {
    final gateway = conectado();
    await montar(tester, const PedidoPage(mesaId: 'm1'), gateway: gateway);
    await tocarArticulo(tester, 'CANA');
    final linea = gateway.pedido('m1').lineas.single;

    await tester.tap(find.byKey(Key('carrito.linea.${linea.id}')));
    await tester.pumpAndSettle();
    gateway.quitar('m1', linea.id);
    await tester.tap(find.byKey(const Key('detalle.mas')));
    await tester.tap(find.byKey(const Key('detalle.confirmar')));
    await tester.pumpAndSettle();

    expect(
      find.text('La línea ha cambiado mientras la editabas; vuelve a abrirla'),
      findsOneWidget,
    );
    expect(find.textContaining(linea.id), findsNothing);
    expect(gateway.pedido('m1').estaVacio, isTrue);
  });

  testWidgets('u4: en un teléfono pequeño, al buscar con el teclado abierto '
      'la carta ocupa todo el alto y no desborda', (tester) async {
    const telefono = Size(360, 640);
    tester.view
      ..devicePixelRatio = 1
      ..physicalSize = telefono;
    addTearDown(tester.view.reset);
    final gateway = conectado();
    await montar(
      tester,
      const PedidoPage(mesaId: 'm1'),
      gateway: gateway,
      size: telefono,
    );
    gateway.perderConexion();
    await asentar(tester);
    expect(find.byKey(const Key('comandero.avisoSinConexion')), findsOneWidget);

    await tester.tap(find.byKey(const Key('pedido.buscar')));
    tester.view.viewInsets = const FakeViewPadding(bottom: 280);
    await asentar(tester);

    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('pedido.panel')), findsNothing);
    expect(find.byKey(const Key('comandero.avisoSinConexion')), findsNothing);
    // El estado de la conexión sigue visible en la barra superior.
    expect(find.text('Sin conexión'), findsOneWidget);
    final carta = tester.getRect(find.byKey(const Key('pedido.carta')));
    final articulo = tester.getRect(find.byKey(const Key('articulo.CANA')));
    expect(carta.height, greaterThan(150));
    expect(articulo.bottom, lessThanOrEqualTo(carta.bottom));

    await tester.enterText(find.byKey(const Key('pedido.buscar')), 'cana');
    await asentar(tester);
    expect(find.byKey(const Key('articulo.CANA')), findsOneWidget);

    // Al cerrar el teclado vuelven el pedido y el aviso.
    FocusManager.instance.primaryFocus?.unfocus();
    tester.view.resetViewInsets();
    await asentar(tester);
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('pedido.panel')), findsOneWidget);
    expect(find.byKey(const Key('comandero.avisoSinConexion')), findsOneWidget);
  });

  testWidgets('u5: "Vaciar lo no enviado" se puede deshacer', (tester) async {
    final gateway = conectado();
    await montar(tester, const PedidoPage(mesaId: 'm1'), gateway: gateway);
    await tocarArticulo(tester, 'CANA');
    await tocarArticulo(tester, 'CANA');
    gateway.cambiarNota('m1', gateway.pedido('m1').lineas.single.id, 'Fría');
    await tocarArticulo(tester, 'PAELLA');
    final antes = gateway.pedido('m1').lineas;
    expect(antes, hasLength(2));

    await tester.tap(find.byTooltip('Vaciar lo no enviado'));
    await asentar(tester);
    expect(gateway.pedido('m1').estaVacio, isTrue);
    expect(find.text('Se han quitado 2 líneas sin enviar'), findsOneWidget);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('pedido.deshacerVaciar')));
    await asentar(tester);
    expect(gateway.pedido('m1').lineas, antes);
    expect(enPanel(find.text('Fría')), findsOneWidget);
    expect(find.text('3 uds. por enviar'), findsOneWidget);
  });

  testWidgets('u5: el aviso de "Vaciar" desaparece solo', (tester) async {
    final gateway = conectado();
    await montar(tester, const PedidoPage(mesaId: 'm1'), gateway: gateway);
    await tocarArticulo(tester, 'CANA');

    await tester.tap(find.byTooltip('Vaciar lo no enviado'));
    await asentar(tester);
    expect(find.text('Se ha quitado 1 línea sin enviar'), findsOneWidget);
    await tester.pumpAndSettle(); // termina la animación de entrada
    await tester.pump(const Duration(seconds: 7));
    await tester.pumpAndSettle();
    expect(find.text('Se ha quitado 1 línea sin enviar'), findsNothing);
    expect(gateway.pedido('m1').estaVacio, isTrue);
  });
}
