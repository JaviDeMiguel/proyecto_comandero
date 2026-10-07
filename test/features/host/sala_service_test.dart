import 'package:proyecto_comandero/core/errors/app_exception.dart';
import 'package:proyecto_comandero/features/host/application/sala_effects.dart';
import 'package:proyecto_comandero/features/sala/domain/comanda.dart';
import 'package:proyecto_comandero/features/sala/domain/enrutamiento_comandas.dart';
import 'package:proyecto_comandero/features/sala/domain/linea_comanda.dart';
import 'package:proyecto_comandero/features/sala/domain/mesa.dart';
import 'package:proyecto_comandero/features/sala/domain/ticket.dart';
import 'package:proyecto_comandero/features/sala/protocol/sala_messages.dart';
import 'package:test/test.dart';

import 'support/host_test_support.dart';

/// Receptor de efectos que anota lo que recibe.
final class RecordingEffects extends SalaEffects {
  final List<List<LineaComanda>> aceptadas = [];
  final List<LineaComanda> anuladas = [];
  final List<Ticket> cobradas = [];
  Object? falloEn;

  @override
  Future<void> onLineasAceptadas(
    Mesa mesa,
    Comanda comanda,
    List<LineaComanda> nuevas,
  ) async {
    if (falloEn == 'aceptadas') throw StateError('efecto roto');
    aceptadas.add(nuevas);
  }

  @override
  Future<void> onLineaAnulada(
    Mesa mesa,
    Comanda comanda,
    LineaComanda linea,
  ) async => anuladas.add(linea);

  @override
  Future<void> onMesaCobrada(Ticket ticket) async => cobradas.add(ticket);
}

/// Deja que los eventos de los streams (asíncronos) lleguen a sus oyentes.
Future<void> pump() => Future<void>.delayed(Duration.zero);

void main() {
  late SalaFixture f;
  late RecordingEffects effects;
  late List<SalaChangedEvent> eventos;

  setUp(() async {
    f = await SalaFixture.create();
    effects = RecordingEffects();
    f.sala.addEffects(effects);
    eventos = [];
    f.sala.changes.listen(eventos.add);
  });

  tearDown(() => f.dispose());

  group('aceptarLineas', () {
    test('abre la mesa, incorpora las líneas, emite evento y efecto', () async {
      final result = await f.sala.aceptarLineas(
        submit('m1', [linea('l1', 'CANA', 2), linea('l2', 'CAFE', 1)]),
      );
      await f.sala.idle();
      await pump();

      expect(result.lineasNuevas, 2);
      expect(result.lineasDuplicadas, 0);
      expect(result.comanda.mesaId, 'm1');
      expect(result.comanda.lineas.map((l) => l.id), ['l1', 'l2']);
      expect(f.sala.comandaDeMesa('m1'), result.comanda);
      expect(eventos.single.mesaId, 'm1');
      expect(eventos.single.comanda, result.comanda);
      expect(effects.aceptadas.single.map((l) => l.id), ['l1', 'l2']);
      // Persistido.
      final guardado = await f.repo.load();
      expect(guardado!.comandaDeMesa('m1'), result.comanda);
    });

    test('es idempotente por id de línea (retransmisión)', () async {
      await f.sala.aceptarLineas(submit('m1', [linea('l1', 'CANA', 2)]));
      final repetido = await f.sala.aceptarLineas(
        submit('m1', [linea('l1', 'CANA', 2), linea('l3', 'AGUA', 1)]),
      );
      await f.sala.idle();
      await pump();

      expect(repetido.lineasNuevas, 1);
      expect(repetido.lineasDuplicadas, 1);
      expect(repetido.comanda.lineas.length, 2);
      expect(effects.aceptadas.length, 2);
      expect(effects.aceptadas.last.single.id, 'l3');

      final sinNovedad = await f.sala.aceptarLineas(
        submit('m1', [linea('l1', 'CANA', 2)]),
      );
      expect(sinNovedad.lineasNuevas, 0);
      expect(sinNovedad.lineasDuplicadas, 1);
      await f.sala.idle();
      await pump();
      expect(
        effects.aceptadas.length,
        2,
        reason: 'sin efecto si no hay nuevas',
      );
    });

    test('rechaza mesa desconocida y artículo fuera de la carta', () async {
      expect(
        () => f.sala.aceptarLineas(submit('nope', [linea('l1', 'CANA', 1)])),
        throwsA(
          isA<RemoteRequestException>().having(
            (e) => e.code,
            'code',
            SalaErrorCodes.mesaDesconocida,
          ),
        ),
      );
      expect(
        () => f.sala.aceptarLineas(submit('m1', [linea('l1', 'VIEJO', 1)])),
        throwsA(
          isA<RemoteRequestException>().having(
            (e) => e.code,
            'code',
            SalaErrorCodes.articuloDesconocido,
          ),
        ),
      );
      final desconocida = linea('l1', 'CANA', 1);
      expect(
        () => f.sala.aceptarLineas(
          submit('m1', [
            LineaComanda(
              id: 'x',
              referencia: 'NOEXISTE',
              descripcion: 'Nada',
              cantidad: 1,
              pvpUnitarioCents: 100,
              pvpUnitarioNeto: 0.9,
              ivaBp: 1000,
              creadaEn: desconocida.creadaEn,
            ),
          ]),
        ),
        throwsA(isA<RemoteRequestException>()),
      );
      expect(f.sala.comandaDeMesa('m1'), isNull);
    });

    test('sin catálogo (sin ERP) acepta cualquier referencia', () async {
      final sinCatalogo = await SalaFixture.create(conCatalogo: false);
      addTearDown(sinCatalogo.dispose);
      final result = await sinCatalogo.sala.aceptarLineas(
        submit('m1', [linea('l1', 'VIEJO', 1)]),
      );
      expect(result.lineasNuevas, 1);
    });

    test('un efecto que falla no afecta a la respuesta', () async {
      effects.falloEn = 'aceptadas';
      final result = await f.sala.aceptarLineas(
        submit('m1', [linea('l1', 'CANA', 1)]),
      );
      await f.sala.idle();
      await pump();
      expect(result.lineasNuevas, 1);
      expect(f.alerts.recientes.single.titulo, contains('efecto'));
    });
  });

  group('anularLinea', () {
    test('marca la línea, emite evento y efecto; es idempotente', () async {
      await f.sala.aceptarLineas(submit('m1', [linea('l1', 'CANA', 2)]));
      final result = await f.sala.anularLinea('m1', 'l1', motivo: 'error');
      await f.sala.idle();
      await pump();

      final anulada = result.comanda.lineaPorId('l1')!;
      expect(anulada.anulada, isTrue);
      expect(anulada.motivoAnulacion, 'error');
      expect(anulada.anuladaEn, f.clock.now);
      expect(result.comanda.importeCents, 0);
      expect(effects.anuladas.single.id, 'l1');
      expect(eventos.last.comanda, result.comanda);

      final repetida = await f.sala.anularLinea('m1', 'l1');
      await f.sala.idle();
      await pump();
      expect(repetida.comanda, result.comanda);
      expect(effects.anuladas.length, 1);
    });

    test('línea o mesa inexistentes', () async {
      expect(
        () => f.sala.anularLinea('m1', 'l1'),
        throwsA(
          isA<RemoteRequestException>().having(
            (e) => e.code,
            'code',
            SalaErrorCodes.mesaSinComanda,
          ),
        ),
      );
      await f.sala.aceptarLineas(submit('m1', [linea('l1', 'CANA', 2)]));
      expect(
        () => f.sala.anularLinea('m1', 'zz'),
        throwsA(
          isA<RemoteRequestException>().having(
            (e) => e.code,
            'code',
            SalaErrorCodes.lineaDesconocida,
          ),
        ),
      );
    });
  });

  test('marcarCuenta cambia el flag y emite', () async {
    await f.sala.aceptarLineas(submit('m1', [linea('l1', 'CANA', 2)]));
    final result = await f.sala.marcarCuenta('m1', true);
    await pump();
    expect(result.comanda.cuentaSolicitada, isTrue);
    expect(eventos.last.comanda!.cuentaSolicitada, isTrue);
    final igual = await f.sala.marcarCuenta('m1', true);
    expect(igual.comanda, result.comanda);
  });

  group('cobrar', () {
    test('7 × 0.86364 al 10 % → 6,65; libera la mesa; numeración', () async {
      await f.sala.aceptarLineas(submit('m1', [linea('l1', 'CANA', 7)]));
      final ticket = await f.sala.cobrar(
        'm1',
        MetodoPago.efectivo,
        entregadoCents: 1000,
      );
      await f.sala.idle();
      await pump();

      expect(ticket.totales.netoCents, 605);
      expect(ticket.totales.ivaCents, 60);
      expect(ticket.totalCents, 665);
      expect(ticket.cambioCents, 335);
      expect(ticket.totales.desglose.single.codimpuesto, 'IVA10');
      expect(ticket.totales.desglose.single.ivaBp, 1000);
      expect(ticket.numeroLocal, 1);
      expect(ticket.nombreMesa, 'Mesa 1');
      expect(ticket.lineas.single.id, 'l1');
      expect(ticket.factura!.estado, EstadoSincronizacion.pendiente);
      expect(ticket.claveFactura.length, lessThanOrEqualTo(50));

      expect(f.sala.comandaDeMesa('m1'), isNull);
      expect(eventos.last, const SalaChangedEvent(mesaId: 'm1'));
      expect(effects.cobradas.single, ticket);
      expect(f.store.snapshot.ticketsTurno, [ticket]);
      expect(f.store.snapshot.numeroLocalSiguiente, 2);

      await f.sala.aceptarLineas(submit('m2', [linea('l2', 'AGUA', 1)]));
      final segundo = await f.sala.cobrar('m2', MetodoPago.tarjeta);
      expect(segundo.numeroLocal, 2);
      expect(segundo.totalCents, 100);
      expect(segundo.entregadoCents, isNull);
    });

    test('tres tipos de línea del briefing → 28,00 con dos grupos', () async {
      // 2×4.54545 @10; 3×1.36364 @10 → agrupan; 1×AGUA 12.39669 @21 sin dto.
      final l21 = LineaComanda(
        id: 'l21',
        referencia: 'AGUA',
        descripcion: 'Menú',
        cantidad: 1,
        pvpUnitarioCents: 1500,
        pvpUnitarioNeto: 12.39669,
        ivaBp: 2100,
        codimpuesto: 'IVA21',
        creadaEn: DateTime(2026, 10, 7, 13),
      );
      final l10a = LineaComanda(
        id: 'a',
        referencia: 'CANA',
        descripcion: 'A',
        cantidad: 2,
        pvpUnitarioCents: 500,
        pvpUnitarioNeto: 4.54545,
        ivaBp: 1000,
        codimpuesto: 'IVA10',
        creadaEn: DateTime(2026, 10, 7, 13),
      );
      final l10b = LineaComanda(
        id: 'b',
        referencia: 'CAFE',
        descripcion: 'B',
        cantidad: 3,
        pvpUnitarioCents: 150,
        pvpUnitarioNeto: 1.36364,
        ivaBp: 1000,
        codimpuesto: 'IVA10',
        creadaEn: DateTime(2026, 10, 7, 13),
      );
      // Sin catálogo: el host acepta los precios del comandero tal cual (con
      // catálogo los fijaría él, ver h15).
      final g = await SalaFixture.create(conCatalogo: false);
      addTearDown(g.dispose);
      await g.sala.aceptarLineas(submit('m1', [l10a, l21, l10b]));
      final ticket = await g.sala.cobrar('m1', MetodoPago.tarjeta);
      expect(ticket.totales.desglose.length, 2);
      expect(ticket.totales.netoCents, 1318 + 1240);
      expect(ticket.totalCents, 1450 + 1500);
    });

    test(
      'las líneas anuladas no se cobran; sin activas → comanda_cerrada',
      () async {
        await f.sala.aceptarLineas(
          submit('m1', [linea('l1', 'CANA', 1), linea('l2', 'CAFE', 1)]),
        );
        await f.sala.anularLinea('m1', 'l2');
        final ticket = await f.sala.cobrar('m1', MetodoPago.efectivo);
        expect(ticket.lineas.map((l) => l.id), ['l1']);
        expect(ticket.totalCents, 95);

        await f.sala.aceptarLineas(submit('m2', [linea('l3', 'CANA', 1)]));
        await f.sala.anularLinea('m2', 'l3');
        expect(
          () => f.sala.cobrar('m2', MetodoPago.efectivo),
          throwsA(
            isA<RemoteRequestException>().having(
              (e) => e.code,
              'code',
              SalaErrorCodes.comandaCerrada,
            ),
          ),
        );
      },
    );

    test('efectivo insuficiente → ValidationException', () async {
      await f.sala.aceptarLineas(submit('m1', [linea('l1', 'CANA', 7)]));
      expect(
        () => f.sala.cobrar('m1', MetodoPago.efectivo, entregadoCents: 600),
        throwsA(isA<ValidationException>()),
      );
      expect(f.sala.comandaDeMesa('m1'), isNotNull);
    });
  });

  group('cobrarMixto', () {
    test('reparte el total, calcula el cambio sobre el efectivo y libera la '
        'mesa', () async {
      await f.sala.aceptarLineas(submit('m1', [linea('l1', 'CANA', 7)]));
      final ticket = await f.sala.cobrarMixto(
        'm1',
        efectivoCents: 400,
        entregadoCents: 500,
      );
      await f.sala.idle();
      await pump();

      expect(ticket.totalCents, 665);
      expect(ticket.esMixto, isTrue);
      expect(ticket.pagos, const [
        PagoTicket(metodo: MetodoPago.efectivo, importeCents: 400),
        PagoTicket(metodo: MetodoPago.tarjeta, importeCents: 265),
      ]);
      expect(ticket.efectivoCents, 400);
      expect(ticket.tarjetaCents, 265);
      expect(ticket.metodoPago, MetodoPago.efectivo, reason: 'mayor importe');
      expect(ticket.entregadoCents, 500);
      expect(ticket.cambioCents, 100, reason: 'sobre la parte en efectivo');
      expect(ticket.numeroLocal, 1);
      expect(ticket.factura!.estado, EstadoSincronizacion.pendiente);

      expect(f.sala.comandaDeMesa('m1'), isNull);
      expect(eventos.last, const SalaChangedEvent(mesaId: 'm1'));
      expect(effects.cobradas.single, ticket);
      expect(f.store.snapshot.ticketsTurno, [ticket]);
      expect(f.store.snapshot.numeroLocalSiguiente, 2);
      // El reparto se guarda en el diario y se relee igual.
      final guardado = (await f.repo.load())!.ticketPorId(ticket.id)!;
      expect(guardado, ticket);
      expect(guardado.toJson()['pagos'], hasLength(2));
    });

    test('la forma de pago principal es la de mayor importe; en empate, el '
        'efectivo', () async {
      await f.sala.aceptarLineas(submit('m1', [linea('l1', 'CANA', 7)]));
      final masTarjeta = await f.sala.cobrarMixto('m1', efectivoCents: 100);
      expect(masTarjeta.metodoPago, MetodoPago.tarjeta);
      expect(masTarjeta.tarjetaCents, 565);
      expect(masTarjeta.entregadoCents, isNull);
      expect(masTarjeta.cambioCents, 0);

      // 2 cañas = 1,90 €: mitad y mitad.
      await f.sala.aceptarLineas(submit('m2', [linea('l2', 'CANA', 2)]));
      final empate = await f.sala.cobrarMixto('m2', efectivoCents: 95);
      expect(empate.tarjetaCents, 95);
      expect(empate.metodoPago, MetodoPago.efectivo);
      expect(empate.numeroLocal, 2);
    });

    test('rechaza repartos con una parte a cero o negativa sin tocar el '
        'diario', () async {
      await f.sala.aceptarLineas(submit('m1', [linea('l1', 'CANA', 7)]));
      final guardadas = f.repo.saves;
      for (final efectivo in [0, -5, 665, 700]) {
        await expectLater(
          f.sala.cobrarMixto('m1', efectivoCents: efectivo),
          throwsA(isA<ValidationException>()),
          reason: 'efectivo $efectivo de 665',
        );
      }
      expect(f.sala.comandaDeMesa('m1'), isNotNull);
      expect(f.store.snapshot.ticketsTurno, isEmpty);
      expect(f.store.snapshot.numeroLocalSiguiente, 1);
      expect(f.repo.saves, guardadas, reason: 'no se guarda nada');
    });

    test(
      'el entregado debe cubrir la parte en efectivo (no el total)',
      () async {
        await f.sala.aceptarLineas(submit('m1', [linea('l1', 'CANA', 7)]));
        await expectLater(
          f.sala.cobrarMixto('m1', efectivoCents: 400, entregadoCents: 399),
          throwsA(
            isA<ValidationException>().having(
              (e) => e.message,
              'message',
              contains('parte en efectivo'),
            ),
          ),
        );
        expect(f.sala.comandaDeMesa('m1'), isNotNull);
        // Entregar justo la parte en efectivo (menos que el total) sí vale.
        final ticket = await f.sala.cobrarMixto(
          'm1',
          efectivoCents: 400,
          entregadoCents: 400,
        );
        expect(ticket.cambioCents, 0);
      },
    );

    test('r1: si la cuenta cambia entre el diálogo y la confirmación no se '
        'cobra nada (mixto, tarjeta y efectivo)', () async {
      // El cajero ve 7 cañas = 6,65 € y reparte 4,00 + 2,65 con tarjeta.
      await f.sala.aceptarLineas(submit('m1', [linea('l1', 'CANA', 7)]));
      // Entre medias un comandero añade otra caña: el total pasa a 7,60 €.
      await f.sala.aceptarLineas(submit('m1', [linea('l2', 'CANA', 1)]));
      final guardadas = f.repo.saves;
      final cambio = isA<ValidationException>().having(
        (e) => e.message,
        'message',
        allOf(contains('ha cambiado'), contains('6,65'), contains('7,60')),
      );
      await expectLater(
        f.sala.cobrarMixto(
          'm1',
          efectivoCents: 400,
          entregadoCents: 400,
          totalEsperadoCents: 665,
        ),
        throwsA(cambio),
      );
      await expectLater(
        f.sala.cobrar('m1', MetodoPago.tarjeta, totalEsperadoCents: 665),
        throwsA(cambio),
      );
      await expectLater(
        f.sala.cobrar(
          'm1',
          MetodoPago.efectivo,
          entregadoCents: 1000,
          totalEsperadoCents: 665,
        ),
        throwsA(cambio),
      );
      expect(f.sala.comandaDeMesa('m1'), isNotNull);
      expect(f.store.snapshot.ticketsTurno, isEmpty);
      expect(f.store.snapshot.numeroLocalSiguiente, 1);
      expect(f.repo.saves, guardadas, reason: 'no se escribe en el diario');
      expect(effects.cobradas, isEmpty);

      // Con el total actualizado sí se cobra, y la tarjeta es el resto real.
      final ticket = await f.sala.cobrarMixto(
        'm1',
        efectivoCents: 400,
        totalEsperadoCents: 760,
      );
      expect(ticket.totalCents, 760);
      expect(ticket.tarjetaCents, 360);
    });

    test('mesa sin comanda o sin líneas activas', () async {
      expect(
        () => f.sala.cobrarMixto('m1', efectivoCents: 100),
        throwsA(
          isA<RemoteRequestException>().having(
            (e) => e.code,
            'code',
            SalaErrorCodes.mesaSinComanda,
          ),
        ),
      );
      await f.sala.aceptarLineas(submit('m2', [linea('l3', 'CANA', 1)]));
      await f.sala.anularLinea('m2', 'l3');
      expect(
        () => f.sala.cobrarMixto('m2', efectivoCents: 10),
        throwsA(
          isA<RemoteRequestException>().having(
            (e) => e.code,
            'code',
            SalaErrorCodes.comandaCerrada,
          ),
        ),
      );
    });

    test('cobrar de un solo método no escribe reparto', () async {
      await f.sala.aceptarLineas(submit('m1', [linea('l1', 'CANA', 7)]));
      final ticket = await f.sala.cobrar('m1', MetodoPago.tarjeta);
      expect(ticket.esMixto, isFalse);
      expect(ticket.pagos.single.importeCents, 665);
      expect(ticket.toJson().containsKey('pagos'), isFalse);
    });
  });

  test('vaciarMesa anula las activas (efecto por línea) y libera', () async {
    await f.sala.aceptarLineas(
      submit('m1', [linea('l1', 'CANA', 1), linea('l2', 'CAFE', 1)]),
    );
    await f.sala.anularLinea('m1', 'l2');
    await f.sala.vaciarMesa('m1');
    await f.sala.idle();
    await pump();
    expect(f.sala.comandaDeMesa('m1'), isNull);
    expect(effects.anuladas.map((l) => l.id), ['l2', 'l1']);
    expect(eventos.last, const SalaChangedEvent(mesaId: 'm1'));
  });

  test(
    'configurarMesas conserva las mesas con comanda abierta y las devuelve',
    () async {
      await f.sala.aceptarLineas(submit('m1', [linea('l1', 'CANA', 1)]));
      const nuevas = [Mesa(id: 'm9', nombre: 'Terraza 9')];

      expect(await f.sala.configurarMesas(nuevas), ['Mesa 1']);
      expect(f.sala.mesas.map((m) => m.id), ['m9', 'm1']);
      expect(f.sala.comandaDeMesa('m1'), isNotNull);

      // Cobrada la mesa, ya se puede quitar.
      await f.sala.cobrar('m1', MetodoPago.tarjeta);
      expect(await f.sala.configurarMesas(nuevas), isEmpty);
      expect(f.sala.mesas.map((m) => m.id), ['m9']);
    },
  );

  test('snapshot() lleva mesas, comandas y versión del catálogo', () async {
    await f.sala.aceptarLineas(submit('barra', [linea('l1', 'CANA', 1)]));
    final snapshot = f.sala.snapshot();
    expect(snapshot.mesas, mesasPrueba);
    expect(snapshot.comandas.single.mesaId, 'barra');
    expect(snapshot.catalogoVersion, f.catalog.version);
    expect(snapshot.generadoEn, f.clock.now);
    // Viaja por la red tal cual.
    expect(SalaSnapshot.fromJson(snapshot.toJson()), snapshot);
  });

  group('h3: idempotencia de líneas contra todo el turno', () {
    test('una retransmisión tras cobrar no reabre la mesa', () async {
      final p = submit('m1', [linea('l1', 'CANA', 2)]);
      await f.sala.aceptarLineas(p);
      await f.sala.cobrar('m1', MetodoPago.tarjeta);
      await f.sala.idle();
      final guardadas = f.repo.saves;
      final eventosAntes = eventos.length;

      final again = await f.sala.aceptarLineas(p);
      await f.sala.idle();
      await pump();
      expect(again.lineasNuevas, 0);
      expect(again.lineasDuplicadas, 1);
      expect(again.comanda.lineas, isEmpty);
      expect(f.sala.comandaDeMesa('m1'), isNull, reason: 'no se reabre');
      expect(f.repo.saves, guardadas, reason: 'no se guarda nada');
      expect(eventos, hasLength(eventosAntes));
      expect(effects.aceptadas, hasLength(1), reason: 'no se reimprime');
    });

    test('el mismo id de línea en otra mesa abierta es duplicado', () async {
      await f.sala.aceptarLineas(submit('m1', [linea('l1', 'CANA', 2)]));
      final otra = await f.sala.aceptarLineas(
        submit('m2', [linea('l1', 'CANA', 2), linea('l2', 'CAFE', 1)]),
      );
      expect(otra.lineasNuevas, 1);
      expect(otra.lineasDuplicadas, 1);
      expect(otra.comanda.lineas.map((l) => l.id), ['l2']);
    });

    test(
      'tras reiniciar sobre el mismo diario sigue siendo duplicada',
      () async {
        final p = submit('m1', [linea('l1', 'CANA', 2)]);
        await f.sala.aceptarLineas(p);
        await f.sala.cobrar('m1', MetodoPago.efectivo);
        await f.sala.idle();
        await f.store.flush();

        final g = await SalaFixture.create(repo: f.repo);
        addTearDown(g.dispose);
        final again = await g.sala.aceptarLineas(p);
        expect(again.lineasNuevas, 0);
        expect(g.sala.comandaDeMesa('m1'), isNull);
      },
    );
  });

  group('h15: el host es la autoridad de precios', () {
    test('con catálogo fija precio, IVA y codimpuesto del artículo y avisa '
        'si el comandero mandó otros', () async {
      final buena = linea('l1', 'AGUA', 1);
      final manipulada = LineaComanda(
        id: 'l1',
        referencia: 'AGUA',
        descripcion: buena.descripcion,
        cantidad: 1,
        pvpUnitarioCents: 50,
        pvpUnitarioNeto: 0.45455,
        ivaBp: 1000,
        codimpuesto: 'IVA10',
        creadaEn: buena.creadaEn,
      );
      final result = await f.sala.aceptarLineas(submit('m1', [manipulada]));
      final aceptada = result.comanda.lineas.single;
      expect(aceptada.pvpUnitarioCents, buena.pvpUnitarioCents);
      expect(aceptada.pvpUnitarioNeto, buena.pvpUnitarioNeto);
      expect(aceptada.ivaBp, 2100);
      expect(aceptada.codimpuesto, 'IVA21');
      expect(
        f.alerts.recientes.map((a) => a.titulo),
        contains(contains('Precios corregidos')),
      );
      final ticket = await f.sala.cobrar('m1', MetodoPago.tarjeta);
      expect(ticket.totalCents, 100);
    });

    test('si coinciden con el catálogo no se avisa', () async {
      await f.sala.aceptarLineas(submit('m1', [linea('l1', 'AGUA', 1)]));
      expect(f.alerts.recientes, isEmpty);
    });
  });

  group('el host es la autoridad del destino (enrutamiento por familias)', () {
    const bebidasABarra = EnrutamientoComandas(
      porFamilia: {'BEB': DestinoPreparacion.barra},
    );
    final cat = catalogoConSubfamilias();
    LineaComanda l(
      String id,
      String referencia, {
      DestinoPreparacion destino = DestinoPreparacion.cocina,
    }) => linea(id, referencia, 1, destino: destino, catalogo: cat);

    late SalaFixture g;
    late RecordingEffects efectos;

    Future<void> crear(EnrutamientoComandas enrutamiento) async {
      g = await SalaFixture.create(catalogo: cat, enrutamiento: enrutamiento);
      efectos = RecordingEffects();
      g.sala.addEffects(efectos);
    }

    tearDown(() => g.dispose());

    Map<String, DestinoPreparacion> destinos(Comanda comanda) => {
      for (final linea in comanda.lineas) linea.referencia: linea.destino,
    };

    test('corrige el destino que manda el comandero, sin avisar', () async {
      await crear(bebidasABarra);
      final result = await g.sala.aceptarLineas(
        submit('m1', [
          l('l1', 'CANA'), // el comandero dice cocina
          l('l2', 'PAELLA', destino: DestinoPreparacion.barra),
        ]),
      );
      await g.sala.idle();
      expect(destinos(result.comanda), {
        'CANA': DestinoPreparacion.barra,
        'PAELLA': DestinoPreparacion.cocina,
      });
      // Los efectos (impresión) reciben ya el destino corregido.
      expect(
        efectos.aceptadas.single.map((l) => l.destino),
        result.comanda.lineas.map((l) => l.destino),
      );
      expect(g.alerts.recientes, isEmpty);
      // Persistido con el destino del host.
      final guardado = await g.repo.load();
      expect(guardado!.comandaDeMesa('m1'), result.comanda);
    });

    test('una línea añadida en la tablet (destino por defecto de '
        'LineaComanda) va a barra si su familia lo dice', () async {
      await crear(bebidasABarra);
      final tablet = LineaComanda(
        id: 'tablet-1',
        referencia: 'CAFE',
        descripcion: 'Café',
        cantidad: 1,
        pvpUnitarioCents: cat.porReferencia('CAFE')!.pvpCents,
        pvpUnitarioNeto: cat.porReferencia('CAFE')!.precioNeto,
        ivaBp: 1000,
        codimpuesto: 'IVA10',
        creadaEn: g.clock.now,
      );
      final result = await g.sala.aceptarLineas(submit('m2', [tablet]));
      expect(result.comanda.lineas.single.destino, DestinoPreparacion.barra);
    });

    test('las subfamilias heredan de su madre y lo que no tiene regla va al '
        'destino por defecto', () async {
      await crear(
        const EnrutamientoComandas(
          porFamilia: {
            'BEB': DestinoPreparacion.barra,
            'CAF': DestinoPreparacion.cocina, // los cafés, en cocina
          },
        ),
      );
      final result = await g.sala.aceptarLineas(
        submit('m1', [
          for (final (i, ref) in [
            'CANA',
            'CAFE',
            'AGUA',
            'FLAN',
            'PAN',
          ].indexed)
            l('l$i', ref),
        ]),
      );
      expect(destinos(result.comanda), {
        'CANA': DestinoPreparacion.barra, // Cervezas ⊂ Bebidas
        'CAFE': DestinoPreparacion.cocina, // regla propia de Cafés
        'AGUA': DestinoPreparacion.barra,
        'FLAN': DestinoPreparacion.cocina, // por defecto
        'PAN': DestinoPreparacion.cocina, // sin familia
      });
      expect(g.sala.destinoDe('POS'), DestinoPreparacion.cocina);
      expect(g.sala.destinoDe('CER'), DestinoPreparacion.barra);
    });

    test('destino por defecto barra con la comida en cocina', () async {
      await crear(
        const EnrutamientoComandas(
          porFamilia: {'COM': DestinoPreparacion.cocina},
          porDefecto: DestinoPreparacion.barra,
        ),
      );
      final result = await g.sala.aceptarLineas(
        submit('m1', [l('l1', 'FLAN'), l('l2', 'PAN'), l('l3', 'CANA')]),
      );
      expect(destinos(result.comanda), {
        'FLAN': DestinoPreparacion.cocina,
        'PAN': DestinoPreparacion.barra,
        'CANA': DestinoPreparacion.barra,
      });
    });

    test('un precio corregido conserva el destino del enrutamiento', () async {
      await crear(bebidasABarra);
      final buena = l('l1', 'CANA');
      final manipulada = LineaComanda(
        id: 'l1',
        referencia: 'CANA',
        descripcion: buena.descripcion,
        cantidad: 1,
        pvpUnitarioCents: 1,
        pvpUnitarioNeto: 0.01,
        ivaBp: 1000,
        codimpuesto: 'IVA10',
        creadaEn: buena.creadaEn,
      );
      final result = await g.sala.aceptarLineas(submit('m1', [manipulada]));
      final aceptada = result.comanda.lineas.single;
      expect(aceptada.pvpUnitarioCents, buena.pvpUnitarioCents);
      expect(aceptada.destino, DestinoPreparacion.barra);
    });

    test('configurarEnrutamiento se aplica en caliente a las líneas nuevas '
        'y viaja en el snapshot', () async {
      await crear(const EnrutamientoComandas());
      await g.sala.aceptarLineas(submit('m1', [l('l1', 'CANA')]));
      expect(g.sala.snapshot().enrutamiento, const EnrutamientoComandas());

      g.sala.configurarEnrutamiento(bebidasABarra);
      final result = await g.sala.aceptarLineas(
        submit('m1', [l('l2', 'CANA')]),
      );
      expect(
        result.comanda.lineaPorId('l1')!.destino,
        DestinoPreparacion.cocina,
      );
      expect(
        result.comanda.lineaPorId('l2')!.destino,
        DestinoPreparacion.barra,
      );
      expect(g.sala.enrutamiento, bebidasABarra);
      final snapshot = g.sala.snapshot();
      expect(snapshot.enrutamiento, bebidasABarra);
      expect(SalaSnapshot.fromJson(snapshot.toJson()), snapshot);
    });

    test('sin catálogo se conserva el destino recibido', () async {
      g = await SalaFixture.create(
        conCatalogo: false,
        enrutamiento: bebidasABarra,
      );
      final result = await g.sala.aceptarLineas(
        submit('m1', [
          linea('l1', 'CANA', 1), // cocina
          linea('l2', 'PAELLA', 1, destino: DestinoPreparacion.barra),
        ]),
      );
      expect(destinos(result.comanda), {
        'CANA': DestinoPreparacion.cocina,
        'PAELLA': DestinoPreparacion.barra,
      });
    });

    test('vaciar la mesa entrega todas las anuladas juntas', () async {
      await crear(bebidasABarra);
      final juntas = _AnuladasJuntas();
      g.sala.addEffects(juntas);
      await g.sala.aceptarLineas(
        submit('m1', [l('l1', 'CANA'), l('l2', 'PAELLA')]),
      );
      await g.sala.vaciarMesa('m1');
      await g.sala.idle();
      expect(juntas.lotes.single.map((l) => l.id), ['l1', 'l2']);
      // El receptor que solo implementa onLineaAnulada las recibe una a una.
      expect(efectos.anuladas.map((l) => l.id), ['l1', 'l2']);
    });
  });
}

/// Receptor que sobreescribe [SalaEffects.onLineasAnuladas].
final class _AnuladasJuntas extends SalaEffects {
  final List<List<LineaComanda>> lotes = [];

  @override
  Future<void> onLineasAnuladas(
    Mesa mesa,
    Comanda comanda,
    List<LineaComanda> anuladas,
  ) async => lotes.add(anuladas);
}
