import 'dart:convert';

import 'package:proyecto_comandero/core/errors/app_exception.dart';
import 'package:proyecto_comandero/features/sala/domain/linea_comanda.dart';
import 'package:proyecto_comandero/features/sala/domain/ticket.dart';
import 'package:test/test.dart';

final creada = DateTime(2026, 10, 7, 21, 48);

final totales = TotalesTicket(
  netoCents: 1814,
  ivaCents: 181,
  totalCents: 1995,
  desglose: const [
    DesgloseIva(
      codimpuesto: 'IVA10',
      ivaBp: 1000,
      baseCents: 1814,
      cuotaCents: 181,
    ),
  ],
);

Ticket ticket({
  MetodoPago metodoPago = MetodoPago.efectivo,
  List<PagoTicket>? pagos,
  int? entregado,
}) => Ticket(
  id: 'b1c2d3e4-0000-4000-8000-000000000001',
  numeroLocal: 31,
  mesaId: 'm7',
  nombreMesa: 'Mesa 7',
  comandaId: 'c7',
  fechaHora: creada,
  lineas: [
    LineaComanda(
      id: 'l1',
      referencia: 'MENU',
      descripcion: 'Menú',
      cantidad: 1,
      pvpUnitarioCents: 1995,
      pvpUnitarioNeto: 18.13636,
      ivaBp: 1000,
      codimpuesto: 'IVA10',
      camarero: 'Ana',
      creadaEn: creada,
    ),
  ],
  totales: totales,
  metodoPago: metodoPago,
  pagos: pagos,
  entregadoCents: entregado,
);

const mixto = [
  PagoTicket(metodo: MetodoPago.efectivo, importeCents: 1235),
  PagoTicket(metodo: MetodoPago.tarjeta, importeCents: 760),
];

Map<String, Object?> viaTexto(Map<String, Object?> json) =>
    jsonDecode(jsonEncode(json)) as Map<String, Object?>;

void main() {
  group('pago único (compatibilidad)', () {
    test('sin pagos: un único pago del total con metodoPago', () {
      final t = ticket(metodoPago: MetodoPago.tarjeta);
      expect(t.pagos, [
        const PagoTicket(metodo: MetodoPago.tarjeta, importeCents: 1995),
      ]);
      expect(t.esMixto, isFalse);
      expect(t.efectivoCents, 0);
      expect(t.tarjetaCents, 1995);
    });

    test('el JSON de un pago único no cambia (sin "pagos")', () {
      final json = ticket(entregado: 2000).toJson();
      expect(json, isNot(contains('pagos')));
      expect(json['metodoPago'], 'efectivo');
    });

    test('lee diarios antiguos sin "pagos"', () {
      final json = viaTexto(ticket(entregado: 2000).toJson())..remove('pagos');
      final leido = Ticket.fromJson(json);
      expect(leido, ticket(entregado: 2000));
      expect(leido.efectivoCents, 1995);
      expect(leido.cambioCents, 5);
    });

    test('un único pago explícito equivale al implícito', () {
      expect(
        ticket(
          pagos: const [
            PagoTicket(metodo: MetodoPago.efectivo, importeCents: 1995),
          ],
        ),
        ticket(),
      );
    });
  });

  group('cobro mixto', () {
    test('desglose, principal y cambio sobre la parte en efectivo', () {
      final t = ticket(pagos: mixto, entregado: 1500);
      expect(t.esMixto, isTrue);
      expect(t.efectivoCents, 1235);
      expect(t.tarjetaCents, 760);
      expect(t.metodoPago, MetodoPago.efectivo);
      expect(t.cambioCents, 265);
      expect(ticket(pagos: mixto, entregado: 1235).cambioCents, 0);
      expect(ticket(pagos: mixto, entregado: 1000).cambioCents, 0);
      expect(ticket(pagos: mixto).cambioCents, 0);
    });

    test('ida y vuelta JSON con el reparto (y con factura)', () {
      final t = ticket(
        pagos: mixto,
        entregado: 1500,
      ).conFactura(FacturaSincronizada(estado: EstadoSincronizacion.pendiente));
      final json = viaTexto(t.toJson());
      expect(json['pagos'], [
        {'metodo': 'efectivo', 'importeCents': 1235},
        {'metodo': 'tarjeta', 'importeCents': 760},
      ]);
      final leido = Ticket.fromJson(json);
      expect(leido, t);
      expect(leido.pagos, mixto);
    });

    test('metodoPrincipal: mayor importe; en empate, efectivo', () {
      expect(PagoTicket.metodoPrincipal(mixto), MetodoPago.efectivo);
      expect(
        PagoTicket.metodoPrincipal(const [
          PagoTicket(metodo: MetodoPago.efectivo, importeCents: 500),
          PagoTicket(metodo: MetodoPago.tarjeta, importeCents: 1495),
        ]),
        MetodoPago.tarjeta,
      );
      expect(
        PagoTicket.metodoPrincipal(const [
          PagoTicket(metodo: MetodoPago.tarjeta, importeCents: 1000),
          PagoTicket(metodo: MetodoPago.efectivo, importeCents: 1000),
        ]),
        MetodoPago.efectivo,
      );
      expect(
        () => PagoTicket.metodoPrincipal(const []),
        throwsA(isA<ValidationException>()),
      );
    });

    test('la tarjeta como principal', () {
      final t = ticket(
        metodoPago: MetodoPago.tarjeta,
        pagos: const [
          PagoTicket(metodo: MetodoPago.efectivo, importeCents: 500),
          PagoTicket(metodo: MetodoPago.tarjeta, importeCents: 1495),
        ],
      );
      expect(t.metodoPago, MetodoPago.tarjeta);
      expect(t.efectivoCents, 500);
    });
  });

  group('validación del reparto', () {
    void rechaza(MetodoPago metodo, List<PagoTicket> pagos, String texto) {
      expect(
        () => ticket(metodoPago: metodo, pagos: pagos),
        throwsA(
          isA<ValidationException>().having(
            (e) => e.message,
            'message',
            contains(texto),
          ),
        ),
      );
    }

    test('suma distinta del total', () {
      rechaza(MetodoPago.efectivo, const [
        PagoTicket(metodo: MetodoPago.efectivo, importeCents: 1235),
        PagoTicket(metodo: MetodoPago.tarjeta, importeCents: 761),
      ], 'suman');
      rechaza(MetodoPago.efectivo, const [
        PagoTicket(metodo: MetodoPago.efectivo, importeCents: 1990),
      ], 'suman');
    });

    test('formas repetidas, vacío o más de dos', () {
      rechaza(MetodoPago.efectivo, const [
        PagoTicket(metodo: MetodoPago.efectivo, importeCents: 1000),
        PagoTicket(metodo: MetodoPago.efectivo, importeCents: 995),
      ], 'repite');
      rechaza(MetodoPago.efectivo, const [], 'uno o dos');
      rechaza(MetodoPago.efectivo, const [
        PagoTicket(metodo: MetodoPago.efectivo, importeCents: 1000),
        PagoTicket(metodo: MetodoPago.tarjeta, importeCents: 995),
        PagoTicket(metodo: MetodoPago.tarjeta, importeCents: 0),
      ], 'uno o dos');
    });

    test('importes no positivos en un cobro mixto', () {
      rechaza(MetodoPago.efectivo, const [
        PagoTicket(metodo: MetodoPago.efectivo, importeCents: 1995),
        PagoTicket(metodo: MetodoPago.tarjeta, importeCents: 0),
      ], 'no positivo');
      rechaza(MetodoPago.efectivo, const [
        PagoTicket(metodo: MetodoPago.efectivo, importeCents: 2095),
        PagoTicket(metodo: MetodoPago.tarjeta, importeCents: -100),
      ], 'no positivo');
    });

    test('metodoPago que no es el principal', () {
      rechaza(MetodoPago.tarjeta, mixto, 'principal');
      rechaza(MetodoPago.tarjeta, const [
        PagoTicket(metodo: MetodoPago.efectivo, importeCents: 1995),
      ], 'principal');
    });

    test('fromJson con reparto incoherente: FormatException', () {
      final json = viaTexto(ticket(pagos: mixto).toJson());
      json['pagos'] = [
        {'metodo': 'efectivo', 'importeCents': 1235},
        {'metodo': 'tarjeta', 'importeCents': 700},
      ];
      expect(() => Ticket.fromJson(json), throwsFormatException);
      json['pagos'] = [
        {'metodo': 'bizum', 'importeCents': 1995},
      ];
      expect(() => Ticket.fromJson(json), throwsFormatException);
    });
  });
}
