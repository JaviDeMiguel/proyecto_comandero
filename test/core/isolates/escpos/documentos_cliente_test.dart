/// Documentos de cliente tras WP-06b: el documento provisional del cobro, la
/// factura simplificada (ORIGINAL y DUPLICADO) con el QR tributario, la
/// precuenta y el informe Z con las precuentas sin cobro, contra las maquetas
/// (a)–(d), (j) y (k) del diseño de impresión.
library;

import 'dart:typed_data';

import 'package:proyecto_comandero/core/errors/app_exception.dart';
import 'package:proyecto_comandero/core/isolates/escpos/escpos.dart';
import 'package:proyecto_comandero/core/isolates/escpos/qr_raster.dart';
import 'package:proyecto_comandero/core/isolates/isolate_runner.dart';
import 'package:test/test.dart';

import 'escpos_decoder.dart';

/// Emisor de las maquetas: nombre comercial, razón social, NIF, dirección,
/// «CP ciudad (provincia)», teléfono y pie.
const empresa = EmpresaTicket(
  nombre: 'MANOLO GARCÍA HOSTELERÍA, S.L.',
  nombreComercial: 'BAR MANOLO',
  cifnif: 'B12345678',
  direccion: 'C/ Mayor, 12, bajo',
  codpostal: '28001',
  ciudad: 'Madrid',
  provincia: 'Madrid',
  telefono: '910 000 000',
  pie: 'Gracias por su visita',
);

/// Líneas de las maquetas con la letra de IVA de cada tipo (A 10 %, B 21 %).
const lineasConLetra = [
  LineaTicket(
    descripcion: 'Caña',
    cantidad: 4,
    pvpUnitarioCents: 200,
    importeCents: 800,
    letraIva: 'A',
  ),
  LineaTicket(
    descripcion: 'Croquetas de jamón',
    cantidad: 1,
    pvpUnitarioCents: 900,
    importeCents: 900,
    letraIva: 'A',
  ),
  LineaTicket(
    descripcion: 'Entrecot a la brasa',
    cantidad: 2,
    pvpUnitarioCents: 1900,
    importeCents: 3800,
    letraIva: 'A',
  ),
  LineaTicket(
    descripcion: 'Vino Rioja crianza (llevar)',
    cantidad: 1,
    pvpUnitarioCents: 1200,
    importeCents: 1200,
    letraIva: 'B',
  ),
];

const desgloseConLetra = [
  DesgloseIvaTicketPrint(
    ivaPct: 10,
    baseCents: 5000,
    cuotaCents: 500,
    letra: 'A',
  ),
  DesgloseIvaTicketPrint(
    ivaPct: 21,
    baseCents: 992,
    cuotaCents: 208,
    letra: 'B',
  ),
];

/// Las mismas líneas y el mismo desglose sin letras (DTO anterior al diseño).
List<LineaTicket> sinLetra(List<LineaTicket> lineas) => [
  for (final l in lineas)
    LineaTicket(
      descripcion: l.descripcion,
      cantidad: l.cantidad,
      pvpUnitarioCents: l.pvpUnitarioCents,
      importeCents: l.importeCents,
      nota: l.nota,
    ),
];

List<DesgloseIvaTicketPrint> desgloseSinLetra(
  List<DesgloseIvaTicketPrint> desglose,
) => [
  for (final d in desglose)
    DesgloseIvaTicketPrint(
      ivaPct: d.ivaPct,
      baseCents: d.baseCents,
      cuotaCents: d.cuotaCents,
    ),
];

final cobro = DateTime(2026, 10, 9, 14, 32);
final expedicion = DateTime(2026, 10, 9, 14, 33);
final reimpresion = DateTime(2026, 10, 9, 16, 5);

/// URL real de producción VERI*FACTU (125 caracteres: QR de versión 8).
const qrUrl =
    'https://www2.agenciatributaria.gob.es/wlpl/TIKE-CONT/ValidarQR'
    '?nif=B12345678&numserie=F2026S12&fecha=09-10-2026&importe=67.00';

TicketPrintData provisional({
  PaperWidth paper = PaperWidth.mm80,
  int? numeroLocal = 15,
  String? numero2 = 'TPV-1a2b3c4d',
  String mesa = 'Mesa 7',
  bool muestra = false,
  bool abrirCajon = true,
  String? qrUrl,
  DuplicadoPrint? duplicado,
}) => TicketPrintData(
  empresa: empresa,
  tituloDocumento: 'DOCUMENTO PROVISIONAL',
  provisional: true,
  numeroLocal: numeroLocal,
  numero2: numero2,
  fechaHora: cobro,
  mesa: mesa,
  zona: 'Terraza',
  camarero: 'Ana',
  lineas: lineasConLetra,
  desglose: desgloseConLetra,
  totalCents: 6700,
  metodoPago: 'Efectivo',
  entregadoCents: 7000,
  cambioCents: 300,
  ivaIncluido: true,
  muestra: muestra,
  qrUrl: qrUrl,
  duplicado: duplicado,
  paper: paper,
  abrirCajon: abrirCajon,
);

TicketPrintData factura({
  PaperWidth paper = PaperWidth.mm80,
  String? url = qrUrl,
  String? leyenda = 'VERI*FACTU',
  DuplicadoPrint? duplicado,
  DateTime? fechaOperacion,
  List<LineaTicket> lineas = lineasConLetra,
  List<DesgloseIvaTicketPrint> desglose = desgloseConLetra,
  int totalCents = 6700,
  int? entregadoCents = 7000,
  int? cambioCents = 300,
  bool ivaIncluido = true,
  bool muestra = false,
  bool reglaQr = false,
}) => TicketPrintData(
  empresa: empresa,
  tituloDocumento: 'FACTURA SIMPLIFICADA',
  codigoFactura: 'F2026S12',
  numeroLocal: 15,
  fechaHora: cobro,
  fechaExpedicion: expedicion,
  fechaOperacion: fechaOperacion,
  mesa: 'Mesa 7',
  zona: 'Terraza',
  camarero: 'Ana',
  lineas: lineas,
  desglose: desglose,
  totalCents: totalCents,
  metodoPago: 'Efectivo',
  entregadoCents: entregadoCents,
  cambioCents: cambioCents,
  qrUrl: url,
  qrLeyenda: leyenda,
  duplicado: duplicado,
  ivaIncluido: ivaIncluido,
  muestra: muestra,
  reglaQr: reglaQr,
  paper: paper,
);

final duplicado1 = DuplicadoPrint(numero: 1, impresoEn: reimpresion);

PrecuentaPrintData precuenta({
  PaperWidth paper = PaperWidth.mm80,
  String mesa = 'Mesa 7',
  String? zona = 'Terraza',
  int? numero = 2,
  int? comensales = 4,
  String? camarero = 'Ana',
  bool ivaIncluido = true,
  bool muestra = false,
}) => PrecuentaPrintData(
  empresa: empresa,
  fechaHora: DateTime(2026, 10, 9, 14, 10),
  mesa: mesa,
  zona: zona,
  numero: numero,
  camarero: camarero,
  comensales: comensales,
  lineas: lineasConLetra,
  desglose: desgloseConLetra,
  totalCents: 6700,
  ivaIncluido: ivaIncluido,
  muestra: muestra,
  paper: paper,
);

List<PrecuentaZPrint> precuentasSinCobro() => [
  (
    numero: 2,
    mesa: 'Mesa 7',
    emitidaEn: DateTime(2026, 10, 9, 14, 10),
    totalCents: 6700,
    motivo: 'se fueron sin pagar',
  ),
  (
    numero: 1,
    mesa: '3',
    emitidaEn: DateTime(2026, 10, 8, 23, 50),
    totalCents: 1250,
    motivo: null,
  ),
];

ZReportPrintData informeZ({
  List<PrecuentaZPrint> precuentas = const [],
  PaperWidth paper = PaperWidth.mm80,
}) => ZReportPrintData(
  empresa: empresa,
  nombreTpv: 'Caja 1',
  fecha: DateTime(2026, 10, 9),
  numTickets: 15,
  numAnulados: 0,
  ventasTotalCents: 67000,
  ventasEfectivoCents: 40000,
  ventasTarjetaCents: 27000,
  ticketMedioCents: 4467,
  porIva: desgloseConLetra,
  fondoCajaCents: 10000,
  retiradasCents: 0,
  efectivoEsperadoCents: 50000,
  efectivoContadoCents: 50000,
  descuadreCents: 0,
  precuentasSinCobro: precuentas,
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

/// Justo antes de la línea [texto] hay un avance de una línea (`ESC d 1`):
/// la línea en blanco de las maquetas.
void expectAvanceAntesDe(DecodedStream d, String texto) {
  final i = d.elements.indexWhere(
    (e) => e is ElementoTexto && e.linea.text == texto,
  );
  expect(i, greaterThan(0), reason: 'no hay línea «$texto»');
  final anterior = d.elements[i - 1];
  expect(anterior, isA<ElementoMarca>());
  expect((anterior as ElementoMarca).comando.name, 'feed');
  expect(anterior.comando.args, [1]);
}

void expectTituloGrande(DecodedLine l) {
  expect(l.bold, isTrue);
  expect(l.doubleHeight, isTrue);
  expect(l.doubleWidth, isTrue);
  expect(l.align, 1);
}

void main() {
  group('documento provisional (maqueta a)', () {
    test('banda, NO VÁLIDO COMO FACTURA, nº local, mesa con zona, '
        'referencia corta y cajón justo tras el init', () {
      final decoded = decodeEscPos(generarTicket(provisional()));
      final texts = decoded.texts;
      expectWidthsWithin(decoded, PaperWidth.mm80);

      // El pulso del cajón va tras init, codepage y charset (D1), una vez.
      expect(decoded.commands.take(4).map((c) => c.name), [
        'init',
        'codepage',
        'charset',
        'drawer',
      ]);
      expect(decoded.commands[3].args, [0, 25, 250]);
      expect(decoded.named('drawer'), hasLength(1));
      final tail = decoded.commands.sublist(decoded.commands.length - 2);
      expect(tail.map((c) => c.name), ['feed', 'cut']);

      // Cabecera: nombre comercial en negrita y doble alto, razón social,
      // NIF, dirección, «CP ciudad (provincia)» y teléfono.
      final comercial = decoded.lines.first;
      expect(comercial.text, 'BAR MANOLO');
      expect(comercial.bold, isTrue);
      expect(comercial.doubleHeight, isTrue);
      expect(comercial.doubleWidth, isFalse);
      expect(comercial.align, 1);
      expect(texts[1], 'MANOLO GARCÍA HOSTELERÍA, S.L.');
      expect(texts[2], 'NIF: B12345678');
      expect(texts[3], 'C/ Mayor, 12, bajo');
      expect(texts[4], '28001 Madrid (Madrid)');
      expect(texts[5], 'Tel.: 910 000 000');
      expect(texts[6], '-' * 48);

      // Título en banda a todo el ancho, en doble alto, y la advertencia.
      final titulo = banda(decoded, 'DOCUMENTO PROVISIONAL');
      expect(titulo, same(decoded.lines[7]));
      expect(titulo.bold, isTrue);
      expect(titulo.doubleHeight, isTrue);
      expect(titulo.doubleWidth, isFalse);
      expect(titulo.text.runes.length, 48);
      final aviso = decoded.lines[8];
      expect(aviso.text, 'NO VÁLIDO COMO FACTURA');
      expect(aviso.bold, isTrue);
      expect(aviso.inverse, isFalse);
      expect(aviso.align, 1);
      expect(texts[9], '-' * 48);

      // Nº local con la hora del cobro, mesa · zona con el camarero y la
      // referencia corta.
      expect(texts[10], 'Ticket nº 15${' ' * 20}09/10/2026 14:32');
      expect(texts[11], 'Mesa 7 · Terraza${' ' * 19}Camarero: Ana');
      expect(texts[12], 'Ref. TPV-1a2b3c4d');
      expect(texts[13], '-' * 48);

      // Líneas con la letra de IVA tras el importe y el unitario si la
      // cantidad no es 1.
      expect(texts[14], '4 x Caña${' ' * 34}8,00 A');
      expect(texts[15], '   (2,00 €/ud)');
      expect(texts[16], '1 x Croquetas de jamón${' ' * 20}9,00 A');
      expect(texts[17], '2 x Entrecot a la brasa${' ' * 18}38,00 A');
      expect(texts[18], '   (19,00 €/ud)');
      expect(texts[19], '1 x Vino Rioja crianza (llevar)${' ' * 10}12,00 B');

      // TOTAL en el mayor tamaño, «IVA incluido» a la derecha y la tabla de
      // IVA con la letra de cada tipo.
      final total = lineaDesde(decoded, 'TOTAL');
      expect(total.text, endsWith('67,00 €'));
      expect(total.text.runes.length, 24);
      expect(total.bold, isTrue);
      expect(total.doubleHeight, isTrue);
      expect(total.doubleWidth, isTrue);
      final ivaIncluido = linea(decoded, 'IVA incluido');
      expect(ivaIncluido.align, 2);
      expect(
        decoded.lines.indexOf(ivaIncluido),
        indiceDe(decoded, total.text) + 1,
      );
      expect(texts, contains('IVA${' ' * 13}${' ' * 12}Base${' ' * 11}Cuota'));
      expect(texts, contains('A 10 %${' ' * 21}50,00${' ' * 12}5,00'));
      expect(texts, contains('B 21 %${' ' * 22}9,92${' ' * 12}2,08'));

      // Cobro y pie: la frase sobre la factura, una línea en blanco y el pie.
      expect(lineaDesde(decoded, 'Forma de pago').text, endsWith('Efectivo'));
      expect(lineaDesde(decoded, 'Entregado').text, endsWith('70,00 €'));
      expect(lineaDesde(decoded, 'Cambio').text, endsWith('3,00 €'));
      final frase = indiceDe(
        decoded,
        'Su factura simplificada se emite al cobrar:',
      );
      expect(frase, isNonNegative);
      expect(texts[frase + 1], 'pídala en caja si la necesita.');
      expect(decoded.lines[frase].align, 1);
      // La línea en blanco de la maqueta es un avance (`ESC d 1`), no texto.
      expectAvanceAntesDe(decoded, 'Gracias por su visita');
      expect(texts[frase + 2], 'Gracias por su visita');
      expect(texts.length, frase + 3);

      // Nada de factura: ni número, ni QR, ni fechas de expedición.
      for (final prohibido in [
        'FACTURA SIMPLIFICADA',
        'Nº ',
        'QR tributario',
        'VERI*FACTU',
        'Fecha de expedición',
        'Fecha de operación',
        'Duplicado',
        'Pendiente de facturar',
      ]) {
        expect(
          texts.where((t) => t.startsWith(prohibido)),
          isEmpty,
          reason: prohibido,
        );
      }
      expect(decoded.named('raster'), isEmpty);
    });

    test('sin nº local ni referencia: queda la hora; una mesa numérica se '
        'imprime «Mesa 7»; sin efectivo no hay cajón', () {
      final decoded = decodeEscPos(
        generarTicket(
          provisional(
            numeroLocal: null,
            numero2: null,
            mesa: '7',
            abrirCajon: false,
          ),
        ),
      );
      final texts = decoded.texts;
      expect(texts[10].trim(), '09/10/2026 14:32');
      expect(texts[11], startsWith('Mesa 7 · Terraza'));
      expect(texts.where((t) => t.startsWith('Ref.')), isEmpty);
      expect(decoded.named('drawer'), isEmpty);
    });

    test('con muestra: la banda MUESTRA · SIN VALIDEZ va antes que todo', () {
      final decoded = decodeEscPos(generarTicket(provisional(muestra: true)));
      final muestra = decoded.lines.first;
      expect(muestra.text.trim(), 'MUESTRA · SIN VALIDEZ');
      expect(muestra.inverse, isTrue);
      expect(muestra.doubleHeight, isTrue);
      expect(decoded.lines[1].text, 'BAR MANOLO');
      // El cajón sigue siendo lo primero.
      expect(decoded.commands[3].name, 'drawer');
    });

    test('validaciones: ni QR ni DUPLICADO en un provisional; nº local y nº '
        'de duplicado positivos', () {
      expect(
        () => generarTicket(provisional(qrUrl: qrUrl)),
        failsWith('provisional'),
      );
      expect(
        () => generarTicket(provisional(duplicado: duplicado1)),
        failsWith('DUPLICADO'),
      );
      expect(
        () => generarTicket(provisional(numeroLocal: 0)),
        failsWith('número local'),
      );
      expect(
        () => generarTicket(
          factura(duplicado: DuplicadoPrint(numero: 0, impresoEn: reimpresion)),
        ),
        failsWith('duplicado'),
      );
      expect(() => generarTicket(factura(url: ' ')), failsWith('QR'));
    });
  });

  group('factura simplificada (maqueta b)', () {
    test('QR primero (tras el init), VERI*FACTU, cabecera, Nº, fecha de '
        'expedición y sin cajón', () {
      final decoded = decodeEscPos(generarTicket(factura()));
      final texts = decoded.texts;
      expectWidthsWithin(decoded, PaperWidth.mm80);

      // Lo primero del documento: «QR tributario:», la imagen y la leyenda,
      // los dos textos en el mayor tamaño de la factura.
      expect(decoded.commands.take(3).map((c) => c.name), [
        'init',
        'codepage',
        'charset',
      ]);
      expect(decoded.commands[3].name, 'raster');
      expect(decoded.named('drawer'), isEmpty);
      final qr = decoded.lines.first;
      expect(qr.text, 'QR tributario:');
      expectTituloGrande(qr);
      expect(decoded.elements[0], isA<ElementoTexto>());
      expect((decoded.elements[0] as ElementoTexto).linea, same(qr));
      expect(decoded.elements[1], isA<ElementoImagen>());
      final leyenda = decoded.lines[1];
      expect(leyenda.text, 'VERI*FACTU');
      expectTituloGrande(leyenda);
      expect(texts[2], '-' * 48);
      expect(texts[3], 'BAR MANOLO');

      // La imagen es la del rasterizador: versión 8 a 6 puntos por módulo,
      // 36,8 mm, con sus márgenes (392 × 390 puntos).
      final esperado = rasterizarQr(qrUrl, dpi: 203, anchoMaximoPuntos: 576);
      expect(esperado.version, 8);
      expect(esperado.puntosPorModulo, 6);
      expect(esperado.ladoMm, closeTo(36.8, 0.05));
      final imagen = decoded.rasters.single;
      expect(imagen.width, 392);
      expect(imagen.height, 390);
      expect(imagen.bits, esperado.imagen.bits);
      expect(imagen.align, 1);

      // Título, número de FS y fecha de expedición (nunca la del cobro).
      final titulo = linea(decoded, 'FACTURA SIMPLIFICADA');
      expect(titulo.bold, isTrue);
      expect(titulo.doubleHeight, isTrue);
      expect(titulo.doubleWidth, isFalse);
      final numero = linea(decoded, 'Nº F2026S12');
      expect(numero.bold, isTrue);
      expect(numero.doubleHeight, isTrue);
      expect(numero.align, 1);
      final i = decoded.lines.indexOf(numero);
      expect(texts[i + 1], 'Fecha de expedición${' ' * 13}09/10/2026 14:33');
      expect(texts[i + 2], 'Ticket nº 15 · Mesa 7${' ' * 14}Camarero: Ana');
      expect(texts[i + 3], '-' * 48);
      expect(texts.where((t) => t.contains('14:32')), isEmpty);
      expect(texts.where((t) => t.startsWith('Fecha de operación')), isEmpty);
      expect(texts.where((t) => t.startsWith('Ref.')), isEmpty);
      expect(texts, isNot(contains('Pendiente de facturar')));

      // Cuerpo como el provisional, sin la frase sobre la factura.
      expect(
        texts,
        contains('1 x Vino Rioja crianza (llevar)${' ' * 10}12,00 B'),
      );
      final total = lineaDesde(decoded, 'TOTAL');
      expect(total.text, endsWith('67,00 €'));
      expect(total.doubleWidth, isTrue);
      expect(linea(decoded, 'IVA incluido').align, 2);
      expect(texts, contains('A 10 %${' ' * 21}50,00${' ' * 12}5,00'));
      expect(lineaDesde(decoded, 'Cambio').text, endsWith('3,00 €'));
      expect(texts.last, 'Gracias por su visita');
      for (final prohibido in [
        'DOCUMENTO PROVISIONAL',
        'NO VÁLIDO',
        'Su factura',
        'DUPLICADO',
        'Duplicado',
      ]) {
        expect(texts.where((t) => t.trim().startsWith(prohibido)), isEmpty);
      }
      final tail = decoded.commands.sublist(decoded.commands.length - 2);
      expect(tail.map((c) => c.name), ['feed', 'cut']);
    });

    test('NO VERI*FACTU: sin leyenda no hay frase; sin URL no hay QR', () {
      final sinLeyenda = decodeEscPos(generarTicket(factura(leyenda: null)));
      expect(sinLeyenda.lines.first.text, 'QR tributario:');
      expect(sinLeyenda.texts, isNot(contains('VERI*FACTU')));
      expect(sinLeyenda.texts[1], '-' * 48);
      expect(sinLeyenda.rasters, hasLength(1));

      final sinQr = decodeEscPos(generarTicket(factura(url: null)));
      expect(sinQr.lines.first.text, 'BAR MANOLO');
      expect(sinQr.texts, isNot(contains('QR tributario:')));
      expect(sinQr.texts, isNot(contains('VERI*FACTU')));
      expect(sinQr.named('raster'), isEmpty);
    });

    test('«Fecha de operación» solo si el día difiere del de expedición', () {
      final mismoDia = decodeEscPos(
        generarTicket(factura(fechaOperacion: cobro)),
      ).texts;
      expect(
        mismoDia.where((t) => t.startsWith('Fecha de operación')),
        isEmpty,
      );

      final otroDia = decodeEscPos(
        generarTicket(factura(fechaOperacion: DateTime(2026, 10, 8, 23, 55))),
      );
      final operacion = lineaDesde(otroDia, 'Fecha de operación');
      expect(operacion.text, endsWith('08/10/2026'));
      expect(operacion.text, isNot(contains('23:55')));
      expect(
        otroDia.lines.indexOf(operacion),
        otroDia.lines.indexOf(lineaDesde(otroDia, 'Fecha de expedición')) + 1,
      );
    });

    test('duplicado (maqueta c): banda DUPLICADO y «Duplicado nº 1» tras el '
        'Nº, con el mismo QR que el original', () {
      final original = decodeEscPos(generarTicket(factura()));
      final decoded = decodeEscPos(
        generarTicket(factura(duplicado: duplicado1)),
      );
      final texts = decoded.texts;
      expectWidthsWithin(decoded, PaperWidth.mm80);

      final marca = banda(decoded, 'DUPLICADO');
      // Banda: negrita, doble alto y ancho, alineada a la izquierda y
      // centrada por el relleno (§6.1), no por la impresora.
      expect(marca.bold, isTrue);
      expect(marca.doubleHeight, isTrue);
      expect(marca.doubleWidth, isTrue);
      expect(marca.align, 0);
      expect(marca.text.runes.length, 24);
      expect(marca.printedWidth, 48);
      final i = decoded.lines.indexOf(marca);
      expect(texts[i - 1], 'Nº F2026S12');
      expect(texts[i + 1], 'Duplicado nº 1${' ' * 18}09/10/2026 16:05');
      expect(texts[i + 2], startsWith('Fecha de expedición'));
      expect(texts[i + 3], startsWith('Ticket nº 15 · Mesa 7'));

      expect(decoded.lines.first.text, 'QR tributario:');
      expect(decoded.rasters.single.bits, original.rasters.single.bits);
      expect(decoded.named('drawer'), isEmpty);
      expect(texts, isNot(contains('COPIA')));
    });

    test('ninguna línea de la factura ni del duplicado es más alta ni más '
        'ancha que «QR tributario:» (32, 42 y 48 columnas)', () {
      int alto(DecodedRun r) => r.doubleHeight ? 2 : 1;
      int ancho(DecodedRun r) => r.doubleWidth ? 2 : 1;
      for (final paper in PaperWidth.values) {
        for (final data in [
          factura(paper: paper),
          factura(paper: paper, duplicado: duplicado1),
        ]) {
          final decoded = decodeEscPos(generarTicket(data));
          expectWidthsWithin(decoded, paper);
          final qr = decoded.lines.first;
          expect(qr.text, 'QR tributario:');
          final tramoQr = qr.runs.single;
          expect(qr.printedWidth, lessThanOrEqualTo(paper.columns));
          for (final line in decoded.lines) {
            for (final run in line.runs) {
              expect(
                alto(run),
                lessThanOrEqualTo(alto(tramoQr)),
                reason: '${paper.name}: «${line.text}» más alta que el QR',
              );
              expect(
                ancho(run),
                lessThanOrEqualTo(ancho(tramoQr)),
                reason: '${paper.name}: «${line.text}» más ancha que el QR',
              );
            }
          }
        }
      }
    });

    test('a 42 columnas (maqueta j): QR de 34,6 mm, tabla de IVA (14, 14, 14) '
        'y TOTAL en doble ancho', () {
      final paper = PaperWidth.mm80Dpi180;
      final decoded = decodeEscPos(generarTicket(factura(paper: paper)));
      final texts = decoded.texts;
      expectWidthsWithin(decoded, paper);

      final esperado = rasterizarQr(qrUrl, dpi: 180, anchoMaximoPuntos: 512);
      expect(esperado.puntosPorModulo, 5);
      expect(esperado.ladoMm, closeTo(34.6, 0.05));
      final imagen = decoded.rasters.single;
      expect(imagen.width, 336);
      expect(imagen.height, 331);
      expect(imagen.bits, esperado.imagen.bits);

      expect(texts, contains('Fecha de expedición${' ' * 7}09/10/2026 14:33'));
      expect(texts, contains('4 x Caña${' ' * 28}8,00 A'));
      expect(texts, contains('IVA${' ' * 11}${' ' * 10}Base${' ' * 9}Cuota'));
      expect(texts, contains('A 10 %${' ' * 8}${' ' * 9}50,00${' ' * 10}5,00'));
      final total = lineaDesde(decoded, 'TOTAL');
      expect(total.doubleWidth, isTrue);
      expect(total.text.runes.length, 21);
      expect(total.text, endsWith('67,00 €'));
    });

    test('a 58 mm (maqueta k): el QR cabe con 45 puntos de margen y la '
        'etiqueta de la fecha se parte', () {
      final decoded = decodeEscPos(
        generarTicket(factura(paper: PaperWidth.mm58)),
      );
      final texts = decoded.texts;
      expectWidthsWithin(decoded, PaperWidth.mm58);
      final imagen = decoded.rasters.single;
      expect(imagen.width, 384);
      expect(imagen.height, 390);
      expect(decoded.lines.first.printedWidth, 28);
      expect(texts, contains('Fecha de'));
      expect(texts, contains('expedición${' ' * 6}09/10/2026 14:33'));
      expect(texts, contains('A 10 %${' ' * 4}${' ' * 6}50,00${' ' * 7}5,00'));
      final total = lineaDesde(decoded, 'TOTAL');
      expect(total.doubleWidth, isTrue);
      expect(total.text.runes.length, 16);
    });

    test('letras de IVA: solo con dos o más tipos, y en las líneas y el '
        'desglose únicamente cuando el DTO las lleva', () {
      expect(letrasIva(const []), isEmpty);
      expect(letrasIva(const [1000]), isEmpty);
      expect(letrasIva(const [2100, 1000, 2100]), {1000: 'A', 2100: 'B'});
      expect(letrasIva(const [400, 1000, 2100]), {
        400: 'A',
        1000: 'B',
        2100: 'C',
      });

      final decoded = decodeEscPos(
        generarTicket(
          factura(
            lineas: sinLetra(lineasConLetra),
            desglose: desgloseSinLetra(desgloseConLetra),
          ),
        ),
      );
      final texts = decoded.texts;
      expect(lineaDesde(decoded, '4 x Caña').text, endsWith(' 8,00'));
      expect(texts.where((t) => t.endsWith(' A') || t.endsWith(' B')), isEmpty);
      expect(texts, contains('10 %${' ' * 23}50,00${' ' * 12}5,00'));
      expect(texts.where((t) => t.startsWith('A 10 %')), isEmpty);
    });

    test('«IVA incluido» depende del ajuste', () {
      final sin = decodeEscPos(generarTicket(factura(ivaIncluido: false)));
      expect(sin.texts, isNot(contains('IVA incluido')));
      final con = decodeEscPos(generarTicket(factura()));
      expect(con.texts, contains('IVA incluido'));
    });

    test('TOTAL a 58 mm con 12.345,67 €: doble alto sin doble ancho y sin '
        'partir «TOTAL»; a 80 mm sigue en doble ancho', () {
      final grande = factura(
        paper: PaperWidth.mm58,
        lineas: const [
          LineaTicket(
            descripcion: 'Banquete',
            cantidad: 1,
            pvpUnitarioCents: 1234567,
            importeCents: 1234567,
          ),
        ],
        desglose: const [
          DesgloseIvaTicketPrint(
            ivaPct: 10,
            baseCents: 1122334,
            cuotaCents: 112233,
          ),
        ],
        totalCents: 1234567,
        entregadoCents: null,
        cambioCents: null,
      );
      final decoded = decodeEscPos(generarTicket(grande));
      final texts = decoded.texts;
      expectWidthsWithin(decoded, PaperWidth.mm58);
      final total = lineaDesde(decoded, 'TOTAL');
      expect(total.text, 'TOTAL${' ' * 16}12.345,67 €');
      expect(total.text.runes.length, 32);
      expect(total.bold, isTrue);
      expect(total.doubleHeight, isTrue);
      expect(total.doubleWidth, isFalse);
      expect(texts, isNot(contains('TOTA')));
      expect(texts, isNot(contains('L')));
      // Sigue sin superar el tamaño de «QR tributario:».
      expect(decoded.lines.first.doubleWidth, isTrue);

      final en80 = decodeEscPos(
        generarTicket(
          factura(
            lineas: grande.lineas,
            desglose: grande.desglose,
            totalCents: grande.totalCents,
            entregadoCents: null,
            cambioCents: null,
          ),
        ),
      );
      final total80 = lineaDesde(en80, 'TOTAL');
      expect(total80.doubleWidth, isTrue);
      expect(total80.text.runes.length, 24);
      expect(total80.text, endsWith('12.345,67 €'));
    });

    test('con muestra: la banda MUESTRA precede al QR', () {
      final decoded = decodeEscPos(generarTicket(factura(muestra: true)));
      final muestra = decoded.lines.first;
      expect(muestra.text.trim(), 'MUESTRA · SIN VALIDEZ');
      expect(muestra.inverse, isTrue);
      expect(muestra.doubleHeight, isTrue);
      expect(decoded.lines[1].text, 'QR tributario:');
    });

    test('determinismo, igualdad de los DTOs e isolate (el QR se rasteriza '
        'dentro)', () async {
      expect(generarTicket(factura()), generarTicket(factura()));
      expect(factura(), factura());
      expect(factura(), isNot(factura(duplicado: duplicado1)));
      expect(duplicado1, DuplicadoPrint(numero: 1, impresoEn: reimpresion));
      expect(provisional(), provisional());
      expect(provisional(), isNot(provisional(numeroLocal: 16)));

      const inline = InlineIsolateRunner();
      expect(
        await generarTicketEnIsolate(provisional(), runner: inline),
        generarTicket(provisional()),
      );
      expect(
        await generarTicketEnIsolate(factura(), runner: inline),
        generarTicket(factura()),
      );
      final bytes = await generarTicketEnIsolate(
        factura(duplicado: duplicado1),
        runner: const SpawningIsolateRunner(),
      );
      expect(bytes, generarTicket(factura(duplicado: duplicado1)));
      expect(decodeEscPos(bytes).rasters, hasLength(1));
    });
  });

  group('precuenta (maqueta d)', () {
    test('igualdad por valor del DTO', () {
      expect(precuenta(), precuenta());
      expect(precuenta(), isNot(precuenta(numero: 3)));
      expect(precuenta(), isNot(precuenta(paper: PaperWidth.mm58)));
    });

    test('PRECUENTA Nº 2, NO VÁLIDO COMO FACTURA, mesa · zona con los '
        'comensales, camarero con la hora, letras de IVA, IVA incluido y '
        '«Por comensal»; sin QR ni cajón', () {
      final decoded = decodeEscPos(generarPrecuenta(precuenta()));
      final texts = decoded.texts;
      expectWidthsWithin(decoded, PaperWidth.mm80);

      expect(texts[0], 'BAR MANOLO');
      expect(texts[6], '-' * 48);
      final titulo = decoded.lines[7];
      expect(titulo.text, 'PRECUENTA Nº 2');
      expect(titulo.bold, isTrue);
      expect(titulo.doubleHeight, isTrue);
      expect(titulo.doubleWidth, isFalse);
      expect(titulo.align, 1);
      final aviso = decoded.lines[8];
      expect(aviso.text, 'NO VÁLIDO COMO FACTURA');
      expect(aviso.bold, isTrue);
      expect(texts[9], 'Mesa 7 · Terraza${' ' * 20}4 comensales');
      expect(texts[10], 'Camarero: Ana${' ' * 19}09/10/2026 14:10');
      expect(texts[11], '-' * 48);
      expect(texts[12], '4 x Caña${' ' * 34}8,00 A');

      final total = lineaDesde(decoded, 'TOTAL');
      expect(total.text, endsWith('67,00 €'));
      expect(total.doubleHeight, isTrue);
      expect(total.doubleWidth, isTrue);
      expect(linea(decoded, 'IVA incluido').align, 2);
      expect(texts, contains('A 10 %${' ' * 21}50,00${' ' * 12}5,00'));
      expect(texts, contains('B 21 %${' ' * 22}9,92${' ' * 12}2,08'));

      final porComensal = lineaDesde(decoded, 'Por comensal (4)');
      expect(porComensal.text, endsWith('16,75 €'));
      expect(porComensal.bold, isTrue);
      final fiscal = linea(decoded, 'DOCUMENTO SIN VALIDEZ FISCAL');
      expect(fiscal.bold, isTrue);
      expect(fiscal.align, 1);
      final i = decoded.lines.indexOf(fiscal);
      expect(texts[i + 1], 'No es una factura: la factura simplificada se');
      expect(texts[i + 2], 'emite al cobrar.');
      expectAvanceAntesDe(decoded, 'Gracias por su visita');
      expect(texts[i + 3], 'Gracias por su visita');
      expect(texts.length, i + 4);

      for (final prohibido in [
        'QR tributario',
        'VERI*FACTU',
        'Nº F',
        'Ref.',
        'Forma de pago',
        'Entregado',
        'Cambio',
        'FACTURA SIMPLIFICADA',
      ]) {
        expect(texts.where((t) => t.startsWith(prohibido)), isEmpty);
      }
      expect(decoded.named('raster'), isEmpty);
      expect(decoded.named('drawer'), isEmpty);
      final tail = decoded.commands.sublist(decoded.commands.length - 2);
      expect(tail.map((c) => c.name), ['feed', 'cut']);
    });

    test('sin número, comensales ni camarero (ajustes apagados): «PRECUENTA», '
        'mesa · zona sola, la hora a la derecha y sin reparto', () {
      final decoded = decodeEscPos(
        generarPrecuenta(
          precuenta(numero: null, comensales: null, camarero: null),
        ),
      );
      final texts = decoded.texts;
      expect(texts[7], 'PRECUENTA');
      expect(texts[9], 'Mesa 7 · Terraza');
      expect(texts[10].trim(), '09/10/2026 14:10');
      expect(texts[10].runes.length, 48);
      expect(texts.where((t) => t.contains('comensal')), isEmpty);
      expect(texts.where((t) => t.startsWith('Camarero')), isEmpty);
      expect(texts.where((t) => t.startsWith('Nº')), isEmpty);
    });

    test('a 58 mm, con nombres largos y sin comensales, «mesa · zona» y el '
        'camarero se parten por palabras y no pasan de 32 columnas', () {
      final decoded = decodeEscPos(
        generarPrecuenta(
          precuenta(
            paper: PaperWidth.mm58,
            mesa: 'Terraza exterior',
            zona: 'Zona fumadores',
            comensales: null,
            camarero: 'María José Fernández de la Torre',
          ),
        ),
      );
      final texts = decoded.texts;
      expectWidthsWithin(decoded, PaperWidth.mm58);
      // «Terraza exterior · Zona fumadores» son 33 caracteres: no caben en 32.
      final i = texts.indexOf('Terraza exterior · Zona');
      expect(i, isNonNegative, reason: '$texts');
      expect(texts[i + 1], 'fumadores');
      expect(texts[i + 2], 'Camarero: María');
      expect(texts[i + 3], 'José Fernández');
      expect(texts[i + 4], 'de la Torre${' ' * 5}09/10/2026 14:10');
    });

    test('sin IVA incluido y con muestra', () {
      final decoded = decodeEscPos(
        generarPrecuenta(precuenta(ivaIncluido: false, muestra: true)),
      );
      expect(decoded.texts, isNot(contains('IVA incluido')));
      expect(decoded.lines.first.text.trim(), 'MUESTRA · SIN VALIDEZ');
      expect(decoded.lines.first.inverse, isTrue);
      expect(decoded.lines[1].text, 'BAR MANOLO');
    });

    test('validación: el número de la precuenta es positivo', () {
      expect(
        () => generarPrecuenta(precuenta(numero: 0)),
        failsWith('número de la precuenta'),
      );
    });
  });

  group('informe Z: precuentas sin cobro', () {
    test('la sección solo sale si las hay, tras el asiento: nº, mesa, hora o '
        'fecha, total, motivo, recuento y suma', () {
      final decoded = decodeEscPos(
        generarInformeZ(informeZ(precuentas: precuentasSinCobro())),
      );
      final texts = decoded.texts;
      expectWidthsWithin(decoded, PaperWidth.mm80);

      final seccion = linea(decoded, 'PRECUENTAS SIN COBRO');
      expect(seccion.bold, isTrue);
      final i = decoded.lines.indexOf(seccion);
      expect(i, greaterThan(indiceDe(decoded, 'ASIENTO PROPUESTO')));
      expect(texts[i - 1], '-' * 48);
      expect(texts[i + 1], 'Nº 2 · Mesa 7 · 14:10${' ' * 20}67,00 €');
      expect(texts[i + 2], '   se fueron sin pagar');
      // Otro día: fecha y hora; la mesa numérica se imprime «Mesa 3».
      expect(texts[i + 3], 'Nº 1 · Mesa 3 · 08/10/2026 23:50${' ' * 9}12,50 €');
      expect(texts[i + 4], 'Precuentas sin cobro${' ' * 27}2');
      final suma = decoded.lines[i + 5];
      expect(suma.text, 'Suma${' ' * 37}79,50 €');
      expect(suma.bold, isTrue);
      expect(texts.length, i + 6);

      final sinPrecuentas = decodeEscPos(generarInformeZ(informeZ())).texts;
      expect(sinPrecuentas, isNot(contains('PRECUENTAS SIN COBRO')));
      expect(
        sinPrecuentas.where((t) => t.startsWith('Precuentas sin cobro')),
        isEmpty,
      );
    });

    test('validaciones: número positivo y mesa', () {
      expect(
        () => generarInformeZ(
          informeZ(
            precuentas: [
              (
                numero: 0,
                mesa: 'Mesa 7',
                emitidaEn: DateTime(2026, 10, 9),
                totalCents: 1,
                motivo: null,
              ),
            ],
          ),
        ),
        failsWith('número'),
      );
      expect(
        () => generarInformeZ(
          informeZ(
            precuentas: [
              (
                numero: 3,
                mesa: ' ',
                emitidaEn: DateTime(2026, 10, 9),
                totalCents: 1,
                motivo: null,
              ),
            ],
          ),
        ),
        failsWith('mesa'),
      );
    });

    test('igualdad del DTO e isolate', () async {
      expect(
        informeZ(precuentas: precuentasSinCobro()),
        informeZ(precuentas: precuentasSinCobro()),
      );
      expect(informeZ(), isNot(informeZ(precuentas: precuentasSinCobro())));
      final data = informeZ(precuentas: precuentasSinCobro());
      expect(
        await generarInformeZEnIsolate(
          data,
          runner: const InlineIsolateRunner(),
        ),
        generarInformeZ(data),
      );
    });
  });

  group('anchuras en los tres papeles', () {
    for (final paper in PaperWidth.values) {
      test(
        'ninguna línea supera las ${paper.columns} columnas (${paper.name})',
        () {
          final documentos = <String, Uint8ListFactory>{
            'provisional': () => generarTicket(provisional(paper: paper)),
            'factura': () => generarTicket(factura(paper: paper)),
            'duplicado': () =>
                generarTicket(factura(paper: paper, duplicado: duplicado1)),
            'precuenta': () => generarPrecuenta(precuenta(paper: paper)),
            'informe Z': () => generarInformeZ(
              informeZ(paper: paper, precuentas: precuentasSinCobro()),
            ),
          };
          for (final MapEntry(key: nombre, value: generar)
              in documentos.entries) {
            final decoded = decodeEscPos(generar());
            expectWidthsWithin(decoded, paper);
            // Las bandas ocupan todo el ancho.
            for (final b in decoded.lines.where((l) => l.inverse)) {
              expect(
                b.printedWidth,
                paper.columns,
                reason: '$nombre: ${b.text}',
              );
            }
          }
        },
      );
    }
  });

  group('regla de 40 mm de la factura de muestra (reglaQr, §5.18)', () {
    /// Tramos negros de la fila [y] del raster: (columna inicial, longitud).
    List<(int, int)> tramosNegros(DecodedRaster r, int y) {
      final tramos = <(int, int)>[];
      int? inicio;
      for (var x = 0; x <= r.width; x++) {
        final negro = x < r.width && r.isBlack(x, y);
        if (negro) {
          inicio ??= x;
        } else if (inicio != null) {
          tramos.add((inicio, x - inicio));
          inicio = null;
        }
      }
      return tramos;
    }

    test('sin el campo, o sin QR, los bytes no cambian; el campo cuenta en la '
        'igualdad del DTO', () {
      expect(factura(reglaQr: false), factura());
      expect(factura(reglaQr: true), isNot(factura()));
      expect(
        generarTicket(factura(url: null, reglaQr: true)),
        generarTicket(factura(url: null)),
      );
      expect(
        generarTicket(factura(reglaQr: true)),
        generarTicket(factura(reglaQr: true)),
      );
      expect(decodeEscPos(generarTicket(factura())).rasters, hasLength(1));
    });

    for (final (paper, lado) in [
      (PaperWidth.mm80, '36,8'),
      (PaperWidth.mm80Dpi180, '34,6'),
      (PaperWidth.mm58, '36,8'),
    ]) {
      test('${paper.name}: tras la leyenda y su separador, la regla raster de '
          '40 mm con marcas cada 5 mm y el lado del QR ($lado mm)', () {
        final decoded = decodeEscPos(
          generarTicket(factura(paper: paper, reglaQr: true)),
        );
        expectWidthsWithin(decoded, paper);
        final separador = '-' * paper.columns;

        // Texto: «VERI*FACTU», separador, la frase de la regla (centrada y
        // partida por palabras), separador y la cabecera del emisor.
        final texts = decoded.texts;
        final iLeyenda = texts.indexOf('VERI*FACTU');
        expect(iLeyenda, greaterThan(0));
        expect(texts[iLeyenda + 1], separador);
        final iFin = texts.indexOf(separador, iLeyenda + 2);
        expect(
          texts.sublist(iLeyenda + 2, iFin).join(' '),
          'Regla de 40 mm. Este QR debe medir $lado mm: compruébelo con una '
          'regla',
        );
        for (final l in decoded.lines.sublist(iLeyenda + 2, iFin)) {
          expect(l.align, 1, reason: l.text);
        }
        expect(texts[iFin + 1], 'BAR MANOLO');

        // La regla es la segunda imagen, entre el separador y su frase.
        final imagenes = [
          for (var i = 0; i < decoded.elements.length; i++)
            if (decoded.elements[i] is ElementoImagen) i,
        ];
        expect(imagenes, hasLength(2));
        final antes = decoded.elements[imagenes[1] - 1] as ElementoTexto;
        expect(antes.linea.text, separador);
        final despues = decoded.elements[imagenes[1] + 1] as ElementoTexto;
        expect(despues.linea.text, startsWith('Regla de 40 mm.'));
        final regla = (decoded.elements[imagenes[1]] as ElementoImagen).imagen;
        expect(regla.align, 1);
        expect(regla.width % 8, 0);
        expect(regla.width, lessThanOrEqualTo(paper.dots));

        // Marcas cada 5 mm (puntos = mm × puntos por mm): nueve tramos justo
        // encima de la base, a 40 mm la primera de la última.
        final ppmm = paper.puntosPorMm;
        final largo = (40 * ppmm).round();
        final marcas = [
          for (final t in tramosNegros(regla, regla.height - 3)) t.$1,
        ];
        expect(marcas, hasLength(9));
        for (var k = 0; k <= 8; k++) {
          expect(
            marcas[k] - marcas.first,
            (k * 5 * ppmm).round(),
            reason: 'marca de ${k * 5} mm',
          );
        }
        expect(marcas.last - marcas.first, largo);
        // Las de 0, 10, 20, 30 y 40 mm son más largas: llegan a la fila de
        // arriba.
        expect(
          [for (final t in tramosNegros(regla, 0)) t.$1],
          [for (var k = 0; k <= 8; k += 2) marcas[k]],
        );
        // La base es una raya continua de la primera a la última marca, con
        // trazos de 2 puntos.
        expect(tramosNegros(regla, regla.height - 1), [
          (marcas.first, largo + 2),
        ]);
        expect(tramosNegros(regla, regla.height - 3).first.$2, 2);
      });
    }

    test('con la URL de una muestra (entorno de pruebas, serie MUESTRA-1) el '
        'QR es de versión 7 y la regla pide 33,8 mm a 203 ppp', () {
      const urlMuestra =
          'https://prewww2.aeat.es/wlpl/TIKE-CONT/ValidarQR'
          '?nif=B12345678&numserie=MUESTRA-1&fecha=09-10-2026&importe=67.00';
      final qr = rasterizarQr(urlMuestra, dpi: 203, anchoMaximoPuntos: 576);
      expect(qr.version, 7);
      expect(qr.ladoMm, closeTo(33.8, 0.05));
      final decoded = decodeEscPos(
        generarTicket(factura(url: urlMuestra, reglaQr: true, muestra: true)),
      );
      expect(decoded.texts.first.trim(), 'MUESTRA · SIN VALIDEZ');
      expect(decoded.texts.join(' '), contains('Este QR debe medir 33,8 mm'));
    });
  });
}

typedef Uint8ListFactory = Uint8List Function();
