import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proyecto_comandero/core/isolates/escpos/escpos_builder.dart'
    hide Column;
import 'package:proyecto_comandero/core/isolates/escpos/raster.dart';
import 'package:proyecto_comandero/features/host/presentation/widgets/vista_previa_escpos.dart';

/// Anchura de columna por defecto del widget.
const double anchoCaracter = 7;

Future<void> montar(
  WidgetTester tester,
  Uint8List bytes, {
  PaperWidth papel = PaperWidth.mm80,
}) {
  return tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: Center(
            child: VistaPreviaEscPos(bytes: bytes, papel: papel),
          ),
        ),
      ),
    ),
  );
}

Uint8List bytesDe(void Function(EscPosBuilder b) construir) {
  final b = EscPosBuilder(paper: PaperWidth.mm80)..init();
  construir(b);
  return b.build();
}

/// 16 × 2 puntos: primera fila negra entera, segunda con dos rachas (cuatro
/// puntos a la izquierda y dos a la derecha).
RasterImage imagenPrueba() => RasterImage(
  width: 16,
  height: 2,
  bits: Uint8List.fromList([0xFF, 0xFF, 0xF0, 0x03]),
);

Finder fondoNegro() =>
    find.byWidgetPredicate((w) => w is ColoredBox && w.color == Colors.black);

Finder imagenRaster() => find.byWidgetPredicate(
  (w) => w is CustomPaint && w.painter is RasterPainter,
);

/// La caja de papel: el `Container` blanco que envuelve el documento. Su
/// rectángulo en pantalla (`getRect`) incluye la escala con la que el widget
/// la encaja en un padre estrecho; `getSize` daría su tamaño sin escalar.
Finder cajaPapel() => find.byWidgetPredicate(
  (w) => switch (w) {
    Container(decoration: BoxDecoration(color: Colors.white)) => true,
    _ => false,
  },
);

/// Fondo negro del tramo en inverso que contiene [texto].
Finder fondoDe(String texto) =>
    find.ancestor(of: find.textContaining(texto), matching: fondoNegro());

/// Avance real de [texto] con el estilo de su `Text`, medido con un
/// [TextPainter]: el `Text` va en una caja de ancho fijo, así que su tamaño
/// en pantalla no dice cuánto ocupa el texto.
double avanceDe(WidgetTester tester, String texto) {
  final pintor = TextPainter(
    text: TextSpan(
      text: texto,
      style: tester.widget<Text>(find.text(texto)).style,
    ),
    textDirection: TextDirection.ltr,
    textScaler: TextScaler.noScaling,
  )..layout();
  final ancho = pintor.width;
  pintor.dispose();
  return ancho;
}

/// Anchura del papel de 80 mm con la columna por defecto: 48 columnas más
/// una de margen a cada lado.
final double anchoPapel80 = (PaperWidth.mm80.columns + 2) * anchoCaracter;

/// Documento que llena el ancho del papel: línea de 48 columnas, banda,
/// imagen, chips y corte.
Uint8List ticketAncho() => bytesDe(
  (b) => b
    ..line('X' * PaperWidth.mm80.columns)
    ..banda('ESPERAR')
    ..raster(imagenPrueba())
    ..openDrawer()
    ..pitido()
    ..cut(),
);

void main() {
  group('VistaPreviaEscPos', () {
    testWidgets('pinta cada línea con su alineación dentro del papel', (
      tester,
    ) async {
      await montar(
        tester,
        bytesDe(
          (b) => b
            ..line('Izquierda')
            ..line('Centro', align: EscPosAlign.center)
            ..line('Derecha', align: EscPosAlign.right, bold: true)
            ..line('Subrayada', underline: true),
        ),
      );

      final papel = find.byType(VistaPreviaEscPos);
      expect(find.text('Izquierda'), findsOneWidget);
      expect(find.text('Centro'), findsOneWidget);
      expect(find.text('Derecha'), findsOneWidget);

      // Cada carácter avanza exactamente una columna, también en negrita: se
      // mide el texto con su estilo, no la caja de ancho fijo que lo envuelve.
      expect(avanceDe(tester, 'Izquierda'), closeTo(9 * anchoCaracter, 0.01));
      expect(avanceDe(tester, 'Derecha'), closeTo(7 * anchoCaracter, 0.01));
      // Centrada en el papel; izquierda y derecha pegadas a sus márgenes.
      expect(
        tester.getCenter(find.text('Centro')).dx,
        closeTo(tester.getCenter(papel).dx, 0.5),
      );
      final margenIzquierdo =
          tester.getTopLeft(find.text('Izquierda')).dx -
          tester.getTopLeft(papel).dx;
      final margenDerecho =
          tester.getTopRight(papel).dx -
          tester.getTopRight(find.text('Derecha')).dx;
      expect(margenIzquierdo, closeTo(anchoCaracter, 0.01));
      expect(margenDerecho, closeTo(margenIzquierdo, 0.01));

      final negrita = tester.widget<Text>(find.text('Derecha'));
      expect(negrita.style?.fontWeight, FontWeight.bold);
      final subrayada = tester.widget<Text>(find.text('Subrayada'));
      expect(subrayada.style?.decoration, TextDecoration.underline);
      expect(
        tester.widget<Text>(find.text('Izquierda')).style?.fontWeight,
        FontWeight.normal,
      );
    });

    testWidgets('la nota destacada va en inverso solo en su tramo y la banda '
        'a todo el ancho', (tester) async {
      await montar(
        tester,
        bytesDe(
          (b) => b
            ..lineRuns(const [
              TextRun('   > '),
              TextRun('Sin sal', inverse: true),
            ])
            ..banda('ESPERAR'),
        ),
      );

      final nota = find.text('Sin sal');
      final prefijo = find.text('   > ');
      expect(tester.widget<Text>(nota).style?.color, Colors.white);
      expect(tester.widget<Text>(prefijo).style?.color, Colors.black);
      expect(find.ancestor(of: nota, matching: fondoNegro()), findsOneWidget);
      expect(find.ancestor(of: prefijo, matching: fondoNegro()), findsNothing);
      expect(
        tester.getSize(find.ancestor(of: nota, matching: fondoNegro())).width,
        closeTo('Sin sal'.length * anchoCaracter, 0.01),
      );
      // Los dos tramos van seguidos en la misma línea.
      expect(
        tester.getTopLeft(nota).dx,
        closeTo(tester.getTopRight(prefijo).dx, 0.01),
      );

      final banda = find.textContaining('ESPERAR');
      expect(banda, findsOneWidget);
      expect(tester.widget<Text>(banda).style?.color, Colors.white);
      expect(tester.widget<Text>(banda).style?.fontWeight, FontWeight.bold);
      final fondoBanda = find.ancestor(of: banda, matching: fondoNegro());
      expect(
        tester.getSize(fondoBanda).width,
        closeTo(PaperWidth.mm80.columns * anchoCaracter, 0.01),
      );
    });

    testWidgets('marca el corte, el cajón y el aviso sonoro en su orden', (
      tester,
    ) async {
      await montar(
        tester,
        bytesDe(
          (b) => b
            ..line('Fin del ticket')
            ..feed(2)
            ..cut()
            ..openDrawer()
            ..pitido(),
        ),
      );

      expect(find.text('corte'), findsOneWidget);
      expect(find.text('Abre el cajón'), findsOneWidget);
      expect(find.text('Aviso sonoro'), findsOneWidget);

      final yTexto = tester.getTopLeft(find.text('Fin del ticket')).dy;
      final yCorte = tester.getTopLeft(find.text('corte')).dy;
      final yCajon = tester.getTopLeft(find.text('Abre el cajón')).dy;
      final yAviso = tester.getTopLeft(find.text('Aviso sonoro')).dy;
      expect(yTexto, lessThan(yCorte));
      expect(yCorte, lessThan(yCajon));
      expect(yCajon, lessThan(yAviso));
      // El avance de dos líneas separa el texto del corte más que una línea.
      final altoLinea = tester.getSize(find.text('Fin del ticket')).height;
      expect(yCorte - yTexto, greaterThan(altoLinea * 3));
    });

    testWidgets('pinta la imagen raster escalada al ancho del papel', (
      tester,
    ) async {
      await montar(tester, bytesDe((b) => b.raster(imagenPrueba())));

      final imagen = imagenRaster();
      expect(imagen, findsOneWidget);
      final escala =
          PaperWidth.mm80.columns * anchoCaracter / PaperWidth.mm80.dots;
      final tamano = tester.getSize(imagen);
      expect(tamano.width, closeTo(16 * escala, 0.01));
      expect(tamano.height, closeTo(2 * escala, 0.01));
      // Centrada, como la imprime el builder por defecto.
      expect(
        tester.getCenter(imagen).dx,
        closeTo(tester.getCenter(find.byType(VistaPreviaEscPos)).dx, 0.5),
      );
      expect(
        (tester.widget<CustomPaint>(imagen).painter! as RasterPainter).imagen,
        imagenPrueba(),
      );
    });

    testWidgets('salta a 32 columnas en papel de 58 mm', (tester) async {
      final bytes = bytesDe((b) => b.line('A' * 40));

      await montar(tester, bytes);
      expect(find.text('A' * 40), findsOneWidget);
      final anchoPapel80 = tester.getSize(find.byType(VistaPreviaEscPos)).width;

      await montar(tester, bytes, papel: PaperWidth.mm58);
      expect(find.text('A' * 40), findsNothing);
      expect(find.text('A' * 32), findsOneWidget);
      expect(find.text('A' * 8), findsOneWidget);
      final anchoPapel58 = tester.getSize(find.byType(VistaPreviaEscPos)).width;
      expect(
        anchoPapel80 - anchoPapel58,
        closeTo((48 - 32) * anchoCaracter, 0.01),
      );
    });

    testWidgets('el doble ancho y el doble alto escalan el tramo', (
      tester,
    ) async {
      await montar(
        tester,
        bytesDe(
          (b) => b
            ..line('CD')
            ..line('AB', doubleWidth: true, doubleHeight: true),
        ),
      );

      final normal = tester.getSize(find.text('CD'));
      final escalado = find.ancestor(
        of: find.text('AB'),
        // El FittedBox del tramo, no el que encaja el papel en su padre.
        matching: find.byWidgetPredicate(
          (w) => w is FittedBox && w.fit == BoxFit.fill,
        ),
      );
      expect(escalado, findsOneWidget);
      final tamano = tester.getSize(escalado);
      expect(tamano.width, closeTo(2 * 2 * anchoCaracter, 0.01));
      expect(tamano.height, closeTo(2 * normal.height, 0.01));
    });

    testWidgets('con bytes basura no lanza y sigue pintando el papel', (
      tester,
    ) async {
      final azar = Random(7);
      final basura = Uint8List.fromList([
        0x1B,
        0x1D,
        0xFF,
        0x00,
        0x1D,
        0x76,
        0x30,
        0x00,
        0xFF,
        0xFF,
        for (var i = 0; i < 300; i++) azar.nextInt(256),
        0x1B,
      ]);

      await montar(tester, basura);

      expect(tester.takeException(), isNull);
      expect(find.byType(VistaPreviaEscPos), findsOneWidget);
    });

    testWidgets('sin bytes pinta un papel vacío', (tester) async {
      await montar(tester, Uint8List(0));

      expect(tester.takeException(), isNull);
      expect(find.byType(Text), findsNothing);
    });

    testWidgets('expone el texto completo como etiqueta semántica', (
      tester,
    ) async {
      final semantica = tester.ensureSemantics();
      await montar(
        tester,
        bytesDe(
          (b) => b
            ..line('Mesa 7')
            ..raster(imagenPrueba())
            ..cut(),
        ),
      );

      expect(
        find.bySemanticsLabel(
          RegExp(r'^Mesa 7\n\[imagen de 16×2 puntos\]\n\[corte\]$'),
        ),
        findsOneWidget,
      );
      semantica.dispose();
    });

    // El papel de 80 mm mide (48 + 2) × 7 = 350 px: en un padre más
    // estrecho se reduce a escala en lugar de desbordarse.
    for (final ancho in const [200.0, 340.0]) {
      testWidgets('en un padre de ${ancho.round()} px se reduce a escala sin '
          'desbordarse', (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: Center(
                  child: SizedBox(
                    width: ancho,
                    child: VistaPreviaEscPos(
                      bytes: ticketAncho(),
                      papel: PaperWidth.mm80,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );

        expect(tester.takeException(), isNull);
        final papel = tester.getRect(cajaPapel());
        expect(papel.width, closeTo(ancho, 0.01));
        expect(
          papel.center.dx,
          closeTo(tester.getCenter(find.byType(Scaffold)).dx, 0.5),
        );
        // A escala, la banda sigue llenando la zona imprimible.
        final margen = anchoCaracter * ancho / anchoPapel80;
        final banda = tester.getRect(fondoDe('ESPERAR'));
        expect(banda.left - papel.left, closeTo(margen, 0.01));
        expect(papel.right - banda.right, closeTo(margen, 0.01));
      });
    }

    // Un padre que impone su anchura a los hijos no estira el papel.
    final padresAnchos = <String, Widget Function(Widget hijo)>{
      'un ListView': (hijo) => ListView(children: [hijo]),
      'una Column estirada': (hijo) => SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [hijo],
        ),
      ),
    };
    for (final MapEntry(key: padre, value: envolver) in padresAnchos.entries) {
      testWidgets('en $padre conserva su anchura, va centrado y la banda '
          'llena la zona imprimible', (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: envolver(
                VistaPreviaEscPos(bytes: ticketAncho(), papel: PaperWidth.mm80),
              ),
            ),
          ),
        );

        expect(tester.takeException(), isNull);
        final papel = tester.getRect(cajaPapel());
        expect(papel.width, closeTo(anchoPapel80, 0.01));
        expect(
          papel.center.dx,
          closeTo(tester.getCenter(find.byType(Scaffold)).dx, 0.5),
        );
        // La banda llena las 48 columnas, de margen a margen del papel.
        final banda = tester.getRect(fondoDe('ESPERAR'));
        expect(
          banda.width,
          closeTo(PaperWidth.mm80.columns * anchoCaracter, 0.01),
        );
        expect(banda.left - papel.left, closeTo(anchoCaracter, 0.01));
        expect(papel.right - banda.right, closeTo(anchoCaracter, 0.01));
      });
    }
  });

  group('rachasNegras', () {
    test('devuelve una racha por tramo horizontal de puntos negros', () {
      expect(rachasNegras(imagenPrueba()), [
        (y: 0, x0: 0, x1: 16),
        (y: 1, x0: 0, x1: 4),
        (y: 1, x0: 14, x1: 16),
      ]);
    });

    test('una imagen en blanco no tiene rachas', () {
      final blanca = RasterImage(width: 24, height: 3, bits: Uint8List(9));
      expect(rachasNegras(blanca), isEmpty);
    });

    test('las rachas cruzan los límites de byte', () {
      final imagen = RasterImage(
        width: 24,
        height: 1,
        bits: Uint8List.fromList([0x01, 0xFF, 0x80]),
      );
      expect(rachasNegras(imagen), [(y: 0, x0: 7, x1: 17)]);
    });
  });

  test('RasterPainter solo repinta si cambia la imagen', () {
    final a = RasterPainter(imagenPrueba());
    final b = RasterPainter(imagenPrueba());
    final c = RasterPainter(
      RasterImage(width: 8, height: 1, bits: Uint8List.fromList([0x18])),
    );
    expect(a.shouldRepaint(b), isFalse);
    expect(a.shouldRepaint(c), isTrue);
  });

  group('RasterPainter', () {
    // Un bloque negro sólido debe salir negro opaco en todo su interior a las
    // escalas reales de la vista previa: 0,5833 px por punto (7 px por columna
    // en 80 mm) y 1,1667 (lo mismo a DPR 2). Con suavizado, los bordes que
    // comparten dos filas a coordenadas fraccionarias se componen con alfa
    // parcial y el bloque se ve gris y con bandas horizontales.
    for (final escala in const [0.5833333, 1.1666667]) {
      testWidgets('un bloque negro es negro opaco a $escala px por punto', (
        tester,
      ) async {
        const puntos = 64;
        final bits = Uint8List(puntos ~/ 8 * puntos)
          ..fillRange(0, puntos ~/ 8 * puntos, 0xFF);
        final imagen = RasterImage(width: puntos, height: puntos, bits: bits);
        final lado = (puntos * escala).floor();

        final grabador = ui.PictureRecorder();
        RasterPainter(imagen)
            .paint(Canvas(grabador), Size(puntos * escala, puntos * escala));
        final dibujo = grabador.endRecording();
        late Uint8List rgba;
        await tester.runAsync(() async {
          final foto = await dibujo.toImage(lado + 2, lado + 2);
          final datos = await foto.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          );
          rgba = datos!.buffer.asUint8List(
            datos.offsetInBytes,
            datos.lengthInBytes,
          );
          foto.dispose();
        });
        dibujo.dispose();

        var noOpacos = 0;
        for (var y = 1; y < lado - 1; y++) {
          for (var x = 1; x < lado - 1; x++) {
            if (rgba[(y * (lado + 2) + x) * 4 + 3] != 255) noOpacos++;
          }
        }
        expect(noOpacos, 0, reason: 'píxeles interiores no opacos');
      });
    }
  });
}
