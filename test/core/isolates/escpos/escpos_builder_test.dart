import 'dart:convert';
import 'dart:typed_data';

import 'package:proyecto_comandero/core/errors/app_exception.dart';
import 'package:proyecto_comandero/core/isolates/escpos/cp858.dart';
import 'package:proyecto_comandero/core/isolates/escpos/escpos_builder.dart';
import 'package:proyecto_comandero/core/isolates/escpos/raster.dart';
import 'package:test/test.dart';

import 'escpos_decoder.dart';

const esc = 0x1B;
const gs = 0x1D;
const lf = 0x0A;

List<int> ascii(String s) => s.codeUnits;

/// Imagen raster uniforme (todo negro) de [width]×[height].
RasterImage solidRaster(int width, int height) => RasterImage(
  width: width,
  height: height,
  bits: Uint8List((width ~/ 8) * height)
    ..fillRange(0, (width ~/ 8) * height, 0xFF),
);

void main() {
  group('PaperWidth', () {
    test('columnas y puntos por anchura', () {
      expect(PaperWidth.mm58.columns, 32);
      expect(PaperWidth.mm58.dots, 384);
      expect(PaperWidth.mm80.columns, 48);
      expect(PaperWidth.mm80.dots, 576);
      expect(PaperWidth.mm80Dpi180.columns, 42);
      expect(PaperWidth.mm80Dpi180.dots, 512);
    });

    test('resolución, etiqueta y puntos por milímetro', () {
      expect(PaperWidth.mm58.dpi, 203);
      expect(PaperWidth.mm80.dpi, 203);
      expect(PaperWidth.mm80Dpi180.dpi, 180);
      expect(PaperWidth.mm58.etiqueta, '58 mm');
      expect(PaperWidth.mm80.etiqueta, '80 mm');
      expect(PaperWidth.mm80Dpi180.etiqueta, '80 mm (180 ppp)');
      expect(PaperWidth.mm80.puntosPorMm, closeTo(7.99, 0.005));
      expect(PaperWidth.mm80Dpi180.puntosPorMm, closeTo(7.09, 0.005));
      expect(PaperWidth.values.map((p) => p.name), [
        'mm58',
        'mm80',
        'mm80Dpi180',
      ]);
    });

    test('a 180 ppp el doble ancho dispone de 21 columnas', () {
      final b = EscPosBuilder(paper: PaperWidth.mm80Dpi180);
      expect(b.columnsFor(), 42);
      expect(b.columnsFor(doubleWidth: true), 21);
      expect(
        decodeEscPos((b..separator()).build()).lines.single.text.runes.length,
        42,
      );
    });
  });

  group('EscPosBuilder secuencias exactas', () {
    test('init = ESC @ + ESC t 19 (CP858) + ESC R 0 (EE. UU.)', () {
      final bytes = (EscPosBuilder(paper: PaperWidth.mm80)..init()).build();
      expect(bytes, [esc, 0x40, esc, 0x74, 19, esc, 0x52, 0]);
      final decoded = decodeEscPos(bytes);
      expect(decoded.commands.map((c) => c.name), [
        'init',
        'codepage',
        'charset',
      ]);
      expect(decoded.commands[1].args, [19]);
      expect(decoded.commands[2].args, [0]);
    });

    test('build() sin llamadas devuelve vacío y es una copia', () {
      final b = EscPosBuilder(paper: PaperWidth.mm58);
      expect(b.build(), isEmpty);
      final first = (b..line('a')).build();
      b.line('b');
      expect(first, [esc, 0x61, 0, 0x61, lf]);
    });

    test('text sin atributos: solo alineación y bytes', () {
      final bytes = (EscPosBuilder(
        paper: PaperWidth.mm80,
      )..text('Hola')).build();
      expect(bytes, [esc, 0x61, 0, ...ascii('Hola')]);
    });

    test('text con alineación centrada y derecha', () {
      expect(
        (EscPosBuilder(
          paper: PaperWidth.mm80,
        )..text('x', align: EscPosAlign.center)).build(),
        [esc, 0x61, 1, 0x78],
      );
      expect(
        (EscPosBuilder(
          paper: PaperWidth.mm80,
        )..text('x', align: EscPosAlign.right)).build(),
        [esc, 0x61, 2, 0x78],
      );
    });

    test('negrita se activa antes y se desactiva después', () {
      final bytes = (EscPosBuilder(
        paper: PaperWidth.mm80,
      )..text('N', bold: true)).build();
      expect(bytes, [esc, 0x61, 0, esc, 0x45, 1, 0x4E, esc, 0x45, 0]);
    });

    test('subrayado ESC - n', () {
      final bytes = (EscPosBuilder(
        paper: PaperWidth.mm80,
      )..text('U', underline: true)).build();
      expect(bytes, [esc, 0x61, 0, esc, 0x2D, 1, 0x55, esc, 0x2D, 0]);
    });

    test(
      'tamaño GS ! n: doble altura 0x01, doble anchura 0x10, ambos 0x11',
      () {
        expect(
          (EscPosBuilder(
            paper: PaperWidth.mm80,
          )..text('a', doubleHeight: true)).build(),
          [esc, 0x61, 0, gs, 0x21, 0x01, 0x61, gs, 0x21, 0],
        );
        expect(
          (EscPosBuilder(
            paper: PaperWidth.mm80,
          )..text('a', doubleWidth: true)).build(),
          [esc, 0x61, 0, gs, 0x21, 0x10, 0x61, gs, 0x21, 0],
        );
        expect(
          (EscPosBuilder(
            paper: PaperWidth.mm80,
          )..text('a', doubleHeight: true, doubleWidth: true)).build(),
          [esc, 0x61, 0, gs, 0x21, 0x11, 0x61, gs, 0x21, 0],
        );
      },
    );

    test(
      'orden de atributos combinados: align, bold, size, texto, size, bold',
      () {
        final bytes =
            (EscPosBuilder(paper: PaperWidth.mm80)..text(
                  'T',
                  align: EscPosAlign.center,
                  bold: true,
                  doubleHeight: true,
                  doubleWidth: true,
                ))
                .build();
        expect(bytes, [
          esc, 0x61, 1, // centrado
          esc, 0x45, 1, // negrita on
          gs, 0x21, 0x11, // doble tamaño
          0x54,
          gs, 0x21, 0x00,
          esc, 0x45, 0,
        ]);
      },
    );

    test('line = text + LF', () {
      final bytes = (EscPosBuilder(paper: PaperWidth.mm80)..line('ab')).build();
      expect(bytes, [esc, 0x61, 0, 0x61, 0x62, lf]);
    });

    test('feed ESC d n; feed(0) no emite nada; fuera de rango falla', () {
      expect((EscPosBuilder(paper: PaperWidth.mm80)..feed(3)).build(), [
        esc,
        0x64,
        3,
      ]);
      expect((EscPosBuilder(paper: PaperWidth.mm80)..feed()).build(), [
        esc,
        0x64,
        1,
      ]);
      expect((EscPosBuilder(paper: PaperWidth.mm80)..feed(0)).build(), isEmpty);
      expect(
        () => EscPosBuilder(paper: PaperWidth.mm80).feed(256),
        throwsA(isA<ValidationException>()),
      );
      expect(
        () => EscPosBuilder(paper: PaperWidth.mm80).feed(-1),
        throwsA(isA<ValidationException>()),
      );
    });

    test('corte parcial GS V 66 3 y completo GS V 65 3', () {
      expect((EscPosBuilder(paper: PaperWidth.mm80)..cut()).build(), [
        gs,
        0x56,
        66,
        3,
      ]);
      expect(
        (EscPosBuilder(paper: PaperWidth.mm80)..cut(partial: false)).build(),
        [gs, 0x56, 65, 3],
      );
    });

    test('cajón ESC p 0 25 250', () {
      expect((EscPosBuilder(paper: PaperWidth.mm80)..openDrawer()).build(), [
        esc,
        0x70,
        0,
        25,
        250,
      ]);
    });

    test('separator ocupa toda la anchura y acepta otro carácter', () {
      final decoded = decodeEscPos(
        (EscPosBuilder(paper: PaperWidth.mm58)
              ..separator()
              ..separator('='))
            .build(),
      );
      expect(decoded.texts, ['-' * 32, '=' * 32]);
      expect(
        () => EscPosBuilder(paper: PaperWidth.mm58).separator('--'),
        throwsA(isA<ValidationException>()),
      );
    });

    test('el texto nunca contiene ESC/GS aunque la entrada los traiga', () {
      final bytes = (EscPosBuilder(
        paper: PaperWidth.mm80,
      )..line('\x1B@peligro\x1DV1')).build();
      // Solo el ESC a inicial de la alineación.
      final escPositions = [
        for (var i = 0; i < bytes.length; i++)
          if (bytes[i] == esc || bytes[i] == gs) i,
      ];
      expect(escPositions, [0]);
      expect(decodeEscPos(bytes).texts, ['?@peligro?V1']);
    });
  });

  group('EscPosBuilder.qr', () {
    test('secuencia completa con longitud calculada', () {
      const data = 'https://ejemplo.es/v/123';
      final bytes = (EscPosBuilder(
        paper: PaperWidth.mm80,
      )..qr(data, size: 6, errorCorrection: QrErrorCorrection.high)).build();
      final payload = utf8.encode(data);
      final storeLen = payload.length + 3; // 27
      expect(bytes, [
        esc, 0x61, 1, // centrado
        gs, 0x28, 0x6B, 4, 0, 0x31, 0x41, 0x32, 0, // modelo 2
        gs, 0x28, 0x6B, 3, 0, 0x31, 0x43, 6, // tamaño 6
        gs, 0x28, 0x6B, 3, 0, 0x31, 0x45, 51, // corrección H
        gs, 0x28, 0x6B, storeLen & 0xFF, storeLen >> 8, 0x31, 0x50, 0x30,
        ...payload,
        gs, 0x28, 0x6B, 3, 0, 0x31, 0x51, 0x30, // imprimir
      ]);
      expect(storeLen, 27);
    });

    test('longitud > 255 usa pH', () {
      final data = 'x' * 300;
      final bytes = (EscPosBuilder(paper: PaperWidth.mm80)..qr(data)).build();
      final store = decodeEscPos(bytes)
          .named('qr')
          .firstWhere((c) => c.args.first == 0x50);
      expect(store.args[1], 303);
      // pL = 303 - 256 = 47, pH = 1
      final idx = _indexOf(bytes, [gs, 0x28, 0x6B, 47, 1, 0x31, 0x50, 0x30]);
      expect(idx, isNonNegative);
    });

    test('datos no ASCII van en UTF-8', () {
      final bytes = (EscPosBuilder(paper: PaperWidth.mm80)..qr('€')).build();
      expect(
        _indexOf(bytes, [0x31, 0x50, 0x30, 0xE2, 0x82, 0xAC]),
        isNonNegative,
      );
    });

    test('valores por defecto: tamaño 4, corrección M', () {
      final bytes = (EscPosBuilder(paper: PaperWidth.mm80)..qr('a')).build();
      expect(_indexOf(bytes, [0x31, 0x43, 4]), isNonNegative);
      expect(_indexOf(bytes, [0x31, 0x45, 49]), isNonNegative);
    });

    test('rechaza vacío, tamaño fuera de rango y datos excesivos', () {
      final b = EscPosBuilder(paper: PaperWidth.mm80);
      expect(() => b.qr(''), throwsA(isA<ValidationException>()));
      expect(() => b.qr('a', size: 0), throwsA(isA<ValidationException>()));
      expect(() => b.qr('a', size: 17), throwsA(isA<ValidationException>()));
      expect(() => b.qr('x' * 2954), throwsA(isA<ValidationException>()));
      expect(b.build(), isEmpty, reason: 'un fallo no deja bytes a medias');
    });
  });

  group('EscPosBuilder.raster', () {
    test('cabecera GS v 0 correcta para una imagen pequeña', () {
      final image = solidRaster(16, 2);
      final bytes = (EscPosBuilder(
        paper: PaperWidth.mm58,
      )..raster(image, align: EscPosAlign.left)).build();
      expect(bytes, [
        esc, 0x61, 0,
        gs, 0x76, 0x30, 0, 2, 0, 2, 0, // xL=2 bytes/fila, yL=2 filas
        0xFF, 0xFF, 0xFF, 0xFF,
      ]);
    });

    test('xL/xH con 576 puntos (72 bytes por fila) y centrado por defecto', () {
      final image = solidRaster(576, 1);
      final bytes = (EscPosBuilder(
        paper: PaperWidth.mm80,
      )..raster(image)).build();
      expect(bytes.sublist(0, 11), [
        esc,
        0x61,
        1,
        gs,
        0x76,
        0x30,
        0,
        72,
        0,
        1,
        0,
      ]);
      expect(bytes.length, 11 + 72);
    });

    test('300 filas → dos bandas de 255 y 45 con datos contiguos', () {
      const width = 64; // 8 bytes por fila
      final bits = Uint8List(8 * 300);
      for (var i = 0; i < bits.length; i++) {
        bits[i] = i & 0xFF;
      }
      final image = RasterImage(width: width, height: 300, bits: bits);
      final bytes = (EscPosBuilder(
        paper: PaperWidth.mm80,
      )..raster(image)).build();

      final decoded = decodeEscPos(bytes);
      final bands = decoded.named('raster').toList();
      expect(bands.length, 2);
      expect(bands[0].args, [0, 8, 255]);
      expect(bands[1].args, [0, 8, 45]);

      // Primera banda: tras ESC a (3) + cabecera (8) vienen 255×8 bytes.
      const firstData = 3 + 8;
      expect(
        bytes.sublist(firstData, firstData + 8 * 255),
        bits.sublist(0, 8 * 255),
      );
      // Segunda banda: cabecera y los 45×8 bytes restantes.
      final secondHeader = firstData + 8 * 255;
      expect(bytes.sublist(secondHeader, secondHeader + 8), [
        gs,
        0x76,
        0x30,
        0,
        8,
        0,
        45,
        0,
      ]);
      expect(bytes.sublist(secondHeader + 8), bits.sublist(8 * 255));
      expect(bytes.length, 3 + 2 * 8 + 8 * 300);
    });

    test('exactamente 255 filas → una sola banda; 256 → dos', () {
      final one = decodeEscPos(
        (EscPosBuilder(
          paper: PaperWidth.mm80,
        )..raster(solidRaster(8, 255))).build(),
      );
      expect(one.named('raster').map((c) => c.args[2]), [255]);
      final two = decodeEscPos(
        (EscPosBuilder(
          paper: PaperWidth.mm80,
        )..raster(solidRaster(8, 256))).build(),
      );
      expect(two.named('raster').map((c) => c.args[2]), [255, 1]);
    });

    test('imagen más ancha que el papel → ValidationException', () {
      expect(
        () => EscPosBuilder(paper: PaperWidth.mm58).raster(solidRaster(392, 1)),
        throwsA(
          isA<ValidationException>().having(
            (e) => e.message,
            'message',
            contains('384'),
          ),
        ),
      );
    });
  });

  group('layout de columnas', () {
    // El bucle cubre los tres papeles: 32, 48 y 42 columnas.
    test('hay tres anchuras de papel', () {
      expect(PaperWidth.values.map((p) => p.columns), [32, 48, 42]);
    });

    for (final paper in PaperWidth.values) {
      test(
        'row rellena exactamente ${paper.columns} columnas (${paper.name})',
        () {
          final w1 = paper.columns ~/ 2;
          final w2 = paper.columns - w1;
          final decoded = decodeEscPos(
            (EscPosBuilder(paper: paper)..row([
                  Column('Café', width: w1),
                  Column('1,20', width: w2, align: EscPosAlign.right),
                ]))
                .build(),
          );
          expect(decoded.lines.length, 1);
          final text = decoded.lines.single.text;
          expect(text.runes.length, paper.columns);
          expect(text.startsWith('Café'), isTrue);
          expect(text.endsWith('1,20'), isTrue);
          expect(text.substring(4, paper.columns - 4).trim(), isEmpty);
        },
      );

      test('columns2 alinea el importe al margen derecho (${paper.name})', () {
        final decoded = decodeEscPos(
          (EscPosBuilder(paper: paper)..columns2('TOTAL', '12,50 €')).build(),
        );
        final text = decoded.lines.single.text;
        expect(text.runes.length, paper.columns);
        expect(text, startsWith('TOTAL'));
        expect(text, endsWith('12,50 €'));
        // Entre ambos solo hay espacios.
        expect(text.substring(5, paper.columns - 7).trim(), isEmpty);
      });
    }

    test('row recorta celdas sin wrap', () {
      final decoded = decodeEscPos(
        (EscPosBuilder(paper: PaperWidth.mm58)..row([
              Column('Descripción larguísima que no cabe', width: 10),
              Column('9,99', width: 22, align: EscPosAlign.right),
            ]))
            .build(),
      );
      expect(decoded.texts, ['Descripció${' ' * 18}9,99']);
    });

    test(
      'row con wrap genera varias filas y deja las demás celdas en blanco',
      () {
        final decoded = decodeEscPos(
          (EscPosBuilder(paper: PaperWidth.mm58)..row([
                Column('Hamburguesa completa con queso', width: 20, wrap: true),
                Column('12,00', width: 12, align: EscPosAlign.right),
              ]))
              .build(),
        );
        expect(decoded.texts, [
          'Hamburguesa completa${' ' * 7}12,00',
          'con queso${' ' * 11}${' ' * 12}',
        ]);
        for (final t in decoded.texts) {
          expect(t.runes.length, 32);
        }
      },
    );

    test('row centra celdas', () {
      final decoded = decodeEscPos(
        (EscPosBuilder(
          paper: PaperWidth.mm58,
        )..row([Column('ab', width: 7, align: EscPosAlign.center)])).build(),
      );
      expect(decoded.texts, ['  ab   ']);
    });

    test('row valida anchuras', () {
      final b = EscPosBuilder(paper: PaperWidth.mm58);
      expect(() => b.row([]), throwsA(isA<ValidationException>()));
      expect(
        () => b.row([Column('a', width: 0)]),
        throwsA(isA<ValidationException>()),
      );
      expect(
        () => b.row([Column('a', width: 20), Column('b', width: 13)]),
        throwsA(
          isA<ValidationException>().having(
            (e) => e.message,
            'message',
            allOf(contains('33'), contains('32')),
          ),
        ),
      );
    });

    test('row en doble anchura dispone de la mitad de columnas', () {
      final b = EscPosBuilder(paper: PaperWidth.mm80);
      expect(b.columnsFor(doubleWidth: true), 24);
      expect(
        () => b.row([Column('a', width: 25)], doubleWidth: true),
        throwsA(isA<ValidationException>()),
      );
      final decoded = decodeEscPos(
        (b..row([Column('a', width: 24)], doubleWidth: true)).build(),
      );
      expect(decoded.lines.single.doubleWidth, isTrue);
      expect(decoded.lines.single.text.length, 24);
    });

    test(
      'columns2 parte la izquierda en varias filas y el importe va al final',
      () {
        final decoded = decodeEscPos(
          (EscPosBuilder(paper: PaperWidth.mm58)..columns2(
                '2 x Hamburguesa completa con queso y bacon',
                '24,00',
              ))
              .build(),
        );
        // Anchura izquierda = 32 - 5 - 1 = 26.
        expect(decoded.texts, [
          '2 x Hamburguesa completa',
          'con queso y bacon${' ' * 9} 24,00',
        ]);
        expect(decoded.texts.last.runes.length, 32);
      },
    );

    test('columns2 en doble tamaño usa 16/24 columnas', () {
      final decoded = decodeEscPos(
        (EscPosBuilder(paper: PaperWidth.mm58)..columns2(
              'TOTAL',
              '1.234,56 €',
              bold: true,
              doubleHeight: true,
              doubleWidth: true,
            ))
            .build(),
      );
      final line = decoded.lines.single;
      expect(line.text.runes.length, 16);
      expect(line.text, 'TOTAL 1.234,56 €');
      expect(line.bold, isTrue);
      expect(line.doubleHeight, isTrue);
      expect(line.doubleWidth, isTrue);
    });

    test('columns2 con derecha más ancha que el papel la recorta', () {
      final decoded = decodeEscPos(
        (EscPosBuilder(
          paper: PaperWidth.mm58,
        )..columns2('a', 'x' * 40)).build(),
      );
      expect(decoded.texts, ['a', 'x' * 32]);
    });

    test('paragraph ajusta por palabras a la anchura del papel', () {
      final decoded = decodeEscPos(
        (EscPosBuilder(paper: PaperWidth.mm58)..paragraph(
              'Gracias por su visita. IVA incluido. Conserve este ticket.',
              align: EscPosAlign.center,
            ))
            .build(),
      );
      expect(decoded.texts, [
        'Gracias por su visita. IVA',
        'incluido. Conserve este ticket.',
      ]);
      for (final l in decoded.lines) {
        expect(l.align, 1);
        expect(l.text.runes.length, lessThanOrEqualTo(32));
      }
    });

    test('la anchura se mide en runas: acentos y emoji cuentan 1', () {
      final decoded = decodeEscPos(
        (EscPosBuilder(
          paper: PaperWidth.mm58,
        )..columns2('Niño 😀', 'ñ')).build(),
      );
      final text = decoded.lines.single.text;
      expect(text.runes.length, 32);
      expect(text, startsWith('Niño ?'));
      expect(text, endsWith('ñ'));
    });
  });

  group('utilidades de maquetación', () {
    test('wrapWords', () {
      expect(wrapWords('', 10), ['']);
      expect(wrapWords('hola', 10), ['hola']);
      expect(wrapWords('uno dos tres', 7), ['uno dos', 'tres']);
      expect(wrapWords('abcdefghij', 4), ['abcd', 'efgh', 'ij']);
      expect(wrapWords('a\nb', 4), ['a', 'b']);
      expect(wrapWords('  muchos   espacios  ', 20), ['muchos espacios']);
      expect(wrapWords('x abcdefgh y', 4), ['x', 'abcd', 'efgh', 'y']);
      expect(() => wrapWords('a', 0), throwsA(isA<ValidationException>()));
    });

    test('fitRunes y truncateRunes', () {
      expect(fitRunes('ab', 5, EscPosAlign.left), 'ab   ');
      expect(fitRunes('ab', 5, EscPosAlign.right), '   ab');
      expect(fitRunes('ab', 5, EscPosAlign.center), ' ab  ');
      expect(fitRunes('abcdef', 3, EscPosAlign.right), 'abc');
      expect(truncateRunes('€€€', 2), '€€');
      expect(runeLength('😀a'), 2);
    });
  });

  group('Column', () {
    test('igualdad por valor', () {
      expect(
        const Column('a', width: 3),
        const Column('a', width: 3, align: EscPosAlign.left),
      );
      expect(const Column('a', width: 3), isNot(const Column('a', width: 4)));
    });
  });

  group('inverso y tramos', () {
    test('inverse rodea el texto con GS B 1 y GS B 0', () {
      final bytes = (EscPosBuilder(
        paper: PaperWidth.mm80,
      )..text('I', inverse: true)).build();
      expect(bytes, [esc, 0x61, 0, gs, 0x42, 1, 0x49, gs, 0x42, 0]);
    });

    test('el inverso es el último en activarse y el primero en apagarse', () {
      final bytes =
          (EscPosBuilder(paper: PaperWidth.mm80)..text(
                'T',
                align: EscPosAlign.right,
                bold: true,
                underline: true,
                doubleHeight: true,
                inverse: true,
              ))
              .build();
      expect(bytes, [
        esc, 0x61, 2, // derecha
        esc, 0x45, 1, // negrita on
        esc, 0x2D, 1, // subrayado on
        gs, 0x21, 0x01, // doble alto
        gs, 0x42, 1, // inverso on
        0x54,
        gs, 0x42, 0,
        gs, 0x21, 0x00,
        esc, 0x2D, 0,
        esc, 0x45, 0,
      ]);
    });

    test('line, paragraph, row y columns2 aceptan inverse', () {
      final b = EscPosBuilder(paper: PaperWidth.mm58)
        ..line('a', inverse: true)
        ..paragraph('b c', inverse: true)
        ..row([const Column('d', width: 4)], inverse: true)
        ..columns2('e', 'f', inverse: true);
      final decoded = decodeEscPos(b.build());
      expect(decoded.texts, ['a', 'b c', 'd   ', 'e${' ' * 30}f']);
      expect(decoded.lines.map((l) => l.inverse), everyElement(isTrue));
    });

    test('lineRuns: un tramo normal y otro en inverso en la misma línea', () {
      final bytes =
          (EscPosBuilder(paper: PaperWidth.mm80)..lineRuns(
                const [TextRun('   > '), TextRun('sin cebolla', inverse: true)],
                bold: true,
                doubleHeight: true,
              ))
              .build();
      expect(bytes, [
        esc, 0x61, 0, // alineación, una vez por línea
        esc, 0x45, 1, gs, 0x21, 0x01, // atributos de la línea
        ...ascii('   > '),
        gs, 0x21, 0, esc, 0x45, 0,
        esc, 0x45, 1, gs, 0x21, 0x01, // atributos de la línea
        gs, 0x42, 1, // inverso solo en este tramo
        ...ascii('sin cebolla'),
        gs, 0x42, 0,
        gs, 0x21, 0, esc, 0x45, 0,
        lf,
      ]);
      final line = decodeEscPos(bytes).lines.single;
      expect(line.text, '   > sin cebolla');
      expect(line.runs.map((r) => r.inverse), [false, true]);
      expect(line.inverse, isTrue);
      expect(line.bold, isTrue);
      expect(line.doubleHeight, isTrue);
    });

    test(
      'lineRuns respeta la alineación y sin tramos deja una línea vacía',
      () {
        expect(
          (EscPosBuilder(
            paper: PaperWidth.mm80,
          )..lineRuns(const [TextRun('x')], align: EscPosAlign.center)).build(),
          [esc, 0x61, 1, 0x78, lf],
        );
        final bytes = (EscPosBuilder(
          paper: PaperWidth.mm80,
        )..lineRuns(const [], align: EscPosAlign.right)).build();
        expect(bytes, [esc, 0x61, 2, lf]);
        expect(decodeEscPos(bytes).lines.single.align, 2);
      },
    );

    test('TextRun: igualdad por valor', () {
      expect(const TextRun('a'), const TextRun('a', inverse: false));
      expect(const TextRun('a'), isNot(const TextRun('a', inverse: true)));
    });
  });

  group('EscPosBuilder.banda', () {
    test('rellena hasta 48 columnas en 80 mm, 42 a 180 ppp y 32 en 58 mm', () {
      for (final paper in PaperWidth.values) {
        final decoded = decodeEscPos(
          (EscPosBuilder(paper: paper)..banda('ESPERAR')).build(),
        );
        final line = decoded.lines.single;
        expect(line.text.runes.length, paper.columns, reason: paper.name);
        expect(line.text, startsWith(' '));
        expect(line.text.trim(), 'ESPERAR');
        expect(line.inverse, isTrue);
        expect(line.bold, isTrue);
        expect(line.doubleHeight, isFalse);
        expect(line.doubleWidth, isFalse);
        expect(line.align, 0, reason: 'el relleno centra; la impresora no');
      }
    });

    test(
      'secuencia exacta: ESC a 0, ESC E 1, GS B 1, texto, GS B 0, ESC E 0',
      () {
        final bytes = (EscPosBuilder(
          paper: PaperWidth.mm58,
        )..banda('X')).build();
        expect(bytes, [
          esc,
          0x61,
          0,
          esc,
          0x45,
          1,
          gs,
          0x42,
          1,
          ...ascii(fitRunes('X', 32, EscPosAlign.center)),
          gs,
          0x42,
          0,
          esc,
          0x45,
          0,
          lf,
        ]);
      },
    );

    test('en doble ancho rellena hasta 24, 21 y 16 columnas', () {
      for (final paper in PaperWidth.values) {
        final bytes = (EscPosBuilder(
          paper: paper,
        )..banda('DUPLICADO', doubleHeight: true, doubleWidth: true)).build();
        expect(_indexOf(bytes, [gs, 0x21, 0x11, gs, 0x42, 1]), isNonNegative);
        final line = decodeEscPos(bytes).lines.single;
        expect(line.text.runes.length, paper.columns ~/ 2, reason: paper.name);
        expect(line.printedWidth, paper.columns);
        expect(line.doubleWidth, isTrue);
        expect(line.doubleHeight, isTrue);
        expect(line.inverse, isTrue);
      }
    });

    test('a 42 columnas: 42 en anchura normal y 21 en doble ancho', () {
      final normal = decodeEscPos(
        (EscPosBuilder(paper: PaperWidth.mm80Dpi180)..banda('ESPERAR')).build(),
      ).lines.single;
      expect(normal.text.runes.length, 42);
      expect(normal.text.trim(), 'ESPERAR');
      expect(normal.inverse, isTrue);

      final doble = decodeEscPos(
        (EscPosBuilder(
              paper: PaperWidth.mm80Dpi180,
            )..banda('MARCHAR SEGUNDOS', doubleHeight: true, doubleWidth: true))
            .build(),
      ).lines.single;
      expect(doble.text.runes.length, 21);
      expect(doble.printedWidth, 42);
      expect(doble.text.trim(), 'MARCHAR SEGUNDOS');
      expect(doble.inverse, isTrue);
      expect(doble.doubleHeight, isTrue);
      expect(doble.doubleWidth, isTrue);
    });

    test('parte los textos largos por palabras', () {
      final decoded = decodeEscPos(
        (EscPosBuilder(
          paper: PaperWidth.mm58,
        )..banda('REIMPRESIÓN · PREPARAR', doubleWidth: true)).build(),
      );
      expect(decoded.texts.map((t) => t.trim()), ['REIMPRESIÓN ·', 'PREPARAR']);
      for (final line in decoded.lines) {
        expect(line.text.runes.length, 16);
        expect(line.inverse, isTrue);
      }
    });
  });

  group('avisos sonoros y cajón', () {
    test('pitido = ESC B n t', () {
      expect((EscPosBuilder(paper: PaperWidth.mm80)..pitido()).build(), [
        esc,
        0x42,
        2,
        2,
      ]);
      expect(
        (EscPosBuilder(
          paper: PaperWidth.mm80,
        )..pitido(veces: 3, duracion: 5)).build(),
        [esc, 0x42, 3, 5],
      );
    });

    test('pitido rechaza 0 y 9, en veces y en duración', () {
      final b = EscPosBuilder(paper: PaperWidth.mm80);
      for (final n in [0, 9]) {
        expect(
          () => b.pitido(veces: n),
          throwsA(isA<ValidationException>()),
          reason: 'veces $n',
        );
        expect(
          () => b.pitido(duracion: n),
          throwsA(isA<ValidationException>()),
          reason: 'duración $n',
        );
      }
      expect(b.build(), isEmpty, reason: 'un fallo no deja bytes a medias');
    });

    test('pulsoZumbadorCajon: pin 5 (m = 1) por defecto y pin 2 (m = 0)', () {
      const pulso5 = [esc, 0x70, 1, 0x32, 0x64];
      const pulso2 = [esc, 0x70, 0, 0x32, 0x64];
      expect(
        (EscPosBuilder(paper: PaperWidth.mm80)..pulsoZumbadorCajon()).build(),
        pulso5,
      );
      expect(
        (EscPosBuilder(
          paper: PaperWidth.mm80,
        )..pulsoZumbadorCajon(veces: 3)).build(),
        [...pulso5, ...pulso5, ...pulso5],
      );
      expect(
        (EscPosBuilder(
          paper: PaperWidth.mm80,
        )..pulsoZumbadorCajon(pin: 2)).build(),
        pulso2,
      );
    });

    test('pulsoZumbadorCajon rechaza veces fuera de 1..3 y otros pines', () {
      final b = EscPosBuilder(paper: PaperWidth.mm80);
      for (final veces in [0, 4]) {
        expect(
          () => b.pulsoZumbadorCajon(veces: veces),
          throwsA(isA<ValidationException>()),
        );
      }
      for (final pin in [0, 1, 3, 4]) {
        expect(
          () => b.pulsoZumbadorCajon(pin: pin),
          throwsA(isA<ValidationException>()),
        );
      }
      expect(b.build(), isEmpty);
    });

    test('bytesAviso en los tres modos', () {
      expect(bytesAviso(ZumbadorModo.ninguno), isEmpty);
      expect(bytesAviso(ZumbadorModo.ninguno, pitidos: 0, pin: 9), isEmpty);

      expect(bytesAviso(ZumbadorModo.generico), [esc, 0x42, 2, 2]);
      expect(bytesAviso(ZumbadorModo.generico, pitidos: 5), [esc, 0x42, 5, 2]);
      // Se acota al rango del comando.
      expect(bytesAviso(ZumbadorModo.generico, pitidos: 0), [esc, 0x42, 1, 2]);
      expect(bytesAviso(ZumbadorModo.generico, pitidos: 20), [esc, 0x42, 8, 2]);

      // Por defecto dos pitidos → dos pulsos por el pin 5.
      expect(bytesAviso(ZumbadorModo.puertoCajon), [
        esc,
        0x70,
        1,
        0x32,
        0x64,
        esc,
        0x70,
        1,
        0x32,
        0x64,
      ]);
      expect(bytesAviso(ZumbadorModo.puertoCajon, pitidos: 1), [
        esc,
        0x70,
        1,
        0x32,
        0x64,
      ]);
      expect(bytesAviso(ZumbadorModo.puertoCajon, pitidos: 20, pin: 2), [
        esc,
        0x70,
        0,
        0x32,
        0x64,
        esc,
        0x70,
        0,
        0x32,
        0x64,
        esc,
        0x70,
        0,
        0x32,
        0x64,
      ]);
      expect(
        () => bytesAviso(ZumbadorModo.puertoCajon, pin: 3),
        throwsA(isA<ValidationException>()),
      );
    });

    test('bytesAbrirCajon = ESC p 0 25 250, igual que openDrawer', () {
      expect(bytesAbrirCajon(), [esc, 0x70, 0, 25, 250]);
      expect(
        bytesAbrirCajon(),
        (EscPosBuilder(paper: PaperWidth.mm58)..openDrawer()).build(),
      );
      expect(decodeEscPos(bytesAbrirCajon()).named('drawer'), hasLength(1));
    });
  });

  test('decodeCp858 reconstruye lo escrito por el builder', () {
    final bytes = (EscPosBuilder(
      paper: PaperWidth.mm80,
    )..line('Jamón 12,50 €', bold: true)).build();
    expect(decodeEscPos(bytes).texts, ['Jamón 12,50 €']);
    expect(decodeCp858(encodeCp858('Jamón 12,50 €')), 'Jamón 12,50 €');
  });
}

int _indexOf(List<int> haystack, List<int> needle) {
  outer:
  for (var i = 0; i + needle.length <= haystack.length; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) continue outer;
    }
    return i;
  }
  return -1;
}
