import 'dart:convert';
import 'dart:io';

import 'package:proyecto_comandero/features/sala/domain/comanda.dart';
import 'package:proyecto_comandero/features/sala/domain/linea_comanda.dart';
import 'package:proyecto_comandero/features/sala/domain/marcha_pase.dart';
import 'package:proyecto_comandero/features/sala/domain/mesa.dart';
import 'package:proyecto_comandero/features/sala/domain/precuenta_emitida.dart';
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
) => read(viaJson(json));

Map<String, Object?> viaJson(Map<String, Object?> json) =>
    jsonDecode(jsonEncode(json)) as Map<String, Object?>;

MarchaPase marcha(
  String id,
  int pase, {
  int minuto = 0,
  bool automatica = false,
  bool repetida = false,
}) => MarchaPase(
  id: id,
  pase: pase,
  cuando: creada.add(Duration(minutes: minuto)),
  camarero: 'Ana',
  automatica: automatica,
  repetida: repetida,
);

PrecuentaEmitida precuenta(int numero) => PrecuentaEmitida(
  numero: numero,
  emitidaEn: creada,
  comandaId: 'c1',
  nombreMesa: 'Terraza 1',
  lineas: [LineaPrecuenta.desde(linea('l1'))],
  totales: TotalesTicket(netoCents: 227, ivaCents: 23, totalCents: 250),
  comensales: 2,
);

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

    test(
      'pase y envío: ida y vuelta, omisión si nulos y lectura tolerante',
      () {
        final directa = linea('l1');
        expect(directa.pase, isNull);
        expect(directa.envio, isNull);
        expect(directa.toJson().containsKey('pase'), isFalse);
        expect(directa.toJson().containsKey('envio'), isFalse);

        final conPase = directa.copyWith(pase: () => 2, envio: 12);
        final json = conPase.toJson();
        expect(json['pase'], 2);
        expect(json['envio'], 12);
        expect(json.keys.skip(json.length - 2), ['pase', 'envio']);
        expect(roundTrip(json, LineaComanda.fromJson), conPase);

        for (final raro in <Object?>['x', 0, -1, 2.5, true, null]) {
          final leida = LineaComanda.fromJson(
            viaJson({...json, 'pase': raro, 'envio': raro}),
          );
          expect(leida.pase, isNull, reason: 'pase $raro');
          expect(leida.envio, isNull, reason: 'envio $raro');
        }
      },
    );

    test('copyWith cubre todos los campos y puede volver a directa', () {
      final original = linea(
        'l2',
        cantidad: 2,
      ).copyWith(pase: () => 3, envio: 7);
      expect(original.copyWith(), original);

      final cambiada = original.copyWith(
        estado: EstadoLinea.servida,
        anuladaEn: creada,
        motivoAnulacion: 'm',
        nota: 'otra',
        cantidad: 5,
        destino: DestinoPreparacion.barra,
        pvpUnitarioCents: 300,
        pvpUnitarioNeto: 2.72727,
        ivaBp: 2100,
        codimpuesto: () => 'IVA21',
        camarero: 'Luis',
        pase: () => 1,
        envio: 9,
      );
      expect(cambiada.id, 'l2');
      expect(cambiada.referencia, 'CANA');
      expect(cambiada.descripcion, 'Caña');
      expect(cambiada.creadaEn, creada);
      expect(cambiada.estado, EstadoLinea.servida);
      expect(cambiada.anuladaEn, creada);
      expect(cambiada.motivoAnulacion, 'm');
      expect(cambiada.nota, 'otra');
      expect(cambiada.cantidad, 5);
      expect(cambiada.destino, DestinoPreparacion.barra);
      expect(cambiada.pvpUnitarioCents, 300);
      expect(cambiada.pvpUnitarioNeto, 2.72727);
      expect(cambiada.ivaBp, 2100);
      expect(cambiada.codimpuesto, 'IVA21');
      expect(cambiada.camarero, 'Luis');
      expect(cambiada.pase, 1);
      expect(cambiada.envio, 9);
      expect(cambiada.importeCents, 1500);

      final directa = cambiada.copyWith(
        pase: () => null,
        codimpuesto: () => null,
      );
      expect(directa.pase, isNull);
      expect(directa.codimpuesto, isNull);
      expect(directa.envio, 9);
      expect(directa.camarero, 'Luis');
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

  group('Comanda: marchas y precuentas', () {
    Comanda base() => Comanda(
      id: 'c1',
      mesaId: 'm1',
      abiertaEn: creada,
      lineas: [linea('l1')],
    );

    test('ida y vuelta JSON y omisión cuando están vacías', () {
      final vacia = base();
      expect(vacia.marchas, isEmpty);
      expect(vacia.precuentas, isEmpty);
      expect(vacia.toJson().containsKey('marchas'), isFalse);
      expect(vacia.toJson().containsKey('precuentas'), isFalse);
      expect(vacia.tieneMarchas, isFalse);
      expect(vacia.pasesMarchados, isEmpty);
      expect(vacia.siguienteNumeroPrecuenta, 1);

      final completa = vacia
          .conMarcha(marcha('a1', 1, automatica: true))
          .conMarcha(marcha('b2', 2, minuto: 30))
          .conPrecuenta(precuenta(1));
      final json = completa.toJson();
      expect(json.keys.skip(json.length - 2), ['marchas', 'precuentas']);
      expect(json['marchas'], [
        marcha('a1', 1, automatica: true).toJson(),
        marcha('b2', 2, minuto: 30).toJson(),
      ]);
      expect(roundTrip(json, Comanda.fromJson), completa);
      expect(completa.marchas.map((m) => m.id), ['a1', 'b2']);
      expect(completa.precuentas.single.numero, 1);
      expect(() => completa.marchas.clear(), throwsUnsupportedError);
      expect(() => completa.precuentas.clear(), throwsUnsupportedError);
    });

    test('MarchaPase: camarero, automatica y repetida solo si procede', () {
      final minima = MarchaPase(id: 'x', pase: 1, cuando: creada);
      expect(minima.toJson(), {
        'id': 'x',
        'pase': 1,
        'cuando': creada.toIso8601String(),
      });
      expect(roundTrip(minima.toJson(), MarchaPase.fromJson), minima);

      final completa = marcha('y', 2, automatica: true, repetida: true);
      expect(completa.toJson(), {
        'id': 'y',
        'pase': 2,
        'cuando': creada.toIso8601String(),
        'camarero': 'Ana',
        'automatica': true,
        'repetida': true,
      });
      expect(roundTrip(completa.toJson(), MarchaPase.fromJson), completa);

      expect(
        () => MarchaPase.fromJson({...minima.toJson(), 'pase': 0}),
        throwsFormatException,
      );
      expect(
        () => MarchaPase.fromJson({'id': 'z', 'pase': 1}),
        throwsFormatException,
      );
      expect(
        () => MarchaPase.fromJson({...minima.toJson(), 'automatica': 'sí'}),
        throwsFormatException,
      );
    });

    test('los elementos ilegibles de marchas y precuentas se descartan', () {
      final json = base()
          .conMarcha(marcha('a1', 1))
          .conPrecuenta(precuenta(1))
          .toJson();
      final leida = Comanda.fromJson(
        viaJson({
          ...json,
          'marchas': [
            ...json['marchas'] as List<Object?>,
            {'id': 'rota'},
            5,
            {...marcha('cero', 1).toJson(), 'pase': 0},
          ],
          'precuentas': [
            ...json['precuentas'] as List<Object?>,
            {'numero': 2},
            null,
          ],
        }),
      );
      expect(leida.marchas.map((m) => m.id), ['a1']);
      expect(leida.precuentas.map((p) => p.numero), [1]);

      final tiposRaros = Comanda.fromJson(
        viaJson({...json, 'marchas': 'x', 'precuentas': 3}),
      );
      expect(tiposRaros.tieneMarchas, isFalse);
      expect(tiposRaros.precuentas, isEmpty);
      expect(tiposRaros.lineas, hasLength(1));
    });

    test('pasesMarchados, marchaPorId, ultimaMarchaDe y nº de precuenta', () {
      final comanda = base()
          .conMarcha(marcha('a1', 1, automatica: true))
          .conMarcha(marcha('b2', 2, minuto: 30))
          .conMarcha(marcha('c2', 2, minuto: 45, repetida: true))
          .conPrecuenta(precuenta(1))
          .conPrecuenta(precuenta(2));
      expect(comanda.pasesMarchados, {1, 2});
      expect(comanda.tieneMarchas, isTrue);
      expect(comanda.marchaPorId('b2')!.pase, 2);
      expect(comanda.marchaPorId('nope'), isNull);
      expect(comanda.ultimaMarchaDe(2)!.id, 'c2');
      expect(comanda.ultimaMarchaDe(1)!.id, 'a1');
      expect(comanda.ultimaMarchaDe(3), isNull);
      expect(comanda.siguienteNumeroPrecuenta, 3);
    });

    test('copyWith conserva o sustituye marchas y precuentas', () {
      final comanda = base()
          .conMarcha(marcha('a1', 1))
          .conPrecuenta(precuenta(1));
      final mismas = comanda.copyWith(camarero: 'Luis');
      expect(mismas.marchas, comanda.marchas);
      expect(mismas.precuentas, comanda.precuentas);
      final otras = comanda.copyWith(marchas: const [], precuentas: const []);
      expect(otras.tieneMarchas, isFalse);
      expect(otras.precuentas, isEmpty);
      expect(otras.lineas, comanda.lineas);
    });
  });

  group('bloques de envío', () {
    test('tramos consecutivos de envio, con nulos y números repetidos', () {
      final comanda = Comanda(
        id: 'c1',
        mesaId: 'm1',
        abiertaEn: creada,
        lineas: [
          // Diario anterior al nº de envío: sin número.
          linea('l1'),
          linea('l2'),
          linea('l3').copyWith(envio: 12),
          linea('l4').copyWith(envio: 12).anular(cuando: creada),
          linea('l5').copyWith(envio: 15),
          // Tras un Cierre Z el contador vuelve a 12: es otro envío.
          linea('l6').copyWith(envio: 12),
        ],
      );
      final bloques = comanda.bloquesDeEnvio;
      expect(bloques.map((b) => b.envio), [null, 12, 15, 12]);
      expect(bloques.map((b) => b.lineas.map((l) => l.id).join(',')), [
        'l1,l2',
        'l3,l4',
        'l5',
        'l6',
      ]);
      expect(bloques[1].lineas[1].anulada, isTrue);
      expect(comanda.lineasUltimoEnvio.map((l) => l.id), ['l6']);
      expect(() => bloques[0].lineas.clear(), throwsUnsupportedError);
    });

    test('sin líneas no hay bloques', () {
      final vacia = Comanda(id: 'c1', mesaId: 'm1', abiertaEn: creada);
      expect(vacia.bloquesDeEnvio, isEmpty);
      expect(vacia.lineasUltimoEnvio, isEmpty);
    });

    test('el último bloque es el último envío, incluidas sus anuladas', () {
      final comanda = Comanda(
        id: 'c1',
        mesaId: 'm1',
        abiertaEn: creada,
        lineas: [linea('l1').copyWith(envio: 3)],
      );
      final ampliada = comanda.conLineas([
        linea('l2').copyWith(envio: 4),
        linea('l3').copyWith(envio: 4),
      ]).comanda;
      expect(ampliada.bloquesDeEnvio, hasLength(2));
      expect(ampliada.lineasUltimoEnvio.map((l) => l.id), ['l2', 'l3']);

      final anulada = ampliada.conLineaActualizada(
        ampliada.lineaPorId('l2')!.anular(cuando: creada),
      );
      expect(anulada.bloquesDeEnvio.map((b) => b.envio), [3, 4]);
      expect(anulada.lineasUltimoEnvio.map((l) => l.id), ['l2', 'l3']);
      expect(anulada.lineasUltimoEnvio.first.anulada, isTrue);
    });
  });

  group('agruparPorPase', () {
    test('directas primero y después pases ascendentes y estables', () {
      final lineas = [
        linea('l1').copyWith(pase: () => 2),
        linea('l2'),
        linea('l3').copyWith(pase: () => 1),
        // Fuera de la configuración habitual (3 pases): se conserva.
        linea('l4').copyWith(pase: () => 7),
        linea('l5').copyWith(pase: () => 2),
        linea('l6'),
      ];
      final grupos = agruparPorPase(lineas);
      expect(grupos.map((g) => g.pase), [null, 1, 2, 7]);
      expect(grupos.map((g) => g.lineas.map((l) => l.id).join(',')), [
        'l2,l6',
        'l3',
        'l1,l5',
        'l4',
      ]);
      expect(() => grupos[0].lineas.clear(), throwsUnsupportedError);
    });

    test('sin directas no hay grupo nulo y sin líneas no hay grupos', () {
      expect(agruparPorPase(const []), isEmpty);
      final soloPases = agruparPorPase([linea('l1').copyWith(pase: () => 3)]);
      expect(soloPases.map((g) => g.pase), [3]);
      expect(soloPases.single.lineas.single.id, 'l1');
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

  group('compatibilidad con el diario de la versión anterior', () {
    test('comanda_ticket_v1.json se lee y se reescribe byte a byte igual', () {
      // Fixture capturada del `toJson` anterior a los pases, marchas,
      // precuentas e impresión: una comanda con línea anulada y un ticket
      // con cobro mixto y factura sincronizada. Se normalizan los finales de
      // línea porque git (`core.autocrlf`) puede extraerla con CRLF.
      final texto = File('test/fixtures/compat/comanda_ticket_v1.json')
          .readAsStringSync()
          .replaceAll('\r\n', '\n');
      final json = jsonDecode(texto) as Map<String, Object?>;
      final comanda = Comanda.fromJson(json['comanda'] as Map<String, Object?>);
      final ticket = Ticket.fromJson(json['ticket'] as Map<String, Object?>);

      final reescrito = const JsonEncoder.withIndent('  ')
          .convert({'comanda': comanda.toJson(), 'ticket': ticket.toJson()});

      expect('$reescrito\n', texto);
      expect(comanda.lineas, hasLength(4));
      expect(comanda.lineaPorId('l4')!.anulada, isTrue);
      expect(ticket.esMixto, isTrue);
      expect(ticket.factura!.codigo, 'F2026S12');
    });
  });
}
