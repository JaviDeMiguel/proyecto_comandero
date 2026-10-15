import 'dart:convert';

import 'package:proyecto_comandero/features/sala/domain/linea_comanda.dart';
import 'package:proyecto_comandero/features/sala/domain/precuenta_emitida.dart';
import 'package:proyecto_comandero/features/sala/domain/ticket.dart';
import 'package:test/test.dart';

final cobro = DateTime(2026, 10, 9, 14, 32, 10);
final original = DateTime(2026, 10, 9, 14, 40);

const qr = QrImpreso(
  url:
      'https://www2.agenciatributaria.gob.es/wlpl/TIKE-CONT/ValidarQR'
      '?nif=B12345678&numserie=F2026S12&fecha=09-10-2026&importe=67.00',
  leyenda: 'VERI*FACTU',
  modo: 'verifactu',
  entorno: 'produccion',
  nif: 'B12345678',
);

/// Serializa y vuelve a leer pasando por texto JSON, como en el diario.
T roundTrip<T>(
  Map<String, Object?> json,
  T Function(Map<String, Object?>) read,
) => read(viaJson(json));

Map<String, Object?> viaJson(Map<String, Object?> json) =>
    jsonDecode(jsonEncode(json)) as Map<String, Object?>;

final totales = TotalesTicket(
  netoCents: 455,
  ivaCents: 45,
  totalCents: 500,
  desglose: const [
    DesgloseIva(
      codimpuesto: 'IVA10',
      ivaBp: 1000,
      baseCents: 455,
      cuotaCents: 45,
    ),
  ],
);

LineaComanda linea() => LineaComanda(
  id: 'l1',
  referencia: 'CANA',
  descripcion: 'Caña',
  cantidad: 2,
  pvpUnitarioCents: 250,
  pvpUnitarioNeto: 2.27273,
  ivaBp: 1000,
  codimpuesto: 'IVA10',
  camarero: 'Ana',
  creadaEn: cobro,
  pase: 1,
  envio: 12,
);

PrecuentaEmitida precuenta(int numero) => PrecuentaEmitida(
  numero: numero,
  emitidaEn: cobro,
  comandaId: 'c1',
  nombreMesa: 'Terraza 1',
  lineas: [LineaPrecuenta.desde(linea())],
  totales: totales,
  comensales: 2,
  emitidaPor: 'Caja 1',
);

Ticket ticket({
  List<PrecuentaEmitida> precuentas = const [],
  ImpresionTicket impresion = ImpresionTicket.vacia,
  FacturaSincronizada? factura,
}) => Ticket(
  id: 't1',
  numeroLocal: 12,
  mesaId: 'm1',
  nombreMesa: 'Terraza 1',
  comandaId: 'c1',
  fechaHora: cobro,
  lineas: [linea()],
  totales: totales,
  metodoPago: MetodoPago.efectivo,
  entregadoCents: 1000,
  camarero: 'Ana',
  comensales: 2,
  factura: factura,
  precuentas: precuentas,
  impresion: impresion,
);

void main() {
  group('QrImpreso', () {
    test('ida y vuelta JSON; la leyenda solo si no es nula', () {
      expect(qr.toJson().keys, ['url', 'leyenda', 'modo', 'entorno', 'nif']);
      expect(roundTrip(qr.toJson(), QrImpreso.fromJson), qr);

      const sinLeyenda = QrImpreso(
        url:
            'https://prewww2.aeat.es/wlpl/TIKE-CONT/ValidarQR'
            '?nif=B12345678&numserie=F2026S12&fecha=09-10-2026&importe=67.00',
        modo: 'noVerifactu',
        entorno: 'pruebas',
        nif: 'B12345678',
      );
      expect(sinLeyenda.toJson().containsKey('leyenda'), isFalse);
      expect(roundTrip(sinLeyenda.toJson(), QrImpreso.fromJson), sinLeyenda);
    });

    test('sin url o con un campo de otro tipo lanza FormatException', () {
      expect(
        () => QrImpreso.fromJson({
          'modo': 'verifactu',
          'entorno': 'produccion',
          'nif': 'B12345678',
        }),
        throwsFormatException,
      );
      expect(
        () => QrImpreso.fromJson({...qr.toJson(), 'nif': 12345678}),
        throwsFormatException,
      );
    });
  });

  group('ImpresionTicket', () {
    test('vacía: todos los campos por defecto y JSON sin claves', () {
      expect(ImpresionTicket.vacia.estaVacia, isTrue);
      expect(ImpresionTicket.vacia.originalImpreso, isFalse);
      expect(ImpresionTicket.vacia.toJson(), isEmpty);
      expect(const ImpresionTicket(), ImpresionTicket.vacia);
      expect(ImpresionTicket.fromJson(const {}), ImpresionTicket.vacia);
    });

    test('conProvisional fija la fecha la 1ª vez y después cuenta copias', () {
      final primera = ImpresionTicket.vacia.conProvisional(cobro);
      expect(primera.provisionalEn, cobro);
      expect(primera.copiasProvisional, 0);
      expect(primera.estaVacia, isFalse);
      expect(primera.originalImpreso, isFalse);

      final copia = primera.conProvisional(
        cobro.add(const Duration(minutes: 1)),
      );
      expect(copia.provisionalEn, cobro);
      expect(copia.copiasProvisional, 1);
      expect(copia.conProvisional(cobro).copiasProvisional, 2);
      expect(copia.toJson(), {
        'provisionalEn': cobro.toIso8601String(),
        'copiasProvisional': 1,
      });
    });

    test('conFacturaOriginal guarda fecha y QR; conDuplicado cuenta', () {
      final provisional = ImpresionTicket.vacia.conProvisional(cobro);
      final conOriginal = provisional.conFacturaOriginal(original, qr: qr);
      expect(conOriginal.originalImpreso, isTrue);
      expect(conOriginal.facturaOriginalEn, original);
      expect(conOriginal.qr, qr);
      expect(conOriginal.provisionalEn, cobro);
      expect(conOriginal.duplicados, 0);

      final dosDuplicados = conOriginal.conDuplicado().conDuplicado();
      expect(dosDuplicados.duplicados, 2);
      expect(dosDuplicados.qr, qr);
      expect(dosDuplicados.facturaOriginalEn, original);
      expect(dosDuplicados.provisionalEn, cobro);

      final sinQr = provisional.conFacturaOriginal(original);
      expect(sinQr.originalImpreso, isTrue);
      expect(sinQr.qr, isNull);
    });

    test('toJson escribe solo los campos no por defecto; ida y vuelta', () {
      final completa = ImpresionTicket.vacia
          .conProvisional(cobro)
          .conProvisional(cobro)
          .conFacturaOriginal(original, qr: qr)
          .conDuplicado();
      final json = completa.toJson();
      expect(json.keys, [
        'provisionalEn',
        'copiasProvisional',
        'facturaOriginalEn',
        'qr',
        'duplicados',
      ]);
      expect(json['qr'], qr.toJson());
      expect(roundTrip(json, ImpresionTicket.fromJson), completa);

      final soloOriginal = ImpresionTicket.vacia.conFacturaOriginal(original);
      expect(soloOriginal.toJson(), {
        'facturaOriginalEn': original.toIso8601String(),
      });
      expect(
        roundTrip(soloOriginal.toJson(), ImpresionTicket.fromJson),
        soloOriginal,
      );
    });

    test('lectura tolerante: ilegible → por defecto; qr ilegible → nulo', () {
      final leida = ImpresionTicket.fromJson(
        viaJson({
          'provisionalEn': 'ayer',
          'copiasProvisional': 'dos',
          'facturaOriginalEn': original.toIso8601String(),
          'qr': {'url': 'https://x', 'modo': 'verifactu'},
          'duplicados': -1,
        }),
      );
      expect(leida.provisionalEn, isNull);
      expect(leida.copiasProvisional, 0);
      expect(leida.facturaOriginalEn, original);
      expect(leida.qr, isNull);
      expect(leida.duplicados, 0);

      expect(ImpresionTicket.fromJson({'qr': 'no'}).qr, isNull);
      expect(
        ImpresionTicket.fromJson(
          viaJson({
            'qr': {...qr.toJson(), 'nif': 5},
          }),
        ).qr,
        isNull,
      );
      expect(ImpresionTicket.fromJson(viaJson({'qr': qr.toJson()})).qr, qr);
    });
  });

  group('Ticket con precuentas e impresión', () {
    test('ida y vuelta JSON y omisión cuando están vacías', () {
      final sencillo = ticket();
      expect(sencillo.precuentas, isEmpty);
      expect(sencillo.impresion, ImpresionTicket.vacia);
      expect(sencillo.toJson().containsKey('precuentas'), isFalse);
      expect(sencillo.toJson().containsKey('impresion'), isFalse);
      expect(roundTrip(sencillo.toJson(), Ticket.fromJson), sencillo);

      final completo = ticket(
        precuentas: [precuenta(1), precuenta(2)],
        impresion: ImpresionTicket.vacia
            .conProvisional(cobro)
            .conFacturaOriginal(original, qr: qr)
            .conDuplicado(),
      );
      final json = completo.toJson();
      expect(json.keys, [
        'id',
        'numeroLocal',
        'mesaId',
        'nombreMesa',
        'comandaId',
        'fechaHora',
        'lineas',
        'totales',
        'metodoPago',
        'entregadoCents',
        'camarero',
        'comensales',
        'precuentas',
        'impresion',
      ]);
      expect(json['precuentas'], [
        precuenta(1).toJson(),
        precuenta(2).toJson(),
      ]);
      expect(json['impresion'], completo.impresion.toJson());

      final leido = roundTrip(json, Ticket.fromJson);
      expect(leido, completo);
      expect(leido.precuentas.map((p) => p.numero), [1, 2]);
      expect(leido.impresion.qr, qr);
      expect(leido.impresion.duplicados, 1);
      expect(() => leido.precuentas.add(precuenta(3)), throwsUnsupportedError);
    });

    test('conFactura y copyWith conservan impresion y precuentas', () {
      final completo = ticket(
        precuentas: [precuenta(1)],
        impresion: ImpresionTicket.vacia.conProvisional(cobro),
      );
      final factura = FacturaSincronizada(
        estado: EstadoSincronizacion.sincronizado,
        idfactura: 812,
        codigo: 'F2026S12',
        numero: 12,
        pagada: true,
        emitida: true,
        fecha: original,
        totalFsCents: 500,
      );
      final conFactura = completo.conFactura(factura);
      expect(conFactura.factura, factura);
      expect(conFactura.precuentas, completo.precuentas);
      expect(conFactura.impresion, completo.impresion);
      expect(conFactura.pagos, completo.pagos);
      expect(conFactura.entregadoCents, completo.entregadoCents);

      final impreso = conFactura.copyWith(
        impresion: conFactura.impresion.conFacturaOriginal(original, qr: qr),
      );
      expect(impreso.factura, factura);
      expect(impreso.precuentas, completo.precuentas);
      expect(impreso.impresion.originalImpreso, isTrue);
      expect(impreso.impresion.provisionalEn, cobro);
      expect(impreso.toJson().keys, contains('factura'));
      expect(roundTrip(impreso.toJson(), Ticket.fromJson), impreso);
    });

    test('precuentas o impresión ilegibles no invalidan el ticket', () {
      final json = ticket(precuentas: [precuenta(1)]).toJson();
      final leido = Ticket.fromJson(
        viaJson({
          ...json,
          'precuentas': [
            precuenta(1).toJson(),
            {'numero': 2},
            'x',
          ],
          'impresion': 'sí',
        }),
      );
      expect(leido.precuentas.map((p) => p.numero), [1]);
      expect(leido.impresion, ImpresionTicket.vacia);

      final sinQr = Ticket.fromJson(
        viaJson({
          ...json,
          'impresion': {
            'facturaOriginalEn': original.toIso8601String(),
            'qr': {'url': 42},
          },
        }),
      );
      expect(sinQr.impresion.originalImpreso, isTrue);
      expect(sinQr.impresion.qr, isNull);

      expect(
        Ticket.fromJson(viaJson({...json, 'precuentas': 'no'})).precuentas,
        isEmpty,
      );
    });
  });

  group('FacturaSincronizada', () {
    test('fecha y totalFsCents: ida y vuelta y omisión si son nulos', () {
      final sinDatos = FacturaSincronizada(
        estado: EstadoSincronizacion.pendiente,
      );
      expect(sinDatos.toJson().containsKey('fecha'), isFalse);
      expect(sinDatos.toJson().containsKey('totalFsCents'), isFalse);
      expect(
        roundTrip(sinDatos.toJson(), FacturaSincronizada.fromJson),
        sinDatos,
      );

      final completa = FacturaSincronizada(
        estado: EstadoSincronizacion.sincronizado,
        idfactura: 812,
        codigo: 'F2026S12',
        numero: 12,
        pagada: true,
        emitida: true,
        actualizadoEn: original,
        fecha: DateTime(2026, 10, 9, 14, 33, 5),
        totalFsCents: 6700,
      );
      final json = completa.toJson();
      expect(json['fecha'], '2026-10-09T14:33:05.000');
      expect(json['totalFsCents'], 6700);
      expect(roundTrip(json, FacturaSincronizada.fromJson), completa);

      // Un total de 0 € es válido: se escribe y se lee.
      final cero = FacturaSincronizada(
        estado: EstadoSincronizacion.sincronizado,
        totalFsCents: 0,
      );
      expect(cero.toJson()['totalFsCents'], 0);
      expect(
        roundTrip(cero.toJson(), FacturaSincronizada.fromJson).totalFsCents,
        0,
      );
    });

    test('lectura tolerante de fecha y totalFsCents', () {
      final textoRaro = FacturaSincronizada.fromJson({
        'estado': 'sincronizado',
        'fecha': 'ayer',
        'totalFsCents': '6700',
      });
      expect(textoRaro.fecha, isNull);
      expect(textoRaro.totalFsCents, isNull);

      final tipoRaro = FacturaSincronizada.fromJson({
        'estado': 'sincronizado',
        'fecha': 20261009,
        'totalFsCents': 67.0,
      });
      expect(tipoRaro.fecha, isNull);
      expect(tipoRaro.totalFsCents, isNull);
      expect(tipoRaro.estado, EstadoSincronizacion.sincronizado);
    });
  });
}
