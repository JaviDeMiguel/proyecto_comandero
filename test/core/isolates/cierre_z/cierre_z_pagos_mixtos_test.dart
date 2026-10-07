import 'package:proyecto_comandero/core/errors/app_exception.dart';
import 'package:proyecto_comandero/core/isolates/cierre_z/cierre_z_engine.dart';
import 'package:proyecto_comandero/core/isolates/isolate_runner.dart';
import 'package:test/test.dart';

const cuentas = CuentasCierre(
  subcuentaCaja: '5700000000',
  subcuentaBanco: '5720000000',
  subcuentaVentas: '7000000000',
  subcuentaIvaGenerica: '4770000000',
  subcuentaIvaPorCodimpuesto: {'IVA10': '4770000010'},
  subcuentaPerdidas: '6590000000',
  subcuentaIngresos: '7590000000',
);

TicketCierre ticket(
  String id,
  int totalCents, {
  MetodoPago metodo = MetodoPago.efectivo,
  List<PagoCierre>? pagos,
}) {
  final base = ((totalCents * 10000) / 11000).round();
  return TicketCierre(
    id: id,
    fechaHora: DateTime(2026, 10, 7, 14),
    totalCents: totalCents,
    metodoPago: metodo,
    pagos: pagos,
    desglose: [
      DesgloseIvaTicket(
        codimpuesto: 'IVA10',
        ivaBp: 1000,
        baseCents: base,
        cuotaCents: totalCents - base,
      ),
    ],
  );
}

/// 19,95 €: 12,35 € en efectivo y 7,60 € con tarjeta.
TicketCierre mixto(String id) => ticket(
  id,
  1995,
  pagos: const [
    PagoCierre(metodo: MetodoPago.efectivo, importeCents: 1235),
    PagoCierre(metodo: MetodoPago.tarjeta, importeCents: 760),
  ],
);

CierreZRequest request(
  List<TicketCierre> tickets, {
  int fondo = 10000,
  int? contado,
  ModoAsientoZ modo = ModoAsientoZ.soloDescuadre,
}) => CierreZRequest(
  idCierre: 'cierre-mixto',
  fecha: DateTime(2026, 10, 7, 23),
  tickets: tickets,
  fondoCajaCents: fondo,
  efectivoContadoCents: contado,
  modo: modo,
  cuentas: cuentas,
);

int debe(AsientoPropuesto asiento, String subcuenta) => asiento.partidas
    .where((p) => p.codsubcuenta == subcuenta)
    .fold(0, (sum, p) => sum + p.debeCents);

void main() {
  test('sin desglose, todo el total va a su metodoPago', () {
    final t = ticket('t1', 500, metodo: MetodoPago.tarjeta);
    expect(t.pagos, [
      const PagoCierre(metodo: MetodoPago.tarjeta, importeCents: 500),
    ]);
    expect(t.efectivoCents, 0);
    expect(t.tarjetaCents, 500);
    expect(t.esMixto, isFalse);
  });

  test('reparte las ventas por forma de pago y cuenta los mixtos', () {
    final informe = calcularCierreZ(
      request([
        mixto('m1'),
        ticket('e1', 1000),
        ticket('t1', 300, metodo: MetodoPago.tarjeta),
      ], contado: 10000 + 1235 + 1000),
    ).informe;

    expect(informe.ventasTotalCents, 3295);
    expect(informe.ventasEfectivoCents, 2235);
    expect(informe.ventasTarjetaCents, 1060);
    expect(informe.numTicketsMixtos, 1);
    expect(informe.numTickets, 3);
    // Efectivo esperado: fondo + partes en efectivo, NO el total del mixto.
    expect(informe.efectivoEsperadoCents, 10000 + 2235);
    expect(informe.descuadreCents, 0);
  });

  test('soloDescuadre: el faltante se mide contra la parte en efectivo', () {
    final result = calcularCierreZ(
      request([mixto('m1')], contado: 10000 + 1200),
    );
    expect(result.informe.descuadreCents, -35);
    expect(result.asiento.partidas, hasLength(2));
    expect(debe(result.asiento, '6590000000'), 35);
  });

  test('resumenCompleto: Debe 570/572 con la parte de cada ticket', () {
    final result = calcularCierreZ(
      request(
        [
          mixto('m1'),
          mixto('m2'),
          ticket('t1', 300, metodo: MetodoPago.tarjeta),
        ],
        contado: 10000 + 2470,
        modo: ModoAsientoZ.resumenCompleto,
      ),
    );
    final asiento = result.asiento;
    expect(asiento.cuadrado, isTrue);
    expect(debe(asiento, '5700000000'), 2470);
    expect(debe(asiento, '5720000000'), 1520 + 300);
    expect(asiento.haberCents, 1995 * 2 + 300);
  });

  test('los anulados no suman en ninguna forma de pago', () {
    final anulado = TicketCierre(
      id: 'a1',
      fechaHora: DateTime(2026, 10, 7, 15),
      totalCents: 1995,
      metodoPago: MetodoPago.efectivo,
      pagos: mixto('x').pagos,
      desglose: mixto('x').desglose,
      anulado: true,
    );
    final informe = calcularCierreZ(request([anulado], contado: 10000)).informe;
    expect(informe.ventasEfectivoCents, 0);
    expect(informe.ventasTarjetaCents, 0);
    expect(informe.numTicketsMixtos, 0);
    expect(informe.importeAnuladoCents, 1995);
  });

  group('validación del desglose', () {
    void rechaza(List<PagoCierre> pagos, String texto) {
      expect(
        () => calcularCierreZ(request([ticket('t1', 1995, pagos: pagos)])),
        throwsA(
          isA<ValidationException>().having(
            (e) => e.message,
            'message',
            contains(texto),
          ),
        ),
      );
    }

    test('no suma el total', () {
      rechaza(const [
        PagoCierre(metodo: MetodoPago.efectivo, importeCents: 1235),
        PagoCierre(metodo: MetodoPago.tarjeta, importeCents: 700),
      ], 'suman');
    });

    test('forma repetida, vacío o importe no positivo', () {
      rechaza(const [
        PagoCierre(metodo: MetodoPago.efectivo, importeCents: 1000),
        PagoCierre(metodo: MetodoPago.efectivo, importeCents: 995),
      ], 'repetida');
      rechaza(const [], 'sin desglose');
      rechaza(const [
        PagoCierre(metodo: MetodoPago.efectivo, importeCents: 1995),
        PagoCierre(metodo: MetodoPago.tarjeta, importeCents: 0),
      ], 'no positivo');
    });
  });

  test('en isolate da lo mismo que en línea', () async {
    final req = request(
      [mixto('m1')],
      contado: 11235,
      modo: ModoAsientoZ.resumenCompleto,
    );
    final enIsolate = await calcularCierreZEnIsolate(req);
    expect(
      enIsolate,
      await calcularCierreZEnIsolate(req, runner: const InlineIsolateRunner()),
    );
    expect(enIsolate.informe.ventasEfectivoCents, 1235);
  });
}
