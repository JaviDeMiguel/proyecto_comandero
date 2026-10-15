import 'package:proyecto_comandero/core/errors/app_exception.dart';
import 'package:proyecto_comandero/features/host/application/sala_effects.dart';
import 'package:proyecto_comandero/features/host/application/sala_service.dart';
import 'package:proyecto_comandero/features/sala/domain/comanda.dart';
import 'package:proyecto_comandero/features/sala/domain/linea_comanda.dart';
import 'package:proyecto_comandero/features/sala/domain/marcha_pase.dart';
import 'package:proyecto_comandero/features/sala/domain/mesa.dart';
import 'package:proyecto_comandero/features/sala/domain/precuenta_emitida.dart';
import 'package:proyecto_comandero/features/sala/domain/ticket.dart';
import 'package:proyecto_comandero/features/sala/protocol/sala_messages.dart';
import 'package:test/test.dart';

import 'support/host_test_support.dart';

/// Receptor que anota qué efectos se despachan (la precuenta no es uno).
final class _Despachados extends SalaEffects {
  final List<String> efectos = [];

  @override
  Future<void> onLineasAceptadas(
    Mesa mesa,
    Comanda comanda,
    List<LineaComanda> nuevas,
  ) async => efectos.add('aceptadas');

  @override
  Future<void> onLineasAnuladas(
    Mesa mesa,
    Comanda comanda,
    List<LineaComanda> anuladas,
  ) async => efectos.add('anuladas');

  @override
  Future<void> onPaseMarchado(
    Mesa mesa,
    Comanda comanda,
    MarchaPase marcha,
    List<LineaComanda> lineas,
  ) async => efectos.add('marchado');

  @override
  Future<void> onMesaCobrada(Ticket ticket) async => efectos.add('cobrada');
}

/// Deja que los eventos de los streams (asíncronos) lleguen a sus oyentes.
Future<void> pump() => Future<void>.delayed(Duration.zero);

/// Error de sala con el código [code].
Matcher lanzaCodigo(String code) =>
    throwsA(isA<RemoteRequestException>().having((e) => e.code, 'code', code));

void main() {
  late SalaFixture f;
  late _Despachados effects;
  late List<SalaChangedEvent> eventos;

  setUp(() async {
    f = await SalaFixture.create();
    effects = _Despachados();
    f.sala.addEffects(effects);
    eventos = [];
    f.sala.changes.listen(eventos.add);
  });

  tearDown(() => f.dispose());

  /// Abre la mesa 1 con dos cañas y un café (3,20 €) de `Ana`.
  Future<Comanda> abrirConLineas({int? comensales}) async =>
      (await f.sala.aceptarLineas(
        submit(
          'm1',
          [linea('l1', 'CANA', 2), linea('l2', 'CAFE', 1)],
          camarero: 'Ana',
          comensales: comensales,
        ),
      )).comanda;

  group('emitirPrecuenta', () {
    test('registra la nº 1 y la nº 2 con las líneas activas y los totales '
        'de ese momento', () async {
      final abierta = await abrirConLineas(comensales: 3);
      f.clock.advance(const Duration(minutes: 40));
      final primera = await f.sala.emitirPrecuenta('m1', emitidaPor: 'TPV');
      await f.sala.idle();
      await pump();

      expect(primera.numero, 1);
      expect(primera.emitidaEn, f.clock.now);
      expect(primera.comandaId, abierta.id);
      expect(primera.nombreMesa, 'Mesa 1');
      expect(primera.comensales, 3);
      expect(primera.emitidaPor, 'TPV');
      expect(primera.lineas, [
        for (final l in abierta.lineas) LineaPrecuenta.desde(l),
      ]);
      expect(primera.totales, f.sala.calcularTotales(abierta.lineas));
      expect(primera.totalCents, 320);
      expect(f.sala.comandaDeMesa('m1')!.precuentas, [primera]);
      expect(eventos.last.comanda!.precuentas, [primera]);

      // Una línea más y la segunda precuenta, con todo lo activo.
      f.clock.advance(const Duration(minutes: 5));
      final ampliada = (await f.sala.aceptarLineas(
        submit('m1', [linea('l3', 'AGUA', 1)]),
      )).comanda;
      final segunda = await f.sala.emitirPrecuenta('m1');

      expect(segunda.numero, 2);
      expect(segunda.emitidaEn, f.clock.now);
      expect(segunda.emitidaPor, isNull);
      expect(segunda.lineas.map((l) => l.descripcion), [
        'Caña',
        'Café',
        'Agua',
      ]);
      expect(segunda.totales, f.sala.calcularTotales(ampliada.lineas));
      expect(segunda.totalCents, greaterThan(primera.totalCents));
      final comanda = f.sala.comandaDeMesa('m1')!;
      expect(comanda.precuentas, [primera, segunda]);
      expect(comanda.siguienteNumeroPrecuenta, 3);
      // Persistidas en el diario.
      expect((await f.repo.load())!.comandaDeMesa('m1'), comanda);
    });

    test('sin líneas activas, ValidationException; sin comanda, '
        'mesa_sin_comanda; mesa desconocida', () async {
      await f.sala.abrirMesa('m1');
      final guardadas = f.repo.saves;
      await expectLater(
        f.sala.emitirPrecuenta('m1'),
        throwsA(isA<ValidationException>()),
      );
      expect(f.repo.saves, guardadas, reason: 'un error no escribe');

      await abrirConLineas();
      await f.sala.anularLinea('m1', 'l1');
      await f.sala.anularLinea('m1', 'l2');
      await expectLater(
        f.sala.emitirPrecuenta('m1'),
        throwsA(isA<ValidationException>()),
      );
      expect(f.sala.comandaDeMesa('m1')!.precuentas, isEmpty);

      await expectLater(
        f.sala.emitirPrecuenta('m2'),
        lanzaCodigo(SalaErrorCodes.mesaSinComanda),
      );
      await expectLater(
        f.sala.emitirPrecuenta('nope'),
        lanzaCodigo(SalaErrorCodes.mesaDesconocida),
      );
    });

    test('no despacha ningún efecto: la imprime quien la pide', () async {
      await abrirConLineas();
      await f.sala.idle();
      expect(effects.efectos, ['aceptadas']);

      await f.sala.emitirPrecuenta('m1', emitidaPor: 'TPV');
      await f.sala.idle();
      await pump();
      expect(effects.efectos, ['aceptadas']);
    });

    test(
      'una línea anulada después no cambia la precuenta registrada',
      () async {
        await abrirConLineas();
        final primera = await f.sala.emitirPrecuenta('m1');
        await f.sala.anularLinea('m1', 'l1', motivo: 'error');

        final comanda = f.sala.comandaDeMesa('m1')!;
        expect(comanda.precuentas.single, primera);
        expect(comanda.precuentas.single.lineas.map((l) => l.descripcion), [
          'Caña',
          'Café',
        ]);
        expect(comanda.precuentas.single.totalCents, 320);

        final segunda = await f.sala.emitirPrecuenta('m1');
        expect(segunda.lineas.map((l) => l.descripcion), ['Café']);
        expect(segunda.totalCents, 130);
        expect(f.sala.comandaDeMesa('m1')!.precuentas, [primera, segunda]);
      },
    );
  });

  group('enlace con el ticket y con el Cierre Z', () {
    test('el cobro copia las precuentas al ticket', () async {
      await abrirConLineas();
      final primera = await f.sala.emitirPrecuenta('m1', emitidaPor: 'TPV');
      final segunda = await f.sala.emitirPrecuenta('m1', emitidaPor: 'TPV');

      final ticket = await f.sala.cobrar('m1', MetodoPago.tarjeta);
      await f.sala.idle();

      expect(ticket.precuentas, [primera, segunda]);
      expect(f.store.snapshot.ticketsTurno.single.precuentas, [
        primera,
        segunda,
      ]);
      expect(f.store.snapshot.precuentasSinCobro, isEmpty);
      final guardado = (await f.repo.load())!;
      expect(guardado.ticketsTurno.single, ticket);
      expect(guardado.ticketsTurno.single.precuentas, [primera, segunda]);
    });

    test('vaciarMesa archiva las precuentas como sin cobro, con el motivo, '
        'en la misma escritura', () async {
      await abrirConLineas();
      final primera = await f.sala.emitirPrecuenta('m1');
      final segunda = await f.sala.emitirPrecuenta('m1');
      await f.sala.idle();
      final guardadas = f.repo.saves;
      f.clock.advance(const Duration(minutes: 15));

      await f.sala.vaciarMesa('m1', motivo: 'se fueron sin pagar');
      await f.sala.idle();

      expect(f.repo.saves, guardadas + 1, reason: 'una única escritura');
      expect(f.sala.comandaDeMesa('m1'), isNull);
      final esperadas = [
        PrecuentaSinCobro(
          precuenta: primera,
          vaciadaEn: f.clock.now,
          motivo: 'se fueron sin pagar',
        ),
        PrecuentaSinCobro(
          precuenta: segunda,
          vaciadaEn: f.clock.now,
          motivo: 'se fueron sin pagar',
        ),
      ];
      expect(f.store.snapshot.precuentasSinCobro, esperadas);
      expect((await f.repo.load())!.precuentasSinCobro, esperadas);
      expect(effects.efectos, ['aceptadas', 'anuladas']);

      // Otra mesa vaciada sin motivo se añade detrás, con motivo nulo; una
      // sin precuentas (o sin comanda) no añade nada.
      await f.sala.aceptarLineas(submit('m2', [linea('l9', 'AGUA', 1)]));
      final tercera = await f.sala.emitirPrecuenta('m2');
      await f.sala.vaciarMesa('m2');
      await f.sala.aceptarLineas(submit('barra', [linea('l10', 'CAFE', 1)]));
      await f.sala.vaciarMesa('barra', motivo: 'error');
      await f.sala.vaciarMesa('m1');
      await f.sala.idle();

      expect(f.store.snapshot.precuentasSinCobro, [
        ...esperadas,
        PrecuentaSinCobro(precuenta: tercera, vaciadaEn: f.clock.now),
      ]);
      expect(f.store.snapshot.precuentasSinCobro.last.motivo, isNull);
    });
  });

  group('fijarComensales', () {
    test('abre una mesa libre con los comensales y el camarero, y '
        'emite', () async {
      final result = await f.sala.fijarComensales('m1', 4, camarero: 'Ana');
      await pump();

      expect(result.comanda.mesaId, 'm1');
      expect(result.comanda.comensales, 4);
      expect(result.comanda.camarero, 'Ana');
      expect(result.comanda.lineas, isEmpty);
      expect(f.sala.comandaDeMesa('m1'), result.comanda);
      expect(eventos.single.comanda, result.comanda);
      expect((await f.repo.load())!.comandaDeMesa('m1'), result.comanda);
    });

    test('actualiza la comanda abierta sin tocar el resto y emite; sin '
        'cambios no escribe ni emite', () async {
      final abierta = await abrirConLineas(comensales: 2);
      await pump();
      eventos.clear();

      final result = await f.sala.fijarComensales('m1', 6, camarero: 'Luis');
      await pump();
      expect(result.comanda, abierta.copyWith(comensales: 6));
      expect(result.comanda.camarero, 'Ana', reason: 'el camarero no cambia');
      expect(f.sala.comandaDeMesa('m1'), result.comanda);
      expect(eventos.single.comanda, result.comanda);
      expect((await f.repo.load())!.comandaDeMesa('m1'), result.comanda);

      final guardadas = f.repo.saves;
      final igual = await f.sala.fijarComensales('m1', 6);
      await pump();
      expect(igual.comanda, result.comanda);
      expect(f.repo.saves, guardadas);
      expect(eventos, hasLength(1));
    });

    test('valida de 1 a 99 y la mesa', () async {
      for (final malos in [0, -1, 100]) {
        await expectLater(
          f.sala.fijarComensales('m1', malos),
          throwsA(isA<ValidationException>()),
          reason: '$malos comensales',
        );
      }
      expect(f.sala.comandaDeMesa('m1'), isNull, reason: 'no se abre la mesa');
      await expectLater(
        f.sala.fijarComensales('nope', 2),
        lanzaCodigo(SalaErrorCodes.mesaDesconocida),
      );

      final minimo = await f.sala.fijarComensales(
        'm1',
        SalaService.minComensales,
      );
      expect(minimo.comanda.comensales, 1);
      final maximo = await f.sala.fijarComensales(
        'm1',
        SalaService.maxComensales,
      );
      expect(maximo.comanda.comensales, 99);
    });
  });
}
