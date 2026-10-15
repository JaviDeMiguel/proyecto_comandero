import 'package:proyecto_comandero/core/errors/app_exception.dart';
import 'package:proyecto_comandero/features/host/application/sala_effects.dart';
import 'package:proyecto_comandero/features/sala/domain/comanda.dart';
import 'package:proyecto_comandero/features/sala/domain/linea_comanda.dart';
import 'package:proyecto_comandero/features/sala/domain/mesa.dart';
import 'package:proyecto_comandero/features/sala/protocol/sala_messages.dart';
import 'package:test/test.dart';

import 'support/host_test_support.dart';

/// Receptor que anota las líneas aceptadas (ya estampadas con su envío).
final class _Aceptadas extends SalaEffects {
  final List<List<LineaComanda>> lotes = [];

  @override
  Future<void> onLineasAceptadas(
    Mesa mesa,
    Comanda comanda,
    List<LineaComanda> nuevas,
  ) async => lotes.add(nuevas);
}

/// Deja que los eventos de los streams (asíncronos) lleguen a sus oyentes.
Future<void> pump() => Future<void>.delayed(Duration.zero);

void main() {
  late SalaFixture f;
  late _Aceptadas effects;
  late List<SalaChangedEvent> eventos;

  setUp(() async {
    f = await SalaFixture.create();
    effects = _Aceptadas();
    f.sala.addEffects(effects);
    eventos = [];
    f.sala.changes.listen(eventos.add);
  });

  tearDown(() => f.dispose());

  List<int?> envios(Comanda comanda) => [
    for (final l in comanda.lineas) l.envio,
  ];

  group('nº de envío', () {
    test('los envíos se numeran 1, 2, 3 y cada línea nueva lleva el suyo, '
        'también en el efecto', () async {
      final primero = await f.sala.aceptarLineas(
        submit('m1', [linea('l1', 'CANA', 2), linea('l2', 'CAFE', 1)]),
      );
      final otraMesa = await f.sala.aceptarLineas(
        submit('m2', [linea('l3', 'AGUA', 1)]),
      );
      final tercero = await f.sala.aceptarLineas(
        submit('m1', [linea('l4', 'PAELLA', 1)]),
      );
      await f.sala.idle();

      expect(envios(primero.comanda), [1, 1]);
      expect(envios(otraMesa.comanda), [2]);
      expect(envios(tercero.comanda), [1, 1, 3]);
      expect(f.store.snapshot.numeroEnvioSiguiente, 4);
      expect(tercero.comanda.bloquesDeEnvio.map((b) => b.envio), [
        1,
        3,
      ], reason: 'dos envíos de la mesa');
      expect(tercero.comanda.lineasUltimoEnvio.single.id, 'l4');
      expect(
        [for (final lote in effects.lotes) lote.map((l) => l.envio).toList()],
        [
          [1, 1],
          [2],
          [3],
        ],
      );
    });

    test('una retransmisión y un envío vacío no consumen número', () async {
      final abierta = await f.sala.aceptarLineas(
        submit('m1', [linea('l1', 'CANA', 2)]),
      );
      await f.sala.idle();
      final guardadas = f.repo.saves;

      // Retransmisión de líneas ya conocidas: ni número ni escritura.
      final repetido = await f.sala.aceptarLineas(
        submit('m1', [linea('l1', 'CANA', 2)]),
      );
      expect(repetido.lineasNuevas, 0);
      expect(repetido.lineasDuplicadas, 1);
      expect(repetido.comanda, abierta.comanda);
      expect(f.store.snapshot.numeroEnvioSiguiente, 2);
      expect(f.repo.saves, guardadas, reason: 'sin cambios no se escribe');

      // Envío vacío con comensales para la comanda abierta: se aplica, se
      // guarda y se emite, pero no avanza el nº de envío ni hay efecto.
      final comensales = await f.sala.aceptarLineas(
        submit('m1', const [], comensales: 3, comandaId: abierta.comanda.id),
      );
      await f.sala.idle();
      await pump();
      expect(comensales.lineasNuevas, 0);
      expect(comensales.lineasDuplicadas, 0);
      expect(comensales.comanda.comensales, 3);
      expect(comensales.comanda.lineas.map((l) => l.id), ['l1']);
      expect(f.sala.comandaDeMesa('m1')!.comensales, 3);
      expect(f.store.snapshot.numeroEnvioSiguiente, 2);
      expect(eventos.last.comanda!.comensales, 3);
      expect(effects.lotes, hasLength(1), reason: 'nada que imprimir');

      // Un host antiguo recibía los comensales sin comandaId: sigue valiendo.
      final sinId = await f.sala.aceptarLineas(
        submit('m1', const [], comensales: 4),
      );
      expect(sinId.comanda.comensales, 4);

      // Y el siguiente envío con líneas sigue la numeración.
      final siguiente = await f.sala.aceptarLineas(
        submit('m1', [linea('l2', 'CAFE', 1)]),
      );
      expect(siguiente.comanda.lineaPorId('l2')!.envio, 2);
    });

    test('el número se guarda en la misma escritura que las líneas y '
        'sobrevive a recargar el diario', () async {
      final guardadas = f.repo.saves;
      final result = await f.sala.aceptarLineas(
        submit('m1', [linea('l1', 'CANA', 2)]),
      );
      await f.store.flush();
      expect(f.repo.saves, guardadas + 1, reason: 'una única escritura');

      final guardado = (await f.repo.load())!;
      expect(guardado.numeroEnvioSiguiente, 2);
      expect(guardado.comandaDeMesa('m1'), result.comanda);
      expect(guardado.comandaDeMesa('m1')!.lineas.single.envio, 1);

      // Reinicio del host sobre el mismo diario: el contador continúa.
      final g = await SalaFixture.create(repo: f.repo);
      addTearDown(g.dispose);
      final tras = await g.sala.aceptarLineas(
        submit('m2', [linea('l2', 'AGUA', 1)]),
      );
      expect(tras.comanda.lineas.single.envio, 2);
      expect(g.store.snapshot.numeroEnvioSiguiente, 3);
    });

    test('un envío que llega del cliente con nº de envío lo pierde: lo pone '
        'el host', () async {
      final delCliente = linea('l1', 'CANA', 1).copyWith(envio: 99);
      final result = await f.sala.aceptarLineas(submit('m1', [delCliente]));
      expect(result.comanda.lineas.single.envio, 1);
    });
  });

  group('envío vacío (solo comensales)', () {
    test('en una mesa libre no la abre ni escribe nada', () async {
      final guardadas = f.repo.saves;
      final result = await f.sala.aceptarLineas(
        submit('m1', const [], comensales: 2, camarero: 'Ana'),
      );
      await f.sala.idle();
      await pump();

      expect(result.lineasNuevas, 0);
      expect(result.lineasDuplicadas, 0);
      expect(result.comanda.mesaId, 'm1');
      expect(result.comanda.lineas, isEmpty);
      expect(result.comanda.comensales, 2);
      expect(result.comanda.camarero, 'Ana');
      expect(f.sala.comandaDeMesa('m1'), isNull, reason: 'no se abre');
      expect(f.repo.saves, guardadas);
      expect(f.store.snapshot.numeroEnvioSiguiente, 1);
      expect(eventos, isEmpty);
      expect(effects.lotes, isEmpty);
    });

    test('con un comandaId distinto del de la comanda abierta no cambia '
        'nada', () async {
      final abierta = await f.sala.aceptarLineas(
        submit('m1', [linea('l1', 'CANA', 2)]),
      );
      await f.sala.idle();
      final guardadas = f.repo.saves;
      final eventosAntes = eventos.length;

      final result = await f.sala.aceptarLineas(
        submit('m1', const [], comensales: 6, comandaId: 'c-anterior'),
      );
      await pump();
      expect(result.comanda, abierta.comanda);
      expect(result.comanda.comensales, isNull);
      expect(f.sala.comandaDeMesa('m1'), abierta.comanda);
      expect(f.repo.saves, guardadas, reason: 'no se escribe');
      expect(eventos, hasLength(eventosAntes), reason: 'no se emite');
    });

    test('mesa desconocida', () {
      expect(
        () => f.sala.aceptarLineas(submit('nope', const [], comensales: 2)),
        throwsA(
          isA<RemoteRequestException>().having(
            (e) => e.code,
            'code',
            SalaErrorCodes.mesaDesconocida,
          ),
        ),
      );
    });
  });

  group('comensales fuera de rango (el TCP es un borde)', () {
    test('con 0 o 100 las líneas se aceptan y los comensales no '
        'cambian', () async {
      // Mesa libre: se abre con las líneas y sin comensales.
      final nueva = await f.sala.aceptarLineas(
        submit('m1', [linea('l1', 'CANA', 1)], comensales: 0),
      );
      expect(nueva.lineasNuevas, 1);
      expect(nueva.comanda.comensales, isNull);

      // Mesa abierta con comensales: conserva los que tenía.
      await f.sala.aceptarLineas(
        submit('m2', [linea('l2', 'CAFE', 1)], comensales: 2),
      );
      final cien = await f.sala.aceptarLineas(
        submit('m2', [linea('l3', 'AGUA', 1)], comensales: 100),
      );
      expect(cien.lineasNuevas, 1);
      expect(cien.comanda.comensales, 2);
      final cero = await f.sala.aceptarLineas(
        submit('m2', [linea('l4', 'PAELLA', 1)], comensales: 0),
      );
      expect(cero.lineasNuevas, 1);
      expect(cero.comanda.comensales, 2);
      expect(cero.comanda.lineas.map((l) => l.id), ['l2', 'l3', 'l4']);
      expect((await f.repo.load())!.comandaDeMesa('m2'), cero.comanda);
    });

    test('con 4 se aplican, y también en los límites 1 y 99', () async {
      final cuatro = await f.sala.aceptarLineas(
        submit('m1', [linea('l1', 'CANA', 1)], comensales: 4),
      );
      expect(cuatro.comanda.comensales, 4);
      final maximo = await f.sala.aceptarLineas(
        submit('m1', [linea('l2', 'CAFE', 1)], comensales: 99),
      );
      expect(maximo.comanda.comensales, 99);
      final minimo = await f.sala.aceptarLineas(
        submit('m1', [linea('l3', 'AGUA', 1)], comensales: 1),
      );
      expect(minimo.lineasNuevas, 1);
      expect(minimo.comanda.comensales, 1);
      expect(f.sala.comandaDeMesa('m1')!.comensales, 1);
    });

    test('un envío vacío con 0 no cambia los comensales de la mesa', () async {
      final abierta = await f.sala.aceptarLineas(
        submit('m1', [linea('l1', 'CANA', 2)], comensales: 3),
      );
      await f.sala.idle();
      await pump();
      final guardadas = f.repo.saves;
      final eventosAntes = eventos.length;

      final result = await f.sala.aceptarLineas(
        submit('m1', const [], comensales: 0, comandaId: abierta.comanda.id),
      );
      await pump();
      expect(result.lineasNuevas, 0);
      expect(result.comanda, abierta.comanda);
      expect(f.sala.comandaDeMesa('m1')!.comensales, 3);
      expect(f.repo.saves, guardadas, reason: 'no se escribe');
      expect(eventos, hasLength(eventosAntes), reason: 'no se emite');

      // En una mesa libre tampoco vuelven en la comanda de la respuesta.
      final libre = await f.sala.aceptarLineas(
        submit('m2', const [], comensales: 0),
      );
      expect(libre.comanda.comensales, isNull);
      expect(f.sala.comandaDeMesa('m2'), isNull);
    });
  });

  group('normalización de la línea', () {
    test('regresión: un precio corregido con el catálogo conserva pase, '
        'camarero, nota y recibe el envío del host', () async {
      final buena = linea('l1', 'AGUA', 1, nota: 'sin gas', pase: 2);
      final manipulada = LineaComanda(
        id: 'l1',
        referencia: 'AGUA',
        descripcion: buena.descripcion,
        cantidad: 1,
        pvpUnitarioCents: 50,
        pvpUnitarioNeto: 0.45455,
        ivaBp: 1000,
        codimpuesto: 'IVA10',
        nota: 'sin gas',
        camarero: 'Ana',
        creadaEn: buena.creadaEn,
        pase: 2,
        envio: 7,
      );
      final result = await f.sala.aceptarLineas(
        submit('m1', [manipulada], camarero: 'Luis'),
      );
      final aceptada = result.comanda.lineas.single;
      expect(aceptada.pvpUnitarioCents, buena.pvpUnitarioCents);
      expect(aceptada.pvpUnitarioNeto, buena.pvpUnitarioNeto);
      expect(aceptada.ivaBp, 2100);
      expect(aceptada.codimpuesto, 'IVA21');
      expect(aceptada.pase, 2);
      expect(aceptada.camarero, 'Ana', reason: 'el de la línea manda');
      expect(aceptada.nota, 'sin gas');
      expect(aceptada.envio, 1, reason: 'el del host, no el del cliente');
      expect(aceptada.creadaEn, buena.creadaEn);
      expect(aceptada.estado, EstadoLinea.enviada);
      expect(
        f.alerts.recientes.map((a) => a.titulo),
        contains(contains('Precios corregidos')),
      );
    });

    test('una línea que llega anulada se acepta como enviada', () async {
      final anulada = linea(
        'l1',
        'CANA',
        1,
      ).anular(cuando: f.clock.now, motivo: 'x');
      final result = await f.sala.aceptarLineas(submit('m1', [anulada]));
      final aceptada = result.comanda.lineas.single;
      expect(aceptada.estado, EstadoLinea.enviada);
      expect(aceptada.anulada, isFalse);
    });
  });

  group('camarero', () {
    test('la comanda conserva al primer camarero y cada línea lleva el de '
        'su envío', () async {
      final primero = await f.sala.aceptarLineas(
        submit('m1', [linea('l1', 'CANA', 1)], camarero: 'Ana'),
      );
      expect(primero.comanda.camarero, 'Ana');
      expect(primero.comanda.lineas.single.camarero, 'Ana');

      final segundo = await f.sala.aceptarLineas(
        submit('m1', [
          linea('l2', 'CAFE', 1),
          linea('l3', 'AGUA', 1).copyWith(camarero: 'Eva'),
        ], camarero: 'Luis'),
      );
      expect(segundo.comanda.camarero, 'Ana', reason: 'el primero se queda');
      expect(segundo.comanda.lineaPorId('l2')!.camarero, 'Luis');
      expect(
        segundo.comanda.lineaPorId('l3')!.camarero,
        'Eva',
        reason: 'la línea trae el suyo',
      );
      // Persistido tal cual.
      expect((await f.repo.load())!.comandaDeMesa('m1'), segundo.comanda);
    });

    test('una mesa abierta sin camarero lo toma del primer envío que lo '
        'traiga', () async {
      await f.sala.aceptarLineas(submit('m1', [linea('l1', 'CANA', 1)]));
      final con = await f.sala.aceptarLineas(
        submit('m1', [linea('l2', 'CAFE', 1)], camarero: 'Ana'),
      );
      expect(con.comanda.camarero, 'Ana');
      expect(con.comanda.lineaPorId('l1')!.camarero, isNull);
      expect(con.comanda.lineaPorId('l2')!.camarero, 'Ana');
    });
  });
}
