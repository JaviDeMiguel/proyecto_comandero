import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:proyecto_comandero/core/errors/app_exception.dart';
import 'package:proyecto_comandero/core/isolates/escpos/escpos.dart';
import 'package:proyecto_comandero/core/isolates/isolate_runner.dart';
import 'package:test/test.dart';

import 'escpos_decoder.dart';

/// Logo de prueba: 500×100 (más ancho que el papel de 58 mm) con un bloque
/// negro a la izquierda.
Uint8List logoPng() {
  final image = img.Image(width: 500, height: 100)
    ..clear(img.ColorRgb8(255, 255, 255));
  img.fillRect(
    image,
    x1: 0,
    y1: 0,
    x2: 249,
    y2: 99,
    color: img.ColorRgb8(0, 0, 0),
  );
  return img.encodePng(image);
}

final fecha = DateTime(2026, 3, 5, 21, 7, 9);

const empresaCompleta = EmpresaTicket(
  nombre: 'Bar La Mancha Moderna',
  cifnif: 'B12345678',
  direccion: 'Calle Mayor, 12',
  codpostal: '13001',
  ciudad: 'Ciudad Real',
  telefono: '926 123 456',
  pie: 'IVA incluido. Gracias por su visita.',
);

const empresaMinima = EmpresaTicket(nombre: 'Bar Pepe');

TicketPrintData ticketCompleto({
  PaperWidth paper = PaperWidth.mm80,
  Uint8List? logo,
}) => TicketPrintData(
  empresa: logo == null
      ? empresaCompleta
      : EmpresaTicket(
          nombre: empresaCompleta.nombre,
          cifnif: empresaCompleta.cifnif,
          pie: empresaCompleta.pie,
          logoPng: logo,
        ),
  tituloDocumento: 'FACTURA SIMPLIFICADA',
  codigoFactura: 'FS2026-00123',
  numero2: 'TPV-ab12-9f3e',
  fechaHora: fecha,
  mesa: '12',
  camarero: 'Ana',
  lineas: const [
    LineaTicket(
      descripcion: 'Café con leche',
      cantidad: 2,
      pvpUnitarioCents: 150,
      importeCents: 300,
    ),
    LineaTicket(
      descripcion: 'Hamburguesa completa con queso, bacon y huevo',
      cantidad: 1,
      pvpUnitarioCents: 1250,
      importeCents: 1250,
      nota: 'sin cebolla',
    ),
    LineaTicket(
      descripcion: 'Jamón ibérico',
      cantidad: 0.5,
      pvpUnitarioCents: 2400,
      importeCents: 1200,
    ),
  ],
  desglose: const [
    DesgloseIvaTicketPrint(ivaPct: 10, baseCents: 2500, cuotaCents: 250),
  ],
  totalCents: 2750,
  metodoPago: 'Efectivo',
  entregadoCents: 3000,
  cambioCents: 250,
  avisos: const ['COPIA'],
  paper: paper,
  abrirCajon: true,
);

TicketPrintData ticketMinimo() => TicketPrintData(
  empresa: empresaMinima,
  tituloDocumento: 'TICKET',
  fechaHora: fecha,
  lineas: const [
    LineaTicket(
      descripcion: 'Caña',
      cantidad: 1,
      pvpUnitarioCents: 180,
      importeCents: 180,
    ),
  ],
  desglose: const [],
  totalCents: 180,
  metodoPago: 'Tarjeta',
  paper: PaperWidth.mm58,
  cortar: false,
);

KitchenOrderPrintData comanda({PaperWidth paper = PaperWidth.mm80}) =>
    KitchenOrderPrintData(
      titulo: 'COCINA',
      mesa: '7',
      camarero: 'Luis',
      fechaHora: fecha,
      numeroComanda: 'C-0042',
      lineas: const [
        LineaComandaPrint(cantidad: 2, descripcion: 'Entrecot'),
        LineaComandaPrint(
          cantidad: 1,
          descripcion: 'Ensalada mixta',
          nota: 'sin atún, aliño aparte',
        ),
        LineaComandaPrint(
          cantidad: 1,
          descripcion: 'Sopa castellana',
          anulada: true,
        ),
      ],
      observaciones: 'Niño pequeño: sacar primero la ensalada',
      paper: paper,
    );

MarcharPrintData marchar({PaperWidth paper = PaperWidth.mm80}) =>
    MarcharPrintData(
      titulo: 'COCINA',
      mesa: '7',
      zona: 'Terraza',
      pase: 2,
      nombrePase: 'Segundos',
      numerosComanda: const [12],
      pedidaEn: DateTime(2026, 3, 5, 21, 14),
      fechaHora: DateTime(2026, 3, 5, 21, 52),
      camarero: 'Ana',
      comensales: 4,
      lineas: const [
        LineaComandaPrint(
          cantidad: 2,
          descripcion: 'Entrecot a la brasa',
          nota: '1 poco hecho, 1 al punto',
          pase: 2,
        ),
        LineaComandaPrint(cantidad: 1, descripcion: 'Lubina a la sal', pase: 2),
      ],
      paper: paper,
    );

ZReportPrintData informeZ({
  List<PartidaZPrint> partidas = const [],
  PaperWidth paper = PaperWidth.mm80,
  Uint8List? logo,
}) => ZReportPrintData(
  empresa: logo == null
      ? empresaCompleta
      : EmpresaTicket(nombre: 'Bar La Mancha Moderna', logoPng: logo),
  nombreTpv: 'Caja 1',
  fecha: DateTime(2026, 3, 5),
  numTickets: 42,
  numAnulados: 2,
  ventasTotalCents: 123456,
  ventasEfectivoCents: 70000,
  ventasTarjetaCents: 53456,
  ticketMedioCents: 2939,
  porIva: const [
    DesgloseIvaTicketPrint(ivaPct: 10, baseCents: 100000, cuotaCents: 10000),
    DesgloseIvaTicketPrint(ivaPct: 21, baseCents: 11120, cuotaCents: 2336),
  ],
  fondoCajaCents: 10000,
  retiradasCents: 5000,
  efectivoEsperadoCents: 75000,
  efectivoContadoCents: 74500,
  descuadreCents: -500,
  partidas: partidas,
  paper: paper,
);

const partidasDescuadre = <PartidaZPrint>[
  (
    codsubcuenta: '6590000000',
    concepto: 'Faltante de caja Z 05/03/2026',
    debeCents: 500,
    haberCents: 0,
  ),
  (
    codsubcuenta: '5700000000',
    concepto: 'Faltante de caja Z 05/03/2026',
    debeCents: 0,
    haberCents: 500,
  ),
];

PrecuentaPrintData precuenta({int? comensales = 3, String mesa = '12'}) =>
    PrecuentaPrintData(
      empresa: empresaCompleta,
      fechaHora: fecha,
      mesa: mesa,
      camarero: 'Ana',
      comensales: comensales,
      lineas: ticketCompleto().lineas,
      desglose: ticketCompleto().desglose,
      totalCents: 2750,
    );

void main() {
  group('generarPrecuenta', () {
    test('la cabecera imprime el sitio web, recortado, en su propia línea '
        'tras el teléfono; en blanco no imprime nada', () {
      PrecuentaPrintData conWeb(String? web) => PrecuentaPrintData(
        empresa: EmpresaTicket(
          nombre: 'Bar Pepe',
          telefono: '926 123 456',
          web: web,
        ),
        fechaHora: fecha,
        mesa: '1',
        lineas: ticketMinimo().lineas,
        desglose: const [],
        totalCents: 180,
      );
      final conSitio = decodeEscPos(
        generarPrecuenta(conWeb(' www.barpepe.es ')),
      ).texts;
      final telefono = conSitio.indexOf('Tel.: 926 123 456');
      expect(telefono, greaterThan(0));
      expect(conSitio[telefono + 1], 'www.barpepe.es');
      for (final web in [null, '', '   ']) {
        final texts = decodeEscPos(generarPrecuenta(conWeb(web))).texts;
        expect(texts, isNot(contains('www.barpepe.es')));
        expect(texts[texts.indexOf('Tel.: 926 123 456') + 1], '-' * 48);
      }
    });

    test('cuenta provisional: sin datos fiscales, sin pago y sin cajón', () {
      final decoded = decodeEscPos(generarPrecuenta(precuenta()));
      final texts = decoded.texts;
      expectWidthsWithin(decoded, PaperWidth.mm80);

      expect(texts, contains('Bar La Mancha Moderna'));
      final titulo = decoded.lines.firstWhere((l) => l.text == 'PRECUENTA');
      expect(titulo.bold, isTrue);
      expect(titulo.align, 1);
      expect(texts, contains('NO VÁLIDO COMO FACTURA'));
      // «Mesa 12» (sin el «Mesa:» de antes) con los comensales a la derecha;
      // debajo, el camarero con la fecha y la hora.
      expect(
        texts.firstWhere((t) => t.startsWith('Mesa 12')),
        endsWith('3 comensales'),
      );
      expect(
        texts.firstWhere((t) => t.startsWith('Camarero: Ana')),
        endsWith('05/03/2026 21:07'),
      );
      expect(
        texts.firstWhere((t) => t.startsWith('2 x Café con leche')),
        endsWith('3,00'),
      );
      expect(texts, contains('   * sin cebolla'));
      expect(
        decoded.lines.firstWhere((l) => l.text.startsWith('TOTAL')).text,
        endsWith('27,50 €'),
      );
      expect(texts.firstWhere((t) => t.startsWith('10 %')), endsWith('2,50'));
      // 27,50 / 3 = 9,1666… -> 9,17 €
      expect(
        texts.firstWhere((t) => t.startsWith('Por comensal (3)')),
        endsWith('9,17 €'),
      );
      final aviso = decoded.lines.firstWhere(
        (l) => l.text == 'DOCUMENTO SIN VALIDEZ FISCAL',
      );
      expect(aviso.bold, isTrue);
      expect(texts, contains('IVA incluido. Gracias por su visita.'));

      // Nada que pueda confundirse con una factura o un cobro.
      for (final prohibido in [
        'TICKET',
        'FACTURA SIMPLIFICADA',
        'Nº ',
        'Pendiente de facturar',
        'Ref.',
        'Forma de pago',
        'Entregado',
        'Cambio',
        'QR tributario',
      ]) {
        expect(
          texts.where((t) => t.startsWith(prohibido)),
          isEmpty,
          reason: prohibido,
        );
      }
      expect(decoded.named('drawer'), isEmpty);
      expect(decoded.named('cut'), hasLength(1));
    });

    test('un solo comensal o sin comensales no reparte el total', () {
      for (final n in [null, 1]) {
        final texts = decodeEscPos(generarPrecuenta(precuenta(comensales: n)))
            .texts;
        expect(texts.where((t) => t.startsWith('Por comensal')), isEmpty);
      }
    });

    test('validaciones', () {
      Matcher failsWith(String fragment) => throwsA(
        isA<ValidationException>().having(
          (e) => e.message,
          'message',
          contains(fragment),
        ),
      );
      expect(() => generarPrecuenta(precuenta(mesa: ' ')), failsWith('mesa'));
      expect(
        () => generarPrecuenta(precuenta(comensales: 0)),
        failsWith('comensales'),
      );
      expect(
        () => generarPrecuenta(
          PrecuentaPrintData(
            empresa: empresaMinima,
            fechaHora: fecha,
            mesa: '1',
            lineas: const [],
            desglose: const [],
            totalCents: 0,
          ),
        ),
        failsWith('líneas'),
      );
    });

    test('en isolate produce lo mismo que la función pura', () async {
      final data = precuenta();
      expect(
        await generarPrecuentaEnIsolate(
          data,
          runner: const InlineIsolateRunner(),
        ),
        generarPrecuenta(data),
      );
      expect(await generarPrecuentaEnIsolate(data), generarPrecuenta(data));
    });
  });

  group('generarTicket', () {
    test('ticket completo (80 mm): estructura y contenido', () {
      final bytes = generarTicket(ticketCompleto());
      final decoded = decodeEscPos(bytes);
      final texts = decoded.texts;

      expect(decoded.commands.first.name, 'init');
      expect(decoded.commands[1].args, [19]);
      expectWidthsWithin(decoded, PaperWidth.mm80);

      // Cabecera de empresa centrada y nombre en negrita.
      final nombre = decoded.lines.firstWhere(
        (l) => l.text == 'Bar La Mancha Moderna',
      );
      expect(nombre.align, 1);
      expect(nombre.bold, isTrue);
      expect(texts, contains('NIF: B12345678'));
      expect(texts, isNot(contains('CIF/NIF: B12345678')));
      expect(texts, contains('Calle Mayor, 12'));
      expect(texts, contains('13001 Ciudad Real'));
      expect(texts, contains('Tel.: 926 123 456'));

      // Título y código de factura: «Nº <código>» y «Ref. <numero2>».
      expect(texts, contains('FACTURA SIMPLIFICADA'));
      expect(texts, contains('Nº FS2026-00123'));
      expect(texts, isNot(contains('Factura: FS2026-00123')));
      expect(texts, isNot(contains('Pendiente de facturar')));
      expect(texts, contains('Ref. TPV-ab12-9f3e'));
      expect(texts, isNot(contains('Ref.: TPV-ab12-9f3e')));
      expect(texts, contains('05/03/2026 21:07'));

      // Mesa (sin el «Mesa:» de antes) y camarero en la misma fila.
      final mesaLine = texts.firstWhere((t) => t.startsWith('Mesa 12'));
      expect(mesaLine, endsWith('Camarero: Ana'));
      expect(mesaLine.length, 48);

      // Líneas: cantidad x descripción ... importe sin símbolo.
      final cafe = texts.firstWhere((t) => t.startsWith('2 x Café con leche'));
      expect(cafe, endsWith('3,00'));
      expect(cafe.length, 48);
      expect(texts, contains('   (1,50 €/ud)'));
      final jamon = texts.firstWhere(
        (t) => t.startsWith('0,5 x Jamón ibérico'),
      );
      expect(jamon, endsWith('12,00'));
      expect(texts, contains('   * sin cebolla'));

      // Total en doble tamaño y negrita.
      final total = decoded.lines.firstWhere((l) => l.text.startsWith('TOTAL'));
      expect(total.bold, isTrue);
      expect(total.doubleHeight, isTrue);
      expect(total.doubleWidth, isTrue);
      expect(total.text, endsWith('27,50 €'));
      expect(total.text.runes.length, 24);

      // Desglose de IVA alineado en columnas.
      final cabeceraIva = texts.firstWhere((t) => t.startsWith('IVA'));
      expect(cabeceraIva, endsWith('Cuota'));
      final filaIva = texts.firstWhere((t) => t.startsWith('10 %'));
      expect(filaIva, '10 %${' ' * 12}${' ' * 11}25,00${' ' * 12}2,50');

      // Pago, entregado y cambio.
      expect(
        texts.firstWhere((t) => t.startsWith('Forma de pago')),
        endsWith('Efectivo'),
      );
      expect(
        texts.firstWhere((t) => t.startsWith('Entregado')),
        endsWith('30,00 €'),
      );
      expect(
        texts.firstWhere((t) => t.startsWith('Cambio')),
        endsWith('2,50 €'),
      );

      // Aviso destacado y pie.
      final copia = decoded.lines.firstWhere((l) => l.text == 'COPIA');
      expect(copia.bold, isTrue);
      expect(copia.doubleHeight, isTrue);
      expect(copia.align, 1);
      expect(texts, contains('IVA incluido. Gracias por su visita.'));

      // El cajón va justo después del init (init, codepage, charset, cajón),
      // para abrirse en cuanto empieza el trabajo; al final, avance y corte.
      expect(decoded.commands.take(4).map((c) => c.name), [
        'init',
        'codepage',
        'charset',
        'drawer',
      ]);
      expect(decoded.named('drawer'), hasLength(1));
      final tail = decoded.commands.sublist(decoded.commands.length - 2);
      expect(tail.map((c) => c.name), ['feed', 'cut']);
      expect(tail[1].args, [66, 3]);
    });

    test('ticket mínimo (58 mm): sin opcionales, sin cambio, sin corte', () {
      final decoded = decodeEscPos(generarTicket(ticketMinimo()));
      final texts = decoded.texts;
      expectWidthsWithin(decoded, PaperWidth.mm58);

      expect(texts, contains('Bar Pepe'));
      expect(texts.where((t) => t.startsWith('CIF')), isEmpty);
      expect(texts.where((t) => t.startsWith('Tel')), isEmpty);
      expect(texts, contains('TICKET'));
      expect(texts, contains('Pendiente de facturar'));
      expect(texts.where((t) => t.startsWith('Ref.')), isEmpty);
      expect(texts.where((t) => t.startsWith('Mesa')), isEmpty);
      expect(texts.where((t) => t.contains('/ud')), isEmpty);
      expect(texts.where((t) => t.startsWith('IVA')), isEmpty);
      expect(texts.where((t) => t.startsWith('Entregado')), isEmpty);
      expect(texts.where((t) => t.startsWith('Cambio')), isEmpty);
      expect(
        texts.firstWhere((t) => t.startsWith('TOTAL')),
        'TOTAL     1,80 €',
      );
      expect(decoded.named('cut'), isEmpty);
      expect(decoded.named('drawer'), isEmpty);
      expect(decoded.named('raster'), isEmpty);
    });

    test(
      'descripción larga se parte en varias filas con el importe al final',
      () {
        final decoded = decodeEscPos(
          generarTicket(ticketCompleto(paper: PaperWidth.mm58)),
        );
        final texts = decoded.texts;
        final start = texts.indexWhere((t) => t.startsWith('1 x Hamburguesa'));
        expect(start, isNonNegative);
        // 49 caracteres en 26 de anchura útil (32 − "12,50" − 1): dos filas.
        expect(texts[start], '1 x Hamburguesa completa');
        expect(texts[start].runes.length, lessThanOrEqualTo(26));
        expect(texts[start + 1], 'con queso, bacon y huevo   12,50');
        expect(texts[start + 1].runes.length, 32);
        expect(texts[start + 2], '   * sin cebolla');
      },
    );

    test('con logo: raster antes del nombre, reescalado al papel', () {
      final decoded = decodeEscPos(
        generarTicket(ticketCompleto(paper: PaperWidth.mm58, logo: logoPng())),
      );
      final raster = decoded.named('raster').single;
      expect(raster.args, [0, 48, 77]); // 384 puntos; 100 × 384 / 500 = 76,8
      // Tras init, codepage, charset y el pulso del cajón.
      expect(decoded.commands.indexOf(raster), 4);
      expect(decoded.commands[3].name, 'drawer');
    });

    test('es determinista', () {
      final a = generarTicket(ticketCompleto(logo: logoPng()));
      final b = generarTicket(ticketCompleto(logo: logoPng()));
      expect(a, b);
    });

    test('validaciones', () {
      final base = ticketMinimo();
      TicketPrintData copy({
        EmpresaTicket? empresa,
        String? titulo,
        List<LineaTicket>? lineas,
        List<DesgloseIvaTicketPrint>? desglose,
        String? metodoPago,
        int? entregado,
        int? cambio,
      }) => TicketPrintData(
        empresa: empresa ?? base.empresa,
        tituloDocumento: titulo ?? base.tituloDocumento,
        fechaHora: base.fechaHora,
        lineas: lineas ?? base.lineas,
        desglose: desglose ?? base.desglose,
        totalCents: base.totalCents,
        metodoPago: metodoPago ?? base.metodoPago,
        entregadoCents: entregado,
        cambioCents: cambio,
      );

      Matcher failsWith(String fragment) => throwsA(
        isA<ValidationException>().having(
          (e) => e.message,
          'message',
          contains(fragment),
        ),
      );

      expect(
        () => generarTicket(copy(empresa: const EmpresaTicket(nombre: ' '))),
        failsWith('nombre de la empresa'),
      );
      expect(() => generarTicket(copy(titulo: '')), failsWith('título'));
      expect(() => generarTicket(copy(lineas: const [])), failsWith('líneas'));
      expect(
        () => generarTicket(
          copy(
            lineas: const [
              LineaTicket(
                descripcion: 'x',
                cantidad: 0,
                pvpUnitarioCents: 1,
                importeCents: 0,
              ),
            ],
          ),
        ),
        failsWith('cantidad 0'),
      );
      expect(
        () => generarTicket(
          copy(
            lineas: const [
              LineaTicket(
                descripcion: '',
                cantidad: 1,
                pvpUnitarioCents: 1,
                importeCents: 1,
              ),
            ],
          ),
        ),
        failsWith('descripción'),
      );
      expect(
        () => generarTicket(
          copy(
            desglose: const [
              DesgloseIvaTicketPrint(ivaPct: -1, baseCents: 0, cuotaCents: 0),
            ],
          ),
        ),
        failsWith('IVA'),
      );
      expect(
        () => generarTicket(copy(metodoPago: '')),
        failsWith('forma de pago'),
      );
      expect(() => generarTicket(copy(entregado: -1)), failsWith('entregado'));
      expect(() => generarTicket(copy(cambio: -1)), failsWith('cambio'));
    });
  });

  group('generarComandaCocina', () {
    test('comanda completa: mesa en doble tamaño, líneas en doble altura', () {
      final decoded = decodeEscPos(generarComandaCocina(comanda()));
      final texts = decoded.texts;
      expectWidthsWithin(decoded, PaperWidth.mm80);

      // El título del puesto es la primera línea, en doble alto y ancho,
      // centrado por la impresora y sin relleno.
      final titulo = decoded.lines.firstWhere((l) => l.text == 'COCINA');
      expect(titulo, same(decoded.lines.first));
      expect(titulo.bold, isTrue);
      expect(titulo.doubleHeight, isTrue);
      expect(titulo.doubleWidth, isTrue);
      expect(titulo.align, 1);

      // La mesa tal cual: «Mesa 7», sin el prefijo «MESA».
      final mesa = decoded.lines.firstWhere((l) => l.text == 'Mesa 7');
      expect(mesa.doubleHeight, isTrue);
      expect(mesa.doubleWidth, isTrue);
      expect(mesa.bold, isTrue);
      expect(texts, isNot(contains('MESA 7')));

      // «COMANDA Nº n · hh:mm» sustituye a «Comanda n» y a la línea de fecha.
      final envio = decoded.lines.firstWhere(
        (l) => l.text == 'COMANDA Nº C-0042 · 21:07',
      );
      expect(envio.bold, isTrue);
      expect(envio.doubleHeight, isTrue);
      expect(texts, isNot(contains('Comanda C-0042')));
      expect(texts, isNot(contains('05/03/2026 21:07')));
      // Sin comensales, el camarero sigue en su propia línea.
      expect(texts, contains('Camarero: Luis'));

      final entrecot = decoded.lines.firstWhere(
        (l) => l.text == '2 x Entrecot',
      );
      expect(entrecot.doubleHeight, isTrue);
      expect(entrecot.doubleWidth, isFalse);
      expect(entrecot.bold, isTrue);

      // La nota: el prefijo sin inverso y el texto en inverso.
      final nota = decoded.lines.firstWhere(
        (l) => l.text == '   > sin atún, aliño aparte',
      );
      expect(nota.doubleHeight, isTrue);
      expect(nota.runs.map((r) => r.inverse), [false, true]);

      // La línea anulada va con la cantidad en negativo (decisión D.1).
      expect(texts, isNot(contains('** ANULADA **')));
      final anulada = decoded.lines.firstWhere(
        (l) => l.text == '-1 x Sopa castellana',
      );
      expect(anulada.bold, isTrue);
      expect(anulada.doubleHeight, isTrue);
      expect(texts, isNot(contains('1 x Sopa castellana')));

      final obsIdx = texts.indexOf('OBSERVACIONES:');
      expect(obsIdx, isNonNegative);
      expect(texts[obsIdx + 1], 'Niño pequeño: sacar primero la ensalada');

      expect(decoded.named('cut').single.args, [66, 3]);
      expect(decoded.named('drawer'), isEmpty);
      expect(decoded.named('raster'), isEmpty);
    });

    test('comanda mínima en 58 mm sin opcionales', () {
      final data = KitchenOrderPrintData(
        titulo: 'BARRA',
        mesa: 'Terraza 3',
        fechaHora: fecha,
        lineas: const [LineaComandaPrint(cantidad: 3, descripcion: 'Caña')],
        paper: PaperWidth.mm58,
        cortar: false,
      );
      final decoded = decodeEscPos(generarComandaCocina(data));
      expectWidthsWithin(decoded, PaperWidth.mm58);
      expect(decoded.texts, contains('Terraza 3'));
      expect(decoded.texts, isNot(contains('MESA Terraza 3')));
      // Sin número de envío: «COMANDA · hh:mm», que no empieza por «Comanda».
      expect(decoded.texts, contains('COMANDA · 21:07'));
      expect(decoded.texts.where((t) => t.startsWith('Comanda')), isEmpty);
      expect(decoded.texts.where((t) => t.startsWith('Camarero')), isEmpty);
      expect(decoded.texts, isNot(contains('OBSERVACIONES:')));
      expect(decoded.texts, contains('3 x Caña'));
      expect(decoded.named('cut'), isEmpty);
    });

    test('mesa larga en doble anchura se ajusta a 16 columnas (58 mm)', () {
      final data = KitchenOrderPrintData(
        titulo: 'COCINA',
        mesa: 'Comedor principal mesa 14',
        fechaHora: fecha,
        lineas: const [LineaComandaPrint(cantidad: 1, descripcion: 'Agua')],
        paper: PaperWidth.mm58,
      );
      final decoded = decodeEscPos(generarComandaCocina(data));
      // El título también va en doble ancho: se excluye del filtro.
      final mesaLines = decoded.lines
          .where((l) => l.doubleWidth && l.text != 'COCINA')
          .toList();
      expect(mesaLines.length, greaterThan(1));
      for (final l in mesaLines) {
        expect(l.text.runes.length, lessThanOrEqualTo(16));
      }
      expect(mesaLines.first.text, 'Comedor');
    });

    test('es determinista', () {
      expect(generarComandaCocina(comanda()), generarComandaCocina(comanda()));
    });

    test('validaciones', () {
      expect(
        () => generarComandaCocina(
          KitchenOrderPrintData(
            titulo: '',
            mesa: '1',
            fechaHora: fecha,
            lineas: const [LineaComandaPrint(cantidad: 1, descripcion: 'a')],
          ),
        ),
        throwsA(isA<ValidationException>()),
      );
      expect(
        () => generarComandaCocina(
          KitchenOrderPrintData(
            titulo: 'COCINA',
            mesa: '',
            fechaHora: fecha,
            lineas: const [LineaComandaPrint(cantidad: 1, descripcion: 'a')],
          ),
        ),
        throwsA(isA<ValidationException>()),
      );
      expect(
        () => generarComandaCocina(
          KitchenOrderPrintData(
            titulo: 'COCINA',
            mesa: '1',
            fechaHora: fecha,
            lineas: const [],
          ),
        ),
        throwsA(isA<ValidationException>()),
      );
      expect(
        () => generarComandaCocina(
          KitchenOrderPrintData(
            titulo: 'COCINA',
            mesa: '1',
            fechaHora: fecha,
            lineas: const [LineaComandaPrint(cantidad: -1, descripcion: 'a')],
          ),
        ),
        throwsA(
          isA<ValidationException>().having(
            (e) => e.message,
            'message',
            contains('cantidad -1'),
          ),
        ),
      );
    });
  });

  group('generarInformeZ', () {
    test(
      'con asiento vacío: todas las magnitudes y "Nada que contabilizar"',
      () {
        final decoded = decodeEscPos(generarInformeZ(informeZ()));
        final texts = decoded.texts;
        expectWidthsWithin(decoded, PaperWidth.mm80);

        final titulo = decoded.lines.firstWhere((l) => l.text == 'INFORME Z');
        expect(titulo.bold, isTrue);
        expect(titulo.doubleHeight, isTrue);

        String valueOf(String label) => texts
            .firstWhere((t) => t.startsWith(label))
            .trim()
            .split(RegExp(r'\s{2,}'))
            .last;

        expect(valueOf('TPV'), 'Caja 1');
        expect(valueOf('Fecha'), '05/03/2026');
        expect(valueOf('Tickets emitidos'), '42');
        expect(valueOf('Tickets anulados'), '2');
        expect(valueOf('Ventas totales'), '1.234,56 €');
        expect(valueOf('Ventas en efectivo'), '700,00 €');
        expect(valueOf('Ventas con tarjeta'), '534,56 €');
        expect(valueOf('Ticket medio'), '29,39 €');
        expect(valueOf('Fondo de caja'), '100,00 €');
        expect(valueOf('Retiradas'), '50,00 €');
        expect(valueOf('Efectivo esperado'), '750,00 €');
        expect(valueOf('Efectivo contado'), '745,00 €');
        expect(valueOf('Descuadre (faltante)'), '-5,00 €');

        expect(texts, contains('DESGLOSE DE IVA'));
        expect(
          texts.firstWhere((t) => t.startsWith('10 %')),
          endsWith('100,00'),
        );
        expect(
          texts.firstWhere((t) => t.startsWith('21 %')),
          endsWith('23,36'),
        );

        final asientoIdx = texts.indexOf('ASIENTO PROPUESTO');
        expect(asientoIdx, isNonNegative);
        expect(texts[asientoIdx + 1], 'Nada que contabilizar');
        expect(texts.where((t) => t.startsWith('Subcuenta')), isEmpty);
      },
    );

    test('con partidas: tabla Debe/Haber y totales cuadrados', () {
      final decoded = decodeEscPos(
        generarInformeZ(informeZ(partidas: partidasDescuadre)),
      );
      final texts = decoded.texts;
      expectWidthsWithin(decoded, PaperWidth.mm80);

      final header = texts.firstWhere((t) => t.startsWith('Subcuenta'));
      expect(header, endsWith('Haber'));
      expect(header.length, 48);

      final fila659 = texts.firstWhere((t) => t.startsWith('6590000000'));
      expect(fila659, '6590000000${' ' * 6}${' ' * 12}5,00${' ' * 16}');
      final fila570 = texts.firstWhere((t) => t.startsWith('5700000000'));
      expect(fila570, '5700000000${' ' * 6}${' ' * 16}${' ' * 12}5,00');
      expect(
        texts.where((t) => t == 'Faltante de caja Z 05/03/2026').length,
        2,
      );

      final total = decoded.lines.firstWhere((l) => l.text.startsWith('TOTAL'));
      expect(total.bold, isTrue);
      expect(total.text, 'TOTAL${' ' * 11}${' ' * 12}5,00${' ' * 12}5,00');
      expect(texts, isNot(contains('ASIENTO DESCUADRADO')));
      expect(texts, isNot(contains('Nada que contabilizar')));
    });

    test('asiento descuadrado se señala', () {
      final decoded = decodeEscPos(
        generarInformeZ(
          informeZ(
            partidas: const [
              (
                codsubcuenta: '5700000000',
                concepto: 'x',
                debeCents: 100,
                haberCents: 0,
              ),
            ],
          ),
        ),
      );
      expect(decoded.texts, contains('ASIENTO DESCUADRADO'));
    });

    test('sin recuento y con sobrante (58 mm)', () {
      final base = informeZ(paper: PaperWidth.mm58);
      final data = ZReportPrintData(
        empresa: base.empresa,
        nombreTpv: base.nombreTpv,
        fecha: base.fecha,
        numTickets: 0,
        numAnulados: 0,
        ventasTotalCents: 0,
        ventasEfectivoCents: 0,
        ventasTarjetaCents: 0,
        ticketMedioCents: 0,
        porIva: const [],
        fondoCajaCents: 10000,
        retiradasCents: 0,
        efectivoEsperadoCents: 10000,
        descuadreCents: 300,
        paper: PaperWidth.mm58,
      );
      final decoded = decodeEscPos(generarInformeZ(data));
      expectWidthsWithin(decoded, PaperWidth.mm58);
      expect(
        decoded.texts.firstWhere((t) => t.startsWith('Efectivo contado')),
        endsWith('sin recuento'),
      );
      expect(
        decoded.texts.firstWhere((t) => t.startsWith('Descuadre (sobrante)')),
        endsWith('3,00 €'),
      );
      expect(decoded.texts, isNot(contains('DESGLOSE DE IVA')));
    });

    test('es determinista', () {
      expect(
        generarInformeZ(informeZ(partidas: partidasDescuadre)),
        generarInformeZ(informeZ(partidas: partidasDescuadre)),
      );
    });

    test('validaciones', () {
      final base = informeZ();
      expect(
        () => generarInformeZ(
          ZReportPrintData(
            empresa: base.empresa,
            nombreTpv: '',
            fecha: base.fecha,
            numTickets: 1,
            numAnulados: 0,
            ventasTotalCents: 0,
            ventasEfectivoCents: 0,
            ventasTarjetaCents: 0,
            ticketMedioCents: 0,
            porIva: const [],
            fondoCajaCents: 0,
            retiradasCents: 0,
            efectivoEsperadoCents: 0,
            descuadreCents: 0,
          ),
        ),
        throwsA(isA<ValidationException>()),
      );
      expect(
        () => generarInformeZ(
          informeZ(
            partidas: const [
              (codsubcuenta: '', concepto: 'x', debeCents: 1, haberCents: 0),
            ],
          ),
        ),
        throwsA(isA<ValidationException>()),
      );
      expect(
        () => generarInformeZ(
          informeZ(
            partidas: const [
              (
                codsubcuenta: '570',
                concepto: 'x',
                debeCents: -1,
                haberCents: 0,
              ),
            ],
          ),
        ),
        throwsA(
          isA<ValidationException>().having(
            (e) => e.message,
            'message',
            contains('negativos'),
          ),
        ),
      );
    });
  });

  group('DTOs', () {
    test('igualdad por valor de la precuenta y de los modelos comunes con '
        'instancias no const (sin canonicalizar, Equatable compara los '
        'props)', () {
      expect(precuenta(), precuenta());
      expect(precuenta().hashCode, precuenta().hashCode);
      expect(precuenta(), isNot(precuenta(mesa: '3')));
      expect(precuenta(), isNot(precuenta(comensales: null)));

      LineaTicket linea({String? letraIva = 'A'}) => LineaTicket(
        descripcion: 'Caña',
        cantidad: 1,
        pvpUnitarioCents: 180,
        importeCents: 180,
        nota: 'sin espuma',
        letraIva: letraIva,
      );
      expect(linea(), linea());
      expect(linea().hashCode, linea().hashCode);
      expect(linea(), isNot(linea(letraIva: 'B')));

      DesgloseIvaTicketPrint desglose({String? letra = 'A'}) =>
          DesgloseIvaTicketPrint(
            ivaPct: 10,
            baseCents: 164,
            cuotaCents: 16,
            letra: letra,
          );
      expect(desglose(), desglose());
      expect(desglose(), isNot(desglose(letra: null)));

      PagoTicketPrint pago({int importeCents = 1000}) =>
          PagoTicketPrint(formaPago: 'Efectivo', importeCents: importeCents);
      expect(pago(), pago());
      expect(pago(), isNot(pago(importeCents: 1500)));

      EmpresaTicket emisor({String? web = 'www.barpepe.es'}) =>
          EmpresaTicket(nombre: 'Bar Pepe', web: web);
      expect(emisor(), emisor());
      expect(emisor(), isNot(emisor(web: null)));
    });

    test('igualdad por valor con logo y partidas', () {
      final logo = logoPng();
      expect(ticketCompleto(logo: logo), ticketCompleto(logo: logo));
      expect(
        informeZ(partidas: partidasDescuadre),
        informeZ(partidas: partidasDescuadre),
      );
      expect(informeZ(), isNot(informeZ(partidas: partidasDescuadre)));
      expect(comanda(), comanda());
      expect(comanda(), isNot(comanda(paper: PaperWidth.mm58)));
      expect(marchar(), marchar());
      expect(marchar(), isNot(marchar(paper: PaperWidth.mm80Dpi180)));
    });
  });

  group('en isolate', () {
    const inline = InlineIsolateRunner();
    const spawning = SpawningIsolateRunner();

    test('InlineIsolateRunner produce lo mismo que la función pura', () async {
      final data = ticketCompleto(logo: logoPng());
      expect(
        await generarTicketEnIsolate(data, runner: inline),
        generarTicket(data),
      );
      expect(
        await generarComandaCocinaEnIsolate(comanda(), runner: inline),
        generarComandaCocina(comanda()),
      );
      expect(
        await generarInformeZEnIsolate(informeZ(), runner: inline),
        generarInformeZ(informeZ()),
      );
      expect(
        await generarMarcharEnIsolate(marchar(), runner: inline),
        generarMarchar(marchar()),
      );
    });

    test('MARCHAR en isolate real', () async {
      final bytes = await generarMarcharEnIsolate(marchar(), runner: spawning);
      expect(bytes, generarMarchar(marchar()));
      expect(decodeEscPos(bytes).texts.first, 'COCINA');
    });

    test('ticket con logo en isolate real', () async {
      final data = ticketCompleto(logo: logoPng());
      final bytes = await generarTicketEnIsolate(data, runner: spawning);
      expect(bytes, generarTicket(data));
      expect(decodeEscPos(bytes).named('raster'), isNotEmpty);
    });

    test('comanda en isolate real', () async {
      final bytes = await generarComandaCocinaEnIsolate(
        comanda(),
        runner: spawning,
      );
      expect(bytes, generarComandaCocina(comanda()));
    });

    test('informe Z con logo y partidas en isolate real', () async {
      final data = informeZ(partidas: partidasDescuadre, logo: logoPng());
      final bytes = await generarInformeZEnIsolate(data, runner: spawning);
      expect(bytes, generarInformeZ(data));
      expect(decodeEscPos(bytes).named('raster'), isNotEmpty);
    });

    test('por defecto usa SpawningIsolateRunner', () async {
      final bytes = await generarComandaCocinaEnIsolate(comanda());
      expect(bytes, generarComandaCocina(comanda()));
    });

    test('las excepciones de validación cruzan el isolate', () async {
      final data = KitchenOrderPrintData(
        titulo: 'COCINA',
        mesa: '1',
        fechaHora: fecha,
        lineas: const [],
      );
      await expectLater(
        generarComandaCocinaEnIsolate(data, runner: spawning),
        throwsA(
          isA<ValidationException>().having(
            (e) => e.message,
            'message',
            contains('líneas'),
          ),
        ),
      );
      await expectLater(
        generarTicketEnIsolate(
          ticketCompleto(logo: Uint8List.fromList([1, 2, 3])),
          runner: spawning,
        ),
        throwsA(isA<ValidationException>()),
      );
    });
  });
}
