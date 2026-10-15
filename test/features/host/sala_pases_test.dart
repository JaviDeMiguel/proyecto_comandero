import 'package:proyecto_comandero/core/errors/app_exception.dart';
import 'package:proyecto_comandero/features/host/application/sala_effects.dart';
import 'package:proyecto_comandero/features/host/data/in_memory_host_state_repository.dart';
import 'package:proyecto_comandero/features/sala/domain/comanda.dart';
import 'package:proyecto_comandero/features/sala/domain/linea_comanda.dart';
import 'package:proyecto_comandero/features/sala/domain/marcha_pase.dart';
import 'package:proyecto_comandero/features/sala/domain/mesa.dart';
import 'package:proyecto_comandero/features/sala/domain/pases.dart';
import 'package:proyecto_comandero/features/sala/protocol/sala_messages.dart';
import 'package:test/test.dart';

import 'support/host_test_support.dart';

/// Marcha despachada a los efectos (las automáticas nunca llegan aquí).
typedef MarchaRecibida = ({
  Mesa mesa,
  Comanda comanda,
  MarchaPase marcha,
  List<LineaComanda> lineas,
});

/// Receptor que anota las marchas despachadas por `onPaseMarchado`.
final class _Marchas extends SalaEffects {
  final List<MarchaRecibida> recibidas = [];

  @override
  Future<void> onPaseMarchado(
    Mesa mesa,
    Comanda comanda,
    MarchaPase marcha,
    List<LineaComanda> lineas,
  ) async => recibidas.add((
    mesa: mesa,
    comanda: comanda,
    marcha: marcha,
    lineas: lineas,
  ));
}

/// Deja que los eventos de los streams (asíncronos) lleguen a sus oyentes.
Future<void> pump() => Future<void>.delayed(Duration.zero);

/// Error de sala con el código [code].
Matcher lanzaCodigo(String code) =>
    throwsA(isA<RemoteRequestException>().having((e) => e.code, 'code', code));

const PasesConfig sinMarcharAlEnviar = PasesConfig(marcharAlEnviar: false);
const PasesConfig desactivados = PasesConfig(activos: false);

void main() {
  late SalaFixture f;
  late _Marchas effects;
  late List<SalaChangedEvent> eventos;

  /// Sala con la configuración de pases [pases] (sobre [repo], si se da).
  Future<void> preparar({
    PasesConfig pases = const PasesConfig(),
    InMemoryHostStateRepository? repo,
  }) async {
    f = await SalaFixture.create(pases: pases, repo: repo);
    effects = _Marchas();
    f.sala.addEffects(effects);
    eventos = [];
    f.sala.changes.listen(eventos.add);
  }

  tearDown(() => f.dispose());

  List<int?> pasesDe(Comanda comanda) => [
    for (final l in comanda.lineas) l.pase,
  ];

  /// (pase, automática) de cada marcha, en orden.
  List<(int, bool)> marchasDe(Comanda comanda) => [
    for (final m in comanda.marchas) (m.pase, m.automatica),
  ];

  Future<Comanda> enviar(List<LineaComanda> lineas, {String? camarero}) async =>
      (await f.sala.aceptarLineas(submit('m1', lineas, camarero: camarero)))
          .comanda;

  group('pase de las líneas aceptadas', () {
    test('con los pases activos se conserva cualquier pase positivo, esté o '
        'no en la configuración', () async {
      await preparar();
      final comanda = await enviar([
        linea('l1', 'CANA', 1, pase: 1),
        linea('l2', 'PAELLA', 1, pase: 5),
        linea('l3', 'AGUA', 1),
        linea('l4', 'CAFE', 1, pase: 0),
      ]);
      expect(pasesDe(comanda), [1, 5, null, null]);
      expect(f.sala.pases.existe(5), isFalse);
      expect(f.sala.pases.nombreDe(5), 'Pase 5');
      // Persistido tal cual.
      final guardada = (await f.repo.load())!.comandaDeMesa('m1')!;
      expect(pasesDe(guardada), [1, 5, null, null]);
    });

    test('con los pases desactivados se descarta y no hay marchas '
        'automáticas', () async {
      await preparar(pases: desactivados);
      final comanda = await enviar([
        linea('l1', 'CANA', 1, pase: 1),
        linea('l2', 'PAELLA', 1, pase: 2),
      ]);
      expect(pasesDe(comanda), [null, null]);
      expect(comanda.tieneMarchas, isFalse);
      expect(f.sala.snapshot().pases, desactivados);
    });
  });

  group('marchas automáticas al aceptar líneas', () {
    test('el primer envío con pases marcha el pase más bajo de sus líneas, '
        'sin despachar ningún efecto', () async {
      await preparar();
      final comanda = await enviar([
        linea('l1', 'PAELLA', 1, pase: 2),
        linea('l2', 'CAFE', 1, pase: 3),
        linea('l3', 'AGUA', 1),
      ], camarero: 'Ana');
      await f.sala.idle();
      await pump();

      expect(marchasDe(comanda), [(2, true)]);
      final marcha = comanda.marchas.single;
      expect(marcha.camarero, 'Ana');
      expect(marcha.cuando, f.clock.now);
      expect(marcha.repetida, isFalse);
      expect(comanda.pasesMarchados, {2});
      expect(
        effects.recibidas,
        isEmpty,
        reason: 'sus líneas ya salen normales en la comanda del envío',
      );
      expect(eventos.single.comanda, comanda);
      expect((await f.repo.load())!.comandaDeMesa('m1'), comanda);
    });

    test('con el primer pase en el envío marcha el primero', () async {
      await preparar();
      final comanda = await enviar([
        linea('l1', 'CANA', 1, pase: 1),
        linea('l2', 'PAELLA', 1, pase: 2),
      ]);
      expect(marchasDe(comanda), [(1, true)]);
    });

    test('un envío solo de directas no marcha nada; el siguiente con pases, '
        'sí', () async {
      await preparar();
      final directas = await enviar([linea('l1', 'CANA', 1)]);
      expect(directas.tieneMarchas, isFalse);
      final conPases = await enviar([linea('l2', 'PAELLA', 1, pase: 2)]);
      expect(marchasDe(conPases), [(2, true)]);
    });

    test('no marcha con «marchar al enviar» desactivado', () async {
      await preparar(pases: sinMarcharAlEnviar);
      final comanda = await enviar([
        linea('l1', 'CANA', 1, pase: 1),
        linea('l2', 'PAELLA', 1, pase: 2),
      ]);
      expect(comanda.tieneMarchas, isFalse);
    });

    test('no marcha si la comanda ya tiene alguna marcha, ni repite un pase '
        'ya marchado', () async {
      await preparar();
      await enviar([linea('l1', 'PAELLA', 1, pase: 2)]);
      final postres = await enviar([linea('l2', 'CAFE', 1, pase: 3)]);
      expect(marchasDe(postres), [
        (2, true),
      ], reason: 'el 3º espera a que lo marchen');
      final mas = await enviar([linea('l3', 'PAELLA', 1, pase: 2)]);
      expect(marchasDe(mas), [(2, true)], reason: 'el 2º ya estaba marchado');
    });

    test('un pase menor que el mayor ya marchado se marcha solo (entrantes '
        'pedidos con los segundos en marcha)', () async {
      await preparar();
      final primero = await enviar([
        linea('l1', 'PAELLA', 1, pase: 2),
        linea('l2', 'CAFE', 1, pase: 4),
      ]);
      expect(marchasDe(primero), [(2, true)]);
      await f.sala.marcharPase(
        'm1',
        4,
        marchaId: 'mk-4',
        comandaId: primero.id,
      );

      final entrantes = await enviar([
        linea('l3', 'CANA', 1, pase: 3),
        linea('l4', 'AGUA', 1, pase: 1),
        linea('l5', 'CAFE', 1, pase: 5),
      ], camarero: 'Luis');
      await f.sala.idle();

      expect(marchasDe(entrantes), [
        (2, true),
        (4, false),
        (1, true),
        (3, true),
      ]);
      expect(entrantes.pasesMarchados, {1, 2, 3, 4});
      expect(entrantes.marchas.last.camarero, 'Luis');
      expect(effects.recibidas.map((r) => r.marcha.id), [
        'mk-4',
      ], reason: 'solo la marcha manual se despacha');
      expect((await f.repo.load())!.comandaDeMesa('m1'), entrantes);
    });

    test('también con «marchar al enviar» desactivado', () async {
      await preparar(pases: sinMarcharAlEnviar);
      final primero = await enviar([
        linea('l1', 'CANA', 1, pase: 1),
        linea('l2', 'PAELLA', 1, pase: 2),
      ]);
      expect(primero.tieneMarchas, isFalse);
      await f.sala.marcharPase('m1', 2, marchaId: 'mk-2');
      final entrantes = await enviar([linea('l3', 'AGUA', 1, pase: 1)]);
      expect(marchasDe(entrantes), [(2, false), (1, true)]);
      // Las líneas que llegan después a un pase ya marchado no añaden marcha.
      final mas = await enviar([linea('l4', 'CANA', 1, pase: 1)]);
      expect(marchasDe(mas), [(2, false), (1, true)]);
    });
  });

  group('marcharPase', () {
    test('registra la marcha, emite y despacha las líneas activas del '
        'pase', () async {
      await preparar(pases: sinMarcharAlEnviar);
      final abierta = await enviar([
        linea('l1', 'CANA', 1, pase: 1),
        linea('l2', 'PAELLA', 1, pase: 2),
        linea('l3', 'CAFE', 1, pase: 2),
        linea('l4', 'AGUA', 1),
      ]);
      await f.sala.anularLinea('m1', 'l3');
      await f.sala.idle();
      await pump();
      eventos.clear();
      f.clock.advance(const Duration(minutes: 20));

      final result = await f.sala.marcharPase(
        'm1',
        2,
        marchaId: 'mk-1',
        comandaId: abierta.id,
        camarero: 'Ana',
      );
      await f.sala.idle();
      await pump();

      final marcha = result.comanda.marchas.single;
      expect(
        marcha,
        MarchaPase(id: 'mk-1', pase: 2, cuando: f.clock.now, camarero: 'Ana'),
      );
      expect(marcha.automatica, isFalse);
      expect(marcha.repetida, isFalse);
      expect(result.comanda.pasesMarchados, {2});
      expect(result.comanda.ultimaMarchaDe(2), marcha);
      expect(f.sala.comandaDeMesa('m1'), result.comanda);
      final recibida = effects.recibidas.single;
      expect(recibida.mesa.id, 'm1');
      expect(recibida.comanda, result.comanda);
      expect(recibida.marcha, marcha);
      expect(recibida.lineas.map((l) => l.id), [
        'l2',
      ], reason: 'ni la anulada ni las de otro pase');
      expect(eventos.single.comanda, result.comanda);
      // La marcha queda en el diario.
      expect(
        (await f.repo.load())!.comandaDeMesa('m1')!.marchaPorId('mk-1'),
        marcha,
      );
    });

    test('es idempotente por marchaId: la retransmisión no vuelve a marchar '
        'ni a imprimir', () async {
      await preparar(pases: sinMarcharAlEnviar);
      final abierta = await enviar([linea('l1', 'CANA', 1, pase: 1)]);
      final primera = await f.sala.marcharPase(
        'm1',
        1,
        marchaId: 'mk-1',
        comandaId: abierta.id,
      );
      await f.sala.idle();
      await pump();
      final guardadas = f.repo.saves;
      eventos.clear();
      f.clock.advance(const Duration(seconds: 30));

      final repetida = await f.sala.marcharPase(
        'm1',
        1,
        marchaId: 'mk-1',
        comandaId: abierta.id,
        camarero: 'Otro',
      );
      await f.sala.idle();
      await pump();

      expect(repetida, primera);
      expect(repetida.comanda.marchas, hasLength(1));
      expect(effects.recibidas, hasLength(1));
      expect(eventos, isEmpty);
      expect(f.repo.saves, guardadas, reason: 'no se escribe');
    });

    test('la idempotencia sobrevive a reiniciar el host: la marcha está en '
        'el diario', () async {
      await preparar(pases: sinMarcharAlEnviar);
      final abierta = await enviar([linea('l1', 'CANA', 1, pase: 1)]);
      await f.sala.marcharPase(
        'm1',
        1,
        marchaId: 'mk-1',
        comandaId: abierta.id,
      );
      await f.sala.idle();

      // Host reiniciado sobre el mismo diario.
      final g = await SalaFixture.create(
        repo: f.repo,
        pases: sinMarcharAlEnviar,
      );
      addTearDown(g.dispose);
      final espia = _Marchas();
      g.sala.addEffects(espia);
      final retransmitida = await g.sala.marcharPase(
        'm1',
        1,
        marchaId: 'mk-1',
        comandaId: abierta.id,
      );
      await g.sala.idle();
      expect(retransmitida.comanda.marchas.map((m) => m.id), ['mk-1']);
      expect(espia.recibidas, isEmpty);

      // Una marcha nueva tras el reinicio sí se registra (y es repetida).
      final nueva = await g.sala.marcharPase(
        'm1',
        1,
        marchaId: 'mk-2',
        comandaId: abierta.id,
      );
      await g.sala.idle();
      expect(nueva.comanda.marchas.map((m) => m.id), ['mk-1', 'mk-2']);
      expect(nueva.comanda.marchas.last.repetida, isTrue);
      expect(espia.recibidas.single.marcha.id, 'mk-2');
    });

    test('con un comandaId que no es el de la comanda abierta: '
        'mesa_sin_comanda sin tocar nada', () async {
      await preparar(pases: sinMarcharAlEnviar);
      final abierta = await enviar([linea('l1', 'CANA', 1, pase: 1)]);
      final guardadas = f.repo.saves;
      await expectLater(
        f.sala.marcharPase('m1', 1, marchaId: 'mk-1', comandaId: 'c-anterior'),
        lanzaCodigo(SalaErrorCodes.mesaSinComanda),
      );
      expect(f.sala.comandaDeMesa('m1'), abierta);
      expect(effects.recibidas, isEmpty);
      expect(f.repo.saves, guardadas);
    });

    test('mesa sin comanda y mesa desconocida', () async {
      await preparar();
      await expectLater(
        f.sala.marcharPase('m1', 1, marchaId: 'mk-1'),
        lanzaCodigo(SalaErrorCodes.mesaSinComanda),
      );
      await expectLater(
        f.sala.marcharPase('nope', 1, marchaId: 'mk-1'),
        lanzaCodigo(SalaErrorCodes.mesaDesconocida),
      );
    });

    test('sin líneas activas del pase: pase_sin_lineas si está en la '
        'configuración y pase_no_valido si no', () async {
      await preparar(pases: sinMarcharAlEnviar);
      await enviar([
        linea('l1', 'CANA', 1, pase: 1),
        linea('l2', 'PAELLA', 1, pase: 2),
      ]);
      await f.sala.anularLinea('m1', 'l2');
      final guardadas = f.repo.saves;

      await expectLater(
        f.sala.marcharPase('m1', 2, marchaId: 'mk-1'),
        throwsA(
          isA<RemoteRequestException>()
              .having((e) => e.code, 'code', SalaErrorCodes.paseSinLineas)
              .having(
                (e) => e.message,
                'message',
                'La mesa Mesa 1 no tiene líneas de Segundos',
              ),
        ),
      );
      for (final pase in [0, 4]) {
        await expectLater(
          f.sala.marcharPase('m1', pase, marchaId: 'mk-$pase'),
          throwsA(
            isA<RemoteRequestException>()
                .having((e) => e.code, 'code', SalaErrorCodes.paseNoValido)
                .having((e) => e.message, 'message', 'El pase $pase no existe'),
          ),
          reason: 'pase $pase',
        );
      }
      expect(f.repo.saves, guardadas, reason: 'un error no escribe');
      expect(effects.recibidas, isEmpty);
    });

    test('con los pases desactivados y sin líneas del pase: '
        'pase_no_valido', () async {
      await preparar(pases: desactivados);
      await enviar([linea('l1', 'CANA', 1, pase: 1)]);
      await expectLater(
        f.sala.marcharPase('m1', 1, marchaId: 'mk-1'),
        lanzaCodigo(SalaErrorCodes.paseNoValido),
      );
    });

    test('se puede marchar un pase con líneas aunque no esté en la '
        'configuración', () async {
      await preparar(pases: sinMarcharAlEnviar);
      final abierta = await enviar([linea('l1', 'PAELLA', 1, pase: 5)]);
      final result = await f.sala.marcharPase(
        'm1',
        5,
        marchaId: 'mk-5',
        comandaId: abierta.id,
      );
      await f.sala.idle();
      expect(result.comanda.pasesMarchados, {5});
      expect(effects.recibidas.single.lineas.map((l) => l.id), ['l1']);
    });

    test('se puede marchar un pase con líneas aunque los pases se hayan '
        'desactivado después', () async {
      await preparar(pases: sinMarcharAlEnviar);
      final abierta = await enviar([linea('l1', 'PAELLA', 1, pase: 2)]);
      f.sala.configurarPases(desactivados);
      final result = await f.sala.marcharPase(
        'm1',
        2,
        marchaId: 'mk-2',
        comandaId: abierta.id,
      );
      await f.sala.idle();
      expect(result.comanda.pasesMarchados, {2});
      expect(effects.recibidas.single.marcha.pase, 2);
      // Las líneas nuevas ya llegan sin pase; las aceptadas conservan el suyo.
      final despues = await enviar([linea('l2', 'CAFE', 1, pase: 2)]);
      expect(pasesDe(despues), [2, null]);
    });

    test('marchar un pase ya marchado (a mano o automático) se registra como '
        'repetida', () async {
      await preparar();
      final abierta = await enviar([linea('l1', 'CANA', 1, pase: 1)]);
      expect(marchasDe(abierta), [(1, true)]);
      final segunda = await f.sala.marcharPase(
        'm1',
        1,
        marchaId: 'mk-1',
        comandaId: abierta.id,
      );
      final tercera = await f.sala.marcharPase(
        'm1',
        1,
        marchaId: 'mk-2',
        comandaId: abierta.id,
      );
      await f.sala.idle();

      expect(segunda.comanda.marchas.last.repetida, isTrue);
      expect(tercera.comanda.marchas.map((m) => (m.pase, m.repetida)), [
        (1, false),
        (1, true),
        (1, true),
      ]);
      expect(tercera.comanda.pasesMarchados, {1});
      expect(tercera.comanda.ultimaMarchaDe(1)!.id, 'mk-2');
      expect(effects.recibidas.map((r) => r.marcha.repetida), [true, true]);
      expect((await f.repo.load())!.comandaDeMesa('m1'), tercera.comanda);
    });
  });

  group('configurarPases', () {
    test('snapshot() publica siempre los pases, activos o no', () async {
      await preparar();
      expect(f.sala.pases, const PasesConfig());
      expect(f.sala.snapshot().pases, const PasesConfig());
      expect(f.sala.snapshot().toJson()['pases'], const PasesConfig().toJson());
      f.sala.configurarPases(desactivados);
      expect(f.sala.pases, desactivados);
      expect(f.sala.snapshot().pases, desactivados);
      expect(f.sala.snapshot().pases!.activos, isFalse);
    });

    test('avisa por enrutamientoChanges solo si la configuración '
        'cambia', () async {
      await preparar();
      var avisos = 0;
      f.sala.enrutamientoChanges.listen((_) => avisos++);

      f.sala.configurarPases(const PasesConfig());
      await pump();
      expect(avisos, 0, reason: 'la misma configuración no avisa');

      const nueva = PasesConfig(nombres: ['Entrantes', 'Platos']);
      f.sala.configurarPases(nueva);
      await pump();
      expect(avisos, 1);
      expect(f.sala.snapshot().pases, nueva);
      expect(f.sala.pases.nombreDe(2), 'Platos');

      f.sala.configurarPases(nueva);
      await pump();
      expect(avisos, 1);
    });
  });
}
