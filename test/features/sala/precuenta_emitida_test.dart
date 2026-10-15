import 'dart:convert';

import 'package:proyecto_comandero/features/sala/domain/linea_comanda.dart';
import 'package:proyecto_comandero/features/sala/domain/precuenta_emitida.dart';
import 'package:proyecto_comandero/features/sala/domain/ticket.dart';
import 'package:test/test.dart';

final emitida = DateTime(2026, 10, 9, 14, 10);

/// Serializa y vuelve a leer pasando por texto JSON, como en el diario.
T roundTrip<T>(
  Map<String, Object?> json,
  T Function(Map<String, Object?>) read,
) => read(viaJson(json));

Map<String, Object?> viaJson(Map<String, Object?> json) =>
    jsonDecode(jsonEncode(json)) as Map<String, Object?>;

/// Copia de [json] sin la [clave].
Map<String, Object?> sin(Map<String, Object?> json, String clave) => {
  for (final entrada in json.entries)
    if (entrada.key != clave) entrada.key: entrada.value,
};

final totales = TotalesTicket(
  netoCents: 5992,
  ivaCents: 708,
  totalCents: 6700,
  desglose: const [
    DesgloseIva(
      codimpuesto: 'IVA10',
      ivaBp: 1000,
      baseCents: 5992,
      cuotaCents: 708,
    ),
  ],
);

const linea = LineaPrecuenta(
  descripcion: 'Caña',
  cantidad: 4,
  pvpUnitarioCents: 200,
  importeCents: 800,
  ivaBp: 1000,
  codimpuesto: 'IVA10',
  referencia: 'CANA',
);

PrecuentaEmitida precuenta({
  int numero = 2,
  int? comensales = 4,
  String? emitidaPor = 'Caja 1',
}) => PrecuentaEmitida(
  numero: numero,
  emitidaEn: emitida,
  comandaId: 'c-7f3a',
  nombreMesa: 'Mesa 7',
  lineas: const [linea],
  totales: totales,
  comensales: comensales,
  emitidaPor: emitidaPor,
);

void main() {
  group('LineaPrecuenta', () {
    test('desde copia los datos imprimibles de la línea de comanda', () {
      final origen = LineaComanda(
        id: 'l1',
        referencia: 'CANA',
        descripcion: 'Caña',
        cantidad: 4,
        pvpUnitarioCents: 200,
        pvpUnitarioNeto: 1.81818,
        ivaBp: 1000,
        codimpuesto: 'IVA10',
        nota: 'sin espuma',
        camarero: 'Ana',
        creadaEn: emitida,
        pase: 2,
        envio: 12,
      );
      expect(
        LineaPrecuenta.desde(origen),
        const LineaPrecuenta(
          descripcion: 'Caña',
          cantidad: 4,
          pvpUnitarioCents: 200,
          importeCents: 800,
          ivaBp: 1000,
          codimpuesto: 'IVA10',
          referencia: 'CANA',
          nota: 'sin espuma',
        ),
      );
    });

    test('ida y vuelta JSON con y sin opcionales', () {
      expect(linea.toJson().keys, [
        'descripcion',
        'cantidad',
        'pvpUnitarioCents',
        'importeCents',
        'ivaBp',
        'codimpuesto',
        'referencia',
      ]);
      expect(roundTrip(linea.toJson(), LineaPrecuenta.fromJson), linea);

      const minima = LineaPrecuenta(
        descripcion: 'Pan',
        cantidad: 1,
        pvpUnitarioCents: 100,
        importeCents: 100,
        ivaBp: 1000,
      );
      final json = minima.toJson();
      expect(json.keys, [
        'descripcion',
        'cantidad',
        'pvpUnitarioCents',
        'importeCents',
        'ivaBp',
      ]);
      expect(roundTrip(json, LineaPrecuenta.fromJson), minima);
    });

    test('sin un campo obligatorio o con otro tipo lanza FormatException', () {
      expect(
        () => LineaPrecuenta.fromJson({'descripcion': 'Pan'}),
        throwsFormatException,
      );
      expect(
        () => LineaPrecuenta.fromJson({...linea.toJson(), 'cantidad': 'x'}),
        throwsFormatException,
      );
    });
  });

  group('PrecuentaEmitida', () {
    test('ida y vuelta JSON, orden de claves y omisión de opcionales', () {
      final completa = precuenta();
      final json = completa.toJson();
      expect(json.keys, [
        'numero',
        'emitidaEn',
        'comandaId',
        'nombreMesa',
        'lineas',
        'totales',
        'comensales',
        'emitidaPor',
      ]);
      expect(json['totales'], totales.toJson());
      expect(roundTrip(json, PrecuentaEmitida.fromJson), completa);

      final minima = precuenta(comensales: null, emitidaPor: null);
      expect(minima.toJson().containsKey('comensales'), isFalse);
      expect(minima.toJson().containsKey('emitidaPor'), isFalse);
      expect(roundTrip(minima.toJson(), PrecuentaEmitida.fromJson), minima);
    });

    test('totalCents sale de los totales y las líneas son inmutables', () {
      expect(precuenta().totalCents, 6700);
      expect(() => precuenta().lineas.add(linea), throwsUnsupportedError);
    });

    test('una línea ilegible se descarta sin invalidar la precuenta', () {
      final json = precuenta().toJson();
      final leida = PrecuentaEmitida.fromJson(
        viaJson({
          ...json,
          'lineas': [
            linea.toJson(),
            {'descripcion': 'rota'},
            'x',
            {...linea.toJson(), 'descripcion': 'Pan'},
          ],
        }),
      );
      expect(leida.lineas.map((l) => l.descripcion), ['Caña', 'Pan']);
      expect(leida.totalCents, 6700);
      expect(PrecuentaEmitida.fromJson(sin(json, 'lineas')).lineas, isEmpty);
    });

    test('un campo propio ausente o inválido lanza FormatException', () {
      final json = precuenta().toJson();
      expect(
        () => PrecuentaEmitida.fromJson(sin(json, 'totales')),
        throwsFormatException,
      );
      expect(
        () => PrecuentaEmitida.fromJson(sin(json, 'nombreMesa')),
        throwsFormatException,
      );
      expect(
        () => PrecuentaEmitida.fromJson({...json, 'numero': 0}),
        throwsFormatException,
      );
      expect(
        () => PrecuentaEmitida.fromJson({...json, 'emitidaEn': 'ayer'}),
        throwsFormatException,
      );
    });
  });

  group('PrecuentaSinCobro', () {
    final vaciada = DateTime(2026, 10, 9, 23, 5);

    test('ida y vuelta JSON con y sin motivo', () {
      final conMotivo = PrecuentaSinCobro(
        precuenta: precuenta(),
        vaciadaEn: vaciada,
        motivo: 'Mesa vaciada en el TPV',
      );
      expect(conMotivo.toJson().keys, ['precuenta', 'vaciadaEn', 'motivo']);
      expect(
        roundTrip(conMotivo.toJson(), PrecuentaSinCobro.fromJson),
        conMotivo,
      );

      final sinMotivo = PrecuentaSinCobro(
        precuenta: precuenta(),
        vaciadaEn: vaciada,
      );
      expect(sinMotivo.toJson().containsKey('motivo'), isFalse);
      expect(
        roundTrip(sinMotivo.toJson(), PrecuentaSinCobro.fromJson),
        sinMotivo,
      );
    });

    test('sin precuenta o con fecha inválida lanza FormatException', () {
      expect(
        () => PrecuentaSinCobro.fromJson({
          'vaciadaEn': vaciada.toIso8601String(),
        }),
        throwsFormatException,
      );
      expect(
        () => PrecuentaSinCobro.fromJson({
          'precuenta': precuenta().toJson(),
          'vaciadaEn': 'ayer',
        }),
        throwsFormatException,
      );
    });
  });
}
