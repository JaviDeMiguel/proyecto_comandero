import 'dart:math';
import 'dart:typed_data';

import 'package:proyecto_comandero/core/isolates/escpos/escpos_builder.dart';
import 'package:proyecto_comandero/core/isolates/escpos/escpos_decoder.dart';
import 'package:proyecto_comandero/core/isolates/escpos/raster.dart';
import 'package:test/test.dart';

const esc = 0x1B;
const gs = 0x1D;
const lf = 0x0A;

List<int> ascii(String s) => s.codeUnits;

Uint8List bytesOf(List<int> values) => Uint8List.fromList(values);

/// Imagen raster uniforme (todo negro) de [width]×[height].
RasterImage solidRaster(int width, int height) => RasterImage(
  width: width,
  height: height,
  bits: Uint8List((width ~/ 8) * height)
    ..fillRange(0, (width ~/ 8) * height, 0xFF),
);

/// Resumen legible de [elements] para comparar el orden.
List<String> describe(Iterable<DecodedElement> elements) => [
  for (final element in elements)
    switch (element) {
      ElementoTexto(:final linea) => 'texto:${linea.text}',
      ElementoImagen(:final imagen) =>
        'imagen:${imagen.width}x${imagen.height}',
      ElementoMarca(:final comando) => comando.name,
    },
];

void main() {
  group('tramos', () {
    test('prefijo normal y texto en inverso: dos tramos en una línea', () {
      final bytes =
          (EscPosBuilder(paper: PaperWidth.mm80)..lineRuns(
                const [TextRun('   > '), TextRun('sin cebolla', inverse: true)],
                bold: true,
                doubleHeight: true,
              ))
              .build();
      final decoded = decodeEscPos(bytes, strict: true);
      final line = decoded.lines.single;

      expect(line.runs.length, 2);
      expect(line.runs[0].text, '   > ');
      expect(line.runs[0].inverse, isFalse);
      expect(line.runs[0].bold, isTrue);
      expect(line.runs[0].doubleHeight, isTrue);
      expect(line.runs[1].text, 'sin cebolla');
      expect(line.runs[1].inverse, isTrue);
      expect(line.runs[1].bold, isTrue);

      expect(line.text, '   > sin cebolla');
      expect(line.inverse, isTrue);
      expect(line.bold, isTrue);
      expect(line.doubleHeight, isTrue);
      expect(line.doubleWidth, isFalse);
      expect(line.underline, isFalse);
      expect(line.printedWidth, 16);
      expect(decoded.texts, ['   > sin cebolla']);
      expect(describe(decoded.elements), ['texto:   > sin cebolla']);
    });

    test('el doble ancho cuenta doble en printedWidth', () {
      final bytes = (EscPosBuilder(
        paper: PaperWidth.mm80,
      )..line('Mesa 7', doubleWidth: true)).build();
      final line = decodeEscPos(bytes, strict: true).lines.single;
      expect(line.runs.single.printedWidth, 12);
      expect(line.printedWidth, 12);
      expect(line.doubleWidth, isTrue);
    });

    test('tramos de distinto tamaño: printedWidth suma los tramos', () {
      final bytes = bytesOf([
        esc,
        0x61,
        1,
        ...ascii('ab'),
        gs,
        0x21,
        0x10,
        ...ascii('cd'),
        gs,
        0x21,
        0,
        ...ascii('e'),
        lf,
      ]);
      final line = decodeEscPos(bytes, strict: true).lines.single;
      expect(line.runs.map((r) => r.text), ['ab', 'cd', 'e']);
      expect(line.runs.map((r) => r.doubleWidth), [false, true, false]);
      expect(line.printedWidth, 2 + 4 + 1);
      expect(line.align, 1);
      expect(line.doubleWidth, isTrue, reason: 'alguno lo tiene');
    });

    test('subrayado: atributo del tramo y comando underline', () {
      final bytes = (EscPosBuilder(
        paper: PaperWidth.mm80,
      )..line('U', underline: true)).build();
      final decoded = decodeEscPos(bytes, strict: true);
      expect(decoded.lines.single.underline, isTrue);
      expect(decoded.lines.single.runs.single.underline, isTrue);
      expect(decoded.named('underline').map((c) => c.args), [
        [1],
        [0],
      ]);
    });

    test('ESC R es charset, ESC B es beep y GS B es un atributo', () {
      final bytes =
          (EscPosBuilder(paper: PaperWidth.mm80)
                ..init()
                ..pitido(veces: 3, duracion: 4)
                ..line('x', inverse: true))
              .build();
      final decoded = decodeEscPos(bytes, strict: true);
      expect(decoded.commands.map((c) => c.name), [
        'init',
        'codepage',
        'charset',
        'beep',
      ]);
      expect(decoded.named('charset').single.args, [0]);
      expect(decoded.named('beep').single.args, [3, 4]);
      expect(decoded.lines.single.inverse, isTrue);
      expect(describe(decoded.elements), ['beep', 'texto:x']);
    });

    test('ESC @ reinicia alineación y atributos', () {
      final bytes = bytesOf([
        esc,
        0x61,
        1,
        esc,
        0x45,
        1,
        esc,
        0x2D,
        1,
        gs,
        0x21,
        0x11,
        gs,
        0x42,
        1,
        esc,
        0x40,
        ...ascii('x'),
        lf,
      ]);
      final line = decodeEscPos(bytes, strict: true).lines.single;
      expect(line.align, 0);
      expect(line.bold, isFalse);
      expect(line.underline, isFalse);
      expect(line.doubleHeight, isFalse);
      expect(line.doubleWidth, isFalse);
      expect(line.inverse, isFalse);
    });

    test('una línea vacía no tiene tramos y toma la alineación vigente', () {
      final bytes = (EscPosBuilder(
        paper: PaperWidth.mm80,
      )..line('', align: EscPosAlign.center, bold: true)).build();
      final line = decodeEscPos(bytes, strict: true).lines.single;
      expect(line.runs, isEmpty);
      expect(line.text, '');
      expect(line.align, 1);
      expect(line.bold, isFalse);
      expect(line.printedWidth, 0);
    });

    test('cajón, corte y avance son marcas en orden con el texto', () {
      final bytes =
          (EscPosBuilder(paper: PaperWidth.mm80)
                ..init()
                ..openDrawer()
                ..line('Hola')
                ..feed(2)
                ..cut())
              .build();
      final decoded = decodeEscPos(bytes, strict: true);
      expect(describe(decoded.elements), [
        'drawer',
        'texto:Hola',
        'feed',
        'cut',
      ]);
      expect(decoded.named('feed').single.args, [2]);
      expect(decoded.named('cut').single.args, [66, 3]);
      expect(decoded.named('drawer').single.args, [0, 25, 250]);
    });

    test('una marca imprime antes el texto pendiente sin LF', () {
      final bytes = bytesOf([
        ...ascii('abc'),
        esc,
        0x64,
        1,
        ...ascii('def'),
        lf,
      ]);
      final decoded = decodeEscPos(bytes, strict: true);
      expect(decoded.texts, ['abc', 'def']);
      expect(describe(decoded.elements), ['texto:abc', 'feed', 'texto:def']);
    });

    test('el texto sin LF al final se conserva como última línea', () {
      final decoded = decodeEscPos(
        (EscPosBuilder(paper: PaperWidth.mm80)..text('fin')).build(),
        strict: true,
      );
      expect(decoded.texts, ['fin']);
    });

    test('acentos y euro se recuperan de CP858', () {
      final decoded = decodeEscPos(
        (EscPosBuilder(paper: PaperWidth.mm80)..line('Jamón 12,50 €')).build(),
        strict: true,
      );
      expect(decoded.texts, ['Jamón 12,50 €']);
    });

    test('toString de líneas, tramos y comandos es legible', () {
      final decoded = decodeEscPos(
        (EscPosBuilder(paper: PaperWidth.mm80)
              ..init()
              ..line(
                'T',
                align: EscPosAlign.center,
                bold: true,
                doubleHeight: true,
                doubleWidth: true,
                underline: true,
                inverse: true,
              ))
            .build(),
        strict: true,
      );
      expect(decoded.lines.single.toString(), '[CBHWUI] "T"');
      expect(decoded.lines.single.runs.single.toString(), '[BHWUI]"T"');
      expect(decoded.commands.first.toString(), 'init[]');
      expect(decoded.commands[1].toString(), 'codepage[19]');
    });
  });

  group('raster', () {
    test('conserva los bits y la alineación de la imagen', () {
      final image = RasterImage(
        width: 16,
        height: 2,
        bits: Uint8List.fromList([0x80, 0x01, 0xFF, 0x00]),
      );
      final bytes = (EscPosBuilder(
        paper: PaperWidth.mm58,
      )..raster(image, align: EscPosAlign.right)).build();
      final decoded = decodeEscPos(bytes, strict: true);

      final raster = decoded.rasters.single;
      expect(raster.width, 16);
      expect(raster.height, 2);
      expect(raster.bits, image.bits);
      expect(raster.image, image);
      expect(raster.align, 2);
      expect(raster.isBlack(0, 0), isTrue);
      expect(raster.isBlack(1, 0), isFalse);
      expect(raster.isBlack(15, 0), isTrue);
      expect(raster.isBlack(7, 1), isTrue);
      expect(raster.isBlack(8, 1), isFalse);
      expect(raster.toString(), 'raster 16x2 align=2');
      expect(describe(decoded.elements), ['imagen:16x2']);
      expect(decoded.named('raster').single.args, [0, 2, 2]);
    });

    test('bandas consecutivas: una imagen en rasters y elements, un raster '
        'por banda en commands', () {
      final bits = Uint8List(8 * 300);
      for (var i = 0; i < bits.length; i++) {
        bits[i] = i & 0xFF;
      }
      final image = RasterImage(width: 64, height: 300, bits: bits);
      final bytes = (EscPosBuilder(
        paper: PaperWidth.mm80,
      )..raster(image)).build();
      final decoded = decodeEscPos(bytes, strict: true);

      expect(decoded.named('raster').map((c) => c.args), [
        [0, 8, 255],
        [0, 8, 45],
      ]);
      final raster = decoded.rasters.single;
      expect(raster.width, 64);
      expect(raster.height, 300);
      expect(raster.bits, bits);
      expect(raster.align, 1);
      expect(describe(decoded.elements), ['imagen:64x300']);
    });

    test('dos imágenes seguidas no se unen: hay un ESC a entre ellas', () {
      final bytes =
          (EscPosBuilder(paper: PaperWidth.mm80)
                ..raster(solidRaster(16, 1))
                ..raster(solidRaster(16, 2)))
              .build();
      final decoded = decodeEscPos(bytes, strict: true);
      expect(decoded.rasters.map((r) => r.height), [1, 2]);
      expect(describe(decoded.elements), ['imagen:16x1', 'imagen:16x2']);
    });

    test('bandas adyacentes de distinto ancho no se unen', () {
      final bytes = bytesOf([
        gs,
        0x76,
        0x30,
        0,
        1,
        0,
        1,
        0,
        0xFF,
        gs,
        0x76,
        0x30,
        0,
        2,
        0,
        1,
        0,
        0xFF,
        0xFF,
      ]);
      final decoded = decodeEscPos(bytes, strict: true);
      expect(decoded.rasters.map((r) => r.width), [8, 16]);
      expect(decoded.named('raster').length, 2);
    });

    test('una banda vacía es un comando pero no una imagen', () {
      final decoded = decodeEscPos(
        bytesOf([gs, 0x76, 0x30, 0, 0, 0, 0, 0, ...ascii('a'), lf]),
        strict: true,
      );
      expect(decoded.named('raster').single.args, [0, 0, 0]);
      expect(decoded.rasters, isEmpty);
      expect(describe(decoded.elements), ['texto:a']);
    });

    test('el texto pendiente sale antes de la imagen', () {
      final bytes = bytesOf([
        ...ascii('abc'),
        gs,
        0x76,
        0x30,
        0,
        1,
        0,
        1,
        0,
        0xFF,
        ...ascii('d'),
        lf,
      ]);
      final decoded = decodeEscPos(bytes, strict: true);
      expect(describe(decoded.elements), [
        'texto:abc',
        'imagen:8x1',
        'texto:d',
      ]);
    });

    test('el QR nativo GS ( k se registra como qr con su función', () {
      final decoded = decodeEscPos(
        (EscPosBuilder(paper: PaperWidth.mm80)..qr('https://e.es/1')).build(),
        strict: true,
      );
      expect(decoded.named('qr').map((c) => c.args.first), [
        0x41,
        0x43,
        0x45,
        0x50,
        0x51,
      ]);
      expect(decoded.named('qr').map((c) => c.args[1]).toList()[3], 14 + 3);
      expect(decoded.elements, isEmpty);
    });
  });

  group('modo tolerante', () {
    test('ESC desconocido se registra y se saltan dos bytes', () {
      final decoded = decodeEscPos(bytesOf([esc, 0x78, ...ascii('ok'), lf]));
      expect(decoded.named('desconocido').single.args, [esc, 0x78]);
      expect(decoded.texts, ['ok']);
    });

    test('GS desconocido se registra y se saltan dos bytes', () {
      final decoded = decodeEscPos(bytesOf([gs, 0x7A, 0x41, lf]));
      expect(decoded.named('desconocido').single.args, [gs, 0x7A]);
      expect(decoded.texts, ['A']);
    });

    test('GS ( con otra función y GS v sin 0 se tratan como desconocidos', () {
      final otraFuncion = decodeEscPos(
        bytesOf([gs, 0x28, 0x41, 2, 0, 0, 0, lf]),
      );
      expect(otraFuncion.named('desconocido').single.args, [gs, 0x28]);
      final rasterRaro = decodeEscPos(
        bytesOf([gs, 0x76, 0x31, 0, 1, 0, 1, 0, 0xFF, lf]),
      );
      expect(rasterRaro.named('desconocido').single.args, [gs, 0x76]);
      expect(rasterRaro.rasters, isEmpty);
    });

    test('un comando truncado al final se descarta sin lanzar', () {
      const truncados = [
        [esc],
        [esc, 0x74],
        [esc, 0x70, 0, 25],
        [esc, 0x42, 2],
        [gs],
        [gs, 0x21],
        [gs, 0x56, 66],
        [gs, 0x76, 0x30, 0, 1, 0, 2, 0, 0xFF],
        [gs, 0x76, 0x30, 0, 1],
        [gs, 0x28, 0x6B, 3, 0, 0x31],
        [gs, 0x28, 0x6B, 30, 0, 0x31, 0x50, 0x30, 0x41],
      ];
      for (final tail in truncados) {
        final decoded = decodeEscPos(bytesOf([...ascii('a'), lf, ...tail]));
        expect(decoded.texts, ['a'], reason: '$tail');
        expect(decoded.commands, isEmpty, reason: '$tail');
        expect(decoded.rasters, isEmpty, reason: '$tail');
      }
    });

    test('el texto y las bandas anteriores a un corte se conservan', () {
      final decoded = decodeEscPos(
        bytesOf([
          gs,
          0x76,
          0x30,
          0,
          1,
          0,
          1,
          0,
          0xFF,
          ...ascii('abc'),
          esc,
          0x74,
        ]),
      );
      expect(decoded.texts, ['abc']);
      expect(decoded.rasters.single.height, 1);
      expect(describe(decoded.elements), ['imagen:8x1', 'texto:abc']);
    });

    test('con bytes basura nunca lanza', () {
      final random = Random(7);
      for (var n = 0; n < 300; n++) {
        final bytes = bytesOf(List.generate(96, (_) => random.nextInt(256)));
        expect(() => decodeEscPos(bytes), returnsNormally, reason: '$bytes');
      }
      // Y con los prefijos de comando muy frecuentes.
      final prefijos = [esc, gs, lf, 0x76, 0x30, 0x28, 0x6B, 0xFF, 0x00];
      for (var n = 0; n < 300; n++) {
        final bytes = bytesOf(
          List.generate(64, (_) => prefijos[random.nextInt(prefijos.length)]),
        );
        expect(() => decodeEscPos(bytes), returnsNormally, reason: '$bytes');
      }
    });

    test('el flujo vacío decodifica a nada', () {
      final decoded = decodeEscPos(Uint8List(0));
      expect(decoded.lines, isEmpty);
      expect(decoded.commands, isEmpty);
      expect(decoded.elements, isEmpty);
    });
  });

  group('modo estricto', () {
    test('comando desconocido lanza FormatException con el byte', () {
      expect(
        () => decodeEscPos(bytesOf([esc, 0x61, 0, esc, 0x78]), strict: true),
        throwsA(
          isA<FormatException>()
              .having((e) => e.message, 'message', contains('ESC'))
              .having((e) => e.message, 'message', contains('0x78'))
              .having((e) => e.offset, 'offset', 3),
        ),
      );
      expect(
        () => decodeEscPos(bytesOf([gs, 0x7A]), strict: true),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('GS'),
          ),
        ),
      );
      expect(
        () => decodeEscPos(bytesOf([gs, 0x28, 0x41, 2, 0, 0, 0]), strict: true),
        throwsFormatException,
      );
    });

    test('comando truncado lanza FormatException con la posición', () {
      const truncados = [
        [esc],
        [esc, 0x74],
        [esc, 0x70, 0, 25],
        [gs, 0x21],
        [gs, 0x76, 0x30, 0, 1, 0, 2, 0, 0xFF],
        [gs, 0x28, 0x6B, 3, 0, 0x31],
      ];
      for (final tail in truncados) {
        expect(
          () =>
              decodeEscPos(bytesOf([...ascii('a'), lf, ...tail]), strict: true),
          throwsA(
            isA<FormatException>()
                .having((e) => e.message, 'message', contains('truncado'))
                .having((e) => e.offset, 'offset', 2),
          ),
          reason: '$tail',
        );
      }
    });

    test('todo lo que emite el builder se decodifica sin desconocidos', () {
      final bytes =
          (EscPosBuilder(paper: PaperWidth.mm80)
                ..init()
                ..openDrawer()
                ..line('Título', align: EscPosAlign.center, bold: true)
                ..banda('ESPERAR', doubleHeight: true)
                ..lineRuns(const [TextRun('a'), TextRun('b', inverse: true)])
                ..paragraph('uno dos tres')
                ..row([const Column('x', width: 10)])
                ..columns2('TOTAL', '1,00 €', doubleWidth: true)
                ..separator()
                ..raster(solidRaster(16, 2))
                ..qr('https://e.es')
                ..pitido()
                ..pulsoZumbadorCajon()
                ..feed(2)
                ..cut())
              .build();
      final decoded = decodeEscPos(bytes, strict: true);
      expect(decoded.named('desconocido'), isEmpty);
      expect(decoded.texts.first, 'Título');
      expect(decoded.lines[1].inverse, isTrue);
      expect(decoded.rasters.single.height, 2);
      expect(describe(decoded.elements).where((e) => !e.startsWith('texto')), [
        'drawer',
        'imagen:16x2',
        'beep',
        'drawer',
        'feed',
        'cut',
      ]);
    });
  });

  group('wrapColumns', () {
    test(
      'parte las líneas largas como la impresora y conserva la alineación',
      () {
        final texto = 'Ref.: TPV-${'a' * 36}'; // 46 columnas
        final bytes = (EscPosBuilder(
          paper: PaperWidth.mm80,
        )..line(texto, align: EscPosAlign.center)).build();

        final decoded = decodeEscPos(bytes, strict: true, wrapColumns: 32);
        expect(decoded.texts, ['Ref.: TPV-${'a' * 22}', 'a' * 14]);
        expect(decoded.lines.map((l) => l.align), [1, 1]);
        expect(decoded.lines.map((l) => l.printedWidth), [32, 14]);
        expect(describe(decoded.elements).length, 2);

        expect(decodeEscPos(bytes, wrapColumns: 48).texts, [texto]);
        expect(decodeEscPos(bytes).texts, [texto], reason: 'sin wrap no parte');
      },
    );

    test('una línea que llena justo el ancho no deja una línea vacía', () {
      final bytes =
          (EscPosBuilder(paper: PaperWidth.mm58)
                ..separator()
                ..line('x'))
              .build();
      final decoded = decodeEscPos(bytes, strict: true, wrapColumns: 32);
      expect(decoded.texts, ['-' * 32, 'x']);
    });

    test('en doble ancho parte a la mitad de columnas', () {
      final bytes = (EscPosBuilder(
        paper: PaperWidth.mm80,
      )..line('MESA Comedor principal', doubleWidth: true)).build();
      final decoded = decodeEscPos(bytes, strict: true, wrapColumns: 32);
      expect(decoded.texts, ['MESA Comedor pri', 'ncipal']);
      for (final line in decoded.lines) {
        expect(line.doubleWidth, isTrue);
        expect(line.printedWidth, lessThanOrEqualTo(32));
      }
    });

    test('parte un tramo conservando sus atributos', () {
      final bytes =
          (EscPosBuilder(paper: PaperWidth.mm80)..lineRuns([
                const TextRun('   > '),
                TextRun('x' * 30, inverse: true),
              ]))
              .build();
      final decoded = decodeEscPos(bytes, strict: true, wrapColumns: 32);
      expect(decoded.texts, ['   > ${'x' * 27}', 'x' * 3]);
      expect(decoded.lines[0].runs.map((r) => r.inverse), [false, true]);
      expect(decoded.lines[1].runs.single.inverse, isTrue);
    });

    test(
      'un carácter en doble ancho que no cabe pasa a la línea siguiente',
      () {
        final bytes = bytesOf([
          esc,
          0x61,
          0,
          ...ascii('abc'),
          gs,
          0x21,
          0x10,
          ...ascii('d'),
          gs,
          0x21,
          0,
          lf,
        ]);
        final decoded = decodeEscPos(bytes, strict: true, wrapColumns: 4);
        expect(decoded.texts, ['abc', 'd']);
        expect(decoded.lines[1].doubleWidth, isTrue);
      },
    );

    test('wrapColumns no positivo lanza ArgumentError', () {
      expect(
        () => decodeEscPos(Uint8List(0), wrapColumns: 0),
        throwsArgumentError,
      );
      expect(
        () => decodeEscPos(Uint8List(0), wrapColumns: -3),
        throwsArgumentError,
      );
    });
  });
}
