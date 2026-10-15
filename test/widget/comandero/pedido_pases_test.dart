/// `PedidoPage` con pases y comensales (§7.10 del diseño de impresión):
/// selector de pase en la carta y en el diálogo de línea, panel agrupado por
/// pases con «MARCHAR», y comensales desde la barra superior.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proyecto_comandero/app/theme.dart';
import 'package:proyecto_comandero/core/errors/app_exception.dart';
import 'package:proyecto_comandero/core/facturascripts/catalog/catalog_models.dart';
import 'package:proyecto_comandero/core/network/discovery/udp_discovery_scanner.dart';
import 'package:proyecto_comandero/core/network/protocol/transport_messages.dart';
import 'package:proyecto_comandero/features/comandero/domain/comandero_config.dart';
import 'package:proyecto_comandero/features/comandero/domain/comandero_exceptions.dart';
import 'package:proyecto_comandero/features/comandero/domain/comandero_state.dart';
import 'package:proyecto_comandero/features/comandero/domain/pedido_en_edicion.dart';
import 'package:proyecto_comandero/features/comandero/domain/traspaso_comandero.dart';
import 'package:proyecto_comandero/features/comandero/presentation/comandero_gateway.dart';
import 'package:proyecto_comandero/features/comandero/presentation/comandero_widgets.dart';
import 'package:proyecto_comandero/features/comandero/presentation/pedido_page.dart';
import 'package:proyecto_comandero/features/comandero/presentation/providers.dart';
import 'package:proyecto_comandero/features/sala/domain/comanda.dart';
import 'package:proyecto_comandero/features/sala/domain/linea_comanda.dart';
import 'package:proyecto_comandero/features/sala/domain/marcha_pase.dart';
import 'package:proyecto_comandero/features/sala/domain/pases.dart';
import 'package:proyecto_comandero/features/sala/protocol/sala_messages.dart';
import 'package:proyecto_comandero/features/settings/data/in_memory_settings_repository.dart';
import 'package:proyecto_comandero/features/settings/presentation/settings_providers.dart';

import 'comandero_harness.dart';
import 'fake_comandero_gateway.dart';

/// Teléfono alto: el panel del pedido muestra casi todos los grupos sin
/// desplazar.
const Size kAlto = Size(420, 1400);

/// Pantalla ancha y alta: el pedido ocupa todo el alto junto a la carta.
const Size kAncho = Size(1100, 1400);

/// Pases por defecto (Primeros, Segundos, Postres), activos.
const PasesConfig kPases = PasesConfig();

void main() {
  final paella = kCatalogoPrueba.porReferencia('PAELLA')!;

  FakeComanderoGateway conectado({
    List<Comanda> comandas = const [],
    PasesConfig? pases,
  }) => FakeComanderoGateway(
    state: Conectado(
      host: kHostPrueba,
      sala: salaPrueba(comandas: comandas, pases: pases),
      catalogo: kCatalogoPrueba,
    ),
  );

  /// Caña directa, Paella de primero, dos Paellas de segundo y un Café de
  /// postre anulado.
  Comanda comandaConPases({
    List<MarchaPase> marchas = const [],
    int? comensales,
  }) => Comanda(
    id: 'c1',
    mesaId: 'm1',
    abiertaEn: kAhora,
    comensales: comensales,
    lineas: [
      lineaPrueba('x1', 'CANA'),
      lineaPrueba('x2', 'PAELLA', pase: 1),
      lineaPrueba('x3', 'PAELLA', cantidad: 2, pase: 2),
      lineaPrueba('x4', 'CAFE', pase: 3, estado: EstadoLinea.anulada),
    ],
    marchas: marchas,
  );

  Finder enPanel(Finder finder) => find.descendant(
    of: find.byKey(const Key('pedido.panel')),
    matching: finder,
  );
  Finder enCarta(String clave) => find.descendant(
    of: find.byKey(const Key('pedido.pases')),
    matching: find.byKey(Key(clave)),
  );
  Finder enDialogo(String clave) => find.descendant(
    of: find.byKey(const Key('detalle.pase')),
    matching: find.byKey(Key(clave)),
  );
  bool marcado(WidgetTester tester, Finder chip) =>
      tester.widget<ChoiceChip>(chip).selected;

  /// Texto del primer [Text] bajo la clave (el rótulo de una cabecera).
  String textoDe(WidgetTester tester, String clave) => tester
      .widget<Text>(
        find
            .descendant(of: find.byKey(Key(clave)), matching: find.byType(Text))
            .first,
      )
      .data!;

  String comensalesEnChip(WidgetTester tester) =>
      textoDe(tester, 'pedido.comensales');

  Future<void> tocar(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.tap(finder);
    await asentar(tester);
  }

  /// Cambia de pantalla (salir de la mesa o volver a entrar) sin desmontar
  /// el `ProviderScope`. Sin `pumpAndSettle`: el indicador de una marcha en
  /// curso no deja de girar.
  Future<void> irA(WidgetTester tester, Widget pantalla) async {
    tester
        .state<NavigatorState>(find.byType(Navigator))
        .pushReplacement(MaterialPageRoute<void>(builder: (_) => pantalla))
        .ignore();
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
  }

  /// [finder] se ve entero a lo ancho de la pantalla (no queda en la parte
  /// desplazada de una fila).
  bool aLaVista(WidgetTester tester, Finder finder) {
    final rect = tester.getRect(finder);
    final ancho = tester.getSize(find.byType(Scaffold).first).width;
    return rect.left >= 0 && rect.right <= ancho;
  }

  Future<void> elegirComensales(WidgetTester tester, int n) async {
    await tester.tap(find.byKey(const Key('pedido.comensales')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key('comensales-$n')));
    await tester.pumpAndSettle();
  }

  group('selector de pase', () {
    testWidgets('sin pases del host (o desactivados) no hay chips ni '
        'grupos', (tester) async {
      for (final pases in [null, const PasesConfig(activos: false)]) {
        final gateway = conectado(
          pases: pases,
          comandas: [
            Comanda(
              id: 'c1',
              mesaId: 'm1',
              abiertaEn: kAhora,
              lineas: [lineaPrueba('x1', 'CANA')],
            ),
          ],
        );
        await montar(tester, const PedidoPage(mesaId: 'm1'), gateway: gateway);

        expect(find.byKey(const Key('pedido.pases')), findsNothing);
        expect(find.byKey(const Key('pase-directo')), findsNothing);
        await tocar(tester, find.byKey(const Key('articulo.PAELLA')));
        expect(gateway.pedido('m1').lineas.single.pase, isNull);
        expect(find.byKey(const Key('carrito.pase.directo')), findsNothing);
        expect(find.byKey(const Key('comanda.pase.directo')), findsNothing);

        // El diálogo de la pulsación larga tampoco ofrece pase.
        await tester.longPress(find.byKey(const Key('articulo.CANA')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('detalle.pase')), findsNothing);
        await tester.tap(find.text('Cancelar'));
        await tester.pumpAndSettle();

        await tester.pumpWidget(const SizedBox());
        await gateway.dispose();
      }
    });

    testWidgets('con pases activos, tocar un artículo añade la línea con el '
        'pase activo', (tester) async {
      final gateway = conectado(pases: kPases);
      await montar(
        tester,
        const PedidoPage(mesaId: 'm1'),
        gateway: gateway,
        size: kAlto,
      );

      // Empieza en directo, con un chip por pase y solo el nombre.
      expect(marcado(tester, enCarta('pase-directo')), isTrue);
      for (final n in [1, 2, 3]) {
        expect(marcado(tester, enCarta('pase-$n')), isFalse);
      }
      expect(
        find.descendant(
          of: find.byKey(const Key('pedido.pases')),
          matching: find.text('Segundos'),
        ),
        findsOneWidget,
      );

      await tocar(tester, find.byKey(const Key('articulo.CANA')));
      await tocar(tester, enCarta('pase-2'));
      expect(marcado(tester, enCarta('pase-2')), isTrue);
      expect(marcado(tester, enCarta('pase-directo')), isFalse);
      await tocar(tester, find.byKey(const Key('articulo.PAELLA')));
      await tocar(tester, find.byKey(const Key('articulo.PAELLA')));
      await tocar(tester, enCarta('pase-directo'));
      await tocar(tester, find.byKey(const Key('articulo.PAELLA')));

      final lineas = gateway.pedido('m1').lineas;
      expect(lineas.map((l) => (l.articulo.referencia, l.pase, l.cantidad)), [
        ('CANA', null, 1.0),
        ('PAELLA', 2, 2.0),
        ('PAELLA', null, 1.0),
      ]);
      // El carrito se agrupa por pase: primero lo directo.
      expect(textoDe(tester, 'carrito.pase.directo'), 'Directo');
      expect(textoDe(tester, 'carrito.pase.2'), '2. Segundos');
      final y = tester.getTopLeft;
      expect(
        y(find.byKey(Key('carrito.linea.${lineas[2].id}'))).dy,
        lessThan(y(find.byKey(const Key('carrito.pase.2'))).dy),
      );

      await tocar(tester, find.byKey(const Key('pedido.enviar')));
      final comanda = gateway.sala!.comandaDeMesa('m1')!;
      expect(comanda.lineas.map((l) => l.pase), [null, 2, null]);
      expect(textoDe(tester, 'comanda.pase.2'), '2. Segundos · en espera');
      expect(find.byKey(const Key('pedido.marchar.2')), findsOneWidget);
    });

    testWidgets('el selector ocupa una sola fila, desplazable si no cabe', (
      tester,
    ) async {
      const telefono = Size(360, 640);
      final gateway = conectado(pases: kPases);
      await montar(
        tester,
        const PedidoPage(mesaId: 'm1'),
        gateway: gateway,
        size: telefono,
      );

      final directo = tester.getRect(enCarta('pase-directo'));
      for (final n in [1, 2, 3]) {
        expect(
          tester.getRect(enCarta('pase-$n')).top,
          directo.top,
          reason: 'pase-$n',
        );
      }
      // Los que no caben se alcanzan desplazando la fila.
      expect(aLaVista(tester, enCarta('pase-3')), isFalse);
      await tocar(tester, enCarta('pase-3'));
      expect(aLaVista(tester, enCarta('pase-3')), isTrue);
      expect(marcado(tester, enCarta('pase-3')), isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('buscando con el teclado abierto el selector sigue a la vista '
        'con el pase activo, y al cerrarlo la búsqueda se conserva', (
      tester,
    ) async {
      const telefono = Size(360, 640);
      tester.view
        ..devicePixelRatio = 1
        ..physicalSize = telefono;
      addTearDown(tester.view.reset);
      final gateway = conectado(pases: kPases);
      await montar(
        tester,
        const PedidoPage(mesaId: 'm1'),
        gateway: gateway,
        size: telefono,
      );
      await tocar(tester, enCarta('pase-3'));

      await tester.tap(find.byKey(const Key('pedido.buscar')));
      tester.view.viewInsets = const FakeViewPadding(bottom: 280);
      await asentar(tester);
      expect(tester.takeException(), isNull);
      // Solo la carta, pero con el pase de las líneas nuevas a la vista.
      expect(find.byKey(const Key('pedido.panel')), findsNothing);
      expect(marcado(tester, enCarta('pase-3')), isTrue);
      expect(aLaVista(tester, enCarta('pase-3')), isTrue);
      await tester.enterText(find.byKey(const Key('pedido.buscar')), 'cafe');
      await asentar(tester);
      await tocar(tester, find.byKey(const Key('articulo.CAFE')));
      expect(gateway.pedido('m1').lineas.single.pase, 3);

      // Al cerrar el teclado vuelve el pedido y la carta sigue filtrada.
      tester.view.resetViewInsets();
      await asentar(tester);
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('pedido.panel')), findsOneWidget);
      expect(find.byKey(const Key('articulo.CANA')), findsNothing);
      expect(find.byKey(const Key('articulo.CAFE')), findsOneWidget);
      expect(marcado(tester, enCarta('pase-3')), isTrue);
      expect(aLaVista(tester, enCarta('pase-3')), isTrue);
    });

    testWidgets('en un teléfono en horizontal la carta no desborda y se pide '
        'con cualquier pase', (tester) async {
      const horizontal = Size(640, 360);
      tester.view
        ..devicePixelRatio = 1
        ..physicalSize = horizontal;
      addTearDown(tester.view.reset);
      final gateway = conectado(pases: kPases);
      await montar(
        tester,
        const PedidoPage(mesaId: 'm1'),
        gateway: gateway,
        size: horizontal,
      );
      expect(tester.takeException(), isNull);

      await tocar(tester, enCarta('pase-3'));
      await tocar(tester, find.byKey(const Key('articulo.CAFE')));
      expect(gateway.pedido('m1').lineas.single.pase, 3);
      expect(tester.takeException(), isNull);
    });

    testWidgets('si el host desactiva los pases con uno elegido, las líneas '
        'nuevas van directas', (tester) async {
      final gateway = conectado(pases: kPases);
      await montar(
        tester,
        const PedidoPage(mesaId: 'm1'),
        gateway: gateway,
        size: kAlto,
      );
      await tocar(tester, enCarta('pase-2'));

      gateway.emitir(
        Conectado(
          host: kHostPrueba,
          sala: salaPrueba(pases: const PasesConfig(activos: false)),
          catalogo: kCatalogoPrueba,
        ),
      );
      await asentar(tester);
      expect(find.byKey(const Key('pedido.pases')), findsNothing);

      // Ni el toque ni la pulsación larga aplican el pase elegido antes.
      await tocar(tester, find.byKey(const Key('articulo.CANA')));
      await tester.longPress(find.byKey(const Key('articulo.PAELLA')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('detalle.pase')), findsNothing);
      await tester.tap(find.byKey(const Key('detalle.confirmar')));
      await tester.pumpAndSettle();

      expect(
        gateway.pedido('m1').lineas.map((l) => (l.articulo.referencia, l.pase)),
        [('CANA', null), ('PAELLA', null)],
      );
      expect(find.byKey(const Key('carrito.pase.2')), findsNothing);
    });

    testWidgets('el carrito ordena los pases de menor a mayor aunque se '
        'pidan al revés', (tester) async {
      final gateway = conectado(pases: kPases);
      await montar(
        tester,
        const PedidoPage(mesaId: 'm1'),
        gateway: gateway,
        size: kAlto,
      );

      await tocar(tester, enCarta('pase-2'));
      await tocar(tester, find.byKey(const Key('articulo.PAELLA')));
      await tocar(tester, enCarta('pase-1'));
      await tocar(tester, find.byKey(const Key('articulo.CAFE')));

      final [paella, cafe] = gateway.pedido('m1').lineas;
      expect((paella.pase, cafe.pase), (2, 1));
      double y(String clave) => tester.getTopLeft(find.byKey(Key(clave))).dy;
      final orden = [
        'carrito.pase.1',
        'carrito.linea.${cafe.id}',
        'carrito.pase.2',
        'carrito.linea.${paella.id}',
      ];
      for (var i = 1; i < orden.length; i++) {
        expect(y(orden[i - 1]), lessThan(y(orden[i])), reason: orden[i]);
      }
    });
  });

  group('diálogo de línea', () {
    testWidgets('la pulsación larga preselecciona el pase activo y permite '
        'cambiarlo sin cambiar el de la carta', (tester) async {
      final gateway = conectado(pases: kPases);
      await montar(tester, const PedidoPage(mesaId: 'm1'), gateway: gateway);
      await tocar(tester, enCarta('pase-2'));

      await tester.longPress(find.byKey(const Key('articulo.PAELLA')));
      await tester.pumpAndSettle();
      expect(marcado(tester, enDialogo('pase-2')), isTrue);
      await tester.tap(enDialogo('pase-3'));
      await tester.pump();
      expect(marcado(tester, enDialogo('pase-3')), isTrue);
      await tester.tap(find.byKey(const Key('detalle.mas')));
      await tester.tap(find.byKey(const Key('detalle.confirmar')));
      await tester.pumpAndSettle();

      final linea = gateway.pedido('m1').lineas.single;
      expect(linea.pase, 3);
      expect(linea.cantidad, 2);
      expect(marcado(tester, enCarta('pase-2')), isTrue);
    });

    testWidgets('el diálogo cambia el pase en una sola edición', (
      tester,
    ) async {
      final gateway = conectado(pases: kPases);
      // Línea devuelta tras un corte: cada edición le da un id nuevo, así
      // que dos ediciones seguidas perderían la segunda.
      gateway.importarPedidos([
        PedidoEnEdicion.vacio('m1')
            .conArticulo(paella, nuevoId: () => 'orig', pase: 1)
            .marcandoEnvio({'orig'}, enviando: true),
      ]);
      expect(
        gateway.pedido('m1').lineas.single.posiblementeTransmitida,
        isTrue,
      );
      await montar(
        tester,
        const PedidoPage(mesaId: 'm1'),
        gateway: gateway,
        size: kAlto,
      );

      await tester.tap(find.byKey(const Key('carrito.linea.orig')));
      await tester.pumpAndSettle();
      expect(marcado(tester, enDialogo('pase-1')), isTrue);
      await tester.tap(find.byKey(const Key('detalle.mas')));
      await tester.enterText(find.byKey(const Key('detalle.nota')), 'Sin sal');
      await tester.tap(enDialogo('pase-2'));
      await tester.pump();
      await tester.tap(find.byKey(const Key('detalle.confirmar')));
      await tester.pumpAndSettle();

      var linea = gateway.pedido('m1').lineas.single;
      expect(linea.pase, 2);
      expect(linea.cantidad, 2);
      expect(linea.nota, 'Sin sal');
      expect(linea.id, isNot('orig'));
      expect(linea.reemplazaA, 'orig');
      expect(find.textContaining('ha cambiado'), findsNothing);
      expect(enPanel(find.byKey(const Key('carrito.pase.2'))), findsOneWidget);
      expect(find.byKey(const Key('carrito.pase.1')), findsNothing);

      // Cambiar solo el pase también es una edición: vuelve a directo.
      await tester.tap(find.byKey(Key('carrito.linea.${linea.id}')));
      await tester.pumpAndSettle();
      await tester.tap(enDialogo('pase-directo'));
      await tester.pump();
      await tester.tap(find.byKey(const Key('detalle.confirmar')));
      await tester.pumpAndSettle();
      linea = gateway.pedido('m1').lineas.single;
      expect(linea.pase, isNull);
      expect((linea.cantidad, linea.nota), (2.0, 'Sin sal'));
      expect(textoDe(tester, 'carrito.pase.directo'), 'Directo');
    });

    testWidgets('con los pases desactivados el diálogo no ofrece pase y la '
        'línea lo conserva', (tester) async {
      final gateway = conectado(pases: const PasesConfig(activos: false));
      gateway.importarPedidos([
        PedidoEnEdicion.vacio('m1')
            .conArticulo(paella, nuevoId: () => 'p1', pase: 2),
      ]);
      await montar(
        tester,
        const PedidoPage(mesaId: 'm1'),
        gateway: gateway,
        size: kAlto,
      );
      // Con líneas con pase el carrito sigue agrupado.
      expect(textoDe(tester, 'carrito.pase.2'), '2. Segundos');

      await tester.tap(find.byKey(const Key('carrito.linea.p1')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('detalle.pase')), findsNothing);
      await tester.tap(find.byKey(const Key('detalle.mas')));
      await tester.tap(find.byKey(const Key('detalle.confirmar')));
      await tester.pumpAndSettle();

      final linea = gateway.pedido('m1').lineas.single;
      expect((linea.cantidad, linea.pase), (2.0, 2));
    });
  });

  group('panel por pases', () {
    testWidgets('muestra los grupos y sus estados', (tester) async {
      final gateway = conectado(
        pases: kPases,
        comandas: [
          comandaConPases(marchas: [marchaPrueba('a1', 1, automatica: true)]),
        ],
      );
      await montar(
        tester,
        const PedidoPage(mesaId: 'm1'),
        gateway: gateway,
        size: kAncho,
      );

      expect(textoDe(tester, 'comanda.pase.directo'), 'Directo');
      expect(
        textoDe(tester, 'comanda.pase.1'),
        '1. Primeros · en marcha 13:30',
      );
      expect(textoDe(tester, 'comanda.pase.2'), '2. Segundos · en espera');
      // Un pase con todas sus líneas anuladas no se puede marchar.
      expect(textoDe(tester, 'comanda.pase.3'), '3. Postres');
      expect(find.byKey(const Key('pedido.paseMenu.1')), findsOneWidget);
      expect(find.byKey(const Key('pedido.marchar.1')), findsNothing);
      expect(find.byKey(const Key('pedido.marchar.2')), findsOneWidget);
      expect(find.byKey(const Key('pedido.marchar.3')), findsNothing);
      expect(find.byKey(const Key('pedido.paseMenu.3')), findsNothing);

      // Cada línea va bajo su pase, en orden de llegada.
      double y(String clave) => tester.getTopLeft(find.byKey(Key(clave))).dy;
      final orden = [
        'comanda.pase.directo',
        'comanda.linea.x1',
        'comanda.pase.1',
        'comanda.linea.x2',
        'comanda.pase.2',
        'comanda.linea.x3',
        'comanda.pase.3',
        'comanda.linea.x4',
      ];
      for (var i = 1; i < orden.length; i++) {
        expect(y(orden[i - 1]), lessThan(y(orden[i])), reason: orden[i]);
      }
    });

    testWidgets('también con los pases desactivados si la comanda tiene '
        'líneas con pase', (tester) async {
      final gateway = conectado(
        pases: const PasesConfig(activos: false),
        comandas: [comandaConPases()],
      );
      await montar(
        tester,
        const PedidoPage(mesaId: 'm1'),
        gateway: gateway,
        size: kAlto,
      );

      expect(find.byKey(const Key('pedido.pases')), findsNothing);
      expect(textoDe(tester, 'comanda.pase.1'), '1. Primeros · en espera');
      expect(textoDe(tester, 'comanda.pase.2'), '2. Segundos · en espera');
      expect(find.byKey(const Key('pedido.marchar.1')), findsOneWidget);
      expect(find.byKey(const Key('pedido.marchar.2')), findsOneWidget);
    });

    testWidgets('un pase fuera de la configuración se rotula «n. Pase n» y '
        'se puede marchar', (tester) async {
      final gateway = conectado(
        pases: kPases,
        comandas: [
          Comanda(
            id: 'c1',
            mesaId: 'm1',
            abiertaEn: kAhora,
            lineas: [lineaPrueba('x7', 'PAELLA', pase: 7)],
          ),
        ],
      );
      await montar(
        tester,
        const PedidoPage(mesaId: 'm1'),
        gateway: gateway,
        size: kAlto,
      );
      expect(textoDe(tester, 'comanda.pase.7'), '7. Pase 7 · en espera');

      await tocar(tester, find.byKey(const Key('pedido.marchar.7')));
      expect(gateway.llamadas.last.args, ['m1', 7]);
      expect(find.text('Marchado el pase 7'), findsOneWidget);
    });

    testWidgets('sin pases, lo enviado sale de lo más reciente a lo más '
        'antiguo y sin grupos', (tester) async {
      final gateway = conectado(
        comandas: [
          Comanda(
            id: 'c1',
            mesaId: 'm1',
            abiertaEn: kAhora,
            lineas: [lineaPrueba('x1', 'CANA'), lineaPrueba('x2', 'CAFE')],
          ),
        ],
      );
      await montar(tester, const PedidoPage(mesaId: 'm1'), gateway: gateway);
      final x1 = tester.getTopLeft(find.byKey(const Key('comanda.linea.x1')));
      final x2 = tester.getTopLeft(find.byKey(const Key('comanda.linea.x2')));
      expect(x2.dy, lessThan(x1.dy));
      expect(find.byKey(const Key('comanda.pase.directo')), findsNothing);
    });
  });

  group('marchar', () {
    testWidgets('«MARCHAR» llama a marcharPase y muestra el mensaje', (
      tester,
    ) async {
      final gateway = conectado(
        pases: kPases,
        comandas: [
          comandaConPases(marchas: [marchaPrueba('a1', 1, automatica: true)]),
        ],
      );
      await montar(
        tester,
        const PedidoPage(mesaId: 'm1'),
        gateway: gateway,
        size: kAlto,
      );

      await tocar(tester, find.byKey(const Key('pedido.marchar.2')));

      expect(gateway.llamadas.last.metodo, 'marcharPase');
      expect(gateway.llamadas.last.args, ['m1', 2]);
      expect(find.text('Marchados los Segundos'), findsOneWidget);
      expect(
        textoDe(tester, 'comanda.pase.2'),
        '2. Segundos · en marcha 13:30',
      );
      expect(find.byKey(const Key('pedido.marchar.2')), findsNothing);
      expect(find.byKey(const Key('pedido.paseMenu.2')), findsOneWidget);
    });

    testWidgets('«Marchar de nuevo» vuelve a marchar un pase en marcha', (
      tester,
    ) async {
      final gateway = conectado(
        pases: kPases,
        comandas: [
          comandaConPases(marchas: [marchaPrueba('a1', 1, automatica: true)]),
        ],
      );
      await montar(
        tester,
        const PedidoPage(mesaId: 'm1'),
        gateway: gateway,
        size: kAlto,
      );

      await tester.tap(find.byKey(const Key('pedido.paseMenu.1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('pedido.marcharDeNuevo.1')));
      await tester.pumpAndSettle();

      expect(gateway.llamadas.last.args, ['m1', 1]);
      expect(find.text('Marchados de nuevo los Primeros'), findsOneWidget);
      final marchas = gateway.sala!.comandaDeMesa('m1')!.marchas;
      expect(marchas.map((m) => (m.pase, m.repetida)), [(1, false), (1, true)]);
    });

    testWidgets('sin conexión la marcha queda pendiente, no se repite y sale '
        'al reconectar', (tester) async {
      final gateway = conectado(pases: kPases, comandas: [comandaConPases()]);
      await montar(
        tester,
        const PedidoPage(mesaId: 'm1'),
        gateway: gateway,
        size: kAlto,
      );
      gateway.perderConexion();
      await asentar(tester);

      await tocar(tester, find.byKey(const Key('pedido.marchar.2')));
      expect(
        find.text(
          'Sin conexión: la marcha queda pendiente y saldrá al reconectar',
        ),
        findsOneWidget,
      );
      // Mientras espera, el pase no ofrece otro «MARCHAR».
      expect(find.byKey(const Key('pedido.marchando.2')), findsOneWidget);
      expect(find.byKey(const Key('pedido.marchar.2')), findsNothing);
      expect(find.byKey(const Key('comandero.pendientes')), findsOneWidget);
      expect(gateway.sala!.comandaDeMesa('m1')!.marchas, isEmpty);

      gateway.reconectar();
      await asentar(tester);
      // El aviso anterior se oculta con animación antes de mostrar el nuevo.
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.byKey(const Key('pedido.marchando.2')), findsNothing);
      expect(find.text('Marchados los Segundos'), findsOneWidget);
      expect(gateway.metodos().where((m) => m == 'marcharPase'), hasLength(1));
      expect(gateway.sala!.comandaDeMesa('m1')!.marchas.single.pase, 2);
      expect(find.byKey(const Key('pedido.paseMenu.2')), findsOneWidget);
    });

    testWidgets('salir de la mesa y volver con la marcha en cola no ofrece '
        'otro «MARCHAR»', (tester) async {
      final gateway = conectado(pases: kPases, comandas: [comandaConPases()]);
      await montar(
        tester,
        const PedidoPage(mesaId: 'm1'),
        gateway: gateway,
        size: kAlto,
      );
      gateway.perderConexion();
      await asentar(tester);
      await tocar(tester, find.byKey(const Key('pedido.marchar.2')));
      expect(find.byKey(const Key('pedido.marchando.2')), findsOneWidget);

      // El camarero vuelve a la lista de mesas y entra otra vez en la mesa.
      await irA(tester, const Scaffold(body: Text('Mesas')));
      expect(find.byType(PedidoPage), findsNothing);
      await irA(tester, const PedidoPage(mesaId: 'm1'));

      expect(find.byKey(const Key('pedido.marchando.2')), findsOneWidget);
      expect(find.byKey(const Key('pedido.marchar.2')), findsNothing);
      expect(gateway.pendientes, 1);

      gateway.reconectar();
      await asentar(tester);
      expect(find.byKey(const Key('pedido.marchando.2')), findsNothing);
      expect(find.byKey(const Key('pedido.paseMenu.2')), findsOneWidget);
      final marchas = gateway.sala!.comandaDeMesa('m1')!.marchas;
      expect(marchas.map((m) => (m.pase, m.repetida)), [(2, false)]);
      expect(gateway.metodos().where((m) => m == 'marcharPase'), hasLength(1));
    });

    testWidgets('unknown_type da el mensaje traducido', (tester) async {
      final gateway = conectado(pases: kPases, comandas: [comandaConPases()])
        ..errorMarchar = const RemoteRequestException(
          "Tipo 'comanda.pase.marchar' desconocido",
          code: ErrorCodes.unknownType,
        );
      await montar(
        tester,
        const PedidoPage(mesaId: 'm1'),
        gateway: gateway,
        size: kAlto,
      );

      await tocar(tester, find.byKey(const Key('pedido.marchar.2')));

      expect(find.text(kMensajeHostAntiguo), findsOneWidget);
      expect(find.textContaining('desconocido'), findsNothing);
      // El botón vuelve: el error no deja el pase bloqueado.
      expect(find.byKey(const Key('pedido.marchando.2')), findsNothing);
      expect(find.byKey(const Key('pedido.marchar.2')), findsOneWidget);
    });

    testWidgets('un rechazo del host muestra su mensaje', (tester) async {
      final gateway = conectado(pases: kPases, comandas: [comandaConPases()])
        ..errorMarchar = const ComanderoSalaException(
          'La mesa Mesa 1 no tiene líneas de Segundos',
          code: SalaErrorCodes.paseSinLineas,
          mesaId: 'm1',
        );
      await montar(
        tester,
        const PedidoPage(mesaId: 'm1'),
        gateway: gateway,
        size: kAlto,
      );

      await tocar(tester, find.byKey(const Key('pedido.marchar.2')));

      expect(
        find.text('La mesa Mesa 1 no tiene líneas de Segundos'),
        findsOneWidget,
      );
    });
  });

  group('comensales', () {
    testWidgets('con la mesa abierta se fijan con fijarComensales', (
      tester,
    ) async {
      final gateway = conectado(
        comandas: [
          Comanda(
            id: 'c1',
            mesaId: 'm1',
            abiertaEn: kAhora,
            lineas: [lineaPrueba('x1', 'CANA')],
          ),
        ],
      );
      await montar(tester, const PedidoPage(mesaId: 'm1'), gateway: gateway);
      expect(comensalesEnChip(tester), '–');

      await elegirComensales(tester, 4);

      expect(gateway.llamadas.last.metodo, 'fijarComensales');
      expect(gateway.llamadas.last.args, ['m1', 4]);
      expect(gateway.metodos(), isNot(contains('enviar')));
      expect(find.text('Mesa con 4 comensales'), findsOneWidget);
      expect(comensalesEnChip(tester), '4');

      // Al volver a abrirlo propone el valor actual; cancelar no cambia nada.
      await tester.tap(find.byKey(const Key('pedido.comensales')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('comensales-campo')))
            .controller!
            .text,
        '4',
      );
      await tester.tap(find.text('Cancelar'));
      await tester.pumpAndSettle();
      expect(gateway.metodos().where((m) => m == 'fijarComensales'), [
        'fijarComensales',
      ]);
    });

    testWidgets('con la mesa libre van en el primer enviar, nunca en un envío '
        'vacío', (tester) async {
      final espia = _GatewayEspia(conectado(pases: kPases));
      await _montarEspia(tester, espia);

      await elegirComensales(tester, 3);
      expect(espia.fake.metodos(), isEmpty);
      expect(
        find.text('Se indicarán 3 comensales con el primer envío'),
        findsOneWidget,
      );
      expect(comensalesEnChip(tester), '3');

      await tocar(tester, find.byKey(const Key('articulo.CANA')));
      await tocar(tester, find.byKey(const Key('pedido.enviar')));

      expect(espia.fake.metodos(), ['enviar']);
      expect(espia.comensalesEnviados, [3]);
      final comanda = espia.fake.sala!.comandaDeMesa('m1')!;
      expect(comanda.lineas, hasLength(1));
      expect(comanda.comensales, 3);
      expect(comensalesEnChip(tester), '3');

      // El siguiente envío ya no los lleva: los tiene la comanda.
      await tocar(tester, find.byKey(const Key('articulo.PAELLA')));
      await tocar(tester, find.byKey(const Key('pedido.enviar')));
      expect(espia.comensalesEnviados, [3, null]);
      expect(espia.fake.metodos(), isNot(contains('fijarComensales')));
    });

    testWidgets('con la mesa libre y sin conexión se ven hasta que el envío '
        'sale al reconectar', (tester) async {
      final espia = _GatewayEspia(conectado());
      await _montarEspia(tester, espia);
      espia.fake.perderConexion();
      await asentar(tester);

      await elegirComensales(tester, 1);
      expect(
        find.text('Se indicará 1 comensal con el primer envío'),
        findsOneWidget,
      );
      await tocar(tester, find.byKey(const Key('articulo.CANA')));
      await tocar(tester, find.byKey(const Key('pedido.enviar')));
      expect(espia.comensalesEnviados, [1]);
      expect(espia.fake.sala?.comandaDeMesa('m1'), isNull);
      expect(comensalesEnChip(tester), '1');

      espia.fake.reconectar();
      await asentar(tester);
      expect(espia.fake.sala!.comandaDeMesa('m1')!.comensales, 1);
      expect(comensalesEnChip(tester), '1');
    });

    testWidgets('si otro camarero abre la mesa, los pendientes se olvidan', (
      tester,
    ) async {
      final espia = _GatewayEspia(conectado());
      await _montarEspia(tester, espia);
      await elegirComensales(tester, 3);
      expect(comensalesEnChip(tester), '3');

      espia.fake.emitir(
        Conectado(
          host: kHostPrueba,
          sala: salaPrueba(
            comandas: [
              Comanda(
                id: 'c9',
                mesaId: 'm1',
                abiertaEn: kAhora,
                comensales: 2,
                lineas: [lineaPrueba('y1', 'CAFE')],
              ),
            ],
          ),
          catalogo: kCatalogoPrueba,
        ),
      );
      await asentar(tester);
      expect(comensalesEnChip(tester), '2');

      await tocar(tester, find.byKey(const Key('articulo.CANA')));
      await tocar(tester, find.byKey(const Key('pedido.enviar')));
      expect(espia.comensalesEnviados, [null]);

      // Esa comanda se cobra y la mesa vuelve a estar libre: el chip no
      // recupera los 3 de antes y el primer envío del cliente siguiente no
      // los lleva.
      espia.fake.emitir(
        Conectado(
          host: kHostPrueba,
          sala: salaPrueba(),
          catalogo: kCatalogoPrueba,
        ),
      );
      await asentar(tester);
      expect(comensalesEnChip(tester), '–');
      await tocar(tester, find.byKey(const Key('articulo.PAELLA')));
      await tocar(tester, find.byKey(const Key('pedido.enviar')));
      expect(espia.comensalesEnviados, [null, null]);
      expect(espia.fake.sala!.comandaDeMesa('m1')!.comensales, isNull);
    });

    testWidgets('mientras se fijan los comensales el chip no admite otra '
        'petición', (tester) async {
      final espia = _GatewayEspia(
        conectado(
          comandas: [
            Comanda(
              id: 'c1',
              mesaId: 'm1',
              abiertaEn: kAhora,
              lineas: [lineaPrueba('x1', 'CANA')],
            ),
          ],
        ),
      );
      final retener = espia.retenerFijar = Completer<void>();
      await _montarEspia(tester, espia);
      ActionChip chip() =>
          tester.widget<ActionChip>(find.byKey(const Key('pedido.comensales')));

      await elegirComensales(tester, 4);
      expect(chip().onPressed, isNull);
      expect(espia.fake.metodos(), isEmpty);

      retener.complete();
      await asentar(tester);
      expect(espia.fake.metodos(), ['fijarComensales']);
      expect(chip().onPressed, isNotNull);
      expect(comensalesEnChip(tester), '4');
      expect(find.text('Mesa con 4 comensales'), findsOneWidget);
    });

    testWidgets('un error al fijarlos se explica y el chip vuelve a estar '
        'disponible', (tester) async {
      // Sin host objetivo: la petición no puede ni quedar en cola.
      final gateway = FakeComanderoGateway(
        sala: salaPrueba(
          comandas: [
            Comanda(
              id: 'c1',
              mesaId: 'm1',
              abiertaEn: kAhora,
              lineas: [lineaPrueba('x1', 'CANA')],
            ),
          ],
        ),
      );
      await montar(tester, const PedidoPage(mesaId: 'm1'), gateway: gateway);

      await elegirComensales(tester, 5);

      expect(
        find.text('No se fijaron los comensales: No hay conexión con el host'),
        findsOneWidget,
      );
      expect(find.textContaining('se fijarán al reconectar'), findsNothing);
      expect(comensalesEnChip(tester), '–');
      expect(
        tester
            .widget<ActionChip>(find.byKey(const Key('pedido.comensales')))
            .onPressed,
        isNotNull,
      );
    });
  });
}

/// Monta [PedidoPage] de la mesa `m1` con el espía [espia] en lugar del
/// doble (el arnés común solo admite el doble).
Future<void> _montarEspia(WidgetTester tester, _GatewayEspia espia) async {
  await tester.binding.setSurfaceSize(kTelefono);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  addTearDown(espia.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        settingsRepositoryProvider.overrideWith(
          (ref) => InMemorySettingsRepository(initial: ajustesPrueba()),
        ),
        comanderoControllerProvider.overrideWith((ref) async => espia),
      ],
      child: MaterialApp(
        theme: AppTheme.light(),
        home: const PedidoPage(mesaId: 'm1'),
      ),
    ),
  );
  await asentar(tester);
}

/// Envoltorio del doble que además anota los comensales de cada `enviar`
/// (el doble compartido solo anota la mesa) y, como el host, los aplica a la
/// comanda que abre o actualiza el envío.
final class _GatewayEspia implements ComanderoGateway {
  _GatewayEspia(this.fake);

  final FakeComanderoGateway fake;

  /// Comensales de cada llamada a [enviar], en orden.
  final List<int?> comensalesEnviados = [];

  @override
  Future<ComandaSubmitResult> enviar(
    String mesaId, {
    String? camarero,
    int? comensales,
  }) async {
    comensalesEnviados.add(comensales);
    final result = await fake.enviar(
      mesaId,
      camarero: camarero,
      comensales: comensales,
    );
    if (comensales == null) return result;
    final comanda = result.comanda.copyWith(comensales: comensales);
    fake.emitir(
      Conectado(
        host: kHostPrueba,
        sala: fake.sala!.conComanda(mesaId, comanda, generadoEn: kAhora),
        catalogo: fake.catalogo,
      ),
    );
    return ComandaSubmitResult(
      comanda: comanda,
      lineasNuevas: result.lineasNuevas,
      lineasDuplicadas: result.lineasDuplicadas,
    );
  }

  // El resto delega en el doble.

  @override
  ComanderoConfig get config => fake.config;

  @override
  ComanderoState get state => fake.state;

  @override
  Stream<ComanderoState> get states => fake.states;

  @override
  Stream<PedidoEnEdicion> get pedidosCambiados => fake.pedidosCambiados;

  @override
  Stream<AvisoComandero> get avisos => fake.avisos;

  @override
  SalaSnapshot? get sala => fake.sala;

  @override
  CatalogSnapshot? get catalogo => fake.catalogo;

  @override
  PasesConfig? get pases => fake.pases;

  @override
  int get pendientes => fake.pendientes;

  @override
  PedidoEnEdicion pedido(String mesaId) => fake.pedido(mesaId);

  @override
  Future<bool> iniciar({Duration? timeout}) => fake.iniciar(timeout: timeout);

  @override
  Future<List<DiscoveredHost>> buscarHosts({Duration? timeout}) =>
      fake.buscarHosts(timeout: timeout);

  @override
  void conectar(HostObjetivo host, {String? pairingCode}) =>
      fake.conectar(host, pairingCode: pairingCode);

  @override
  void conectarDescubierto(DiscoveredHost host, {String? pairingCode}) =>
      fake.conectarDescubierto(host, pairingCode: pairingCode);

  @override
  void conectarManual(String hostPuerto, {String? pairingCode}) =>
      fake.conectarManual(hostPuerto, pairingCode: pairingCode);

  @override
  Future<void> desconectar() => fake.desconectar();

  @override
  void actualizarConexion({
    required String? pairingCode,
    required String? hostManual,
  }) =>
      fake.actualizarConexion(pairingCode: pairingCode, hostManual: hostManual);

  @override
  PedidoEnEdicion anadir(
    String mesaId,
    ArticuloCatalogo articulo, {
    double cantidad = 1,
    String? nota,
    int? pase,
  }) =>
      fake.anadir(mesaId, articulo, cantidad: cantidad, nota: nota, pase: pase);

  @override
  PedidoEnEdicion cambiarCantidad(
    String mesaId,
    String lineaId,
    double cantidad,
  ) => fake.cambiarCantidad(mesaId, lineaId, cantidad);

  @override
  PedidoEnEdicion cambiarNota(String mesaId, String lineaId, String? nota) =>
      fake.cambiarNota(mesaId, lineaId, nota);

  @override
  PedidoEnEdicion editarLinea(
    String mesaId,
    String lineaId, {
    required double cantidad,
    required String? nota,
    int? Function()? pase,
  }) => fake.editarLinea(
    mesaId,
    lineaId,
    cantidad: cantidad,
    nota: nota,
    pase: pase,
  );

  @override
  PedidoEnEdicion quitar(String mesaId, String lineaId) =>
      fake.quitar(mesaId, lineaId);

  @override
  PedidoEnEdicion vaciar(String mesaId) => fake.vaciar(mesaId);

  @override
  List<PedidoEnEdicion> exportarPedidos() => fake.exportarPedidos();

  @override
  int importarPedidos(Iterable<PedidoEnEdicion> pedidos) =>
      fake.importarPedidos(pedidos);

  @override
  Future<Comanda> anularLinea(
    String mesaId,
    String lineaId, {
    String? motivo,
  }) => fake.anularLinea(mesaId, lineaId, motivo: motivo);

  @override
  Future<Comanda> marcharPase(String mesaId, int pase) =>
      fake.marcharPase(mesaId, pase);

  /// Si no es `null`, [fijarComensales] espera a que se complete antes de
  /// llegar al doble, como una petición que tarda en responder.
  Completer<void>? retenerFijar;

  @override
  Future<Comanda> fijarComensales(String mesaId, int comensales) async {
    final retener = retenerFijar;
    if (retener != null) await retener.future;
    return fake.fijarComensales(mesaId, comensales);
  }

  @override
  Future<Comanda> pedirCuenta(String mesaId, {bool solicitada = true}) =>
      fake.pedirCuenta(mesaId, solicitada: solicitada);

  @override
  Future<void> refrescarSala() => fake.refrescarSala();

  @override
  Future<void> dispose() => fake.dispose();

  @override
  Future<TraspasoComandero> cerrarParaTraspaso() => fake.cerrarParaTraspaso();
}
