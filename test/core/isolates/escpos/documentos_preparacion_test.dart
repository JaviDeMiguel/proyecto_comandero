/// Documentos de preparación tras WP-06b: la comanda de cocina o barra con
/// pases, la anulación con las cantidades en negativo, la reimpresión con la
/// banda del motivo y el MARCHAR de un pase, contra las maquetas (e)–(i) y (k)
/// del diseño de impresión.
library;

import 'dart:typed_data';

import 'package:proyecto_comandero/core/errors/app_exception.dart';
import 'package:proyecto_comandero/core/isolates/escpos/escpos.dart';
import 'package:proyecto_comandero/core/isolates/isolate_runner.dart';
import 'package:test/test.dart';

import 'escpos_decoder.dart';

final aceptadaEn = DateTime(2026, 10, 9, 21, 14);
final abiertaEn = DateTime(2026, 10, 9, 21, 2);
final anuladaEn = DateTime(2026, 10, 9, 21, 30);
final marchaEn = DateTime(2026, 10, 9, 21, 52);
final segundaMarchaEn = DateTime(2026, 10, 9, 22, 5);

const respaldoBarra = 'Sin impresora de barra: llevar a barra';

/// Líneas de la comanda de cocina de la maqueta (e): una directa, tres de
/// primeros (pase marchado) y dos de segundos (sin marchar).
const lineasCocina = [
  LineaComandaPrint(cantidad: 1, descripcion: 'Pan con tomate'),
  LineaComandaPrint(
    cantidad: 2,
    descripcion: 'Croquetas de jamón',
    pase: 1,
    nombrePase: 'Primeros',
  ),
  LineaComandaPrint(
    cantidad: 1,
    descripcion: 'Ensalada de ventresca',
    nota: 'sin cebolla',
    pase: 1,
    nombrePase: 'Primeros',
  ),
  LineaComandaPrint(
    cantidad: 1,
    descripcion: 'Salmorejo',
    pase: 1,
    nombrePase: 'Primeros',
  ),
  LineaComandaPrint(
    cantidad: 2,
    descripcion: 'Entrecot a la brasa',
    nota: '1 poco hecho, 1 al punto',
    pase: 2,
    nombrePase: 'Segundos',
    esperar: true,
  ),
  LineaComandaPrint(
    cantidad: 1,
    descripcion: 'Lubina a la sal',
    pase: 2,
    nombrePase: 'Segundos',
    esperar: true,
  ),
];

/// Líneas de la comanda de barra de la maqueta (f): sin pases.
const lineasBarra = [
  LineaComandaPrint(cantidad: 4, descripcion: 'Caña'),
  LineaComandaPrint(cantidad: 1, descripcion: 'Agua con gas'),
  LineaComandaPrint(
    cantidad: 1,
    descripcion: 'Tinto de verano',
    nota: 'con limón',
  ),
];

/// Líneas del MARCHAR SEGUNDOS de la maqueta (g).
const lineasSegundos = [
  LineaComandaPrint(
    cantidad: 2,
    descripcion: 'Entrecot a la brasa',
    nota: '1 poco hecho, 1 al punto',
    pase: 2,
  ),
  LineaComandaPrint(cantidad: 1, descripcion: 'Lubina a la sal', pase: 2),
];

KitchenOrderPrintData comandaCocina({
  PaperWidth paper = PaperWidth.mm80,
  String mesa = 'Mesa 7',
  String? zona = 'Terraza',
  List<LineaComandaPrint> lineas = lineasCocina,
  String? camarero = 'Ana',
  int? comensales = 4,
  int avanceInicial = 0,
  String? observaciones,
  bool muestra = false,
}) => KitchenOrderPrintData(
  titulo: 'COCINA',
  mesa: mesa,
  zona: zona,
  fechaHora: aceptadaEn,
  numeroComanda: '12',
  camarero: camarero,
  comensales: comensales,
  ordinalEnvio: 2,
  abiertaEn: abiertaEn,
  lineas: lineas,
  observaciones: observaciones,
  avanceInicial: avanceInicial,
  muestra: muestra,
  paper: paper,
);

KitchenOrderPrintData comandaBarra({PaperWidth paper = PaperWidth.mm80}) =>
    KitchenOrderPrintData(
      titulo: 'BARRA',
      mesa: '7',
      zona: 'Terraza',
      fechaHora: aceptadaEn,
      numeroComanda: '12',
      camarero: 'Ana',
      comensales: 4,
      lineas: lineasBarra,
      paper: paper,
    );

List<LineaComandaPrint> lineasAnuladas() => [
  LineaComandaPrint(
    cantidad: 1,
    descripcion: 'Lubina a la sal',
    nota: 'sin sal',
    anulada: true,
    motivo: 'el cliente cambia de plato',
    envio: 12,
    pedidaEn: aceptadaEn,
  ),
];

KitchenOrderPrintData anulacion({
  PaperWidth paper = PaperWidth.mm80,
  String mesa = 'Mesa 7',
  String? zona = 'Terraza',
  List<LineaComandaPrint>? lineas,
  String? numeroComanda = '12',
  bool tituloEnBanda = true,
  int avanceInicial = 0,
  String? camarero = 'Ana',
  String? observaciones,
}) => KitchenOrderPrintData(
  titulo: 'ANULACIÓN COCINA',
  tituloEnBanda: tituloEnBanda,
  mesa: mesa,
  zona: zona,
  fechaHora: anuladaEn,
  numeroComanda: numeroComanda,
  camarero: camarero,
  lineas: lineas ?? lineasAnuladas(),
  avanceInicial: avanceInicial,
  observaciones: observaciones,
  paper: paper,
);

KitchenOrderPrintData reimpresion({
  PaperWidth paper = PaperWidth.mm80,
  String banner = 'REIMPRESIÓN · PREPARAR',
  String? observaciones,
}) => KitchenOrderPrintData(
  titulo: 'COCINA',
  mesa: 'Mesa 7',
  zona: 'Terraza',
  fechaHora: aceptadaEn,
  numeroComanda: '12, 15',
  camarero: 'Ana',
  comensales: 4,
  lineas: lineasCocina,
  banner: banner,
  bannerDetalle: const ['Reimpresa 09/10/2026 21:40 · Caja 1'],
  observaciones: observaciones,
  paper: paper,
);

MarcharPrintData marchar({
  PaperWidth paper = PaperWidth.mm80,
  String mesa = 'Mesa 7',
  String? zona = 'Terraza',
  bool repetida = false,
  DateTime? ultimaMarchaEn,
  List<int> numerosComanda = const [12],
  bool conHoraDePedido = true,
  String? nombrePase = 'Segundos',
  String? camarero = 'Ana',
  int? comensales = 4,
  String? observaciones,
  int avanceInicial = 0,
  bool muestra = false,
}) => MarcharPrintData(
  titulo: 'COCINA',
  mesa: mesa,
  zona: zona,
  pase: 2,
  nombrePase: nombrePase,
  repetida: repetida,
  ultimaMarchaEn: ultimaMarchaEn,
  numerosComanda: numerosComanda,
  pedidaEn: conHoraDePedido ? aceptadaEn : null,
  fechaHora: repetida ? segundaMarchaEn : marchaEn,
  camarero: camarero,
  comensales: comensales,
  lineas: lineasSegundos,
  observaciones: observaciones,
  avanceInicial: avanceInicial,
  muestra: muestra,
  paper: paper,
);

DecodedLine linea(DecodedStream d, String texto) => d.lines.firstWhere(
  (l) => l.text == texto,
  orElse: () => fail('no hay línea «$texto» en ${d.texts}'),
);

DecodedLine lineaDesde(DecodedStream d, String prefijo) => d.lines.firstWhere(
  (l) => l.text.startsWith(prefijo),
  orElse: () => fail('ninguna línea empieza por «$prefijo» en ${d.texts}'),
);

/// Banda: línea en inverso cuyo texto, sin el relleno, es [texto].
DecodedLine banda(DecodedStream d, String texto) => d.lines.firstWhere(
  (l) => l.inverse && l.text.trim() == texto,
  orElse: () => fail('no hay banda «$texto» en ${d.texts}'),
);

int indiceDe(DecodedStream d, String texto) =>
    d.lines.indexWhere((l) => l.text == texto);

Matcher failsWith(String fragment) => throwsA(
  isA<ValidationException>().having(
    (e) => e.message,
    'message',
    contains(fragment),
  ),
);

/// Negrita, doble alto y doble ancho, centrado por la impresora.
void expectTituloGrande(DecodedLine l) {
  expect(l.bold, isTrue);
  expect(l.doubleHeight, isTrue);
  expect(l.doubleWidth, isTrue);
  expect(l.align, 1);
}

/// Línea de preparación: negrita y doble alto, sin doble ancho ni inverso.
void expectLineaPreparacion(DecodedLine l) {
  expect(l.bold, isTrue);
  expect(l.doubleHeight, isTrue);
  expect(l.doubleWidth, isFalse);
  expect(l.inverse, isFalse);
}

/// Nota destacada: prefijo sin inverso y texto en inverso, en negrita y
/// doble alto.
void expectNota(DecodedLine l, String prefijo, String texto) {
  expect(l.runs.map((r) => r.text), [prefijo, texto]);
  expect(l.runs.map((r) => r.inverse), [false, true]);
  expect(l.bold, isTrue);
  expect(l.doubleHeight, isTrue);
  expect(l.doubleWidth, isFalse);
}

/// Los dos últimos comandos son el avance y el corte.
void expectFinal(DecodedStream d) {
  final tail = d.commands.sublist(d.commands.length - 2);
  expect(tail.map((c) => c.name), ['feed', 'cut']);
  expect(tail.first.args, [2]);
}

void main() {
  group('comanda de cocina con pases (maqueta e)', () {
    test(
      'cabecera: título 2HW primero, mesa tal cual, zona, COMANDA Nº con la '
      'hora, camarero con comensales y ordinal del envío con la apertura',
      () {
        final decoded = decodeEscPos(generarComandaCocina(comandaCocina()));
        final texts = decoded.texts;
        expectWidthsWithin(decoded, PaperWidth.mm80);

        expect(texts[0], 'COCINA');
        expectTituloGrande(decoded.lines[0]);
        expect(decoded.lines[0].inverse, isFalse);
        expect(texts[1], 'Mesa 7');
        expectTituloGrande(decoded.lines[1]);
        expect(texts[2], 'Terraza');
        expect(decoded.lines[2].align, 1);
        expect(decoded.lines[2].bold, isFalse);
        expect(texts[3], 'COMANDA Nº 12 · 21:14');
        expect(decoded.lines[3].bold, isTrue);
        expect(decoded.lines[3].doubleHeight, isTrue);
        expect(decoded.lines[3].doubleWidth, isFalse);
        expect(decoded.lines[3].align, 1);
        expect(texts[4], 'Camarero: Ana${' ' * 23}4 comensales');
        expect(texts[5], '2º envío de la mesa · abierta 21:02');
        expect(decoded.lines[5].align, 1);
        expect(texts[6], '=' * 48);
        expect(texts.where((t) => t.startsWith('MESA')), isEmpty);
        expect(texts.where((t) => t.contains('09/10/2026')), isEmpty);
        expect(decoded.named('drawer'), isEmpty);
        expectFinal(decoded);
      },
    );

    test('grupos: DIRECTO, pase marchado con rótulo entre guiones y pase sin '
        'marchar bajo la banda ESPERAR en inverso', () {
      final decoded = decodeEscPos(generarComandaCocina(comandaCocina()));
      final texts = decoded.texts;

      final directo = linea(decoded, '${'-' * 19} DIRECTO ${'-' * 20}');
      expect(directo.bold, isTrue);
      expect(directo.inverse, isFalse);
      expect(directo.doubleHeight, isFalse);
      final primeros = linea(decoded, '${'-' * 17} 1. PRIMEROS ${'-' * 18}');
      expect(primeros.bold, isTrue);
      expect(primeros.inverse, isFalse);
      final esperar = banda(decoded, '2. SEGUNDOS · ESPERAR');
      expect(esperar.bold, isTrue);
      expect(esperar.doubleHeight, isFalse);
      expect(esperar.doubleWidth, isFalse);
      expect(esperar.text.runes.length, 48);

      // Orden: directo, primeros y segundos, cada uno con sus líneas.
      final orden = [
        directo.text,
        '1 x Pan con tomate',
        primeros.text,
        '2 x Croquetas de jamón',
        '1 x Ensalada de ventresca',
        '   > sin cebolla',
        '1 x Salmorejo',
        esperar.text,
        '2 x Entrecot a la brasa',
        '   > 1 poco hecho, 1 al punto',
        '1 x Lubina a la sal',
        '=' * 48,
      ];
      final inicio = indiceDe(decoded, directo.text);
      expect(texts.sublist(inicio, inicio + orden.length), orden);
      expectLineaPreparacion(linea(decoded, '2 x Croquetas de jamón'));
      expectLineaPreparacion(linea(decoded, '1 x Lubina a la sal'));
      expect(texts.where((t) => t.contains('ESPERAR')), hasLength(1));
    });

    test('nota en dos tramos: prefijo sin inverso y texto en inverso; las '
        'notas largas se parten con sangría', () {
      final decoded = decodeEscPos(generarComandaCocina(comandaCocina()));
      expectNota(linea(decoded, '   > sin cebolla'), '   > ', 'sin cebolla');
      expectNota(
        linea(decoded, '   > 1 poco hecho, 1 al punto'),
        '   > ',
        '1 poco hecho, 1 al punto',
      );

      final larga = decodeEscPos(
        generarComandaCocina(
          comandaCocina(
            paper: PaperWidth.mm58,
            lineas: const [
              LineaComandaPrint(
                cantidad: 1,
                descripcion: 'Ensalada',
                nota: 'sin cebolla, sin tomate y con el aliño aparte',
              ),
            ],
          ),
        ),
      );
      expectWidthsWithin(larga, PaperWidth.mm58);
      final filas = larga.lines.where((l) => l.runs.length == 2).toList();
      expect(filas.length, greaterThan(1));
      expect(filas.first.runs.first.text, '   > ');
      for (final fila in filas.skip(1)) {
        expect(fila.runs.first.text, ' ' * 5);
      }
      expect(
        filas.map((f) => f.runs.last.text).join(' '),
        'sin cebolla, sin tomate y con el aliño aparte',
      );
      for (final fila in filas) {
        expect(fila.runs.map((r) => r.inverse), [false, true]);
        expect(fila.doubleHeight, isTrue);
      }
    });

    test('sin pases la comanda es plana (maqueta f), y DIRECTO solo aparece '
        'cuando también hay líneas con pase', () {
      final barra = decodeEscPos(generarComandaCocina(comandaBarra()));
      final texts = barra.texts;
      expectWidthsWithin(barra, PaperWidth.mm80);
      expect(texts.sublist(0, 11), [
        'BARRA',
        'Mesa 7',
        'Terraza',
        'COMANDA Nº 12 · 21:14',
        'Camarero: Ana${' ' * 23}4 comensales',
        '=' * 48,
        '4 x Caña',
        '1 x Agua con gas',
        '1 x Tinto de verano',
        '   > con limón',
        '=' * 48,
      ]);
      expect(texts, hasLength(11));
      expect(texts.where((t) => t.contains('DIRECTO')), isEmpty);
      expect(texts.where((t) => t.contains('ESPERAR')), isEmpty);
      expectNota(linea(barra, '   > con limón'), '   > ', 'con limón');

      final soloPases = decodeEscPos(
        generarComandaCocina(comandaCocina(lineas: lineasCocina.sublist(1))),
      ).texts;
      expect(soloPases.where((t) => t.contains('DIRECTO')), isEmpty);
      expect(soloPases.where((t) => t.contains('1. PRIMEROS')), hasLength(1));
    });

    test('un pase fuera de la configuración se rotula «PASE 4» y los pases '
        'van de menor a mayor', () {
      final decoded = decodeEscPos(
        generarComandaCocina(
          comandaCocina(
            lineas: const [
              LineaComandaPrint(cantidad: 1, descripcion: 'Tarta', pase: 4),
              LineaComandaPrint(
                cantidad: 1,
                descripcion: 'Sopa',
                pase: 1,
                nombrePase: 'Primeros',
              ),
              LineaComandaPrint(
                cantidad: 1,
                descripcion: 'Queso',
                pase: 3,
                esperar: true,
              ),
            ],
          ),
        ),
      );
      final texts = decoded.texts;
      final primeros = texts.indexWhere((t) => t.contains(' 1. PRIMEROS '));
      final pase3 = texts.indexWhere((t) => t.trim() == '3. PASE 3 · ESPERAR');
      final pase4 = texts.indexWhere((t) => t.contains(' 4. PASE 4 '));
      expect(primeros, isNonNegative);
      expect(pase3, greaterThan(primeros));
      expect(pase4, greaterThan(pase3));
      expect(decoded.lines[pase3].inverse, isTrue);
      expect(decoded.lines[pase4].inverse, isFalse);
      expect(texts[primeros + 1], '1 x Sopa');
      expect(texts[pase3 + 1], '1 x Queso');
      expect(texts[pase4 + 1], '1 x Tarta');
      expect(texts.where((t) => t.contains('DIRECTO')), isEmpty);
    });

    test('sin comensales el camarero va solo en su línea; sin camarero, los '
        'comensales a la derecha; sin ninguno, nada', () {
      final sinComensales = decodeEscPos(
        generarComandaCocina(comandaCocina(comensales: null)),
      ).texts;
      expect(sinComensales[4], 'Camarero: Ana');

      final sinCamarero = decodeEscPos(
        generarComandaCocina(comandaCocina(camarero: null)),
      ).texts;
      expect(sinCamarero[4].trim(), '4 comensales');
      expect(sinCamarero[4].runes.length, 48);

      final ninguno = decodeEscPos(
        generarComandaCocina(comandaCocina(camarero: ' ', comensales: null)),
      ).texts;
      expect(ninguno[4], '2º envío de la mesa · abierta 21:02');
    });

    test('respaldo: «Sin impresora de barra: llevar a barra» al final, en '
        'observaciones', () {
      final decoded = decodeEscPos(
        generarComandaCocina(comandaCocina(observaciones: respaldoBarra)),
      );
      final texts = decoded.texts;
      final i = indiceDe(decoded, 'OBSERVACIONES:');
      expect(i, isNonNegative);
      expect(decoded.lines[i].bold, isTrue);
      expect(texts[i - 1], '=' * 48);
      // Un solo separador: el que cierra las líneas hace de divisor.
      expect(texts[i - 2], '1 x Lubina a la sal');
      expect(texts[i + 1], respaldoBarra);
      expect(decoded.lines[i + 1].doubleHeight, isTrue);
      expect(texts.length, i + 2);
      expectFinal(decoded);
    });

    test('respaldo en la anulación y la reimpresión: OBSERVACIONES tras el '
        'único separador, el que cierra las líneas', () {
      final casos = {
        'anulación': (
          generarComandaCocina(anulacion(observaciones: respaldoBarra)),
          '-' * 48,
          '   Motivo: el cliente cambia de plato',
        ),
        'reimpresión': (
          generarComandaCocina(reimpresion(observaciones: respaldoBarra)),
          '=' * 48,
          '1 x Lubina a la sal',
        ),
      };
      for (final MapEntry(key: nombre, value: (bytes, separador, ultima))
          in casos.entries) {
        final decoded = decodeEscPos(bytes);
        final texts = decoded.texts;
        final i = indiceDe(decoded, 'OBSERVACIONES:');
        expect(i, isNonNegative, reason: nombre);
        expect(texts[i - 1], separador, reason: nombre);
        expect(texts[i - 2], ultima, reason: nombre);
        expect(texts[i + 1], respaldoBarra, reason: nombre);
        expect(texts.length, i + 2, reason: nombre);
      }
    });

    test('validaciones: comensales positivos, pase positivo y líneas con '
        'descripción', () {
      expect(
        () => generarComandaCocina(comandaCocina(comensales: 0)),
        failsWith('comensales'),
      );
      expect(
        () => generarComandaCocina(
          comandaCocina(
            lineas: const [
              LineaComandaPrint(cantidad: 1, descripcion: 'Sopa', pase: 0),
            ],
          ),
        ),
        failsWith('pase 0'),
      );
      expect(
        () => generarComandaCocina(
          comandaCocina(
            lineas: const [LineaComandaPrint(cantidad: 1, descripcion: ' ')],
          ),
        ),
        failsWith('Una línea de la comanda no tiene descripción'),
      );
    });
  });

  group('avance inicial', () {
    test(
      'con avanceInicial 3 el primer comando tras init, codepage y charset '
      'es feed [3] y después viene el título (comanda, MARCHAR y anulación)',
      () {
        final documentos = {
          'comanda': generarComandaCocina(comandaCocina(avanceInicial: 3)),
          'marchar': generarMarchar(marchar(avanceInicial: 3)),
          'anulación': generarComandaCocina(anulacion(avanceInicial: 3)),
        };
        for (final MapEntry(key: nombre, value: bytes) in documentos.entries) {
          final decoded = decodeEscPos(bytes);
          expect(decoded.commands.take(4).map((c) => c.name), [
            'init',
            'codepage',
            'charset',
            'feed',
          ], reason: nombre);
          expect(decoded.commands[3].args, [3], reason: nombre);
          expect(decoded.elements.first, isA<ElementoMarca>(), reason: nombre);
          expect(
            (decoded.elements.first as ElementoMarca).comando.name,
            'feed',
            reason: nombre,
          );
          final titulo = decoded.elements[1];
          expect(titulo, isA<ElementoTexto>(), reason: nombre);
          expect(
            (titulo as ElementoTexto).linea.text.trim(),
            nombre == 'anulación' ? 'ANULACIÓN COCINA' : 'COCINA',
            reason: nombre,
          );
          // El avance final sigue siendo de dos líneas.
          expect(decoded.named('feed').map((c) => c.args), [
            [3],
            [2],
          ], reason: nombre);
        }
      },
    );

    test('con 0 (valor por defecto) ningún feed antes del título', () {
      final documentos = {
        'comanda': generarComandaCocina(comandaCocina()),
        'marchar': generarMarchar(marchar()),
        'anulación': generarComandaCocina(anulacion()),
      };
      for (final MapEntry(key: nombre, value: bytes) in documentos.entries) {
        final decoded = decodeEscPos(bytes);
        expect(decoded.elements.first, isA<ElementoTexto>(), reason: nombre);
        expect(decoded.named('feed').single.args, [2], reason: nombre);
        expect(decoded.lines.first.text.trim(), isNotEmpty, reason: nombre);
      }
    });

    test(
      'con muestra, la banda MUESTRA va tras el avance y antes del título',
      () {
        for (final bytes in [
          generarComandaCocina(comandaCocina(muestra: true, avanceInicial: 2)),
          generarMarchar(marchar(muestra: true, avanceInicial: 2)),
        ]) {
          final decoded = decodeEscPos(bytes);
          expect(decoded.commands[3].name, 'feed');
          final muestra = decoded.lines.first;
          expect(muestra.text.trim(), 'MUESTRA · SIN VALIDEZ');
          expect(muestra.inverse, isTrue);
          expect(muestra.doubleHeight, isTrue);
          expect(decoded.lines[1].text, 'COCINA');
        }
      },
    );

    test('un avance fuera de 0..255 es un error de validación', () {
      expect(
        () => generarComandaCocina(comandaCocina(avanceInicial: 256)),
        failsWith('avance'),
      );
      expect(
        () => generarMarchar(marchar(avanceInicial: -1)),
        failsWith('avance'),
      );
    });
  });

  group('reimpresión (maqueta i)', () {
    test('banda con el motivo en inverso y doble tamaño, «Reimpresa …», '
        'separador y la comanda con ENVÍOS Nº 12, 15', () {
      final decoded = decodeEscPos(generarComandaCocina(reimpresion()));
      final texts = decoded.texts;
      expectWidthsWithin(decoded, PaperWidth.mm80);

      final marca = decoded.lines.first;
      expect(marca.text.trim(), 'REIMPRESIÓN · PREPARAR');
      expect(marca.inverse, isTrue);
      expect(marca.bold, isTrue);
      expect(marca.doubleHeight, isTrue);
      expect(marca.doubleWidth, isTrue);
      expect(marca.text.runes.length, 24);
      expect(marca.printedWidth, 48);
      expect(texts[1], 'Reimpresa 09/10/2026 21:40 · Caja 1');
      expect(decoded.lines[1].align, 1);
      expect(decoded.lines[1].inverse, isFalse);
      expect(texts[2], '-' * 48);
      expect(texts[3], 'COCINA');
      expectTituloGrande(decoded.lines[3]);
      expect(texts[4], 'Mesa 7');
      expect(texts[5], 'Terraza');
      expect(texts[6], 'ENVÍOS Nº 12, 15');
      expect(decoded.lines[6].bold, isTrue);
      expect(decoded.lines[6].doubleHeight, isTrue);
      expect(texts[7], 'Camarero: Ana${' ' * 23}4 comensales');
      expect(texts[8], '=' * 48);
      expect(texts.where((t) => t.startsWith('COMANDA')), isEmpty);
      expect(texts, contains('${'-' * 19} DIRECTO ${'-' * 20}'));
      expect(banda(decoded, '2. SEGUNDOS · ESPERAR').inverse, isTrue);
    });

    test('«COPIA · NO PREPARAR» según el motivo del DTO', () {
      final decoded = decodeEscPos(
        generarComandaCocina(reimpresion(banner: 'COPIA · NO PREPARAR')),
      );
      final marca = decoded.lines.first;
      expect(marca.text.trim(), 'COPIA · NO PREPARAR');
      expect(marca.inverse, isTrue);
      expect(marca.doubleWidth, isTrue);
      expect(decoded.texts.where((t) => t.contains('REIMPRESIÓN')), isEmpty);
      expect(decoded.texts[1], 'Reimpresa 09/10/2026 21:40 · Caja 1');
    });

    test('a 42 y 32 columnas la banda se parte por palabras y sigue en '
        'inverso y doble tamaño', () {
      for (final (paper, filas) in [
        (PaperWidth.mm80Dpi180, ['REIMPRESIÓN ·', 'PREPARAR']),
        (PaperWidth.mm58, ['REIMPRESIÓN ·', 'PREPARAR']),
      ]) {
        final decoded = decodeEscPos(
          generarComandaCocina(reimpresion(paper: paper)),
        );
        expectWidthsWithin(decoded, paper);
        final bandas = decoded.lines.take(2).toList();
        expect(bandas.map((l) => l.text.trim()), filas, reason: paper.name);
        for (final b in bandas) {
          expect(b.inverse, isTrue, reason: paper.name);
          expect(b.doubleHeight && b.doubleWidth, isTrue, reason: paper.name);
          expect(b.text.runes.length, paper.columns ~/ 2, reason: paper.name);
          expect(b.printedWidth, paper.columns, reason: paper.name);
        }
        // A 32 columnas la línea de detalle (35 caracteres) se parte.
        expect(decoded.texts[2], startsWith('Reimpresa 09/10/2026 21:40'));
        expect(decoded.lines[2].inverse, isFalse);
      }

      final copia42 = decodeEscPos(
        generarComandaCocina(
          reimpresion(
            paper: PaperWidth.mm80Dpi180,
            banner: 'COPIA · NO PREPARAR',
          ),
        ),
      );
      expect(copia42.lines.first.text.trim(), 'COPIA · NO PREPARAR');
      expect(copia42.lines[1].inverse, isFalse);
      final copia32 = decodeEscPos(
        generarComandaCocina(
          reimpresion(paper: PaperWidth.mm58, banner: 'COPIA · NO PREPARAR'),
        ),
      );
      expect(copia32.lines.take(2).map((l) => l.text.trim()), [
        'COPIA · NO',
        'PREPARAR',
      ]);
    });
  });

  group('anulación (maqueta h)', () {
    test('título en banda, mesa, zona, envío con hora y «Anulada», camarero, '
        'cantidad en negativo, nota original y motivo', () {
      final decoded = decodeEscPos(generarComandaCocina(anulacion()));
      final texts = decoded.texts;
      expectWidthsWithin(decoded, PaperWidth.mm80);

      final titulo = decoded.lines.first;
      expect(titulo.text.trim(), 'ANULACIÓN COCINA');
      expect(titulo.inverse, isTrue);
      expect(titulo.bold, isTrue);
      expect(titulo.doubleHeight, isTrue);
      expect(titulo.doubleWidth, isTrue);
      expect(titulo.text.runes.length, 24);
      expect(texts[1], 'Mesa 7');
      expectTituloGrande(decoded.lines[1]);
      expect(texts[2], 'Terraza');
      expect(texts[3], 'Comanda nº 12 (21:14)${' ' * 14}Anulada 21:30');
      expect(texts[4], 'Camarero: Ana');
      expect(texts[5], '-' * 48);
      expect(texts[6], '-1 x Lubina a la sal');
      expectLineaPreparacion(decoded.lines[6]);
      expect(texts[7], '   > sin sal');
      expect(decoded.lines[7].doubleHeight, isTrue);
      expect(decoded.lines[7].bold, isFalse);
      expect(decoded.lines[7].inverse, isFalse);
      expect(texts[8], '   Motivo: el cliente cambia de plato');
      expect(decoded.lines[8].bold, isTrue);
      expect(decoded.lines[8].doubleHeight, isFalse);
      expect(texts[9], '-' * 48);
      expect(texts, hasLength(10));
      expect(texts, isNot(contains('** ANULADA **')));
      expect(texts, isNot(contains('1 x Lubina a la sal')));
      expect(texts.where((t) => t.contains('ESPERAR')), isEmpty);
      expect(texts.where((t) => t.contains('DIRECTO')), isEmpty);
      expect(texts.where((t) => t.startsWith('COMANDA')), isEmpty);
      expect(decoded.named('drawer'), isEmpty);
      expectFinal(decoded);
    });

    test('varias líneas: un bloque por línea en negativo y, si vienen de '
        'envíos distintos, el envío de cada una', () {
      final decoded = decodeEscPos(
        generarComandaCocina(
          anulacion(
            numeroComanda: null,
            lineas: [
              LineaComandaPrint(
                cantidad: 2,
                descripcion: 'Caña',
                anulada: true,
                motivo: 'mesa vaciada',
                envio: 12,
                pedidaEn: aceptadaEn,
              ),
              LineaComandaPrint(
                cantidad: 1,
                descripcion: 'Flan',
                anulada: true,
                motivo: 'mesa vaciada',
                envio: 15,
                pedidaEn: DateTime(2026, 10, 9, 21, 20),
              ),
            ],
          ),
        ),
      );
      final texts = decoded.texts;
      expect(texts[3], 'Comandas nº 12, 15${' ' * 17}Anulada 21:30');
      final cana = indiceDe(decoded, '-2 x Caña');
      expect(cana, isNonNegative);
      expectLineaPreparacion(decoded.lines[cana]);
      expect(texts[cana + 1], '   Motivo: mesa vaciada');
      expect(texts[cana + 2], '   Comanda nº 12 (21:14)');
      expect(texts[cana + 3], '-1 x Flan');
      expect(texts[cana + 4], '   Motivo: mesa vaciada');
      expect(texts[cana + 5], '   Comanda nº 15 (21:20)');
    });

    test('DTO anterior al diseño: sin tituloEnBanda el título va centrado, '
        'sin relleno ni inverso, y el envío sale de las líneas', () {
      final decoded = decodeEscPos(
        generarComandaCocina(
          anulacion(tituloEnBanda: false, numeroComanda: null),
        ),
      );
      final titulo = decoded.lines.first;
      expect(titulo.text, 'ANULACIÓN COCINA');
      expect(titulo.inverse, isFalse);
      expectTituloGrande(titulo);
      expect(decoded.texts.join('|'), startsWith('ANULACIÓN COCINA|Mesa 7'));
      expect(decoded.texts[3], startsWith('Comanda nº 12 (21:14)'));
      expect(decoded.texts, contains('-1 x Lubina a la sal'));
    });

    test('un MARCHAR no admite líneas anuladas', () {
      expect(
        () => generarMarchar(
          MarcharPrintData(
            titulo: 'COCINA',
            mesa: 'Mesa 7',
            pase: 2,
            fechaHora: marchaEn,
            lineas: lineasAnuladas(),
          ),
        ),
        failsWith('anulada'),
      );
    });
  });

  group('MARCHAR (maquetas g y g2)', () {
    test('título, banda MARCHAR SEGUNDOS, mesa, zona, comanda de origen con '
        'la hora de la marcha, camarero y comensales, líneas con notas', () {
      final decoded = decodeEscPos(generarMarchar(marchar()));
      final texts = decoded.texts;
      expectWidthsWithin(decoded, PaperWidth.mm80);

      expect(texts[0], 'COCINA');
      expectTituloGrande(decoded.lines[0]);
      expect(decoded.lines[0].inverse, isFalse);
      final marca = decoded.lines[1];
      expect(marca.text.trim(), 'MARCHAR SEGUNDOS');
      expect(marca.inverse, isTrue);
      expect(marca.bold, isTrue);
      expect(marca.doubleHeight, isTrue);
      expect(marca.doubleWidth, isTrue);
      expect(marca.text.runes.length, 24);
      expect(texts[2], 'Mesa 7');
      expectTituloGrande(decoded.lines[2]);
      expect(texts[3], 'Terraza');
      expect(texts[4], 'Comanda nº 12 (21:14)${' ' * 15}Marcha 21:52');
      expect(texts[5], 'Camarero: Ana${' ' * 23}4 comensales');
      expect(texts[6], '-' * 48);
      expect(texts[7], '2 x Entrecot a la brasa');
      expectLineaPreparacion(decoded.lines[7]);
      expectNota(decoded.lines[8], '   > ', '1 poco hecho, 1 al punto');
      expect(texts[9], '1 x Lubina a la sal');
      expect(texts[10], '-' * 48);
      expect(texts, hasLength(11));
      expect(texts.where((t) => t.contains('REPETIDO')), isEmpty);
      expect(texts.where((t) => t.contains('ESPERAR')), isEmpty);
      expect(decoded.named('drawer'), isEmpty);
      expectFinal(decoded);
    });

    test('REPETIDO: línea con la hora de la marcha anterior y «Marcha» con '
        'la de esta', () {
      final decoded = decodeEscPos(
        generarMarchar(marchar(repetida: true, ultimaMarchaEn: marchaEn)),
      );
      final texts = decoded.texts;
      expect(texts[1].trim(), 'MARCHAR SEGUNDOS');
      expect(texts[2], 'REPETIDO · ya marchado a las 21:52');
      expect(decoded.lines[2].bold, isTrue);
      expect(decoded.lines[2].doubleHeight, isTrue);
      expect(decoded.lines[2].doubleWidth, isFalse);
      expect(decoded.lines[2].align, 1);
      expect(decoded.lines[2].inverse, isFalse);
      expect(texts[3], 'Mesa 7');
      expect(texts[5], 'Comanda nº 12 (21:14)${' ' * 15}Marcha 22:05');

      final sinHora = decodeEscPos(generarMarchar(marchar(repetida: true)));
      expect(sinHora.texts[2], 'REPETIDO');
    });

    test('varias comandas de origen, sin hora de pedido y pase sin nombre', () {
      final varias = decodeEscPos(
        generarMarchar(marchar(numerosComanda: const [15, 12, 15])),
      ).texts;
      expect(varias[4], startsWith('Comandas nº 12, 15 (21:14)'));
      expect(varias[4], endsWith('Marcha 21:52'));

      final sinHora = decodeEscPos(
        generarMarchar(marchar(conHoraDePedido: false)),
      ).texts;
      expect(sinHora[4], 'Comanda nº 12${' ' * 23}Marcha 21:52');

      final sinNada = decodeEscPos(
        generarMarchar(
          marchar(numerosComanda: const [], conHoraDePedido: false),
        ),
      ).texts;
      expect(sinNada[4].trim(), 'Marcha 21:52');

      final sinNombre = decodeEscPos(generarMarchar(marchar(nombrePase: null)));
      expect(sinNombre.lines[1].text.trim(), 'MARCHAR PASE 2');
    });

    test('respaldo: «Sin impresora de barra: llevar a barra» también en el '
        'MARCHAR', () {
      final decoded = decodeEscPos(
        generarMarchar(marchar(observaciones: respaldoBarra)),
      );
      final texts = decoded.texts;
      final i = indiceDe(decoded, 'OBSERVACIONES:');
      expect(i, 11);
      expect(decoded.lines[i].bold, isTrue);
      expect(texts[i - 1], '-' * 48);
      // Un solo separador: el que cierra las líneas hace de divisor.
      expect(texts[i - 2], '1 x Lubina a la sal');
      expect(texts[i + 1], respaldoBarra);
      expect(decoded.lines[i + 1].doubleHeight, isTrue);
      expect(texts.length, i + 2);
      expectFinal(decoded);
    });

    test('validaciones', () {
      MarcharPrintData con({
        String titulo = 'COCINA',
        String mesa = 'Mesa 7',
        int pase = 2,
        List<LineaComandaPrint> lineas = lineasSegundos,
        int? comensales,
        List<int> numerosComanda = const [],
      }) => MarcharPrintData(
        titulo: titulo,
        mesa: mesa,
        pase: pase,
        fechaHora: marchaEn,
        lineas: lineas,
        comensales: comensales,
        numerosComanda: numerosComanda,
      );
      expect(() => generarMarchar(con(titulo: ' ')), failsWith('título'));
      expect(() => generarMarchar(con(mesa: '')), failsWith('mesa'));
      expect(() => generarMarchar(con(pase: 0)), failsWith('pase'));
      expect(
        () => generarMarchar(con(lineas: const [])),
        failsWith('El MARCHAR no tiene líneas'),
      );
      expect(
        () => generarMarchar(
          con(lineas: const [LineaComandaPrint(cantidad: 1, descripcion: ' ')]),
        ),
        failsWith('Una línea del MARCHAR no tiene descripción'),
      );
      expect(
        () => generarMarchar(
          con(lineas: const [LineaComandaPrint(cantidad: 0, descripcion: 'x')]),
        ),
        failsWith('cantidad'),
      );
      expect(() => generarMarchar(con(comensales: 0)), failsWith('comensales'));
      expect(
        () => generarMarchar(con(numerosComanda: const [0])),
        failsWith('número de comanda'),
      );
    });
  });

  group('aviso sonoro', () {
    test('el generador no lo emite: termina en avance y corte, y el canal '
        'añade bytesAviso una sola vez al final del trabajo', () {
      final documentos = {
        'comanda': generarComandaCocina(comandaCocina()),
        'marchar': generarMarchar(marchar()),
        'anulación': generarComandaCocina(anulacion()),
        'reimpresión': generarComandaCocina(reimpresion()),
      };
      for (final MapEntry(key: nombre, value: bytes) in documentos.entries) {
        final decoded = decodeEscPos(bytes);
        expect(decoded.named('beep'), isEmpty, reason: nombre);
        expect(decoded.named('drawer'), isEmpty, reason: nombre);
        expectFinal(decoded);

        final trabajo = Uint8List.fromList([
          ...bytes,
          ...bytesAviso(ZumbadorModo.generico),
        ]);
        final conAviso = decodeEscPos(trabajo);
        expect(conAviso.commands.last.name, 'beep', reason: nombre);
        expect(conAviso.commands.last.args, [2, 2], reason: nombre);
        expect(conAviso.texts, decoded.texts, reason: nombre);
      }
    });
  });

  group('anchuras en los tres papeles', () {
    for (final paper in PaperWidth.values) {
      test(
        'ninguna línea supera las ${paper.columns} columnas (${paper.name})',
        () {
          final documentos = {
            'comanda': generarComandaCocina(comandaCocina(paper: paper)),
            'barra': generarComandaCocina(comandaBarra(paper: paper)),
            'anulación': generarComandaCocina(anulacion(paper: paper)),
            'reimpresión': generarComandaCocina(reimpresion(paper: paper)),
            'copia': generarComandaCocina(
              reimpresion(paper: paper, banner: 'COPIA · NO PREPARAR'),
            ),
            'marchar': generarMarchar(
              marchar(
                paper: paper,
                repetida: true,
                ultimaMarchaEn: marchaEn,
                observaciones: respaldoBarra,
              ),
            ),
          };
          for (final MapEntry(key: nombre, value: bytes)
              in documentos.entries) {
            final decoded = decodeEscPos(bytes);
            expectWidthsWithin(decoded, paper);
            // Las bandas ocupan todo el ancho; el doble ancho, la mitad de
            // caracteres.
            for (final l in decoded.lines.where(
              (l) => l.inverse && l.runs.length == 1,
            )) {
              expect(
                l.printedWidth,
                paper.columns,
                reason: '$nombre: ${l.text}',
              );
            }
            for (final l in decoded.lines.where((l) => l.doubleWidth)) {
              expect(
                l.text.runes.length,
                lessThanOrEqualTo(paper.columns ~/ 2),
                reason: '$nombre: ${l.text}',
              );
            }
          }
        },
      );
    }

    test('a 58 mm con nombres largos y sin comensales (mesa «Terraza '
        'exterior», zona «Zona fumadores»), «Camarero: …» va solo en su línea '
        'y se parte por palabras: ninguna línea supera 32 columnas', () {
      const mesa = 'Terraza exterior';
      const zona = 'Zona fumadores';
      const camarero = 'María José Fernández de la Torre';
      final documentos = {
        'comanda': generarComandaCocina(
          comandaCocina(
            paper: PaperWidth.mm58,
            mesa: mesa,
            zona: zona,
            camarero: camarero,
            comensales: null,
          ),
        ),
        'anulación': generarComandaCocina(
          anulacion(
            paper: PaperWidth.mm58,
            mesa: mesa,
            zona: zona,
            camarero: camarero,
          ),
        ),
        'marchar': generarMarchar(
          marchar(
            paper: PaperWidth.mm58,
            mesa: mesa,
            zona: zona,
            camarero: camarero,
            comensales: null,
          ),
        ),
      };
      for (final MapEntry(key: nombre, value: bytes) in documentos.entries) {
        final decoded = decodeEscPos(bytes);
        expectWidthsWithin(decoded, PaperWidth.mm58);
        expect(decoded.texts, containsAll([mesa, zona]), reason: nombre);
        final i = indiceDe(decoded, 'Camarero: María José Fernández');
        expect(i, isNonNegative, reason: '$nombre: ${decoded.texts}');
        expect(decoded.texts[i + 1], 'de la Torre', reason: nombre);
      }
    });

    test('a 32 columnas (maqueta k): la banda ESPERAR y las líneas largas se '
        'parten por palabras', () {
      final decoded = decodeEscPos(
        generarComandaCocina(
          comandaCocina(
            paper: PaperWidth.mm58,
            lineas: const [
              LineaComandaPrint(
                cantidad: 2,
                descripcion: 'Entrecot a la brasa con patatas',
                pase: 2,
                nombrePase: 'Segundos',
                esperar: true,
              ),
            ],
          ),
        ),
      );
      final texts = decoded.texts;
      expectWidthsWithin(decoded, PaperWidth.mm58);
      expect(texts[1], 'Mesa 7');
      expect(decoded.lines[1].printedWidth, 12);
      final esperar = banda(decoded, '2. SEGUNDOS · ESPERAR');
      expect(esperar.text.runes.length, 32);
      final i = decoded.lines.indexOf(esperar);
      expect(texts[i + 1], '2 x Entrecot a la brasa con');
      expect(texts[i + 2], 'patatas');
      expect(decoded.lines[i + 2].doubleHeight, isTrue);
    });
  });

  group('determinismo, igualdad de los DTOs e isolate', () {
    test('los mismos datos producen los mismos bytes', () {
      expect(
        generarComandaCocina(comandaCocina()),
        generarComandaCocina(comandaCocina()),
      );
      expect(
        generarComandaCocina(anulacion()),
        generarComandaCocina(anulacion()),
      );
      expect(
        generarComandaCocina(reimpresion()),
        generarComandaCocina(reimpresion()),
      );
      expect(generarMarchar(marchar()), generarMarchar(marchar()));
    });

    test('igualdad por valor de los DTOs', () {
      expect(comandaCocina(), comandaCocina());
      expect(comandaCocina(), isNot(comandaCocina(avanceInicial: 1)));
      expect(anulacion(), anulacion());
      expect(reimpresion(), isNot(reimpresion(banner: 'COPIA · NO PREPARAR')));
      expect(marchar(), marchar());
      expect(marchar(), isNot(marchar(repetida: true)));
      expect(lineasAnuladas(), lineasAnuladas());
    });

    test('en isolate producen lo mismo que la función pura', () async {
      const inline = InlineIsolateRunner();
      expect(
        await generarComandaCocinaEnIsolate(comandaCocina(), runner: inline),
        generarComandaCocina(comandaCocina()),
      );
      expect(
        await generarComandaCocinaEnIsolate(reimpresion(), runner: inline),
        generarComandaCocina(reimpresion()),
      );
      expect(
        await generarMarcharEnIsolate(marchar(repetida: true), runner: inline),
        generarMarchar(marchar(repetida: true)),
      );
      const spawning = SpawningIsolateRunner();
      final bytes = await generarComandaCocinaEnIsolate(
        anulacion(),
        runner: spawning,
      );
      expect(bytes, generarComandaCocina(anulacion()));
      expect(decodeEscPos(bytes).lines.first.text.trim(), 'ANULACIÓN COCINA');
      await expectLater(
        generarMarcharEnIsolate(marchar(avanceInicial: 999), runner: spawning),
        failsWith('avance'),
      );
    });
  });
}
