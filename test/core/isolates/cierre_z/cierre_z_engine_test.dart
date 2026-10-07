import 'dart:math';

import 'package:proyecto_comandero/core/errors/app_exception.dart';
import 'package:proyecto_comandero/core/isolates/cierre_z/cierre_z_engine.dart';
import 'package:proyecto_comandero/core/isolates/isolate_runner.dart';
import 'package:test/test.dart';

const cuentas = CuentasCierre(
  subcuentaCaja: '5700000000',
  subcuentaBanco: '5720000000',
  subcuentaVentas: '7000000000',
  subcuentaIvaGenerica: '4770000000',
  subcuentaIvaPorCodimpuesto: {'IVA10': '4770000010', 'IVA21': '4770000021'},
  subcuentaPerdidas: '6590000000',
  subcuentaIngresos: '7590000000',
);

final fecha = DateTime(2026, 10, 6, 23, 30);

TicketCierre ticket(
  String id,
  int totalCents, {
  MetodoPago metodo = MetodoPago.efectivo,
  int ivaBp = 1000,
  String codimpuesto = 'IVA10',
  bool anulado = false,
  DateTime? hora,
}) {
  // base = round(total / (1 + iva)); cuota = total - base
  final base = ((totalCents * 10000) / (10000 + ivaBp)).round();
  return TicketCierre(
    id: id,
    fechaHora: hora ?? DateTime(2026, 10, 6, 14, 0),
    totalCents: totalCents,
    metodoPago: metodo,
    desglose: [
      DesgloseIvaTicket(
        codimpuesto: codimpuesto,
        ivaBp: ivaBp,
        baseCents: base,
        cuotaCents: totalCents - base,
      ),
    ],
    anulado: anulado,
  );
}

CierreZRequest request({
  List<TicketCierre> tickets = const [],
  int fondo = 0,
  int? contado,
  int retiradas = 0,
  ModoAsientoZ modo = ModoAsientoZ.soloDescuadre,
}) => CierreZRequest(
  idCierre: 'cierre-001',
  fecha: fecha,
  tickets: tickets,
  fondoCajaCents: fondo,
  efectivoContadoCents: contado,
  retiradasCents: retiradas,
  modo: modo,
  cuentas: cuentas,
  nombreTpv: 'TPV Barra',
);

PartidaPropuesta partida(AsientoPropuesto asiento, String subcuenta) =>
    asiento.partidas.singleWhere((p) => p.codsubcuenta == subcuenta);

void main() {
  group('informe', () {
    test('sin tickets', () {
      final result = calcularCierreZ(request(fondo: 10000, contado: 10000));
      final informe = result.informe;
      expect(informe.numTickets, 0);
      expect(informe.ventasTotalCents, 0);
      expect(informe.ticketMedioCents, 0);
      expect(informe.porIva, isEmpty);
      expect(informe.efectivoEsperadoCents, 10000);
      expect(informe.descuadreCents, 0);
      expect(informe.primerTicket, isNull);
      expect(result.asiento.vacio, isTrue);
      expect(result.asiento.cuadrado, isTrue);
      expect(result.asiento.documento, 'Z-20261006-cierre001');
      expect(result.asiento.fecha, DateTime(2026, 10, 6));
    });

    test('agrega ventas por forma de pago y por IVA', () {
      final result = calcularCierreZ(
        request(
          tickets: [
            ticket('t1', 665, hora: DateTime(2026, 10, 6, 13)),
            ticket(
              't2',
              1200,
              metodo: MetodoPago.tarjeta,
              hora: DateTime(2026, 10, 6, 15),
            ),
            ticket(
              't3',
              1210,
              ivaBp: 2100,
              codimpuesto: 'IVA21',
              hora: DateTime(2026, 10, 6, 14),
            ),
            ticket('t4', 500, anulado: true),
          ],
          fondo: 5000,
          contado: 6875,
        ),
      );
      final informe = result.informe;
      expect(informe.numTickets, 3);
      expect(informe.numAnulados, 1);
      expect(informe.importeAnuladoCents, 500);
      expect(informe.ventasEfectivoCents, 665 + 1210);
      expect(informe.ventasTarjetaCents, 1200);
      expect(informe.ventasTotalCents, 3075);
      expect(informe.ticketMedioCents, 1025);
      expect(informe.porIva.map((v) => v.ivaBp), [1000, 2100]);
      expect(informe.porIva[0].baseCents, 605 + 1091);
      expect(informe.porIva[0].cuotaCents, 60 + 109);
      expect(informe.porIva[0].numTickets, 2);
      expect(informe.porIva[1].baseCents, 1000);
      expect(informe.porIva[1].cuotaCents, 210);
      expect(informe.efectivoEsperadoCents, 5000 + 1875);
      expect(informe.descuadreCents, 0);
      expect(informe.primerTicket, DateTime(2026, 10, 6, 13));
      expect(informe.ultimoTicket, DateTime(2026, 10, 6, 15));
    });

    test('retiradas y descuadre', () {
      final informe = calcularCierreZ(
        request(
          tickets: [ticket('t1', 1000)],
          fondo: 5000,
          retiradas: 2000,
          contado: 3850,
        ),
      ).informe;
      expect(informe.efectivoEsperadoCents, 4000);
      expect(informe.descuadreCents, -150);
    });

    test('sin arqueo no hay descuadre y se avisa', () {
      final result = calcularCierreZ(request(tickets: [ticket('t1', 1000)]));
      expect(result.informe.descuadreCents, 0);
      expect(result.informe.efectivoContadoCents, isNull);
      expect(result.informe.avisos, contains(contains('Sin arqueo')));
      expect(result.asiento.vacio, isTrue);
    });
  });

  group('asiento soloDescuadre', () {
    test('caja cuadrada: asiento vacío', () {
      final asiento = calcularCierreZ(
        request(tickets: [ticket('t1', 1000)], contado: 1000),
      ).asiento;
      expect(asiento.vacio, isTrue);
      expect(asiento.modo, ModoAsientoZ.soloDescuadre);
    });

    test('faltante: Debe 659 / Haber 570', () {
      final asiento = calcularCierreZ(
        request(tickets: [ticket('t1', 1000)], contado: 850),
      ).asiento;
      expect(asiento.partidas, hasLength(2));
      expect(partida(asiento, '6590000000').debeCents, 150);
      expect(partida(asiento, '6590000000').haberCents, 0);
      expect(partida(asiento, '5700000000').haberCents, 150);
      expect(partida(asiento, '5700000000').debeCents, 0);
      expect(asiento.cuadrado, isTrue);
      expect(asiento.concepto, 'Cierre Z 06-10-2026 TPV Barra');
      expect(partida(asiento, '6590000000').concepto, contains('faltante'));
    });

    test('sobrante: Debe 570 / Haber 759', () {
      final asiento = calcularCierreZ(
        request(tickets: [ticket('t1', 1000)], contado: 1020),
      ).asiento;
      expect(asiento.partidas, hasLength(2));
      expect(partida(asiento, '5700000000').debeCents, 20);
      expect(partida(asiento, '7590000000').haberCents, 20);
      expect(asiento.cuadrado, isTrue);
    });
  });

  group('asiento resumenCompleto', () {
    test('mixto con dos IVAs y caja cuadrada', () {
      final asiento = calcularCierreZ(
        request(
          tickets: [
            ticket('t1', 665),
            ticket('t2', 1200, metodo: MetodoPago.tarjeta),
            ticket('t3', 1210, ivaBp: 2100, codimpuesto: 'IVA21'),
          ],
          contado: 665 + 1210,
          modo: ModoAsientoZ.resumenCompleto,
        ),
      ).asiento;
      expect(partida(asiento, '5700000000').debeCents, 1875);
      expect(partida(asiento, '5720000000').debeCents, 1200);
      expect(partida(asiento, '7000000000').haberCents, 605 + 1091 + 1000);
      final iva10 = partida(asiento, '4770000010');
      expect(iva10.haberCents, 60 + 109);
      expect(iva10.baseCents, 605 + 1091);
      expect(iva10.ivaPct, 10);
      final iva21 = partida(asiento, '4770000021');
      expect(iva21.haberCents, 210);
      expect(iva21.ivaPct, 21);
      expect(
        asiento.partidas.where((p) => p.codsubcuenta == '6590000000'),
        isEmpty,
      );
      expect(
        asiento.partidas.where((p) => p.codsubcuenta == '7590000000'),
        isEmpty,
      );
      expect(asiento.debeCents, 3075);
      expect(asiento.cuadrado, isTrue);
    });

    test('faltante: 570 refleja el efectivo real y 659 la pérdida', () {
      final asiento = calcularCierreZ(
        request(
          tickets: [ticket('t1', 1000)],
          contado: 850,
          modo: ModoAsientoZ.resumenCompleto,
        ),
      ).asiento;
      expect(partida(asiento, '5700000000').debeCents, 850);
      expect(partida(asiento, '6590000000').debeCents, 150);
      expect(partida(asiento, '7000000000').haberCents, 909);
      expect(partida(asiento, '4770000010').haberCents, 91);
      expect(asiento.cuadrado, isTrue);
    });

    test('sobrante: 570 incluye el sobrante y 759 lo compensa', () {
      final asiento = calcularCierreZ(
        request(
          tickets: [ticket('t1', 1000)],
          contado: 1020,
          modo: ModoAsientoZ.resumenCompleto,
        ),
      ).asiento;
      expect(partida(asiento, '5700000000').debeCents, 1020);
      expect(partida(asiento, '7590000000').haberCents, 20);
      expect(asiento.cuadrado, isTrue);
    });

    test('solo tarjeta: no hay partida de caja', () {
      final asiento = calcularCierreZ(
        request(
          tickets: [ticket('t1', 1000, metodo: MetodoPago.tarjeta)],
          contado: 0,
          modo: ModoAsientoZ.resumenCompleto,
        ),
      ).asiento;
      expect(
        asiento.partidas.where((p) => p.codsubcuenta == '5700000000'),
        isEmpty,
      );
      expect(partida(asiento, '5720000000').debeCents, 1000);
      expect(asiento.cuadrado, isTrue);
    });

    test('impuesto sin subcuenta propia usa la 477 genérica', () {
      final asiento = calcularCierreZ(
        request(
          tickets: [ticket('t1', 104, ivaBp: 400, codimpuesto: 'IVA4')],
          contado: 104,
          modo: ModoAsientoZ.resumenCompleto,
        ),
      ).asiento;
      expect(partida(asiento, '4770000000').haberCents, 4);
    });

    test('sin tickets ni descuadre: asiento vacío', () {
      final asiento = calcularCierreZ(
        request(contado: 0, modo: ModoAsientoZ.resumenCompleto),
      ).asiento;
      expect(asiento.vacio, isTrue);
    });
  });

  group('validaciones', () {
    test('desglose incoherente', () {
      final malo = TicketCierre(
        id: 'x',
        fechaHora: fecha,
        totalCents: 1000,
        metodoPago: MetodoPago.efectivo,
        desglose: const [
          DesgloseIvaTicket(ivaBp: 1000, baseCents: 900, cuotaCents: 90),
        ],
      );
      expect(
        () => calcularCierreZ(request(tickets: [malo])),
        throwsA(
          isA<ValidationException>().having(
            (e) => e.message,
            'message',
            contains('desglose'),
          ),
        ),
      );
    });

    test('ids repetidos, importes negativos e id vacío', () {
      expect(
        () => calcularCierreZ(
          request(tickets: [ticket('a', 100), ticket('a', 200)]),
        ),
        throwsA(isA<ValidationException>()),
      );
      expect(
        () => calcularCierreZ(request(fondo: -1)),
        throwsA(isA<ValidationException>()),
      );
      expect(
        () => calcularCierreZ(request(retiradas: -1)),
        throwsA(isA<ValidationException>()),
      );
      expect(
        () => calcularCierreZ(request(contado: -1)),
        throwsA(isA<ValidationException>()),
      );
      expect(
        () => calcularCierreZ(
          CierreZRequest(
            idCierre: ' ',
            fecha: fecha,
            tickets: const [],
            cuentas: cuentas,
          ),
        ),
        throwsA(isA<ValidationException>()),
      );
    });
  });

  group('propiedades', () {
    test('Debe == Haber y sumas coherentes con 200 tickets aleatorios', () {
      final random = Random(42);
      final tickets = [
        for (var i = 0; i < 200; i++)
          ticket(
            't$i',
            random.nextInt(5000) + 1,
            metodo: random.nextBool()
                ? MetodoPago.efectivo
                : MetodoPago.tarjeta,
            ivaBp: [400, 1000, 2100][random.nextInt(3)],
            codimpuesto: ['IVA4', 'IVA10', 'IVA21'][random.nextInt(3)],
            anulado: random.nextInt(10) == 0,
            hora: DateTime(
              2026,
              10,
              6,
              12 + random.nextInt(10),
              random.nextInt(60),
            ),
          ),
      ];
      for (final modo in ModoAsientoZ.values) {
        for (final contadoDelta in [-700, 0, 350]) {
          final efectivo = tickets
              .where((t) => !t.anulado && t.metodoPago == MetodoPago.efectivo)
              .fold(0, (sum, t) => sum + t.totalCents);
          final result = calcularCierreZ(
            request(
              tickets: tickets,
              fondo: 10000,
              contado: 10000 + efectivo + contadoDelta,
              modo: modo,
            ),
          );
          expect(
            result.asiento.cuadrado,
            isTrue,
            reason: '$modo $contadoDelta',
          );
          expect(result.informe.descuadreCents, contadoDelta);
          expect(
            result.informe.ventasTotalCents,
            result.informe.ventasEfectivoCents +
                result.informe.ventasTarjetaCents,
          );
          expect(
            result.informe.porIva.fold(0, (sum, v) => sum + v.totalCents),
            result.informe.ventasTotalCents,
          );
          if (modo == ModoAsientoZ.resumenCompleto) {
            expect(
              result.asiento.debeCents,
              result.informe.ventasTotalCents +
                  max(0, contadoDelta) +
                  (contadoDelta < 0 ? 0 : 0),
            );
          }
        }
      }
    });
  });

  test('se ejecuta en un isolate real', () async {
    final result = await calcularCierreZEnIsolate(
      request(
        tickets: [ticket('t1', 665)],
        contado: 600,
        modo: ModoAsientoZ.resumenCompleto,
      ),
    );
    expect(result.asiento.cuadrado, isTrue);
    expect(result.informe.descuadreCents, -65);

    final inline = await calcularCierreZEnIsolate(
      request(
        tickets: [ticket('t1', 665)],
        contado: 600,
        modo: ModoAsientoZ.resumenCompleto,
      ),
      runner: const InlineIsolateRunner(),
    );
    expect(inline, result);
  });
}
