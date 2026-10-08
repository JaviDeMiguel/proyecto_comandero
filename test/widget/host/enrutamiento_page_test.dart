import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proyecto_comandero/core/facturascripts/catalog/catalog_models.dart';
import 'package:proyecto_comandero/features/host/domain/host_snapshot.dart';
import 'package:proyecto_comandero/features/host/presentation/enrutamiento_page.dart';
import 'package:proyecto_comandero/features/host/presentation/host_home_page.dart';
import 'package:proyecto_comandero/features/sala/domain/enrutamiento_comandas.dart';
import 'package:proyecto_comandero/features/sala/domain/linea_comanda.dart';
import 'package:proyecto_comandero/features/settings/domain/app_settings.dart';

import '../../features/host/support/host_test_support.dart'
    show catalogoConSubfamilias;
import 'support/host_harness.dart';

Finder efectivo(String codfamilia) => find.byKey(Key('efectivo-$codfamilia'));

String textoEfectivo(WidgetTester tester, String codfamilia) =>
    tester.widget<Text>(efectivo(codfamilia)).data!;

String textoOrigen(WidgetTester tester, String codfamilia) =>
    tester.widget<Text>(find.byKey(Key('origen-$codfamilia'))).data!;

/// Destino y origen de la fila de [codfamilia], p. ej. `Va a Barra · ERP`.
String fila(WidgetTester tester, String codfamilia) =>
    '${textoEfectivo(tester, codfamilia)} · ${textoOrigen(tester, codfamilia)}';

Finder segmento(String codfamilia, String texto) => find.descendant(
  of: find.byKey(Key('selector-$codfamilia')),
  matching: find.text(texto),
);

Finder get guardar => find.byKey(const Key('enrutamiento-guardar'));

bool guardarActivo(WidgetTester tester) =>
    tester.widget<ButtonStyleButton>(guardar).enabled;

AppSettings conImpresoras({
  PrinterEndpoint? cocina,
  PrinterEndpoint? barra,
  EnrutamientoComandas enrutamiento = const EnrutamientoComandas(),
}) => ajustesPrueba().copyWith(
  impresion: PrintingSettings(
    cocina: cocina,
    barra: barra,
    enrutamiento: enrutamiento,
  ),
);

void main() {
  Future<HostHarness> montar(
    WidgetTester tester, {
    AppSettings? ajustes,
    CatalogSnapshot? catalogo,
    bool sinCatalogo = false,
    Widget? home,
  }) async {
    final harness = HostHarness(
      ajustes: ajustes,
      inicial: sinCatalogo
          ? HostSnapshot(mesas: mesasPrueba)
          : snapshotPrueba(catalogo: catalogo ?? catalogoConSubfamilias()),
    );
    await harness.pump(tester, home: home ?? const EnrutamientoPage());
    // Pantalla alta para que el árbol entero quepa sin desplazarse.
    tester.view.physicalSize = const Size(1280, 2200);
    await harness.settle(tester);
    return harness;
  }

  testWidgets('muestra el árbol de familias con el destino efectivo y el '
      'estado de las impresoras', (tester) async {
    final h = await montar(
      tester,
      ajustes: conImpresoras(
        cocina: PrinterEndpoint('10.0.0.10'),
        enrutamiento: const EnrutamientoComandas(
          porFamilia: {'BEB': DestinoPreparacion.barra},
        ),
      ),
    );

    // Las subfamilias aparecen debajo de su madre, sangradas.
    final orden = [
      for (final cod in ['BEB', 'CAF', 'CER', 'COM', 'POS'])
        tester.getTopLeft(
          find.descendant(
            of: find.byKey(Key('familia-$cod')),
            matching: find.byType(Card),
          ),
        ),
    ];
    for (var i = 1; i < orden.length; i++) {
      expect(orden[i].dy, greaterThan(orden[i - 1].dy));
    }
    expect(orden[1].dx, greaterThan(orden[0].dx), reason: 'CAF ⊂ BEB');
    expect(orden[4].dx, greaterThan(orden[3].dx), reason: 'POS ⊂ COM');

    expect(fila(tester, 'BEB'), 'Va a Barra · Regla del TPV');
    expect(
      fila(tester, 'CER'),
      'Va a Barra · Heredado de Bebidas (regla del TPV)',
    );
    expect(fila(tester, 'COM'), 'Va a Cocina · Por defecto');
    expect(fila(tester, 'POS'), 'Va a Cocina · Por defecto');
    // Sin destinos en el ERP el tercer segmento es "Heredar".
    expect(segmento('BEB', 'Heredar'), findsOneWidget);
    expect(segmento('BEB', 'ERP'), findsNothing);

    expect(find.text('Cocina: 10.0.0.10:9100'), findsOneWidget);
    expect(find.text('Barra: sin impresora'), findsOneWidget);
    expect(
      find.textContaining(
        'No hay impresora de barra: lo de barra saldrá por '
        'la impresora de cocina',
      ),
      findsOneWidget,
    );
    expect(guardarActivo(tester), isFalse);
    await h.dispose(tester);
  });

  testWidgets('elegir destinos, heredar y guardar lo aplica al host', (
    tester,
  ) async {
    final h = await montar(
      tester,
      ajustes: conImpresoras(
        cocina: PrinterEndpoint('10.0.0.10'),
        barra: PrinterEndpoint('10.0.0.11'),
      ),
    );
    expect(find.textContaining('No hay impresora de barra'), findsNothing);

    await tester.tap(segmento('BEB', 'Barra'));
    await tester.pump();
    expect(
      fila(tester, 'CAF'),
      'Va a Barra · Heredado de Bebidas (regla del TPV)',
    );
    expect(guardarActivo(tester), isTrue);

    // Los cafés, en cocina; luego vuelven a heredar.
    await tester.tap(segmento('CAF', 'Cocina'));
    await tester.pump();
    expect(fila(tester, 'CAF'), 'Va a Cocina · Regla del TPV');
    await tester.tap(segmento('CAF', 'Heredar'));
    await tester.pump();
    expect(
      fila(tester, 'CAF'),
      'Va a Barra · Heredado de Bebidas (regla del TPV)',
    );

    // Destino por defecto: barra.
    await tester.tap(
      find.descendant(
        of: find.byKey(const Key('enrutamiento-defecto')),
        matching: find.text('Barra'),
      ),
    );
    await tester.pump();
    expect(fila(tester, 'COM'), 'Va a Barra · Por defecto');

    await tester.tap(guardar);
    await h.settle(tester);

    const esperado = EnrutamientoComandas(
      porFamilia: {'BEB': DestinoPreparacion.barra},
      porDefecto: DestinoPreparacion.barra,
    );
    expect(find.text('Enrutamiento guardado'), findsOneWidget);
    expect(h.runtime.settings.impresion.enrutamiento, esperado);
    expect(h.runtime.sala.enrutamiento, esperado);
    expect(guardarActivo(tester), isFalse);
    await h.dispose(tester);
  });

  testWidgets('destinos del ERP: muestra el origen, se sobrescriben con una '
      'regla del TPV y se vuelve a "ERP"; el host publica el efectivo', (
    tester,
  ) async {
    // ERP (familias.tpv_destino): Bebidas → barra, Cafés → cocina.
    final base = catalogoConSubfamilias();
    final conErp = CatalogSnapshot(
      familias: [
        for (final f in base.familias)
          FamiliaCatalogo(
            codfamilia: f.codfamilia,
            descripcion: f.descripcion,
            madre: f.madre,
            destino: switch (f.codfamilia) {
              'BEB' => 'barra',
              'CAF' => 'cocina',
              _ => null,
            },
          ),
      ],
      impuestos: base.impuestos,
      articulos: base.articulos,
      avisos: const [],
      obtenidoEn: base.obtenidoEn,
    );
    final h = await montar(
      tester,
      catalogo: conErp,
      ajustes: conImpresoras(cocina: PrinterEndpoint('10.0.0.10')),
    );

    expect(fila(tester, 'BEB'), 'Va a Barra · ERP');
    expect(fila(tester, 'CER'), 'Va a Barra · Heredado de Bebidas (ERP)');
    expect(fila(tester, 'CAF'), 'Va a Cocina · ERP');
    expect(fila(tester, 'COM'), 'Va a Cocina · Por defecto');
    // Las familias con destino en el ERP ofrecen "ERP" en vez de "Heredar".
    expect(segmento('BEB', 'ERP'), findsOneWidget);
    expect(segmento('BEB', 'Heredar'), findsNothing);
    expect(segmento('CER', 'Heredar'), findsOneWidget);
    // El aviso de impresoras tiene en cuenta los destinos del ERP.
    expect(find.textContaining('No hay impresora de barra'), findsOneWidget);

    // Regla del TPV sobre el ERP de Bebidas.
    await tester.tap(segmento('BEB', 'Cocina'));
    await tester.pump();
    expect(fila(tester, 'BEB'), 'Va a Cocina · Regla del TPV');
    expect(
      tester.widget<Text>(find.byKey(const Key('erp-sobrescrito-BEB'))).data,
      'Sobrescribe el destino del ERP (Barra)',
    );
    expect(
      fila(tester, 'CER'),
      'Va a Cocina · Heredado de Bebidas (regla del TPV)',
    );
    expect(find.textContaining('No hay impresora de barra'), findsNothing);
    expect(guardarActivo(tester), isTrue);

    // Volver al ERP deshace la regla.
    await tester.tap(segmento('BEB', 'ERP'));
    await tester.pump();
    expect(fila(tester, 'BEB'), 'Va a Barra · ERP');
    expect(find.byKey(const Key('erp-sobrescrito-BEB')), findsNothing);
    expect(guardarActivo(tester), isFalse);

    // Una regla en Comidas: el host guarda solo la regla y publica el
    // enrutamiento efectivo (reglas + ERP) a los comanderos.
    await tester.tap(segmento('COM', 'Barra'));
    await tester.pump();
    expect(
      fila(tester, 'POS'),
      'Va a Barra · Heredado de Comidas (regla del '
      'TPV)',
    );
    await tester.tap(guardar);
    await h.settle(tester);

    const reglas = EnrutamientoComandas(
      porFamilia: {'COM': DestinoPreparacion.barra},
    );
    expect(h.runtime.settings.impresion.enrutamiento, reglas);
    expect(h.runtime.sala.enrutamiento, reglas);
    expect(h.runtime.sala.snapshot().enrutamiento!.porFamilia, {
      'BEB': DestinoPreparacion.barra,
      'CER': DestinoPreparacion.barra,
      'CAF': DestinoPreparacion.cocina,
      'COM': DestinoPreparacion.barra,
      'POS': DestinoPreparacion.barra,
    });
    await h.dispose(tester);
  });

  testWidgets('sin catálogo: mensaje claro y solo el destino por defecto', (
    tester,
  ) async {
    final h = await montar(
      tester,
      sinCatalogo: true,
      ajustes: conImpresoras(
        enrutamiento: const EnrutamientoComandas(
          porFamilia: {'BEB': DestinoPreparacion.barra},
        ),
      ),
    );
    expect(find.text('No hay catálogo de FacturaScripts'), findsOneWidget);
    expect(find.byKey(const Key('enrutamiento-defecto')), findsOneWidget);
    expect(find.byKey(const Key('familia-BEB')), findsNothing);
    expect(
      find.textContaining('No hay ninguna impresora de comandas'),
      findsOneWidget,
    );
    // Las reglas guardadas se ven y se pueden quitar.
    expect(find.byKey(const Key('regla-huerfana-BEB')), findsOneWidget);
    await tester.tap(find.byTooltip('Quitar la regla'));
    await tester.pump();
    expect(find.byKey(const Key('regla-huerfana-BEB')), findsNothing);
    expect(guardarActivo(tester), isTrue);
    await h.dispose(tester);
  });

  testWidgets('se abre desde el salón y avisa al salir sin guardar', (
    tester,
  ) async {
    final h = await montar(tester, home: const HostHomePage());
    await tester.tap(find.byKey(const Key('accion-enrutamiento')));
    await h.settle(tester);
    expect(find.byType(EnrutamientoPage), findsOneWidget);

    await tester.tap(segmento('COM', 'Barra'));
    await tester.pump();
    // Botón "atrás" del sistema: pasa por el PopScope.
    await tester.binding.handlePopRoute();
    await h.settle(tester);
    expect(find.text('Cambios sin guardar'), findsOneWidget);
    await tester.tap(find.byKey(const Key('confirmar-aceptar')));
    await h.settle(tester);
    expect(find.byType(EnrutamientoPage), findsNothing);
    expect(
      h.runtime.settings.impresion.enrutamiento,
      const EnrutamientoComandas(),
    );
    await h.dispose(tester);
  });

  test('ordenarArbolFamilias no pierde familias huérfanas ni en ciclo', () {
    final arbol = ordenarArbolFamilias(const [
      FamiliaCatalogo(codfamilia: 'B', descripcion: 'B', madre: 'A'),
      FamiliaCatalogo(codfamilia: 'A', descripcion: 'A'),
      FamiliaCatalogo(codfamilia: 'H', descripcion: 'H', madre: 'NOEXISTE'),
      FamiliaCatalogo(codfamilia: 'X', descripcion: 'X', madre: 'Y'),
      FamiliaCatalogo(codfamilia: 'Y', descripcion: 'Y', madre: 'X'),
    ]);
    expect(
      [for (final f in arbol) (f.familia.codfamilia, f.nivel)],
      [('A', 0), ('B', 1), ('H', 0), ('X', 0), ('Y', 1)],
    );
  });
}
