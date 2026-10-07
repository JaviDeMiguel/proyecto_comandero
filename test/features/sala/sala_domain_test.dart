import 'dart:convert';

import 'package:proyecto_comandero/features/sala/domain/comanda.dart';
import 'package:proyecto_comandero/features/sala/domain/linea_comanda.dart';
import 'package:proyecto_comandero/features/sala/domain/mesa.dart';
import 'package:proyecto_comandero/features/sala/domain/ticket.dart';
import 'package:proyecto_comandero/features/sala/protocol/sala_messages.dart';
import 'package:test/test.dart';

final creada = DateTime(2026, 10, 6, 14, 5, 9);

LineaComanda linea(String id, {double cantidad = 1, int pvp = 250}) =>
    LineaComanda(
      id: id,
      referencia: 'CANA',
      descripcion: 'Caña',
      cantidad: cantidad,
      pvpUnitarioCents: pvp,
      pvpUnitarioNeto: 2.27273,
      ivaBp: 1000,
      codimpuesto: 'IVA10',
      nota: id == 'l2' ? 'sin espuma\n"doble"' : null,
      camarero: 'Ana',
      creadaEn: creada,
    );

/// Serializa y vuelve a leer pasando por texto JSON, como en el cable.
T roundTrip<T>(
  Map<String, Object?> json,
  T Function(Map<String, Object?>) read,
) => read(jsonDecode(jsonEncode(json)) as Map<String, Object?>);

void main() {
  group('Mesa', () {
    test('ida y vuelta JSON con y sin opcionales', () {
      const completa = Mesa(
        id: 'm1',
        nombre: 'Terraza 1',
        zona: 'Terraza',
        orden: 3,
        comensales: 4,
      );
      expect(roundTrip(completa.toJson(), Mesa.fromJson), completa);
      const minima = Mesa(id: 'm2', nombre: 'Barra');
      expect(roundTrip(minima.toJson(), Mesa.fromJson), minima);
      expect(minima.toJson().containsKey('comensales'), isFalse);
    });
  });

  group('LineaComanda', () {
    test('importe y anulación', () {
      final l = linea('l1', cantidad: 3, pvp: 95);
      expect(l.importeCents, 285);
      expect(l.anulada, isFalse);
      final anulada = l.anular(cuando: creada, motivo: 'error');
      expect(anulada.anulada, isTrue);
      expect(anulada.importeCents, 0);
      expect(anulada.motivoAnulacion, 'error');
      expect(anulada.anular(cuando: DateTime(2030)), same(anulada));
    });

    test('ida y vuelta JSON conserva notas con saltos de línea y comillas', () {
      final l = linea('l2', cantidad: 0.5);
      final leida = roundTrip(l.toJson(), LineaComanda.fromJson);
      expect(leida, l);
      expect(leida.nota, 'sin espuma\n"doble"');
      expect(leida.creadaEn, creada);
    });

    test('estados y destinos desconocidos se rechazan', () {
      expect(() => EstadoLinea.parse('x'), throwsFormatException);
      expect(() => DestinoPreparacion.parse('x'), throwsFormatException);
      expect(EstadoLinea.parse('anulada'), EstadoLinea.anulada);
    });
  });

  group('Comanda', () {
    test('conLineas es idempotente por id', () {
      final comanda = Comanda(id: 'c1', mesaId: 'm1', abiertaEn: creada);
      final primera = comanda.conLineas([linea('l1'), linea('l2')]);
      expect(primera.nuevas, hasLength(2));
      expect(primera.comanda.lineas, hasLength(2));

      final repetida = primera.comanda.conLineas([linea('l2'), linea('l3')]);
      expect(repetida.nuevas.map((l) => l.id), ['l3']);
      expect(repetida.comanda.lineas.map((l) => l.id), ['l1', 'l2', 'l3']);

      final nada = repetida.comanda.conLineas([linea('l1')]);
      expect(nada.nuevas, isEmpty);
      expect(nada.comanda, same(repetida.comanda));
    });

    test('importe, líneas activas y actualización de línea', () {
      final comanda = Comanda(
        id: 'c1',
        mesaId: 'm1',
        abiertaEn: creada,
        lineas: [linea('l1', cantidad: 2), linea('l2', cantidad: 1)],
      );
      expect(comanda.importeCents, 750);
      final anulada = comanda.conLineaActualizada(
        comanda.lineaPorId('l2')!.anular(cuando: creada),
      );
      expect(anulada.importeCents, 500);
      expect(anulada.lineasActivas.map((l) => l.id), ['l1']);
      expect(anulada.lineas, hasLength(2));
      expect(anulada.estaVacia, isFalse);
      expect(comanda.lineaPorId('nope'), isNull);
    });

    test('ida y vuelta JSON', () {
      final comanda = Comanda(
        id: 'c1',
        mesaId: 'm1',
        abiertaEn: creada,
        lineas: [linea('l1'), linea('l2')],
        camarero: 'Ana',
        comensales: 2,
        cuentaSolicitada: true,
        observaciones: 'alérgico a frutos secos',
      );
      expect(roundTrip(comanda.toJson(), Comanda.fromJson), comanda);
    });
  });

  group('Ticket', () {
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

    Ticket ticket({int? entregado, FacturaSincronizada? factura}) => Ticket(
      id: '7c9e6679-7425-40de-944b-e07fc1f90ae7',
      numeroLocal: 12,
      mesaId: 'm1',
      nombreMesa: 'Terraza 1',
      comandaId: 'c1',
      fechaHora: creada,
      lineas: [linea('l1', cantidad: 2)],
      totales: totales,
      metodoPago: MetodoPago.efectivo,
      entregadoCents: entregado,
      camarero: 'Ana',
      factura: factura,
    );

    test('cambio y clave de factura', () {
      expect(ticket(entregado: 1000).cambioCents, 500);
      expect(ticket(entregado: 500).cambioCents, 0);
      expect(ticket(entregado: 400).cambioCents, 0);
      expect(ticket().cambioCents, 0);
      final clave = ticket().claveFactura;
      expect(clave, 'TPV-7c9e6679-7425-40de-944b-e07fc1f90ae7');
      expect(clave.length, lessThanOrEqualTo(50));
      expect(RegExp(r'^\d{1,2}-\d{1,2}-\d{4}').hasMatch(clave), isFalse);
    });

    test('ida y vuelta JSON con factura sincronizada', () {
      final t = ticket(
        entregado: 1000,
        factura: FacturaSincronizada(
          estado: EstadoSincronizacion.sincronizado,
          idfactura: 57,
          codigo: 'F2026S12',
          numero: 12,
          idasiento: 101,
          pagada: true,
          emitida: true,
          avisos: const ['Total FS 5,01 € ≠ TPV 5,00 €'],
          actualizadoEn: creada,
        ),
      );
      final leido = roundTrip(t.toJson(), Ticket.fromJson);
      expect(leido, t);
      expect(leido.factura!.codigo, 'F2026S12');
      final pendiente = ticket().conFactura(
        FacturaSincronizada(estado: EstadoSincronizacion.pendiente),
      );
      expect(roundTrip(pendiente.toJson(), Ticket.fromJson), pendiente);
      expect(() => MetodoPago.parse('bizum'), throwsFormatException);
    });
  });

  group('mensajes de sala', () {
    test('snapshot, submit, anular, cuenta y eventos viajan por JSON', () {
      final comanda = Comanda(
        id: 'c1',
        mesaId: 'm1',
        abiertaEn: creada,
        lineas: [linea('l1')],
      );
      final snapshot = SalaSnapshot(
        mesas: const [Mesa(id: 'm1', nombre: 'Terraza 1')],
        comandas: [comanda],
        catalogoVersion: 'v3',
        generadoEn: creada,
      );
      expect(roundTrip(snapshot.toJson(), SalaSnapshot.fromJson), snapshot);
      expect(snapshot.comandaDeMesa('m1'), comanda);
      expect(snapshot.comandaDeMesa('m9'), isNull);

      final submit = ComandaSubmitPayload(
        mesaId: 'm1',
        lineas: [linea('l1'), linea('l2')],
        camarero: 'Ana',
        comensales: 3,
      );
      expect(roundTrip(submit.toJson(), ComandaSubmitPayload.fromJson), submit);

      final result = ComandaSubmitResult(
        comanda: comanda,
        lineasNuevas: 1,
        lineasDuplicadas: 1,
      );
      expect(roundTrip(result.toJson(), ComandaSubmitResult.fromJson), result);

      const anular = LineaAnularPayload(
        mesaId: 'm1',
        lineaId: 'l1',
        motivo: 'cambio',
      );
      expect(roundTrip(anular.toJson(), LineaAnularPayload.fromJson), anular);

      const cuenta = MesaCuentaPayload(mesaId: 'm1', solicitada: true);
      expect(roundTrip(cuenta.toJson(), MesaCuentaPayload.fromJson), cuenta);

      final cambio = SalaChangedEvent(mesaId: 'm1', comanda: comanda);
      expect(roundTrip(cambio.toJson(), SalaChangedEvent.fromJson), cambio);
      const libre = SalaChangedEvent(mesaId: 'm1');
      expect(roundTrip(libre.toJson(), SalaChangedEvent.fromJson), libre);

      const catalogo = CatalogoChangedEvent(version: 'v4');
      expect(
        roundTrip(catalogo.toJson(), CatalogoChangedEvent.fromJson),
        catalogo,
      );
      final comandaResult = ComandaResult(comanda: comanda);
      expect(
        roundTrip(comandaResult.toJson(), ComandaResult.fromJson),
        comandaResult,
      );
    });
  });
}
