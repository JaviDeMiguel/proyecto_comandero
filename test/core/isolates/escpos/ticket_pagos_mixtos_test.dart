import 'package:proyecto_comandero/core/errors/app_exception.dart';
import 'package:proyecto_comandero/core/isolates/escpos/escpos.dart';
import 'package:proyecto_comandero/core/isolates/isolate_runner.dart';
import 'package:test/test.dart';

import 'escpos_decoder.dart';

final fecha = DateTime(2026, 10, 7, 21, 48);

const mixto = [
  PagoTicketPrint(formaPago: 'Efectivo', importeCents: 1235),
  PagoTicketPrint(formaPago: 'Tarjeta', importeCents: 760),
];

TicketPrintData ticket({
  List<PagoTicketPrint> pagos = mixto,
  String metodoPago = 'Efectivo',
  int? entregado = 1500,
  int? cambio = 265,
  PaperWidth paper = PaperWidth.mm80,
}) => TicketPrintData(
  empresa: const EmpresaTicket(nombre: 'Bar La Mancha Moderna'),
  tituloDocumento: 'FACTURA SIMPLIFICADA',
  codigoFactura: 'F2026S8',
  fechaHora: fecha,
  lineas: const [
    LineaTicket(
      descripcion: 'Menú del día',
      cantidad: 1,
      pvpUnitarioCents: 1995,
      importeCents: 1995,
    ),
  ],
  desglose: const [
    DesgloseIvaTicketPrint(ivaPct: 10, baseCents: 1814, cuotaCents: 181),
  ],
  totalCents: 1995,
  metodoPago: metodoPago,
  pagos: pagos,
  entregadoCents: entregado,
  cambioCents: cambio,
  paper: paper,
);

/// Textos desde "Forma de pago" hasta el final del bloque de cobro.
List<String> bloqueCobro(List<String> texts) {
  final inicio = texts.indexWhere((t) => t.startsWith('Forma de pago'));
  expect(inicio, isNonNegative);
  const etiquetas = [
    'Forma de pago',
    'Efectivo',
    'Tarjeta',
    'Entregado',
    'Cambio',
  ];
  return texts
      .skip(inicio)
      .takeWhile((t) => etiquetas.any(t.startsWith))
      .toList();
}

void main() {
  test('cobro mixto: "Mixto", una fila por pago y entregado/cambio', () {
    for (final paper in PaperWidth.values) {
      final texts = decodeEscPos(generarTicket(ticket(paper: paper))).texts;
      final bloque = bloqueCobro(texts);
      expect(bloque, hasLength(5));
      expect(bloque[0], startsWith('Forma de pago'));
      expect(bloque[0], endsWith('Mixto'));
      expect(bloque[1], startsWith('Efectivo'));
      expect(bloque[1], endsWith('12,35 €'));
      expect(bloque[2], startsWith('Tarjeta'));
      expect(bloque[2], endsWith('7,60 €'));
      expect(bloque[3], startsWith('Entregado'));
      expect(bloque[3], endsWith('15,00 €'));
      expect(bloque[4], startsWith('Cambio'));
      expect(bloque[4], endsWith('2,65 €'));
      for (final t in texts) {
        expect(t.runes.length, lessThanOrEqualTo(paper.columns));
      }
    }
  });

  test('mixto sin efectivo entregado: sin filas de entregado ni cambio', () {
    final texts = decodeEscPos(
      generarTicket(ticket(entregado: null, cambio: null)),
    ).texts;
    expect(bloqueCobro(texts), hasLength(3));
  });

  test('un solo pago se imprime exactamente igual que sin desglose', () {
    final sinDesglose = generarTicket(ticket(pagos: const []));
    final conUno = generarTicket(
      ticket(
        pagos: const [
          PagoTicketPrint(formaPago: 'Efectivo', importeCents: 1995),
        ],
      ),
    );
    expect(conUno, sinDesglose);
    final bloque = bloqueCobro(decodeEscPos(sinDesglose).texts);
    expect(bloque.first, endsWith('Efectivo'));
    expect(bloque.skip(1).map((t) => t.split(' ').first), [
      'Entregado',
      'Cambio',
    ]);
  });

  test('validaciones del desglose', () {
    void rechaza(List<PagoTicketPrint> pagos, String texto) {
      expect(
        () => generarTicket(ticket(pagos: pagos)),
        throwsA(
          isA<ValidationException>().having(
            (e) => e.message,
            'message',
            contains(texto),
          ),
        ),
      );
    }

    rechaza(const [
      PagoTicketPrint(formaPago: 'Efectivo', importeCents: 1235),
      PagoTicketPrint(formaPago: 'Tarjeta', importeCents: 700),
    ], 'suman');
    rechaza(const [
      PagoTicketPrint(formaPago: 'Efectivo', importeCents: 1990),
    ], 'suman');
    rechaza(const [
      PagoTicketPrint(formaPago: 'Efectivo', importeCents: 1995),
      PagoTicketPrint(formaPago: 'Tarjeta', importeCents: 0),
    ], 'positivo');
    rechaza(const [
      PagoTicketPrint(formaPago: 'Efectivo', importeCents: 1000),
      PagoTicketPrint(formaPago: 'efectivo', importeCents: 995),
    ], 'repite');
    rechaza(const [
      PagoTicketPrint(formaPago: ' ', importeCents: 1000),
      PagoTicketPrint(formaPago: 'Tarjeta', importeCents: 995),
    ], 'vacía');
  });

  test('en isolate produce los mismos bytes', () async {
    final data = ticket();
    expect(
      await generarTicketEnIsolate(data),
      await generarTicketEnIsolate(data, runner: const InlineIsolateRunner()),
    );
  });
}
