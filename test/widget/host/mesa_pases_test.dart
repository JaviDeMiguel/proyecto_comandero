/// MesaPage de la tablet con pases, marchas, reimpresión, comensales,
/// precuenta y vaciado (WP-13, §7.5).
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proyecto_comandero/core/errors/app_exception.dart';
import 'package:proyecto_comandero/core/isolates/escpos/escpos_decoder.dart';
import 'package:proyecto_comandero/features/host/application/host_state_repository.dart';
import 'package:proyecto_comandero/features/host/data/in_memory_host_state_repository.dart';
import 'package:proyecto_comandero/features/host/domain/host_snapshot.dart';
import 'package:proyecto_comandero/features/host/presentation/widgets/comanda_por_pases.dart';
import 'package:proyecto_comandero/features/host/presentation/widgets/host_formatos.dart';
import 'package:proyecto_comandero/features/impresion/domain/formato_impresion.dart';
import 'package:proyecto_comandero/features/sala/domain/comanda.dart';
import 'package:proyecto_comandero/features/sala/domain/linea_comanda.dart';
import 'package:proyecto_comandero/features/sala/domain/marcha_pase.dart';
import 'package:proyecto_comandero/features/sala/domain/pases.dart';
import 'package:proyecto_comandero/features/sala/protocol/sala_messages.dart';

import 'support/host_harness.dart';

const String _tpv = 'TPV Prueba';

String _textoDe(Uint8List bytes) => decodeEscPos(bytes).texts.join('|');

Finder _clave(String clave) => find.byKey(Key(clave));

String _textoCabecera(WidgetTester tester, String clave) => tester
    .widgetList<Text>(
      find.descendant(of: _clave(clave), matching: find.byType(Text)),
    )
    .map((t) => t.data)
    .join(' ');

/// Comanda de la mesa 1: una caña directa (barra), una paella de primeros ya
/// marchados hace 10 minutos y otra de segundos en espera (cocina).
Comanda _comandaConPases(FakeClock clock) =>
    comandaPrueba('m1', [
      linea('l1', 'CANA', 1, destino: DestinoPreparacion.barra),
      linea('l2', 'PAELLA', 1, pase: 1),
      linea('l3', 'PAELLA', 2, pase: 2),
    ], clock: clock).copyWith(
      marchas: [
        MarchaPase(
          id: 'marcha-1',
          pase: 1,
          cuando: clock.now.subtract(const Duration(minutes: 10)),
          automatica: true,
        ),
      ],
    );

/// Monta el salón, entra en la mesa [mesaId] y devuelve el banco.
Future<HostHarness> _montar(
  WidgetTester tester, {
  List<Comanda> comandas = const [],
  bool conImpresora = true,
  PasesConfig pases = const PasesConfig(),
  FakePrinterPort? impresora,
  String mesaId = 'm1',
  HostStateRepository? repo,
}) async {
  final h = HostHarness(
    inicial: snapshotPrueba(comandas: comandas),
    repo: repo,
    ajustes: ajustesPrueba(
      conImpresora: conImpresora,
      formato: FormatoImpresion(pases: pases),
    ),
    impresora: conImpresora ? (impresora ?? FakePrinterPort()) : null,
  );
  await h.pump(tester);
  await tester.tap(_clave('mesa-$mesaId'));
  await h.settle(tester);
  return h;
}

Future<void> _tocar(WidgetTester tester, HostHarness h, String clave) async {
  await tester.ensureVisible(_clave(clave));
  await tester.pump();
  await tester.tap(_clave(clave));
  await h.settle(tester);
}

void main() {
  testWidgets('el selector de pase aparece, los artículos van al pase activo '
      'y «Sin enviar» se agrupa por pase', (tester) async {
    final h = await _montar(tester);

    expect(_clave('pase-directo'), findsOneWidget);
    expect(_clave('pase-2'), findsOneWidget);

    await _tocar(tester, h, 'articulo-CANA');
    await _tocar(tester, h, 'pase-2');
    await _tocar(tester, h, 'articulo-PAELLA');
    await _tocar(tester, h, 'articulo-PAELLA');

    expect(_clave('pendientes-pase-directo'), findsOneWidget);
    expect(_clave('pendientes-pase-2'), findsOneWidget);
    // La paella se suma en una sola fila de segundos, bajo su cabecera.
    expect(_clave('pendiente-PAELLA'), findsOneWidget);
    expect(
      tester.getTopLeft(_clave('pendientes-pase-2')).dy,
      lessThan(tester.getTopLeft(_clave('pendiente-PAELLA')).dy),
    );
    expect(
      tester.getTopLeft(_clave('pendiente-CANA')).dy,
      lessThan(tester.getTopLeft(_clave('pendientes-pase-2')).dy),
    );

    // El menú «Pase» de la fila la cambia de grupo.
    await _tocar(tester, h, 'pase-pendiente-CANA');
    await tester.tap(_clave('menu-pase-1').last);
    await h.settle(tester);
    expect(_clave('pendientes-pase-directo'), findsNothing);
    expect(_clave('pendientes-pase-1'), findsOneWidget);

    await h.dispose(tester);
  });

  testWidgets('el envío lleva el pase de cada línea y el TPV como camarero', (
    tester,
  ) async {
    final h = await _montar(tester);

    await _tocar(tester, h, 'articulo-CANA');
    await _tocar(tester, h, 'pase-2');
    await _tocar(tester, h, 'articulo-PAELLA');
    await _tocar(tester, h, 'enviar-pendientes');

    final comanda = h.runtime.sala.comandaDeMesa('m1')!;
    expect(comanda.camarero, _tpv);
    final porReferencia = {for (final l in comanda.lineas) l.referencia: l};
    expect(porReferencia['CANA']!.pase, isNull);
    expect(porReferencia['PAELLA']!.pase, 2);
    expect(comanda.lineas.map((l) => l.camarero), everyElement(_tpv));
    expect(_clave('pendiente-PAELLA'), findsNothing);
    // La comanda enviada ya sale agrupada.
    expect(_clave('comanda-pase-directo'), findsOneWidget);
    expect(_clave('comanda-pase-2'), findsOneWidget);

    await h.dispose(tester);
  });

  testWidgets('la comanda se agrupa con sus estados y «Marchar» deja una '
      'marcha en el diario y un trabajo MARCHAR', (tester) async {
    final clock = FakeClock();
    final impresora = FakePrinterPort();
    final h = await _montar(
      tester,
      comandas: [_comandaConPases(clock)],
      impresora: impresora,
    );
    final hace10 = formatHora(clock.now.subtract(const Duration(minutes: 10)));

    expect(_textoCabecera(tester, 'comanda-pase-directo'), 'Directo');
    expect(
      _textoCabecera(tester, 'comanda-pase-1'),
      contains('1. Primeros · en marcha $hace10'),
    );
    expect(
      _textoCabecera(tester, 'comanda-pase-2'),
      contains('2. Segundos · en espera'),
    );
    expect(_clave('pase-menu-1'), findsOneWidget);
    expect(_clave('marchar-1'), findsNothing);

    await _tocar(tester, h, 'marchar-2');

    var comanda = h.runtime.sala.comandaDeMesa('m1')!;
    expect(comanda.marchas, hasLength(2));
    expect(comanda.marchas.last.pase, 2);
    expect(comanda.marchas.last.camarero, _tpv);
    expect(comanda.marchas.last.automatica, isFalse);
    expect(comanda.marchas.last.repetida, isFalse);
    expect(find.text('Marchados los Segundos'), findsOneWidget);
    await h.runtime.printing.idle();
    expect(
      impresora.jobs.map((j) => j.description),
      contains('Marchar Segundos · Mesa 1 · cocina'),
    );
    expect(_clave('marchar-2'), findsNothing);
    expect(
      _textoCabecera(tester, 'comanda-pase-2'),
      contains('2. Segundos · en marcha'),
    );

    // «Marchar de nuevo» registra una marcha repetida (se imprime REPETIDO).
    await _tocar(tester, h, 'pase-menu-2');
    await tester.tap(_clave('marchar-de-nuevo-2'));
    await h.settle(tester);
    comanda = h.runtime.sala.comandaDeMesa('m1')!;
    expect(comanda.marchas, hasLength(3));
    expect(comanda.marchas.last.repetida, isTrue);
    await h.runtime.printing.idle();
    expect(
      impresora.jobs.map((j) => j.description),
      contains('Marchar Segundos (repetido) · Mesa 1 · cocina'),
    );

    await h.dispose(tester);
  });

  testWidgets('con los pases desactivados y líneas con pase, los grupos y '
      '«Marchar» siguen visibles', (tester) async {
    final clock = FakeClock();
    final h = await _montar(
      tester,
      comandas: [_comandaConPases(clock)],
      pases: const PasesConfig(activos: false),
    );

    expect(_clave('pase-directo'), findsNothing);
    expect(_clave('comanda-pase-1'), findsOneWidget);
    expect(_clave('comanda-pase-2'), findsOneWidget);
    expect(_clave('marchar-2'), findsOneWidget);

    // Lo nuevo no lleva pase ni se agrupa.
    await _tocar(tester, h, 'articulo-CAFE');
    expect(_clave('pendiente-CAFE'), findsOneWidget);
    expect(_clave('pendientes-pase-directo'), findsNothing);
    expect(_clave('pase-pendiente-CAFE'), findsNothing);

    await _tocar(tester, h, 'marchar-2');
    final comanda = h.runtime.sala.comandaDeMesa('m1')!;
    expect(comanda.marchas.last.pase, 2);

    await h.dispose(tester);
  });

  group('reimprimir comanda', () {
    Future<(HostHarness, FakePrinterPort)> abrirDialogo(
      WidgetTester tester,
    ) async {
      final clock = FakeClock();
      final impresora = FakePrinterPort();
      final h = await _montar(
        tester,
        comandas: [
          comandaPrueba('m1', [
            linea('l1', 'PAELLA', 1),
            linea('l2', 'PAELLA', 1, pase: 2),
          ], clock: clock),
        ],
        impresora: impresora,
      );
      await h.runtime.printing.idle();
      impresora.jobs.clear();
      await _tocar(tester, h, 'reimprimir-comanda');
      return (h, impresora);
    }

    ButtonStyleButton aceptar(WidgetTester tester) =>
        tester.widget<ButtonStyleButton>(_clave('reimprimir-aceptar'));

    testWidgets('ofrece solo los puestos con líneas, exige el motivo y '
        'encola «REIMPRESIÓN · PREPARAR»', (tester) async {
      final (h, impresora) = await abrirDialogo(tester);

      expect(_clave('reimprimir-puesto-cocina'), findsOneWidget);
      expect(_clave('reimprimir-puesto-barra'), findsNothing);
      expect(aceptar(tester).onPressed, isNull);

      await _tocar(tester, h, 'reimprimir-motivo-nosalio');
      expect(aceptar(tester).onPressed, isNotNull);
      await _tocar(tester, h, 'reimprimir-aceptar');
      await h.runtime.printing.idle();

      final trabajos = impresora.jobs;
      expect(trabajos, hasLength(1));
      expect(
        trabajos.single.description,
        'Reimpresión de comanda · Mesa 1 · cocina',
      );
      expect(trabajos.single.endpoint, impresoraCocinaPrueba);
      final texto = _textoDe(trabajos.single.bytes);
      expect(texto, contains('REIMPRESIÓN · PREPARAR'));
      expect(texto, contains('Reimpresa'));
      expect(texto, contains(_tpv));

      await h.dispose(tester);
    });

    testWidgets('«Copia para el puesto» encola «COPIA · NO PREPARAR»', (
      tester,
    ) async {
      final (h, impresora) = await abrirDialogo(tester);

      await _tocar(tester, h, 'reimprimir-motivo-copia');
      await _tocar(tester, h, 'reimprimir-aceptar');
      await h.runtime.printing.idle();

      expect(
        impresora.jobs.single.description,
        'Copia de comanda · Mesa 1 · cocina',
      );
      expect(
        _textoDe(impresora.jobs.single.bytes),
        contains('COPIA · NO PREPARAR'),
      );

      await h.dispose(tester);
    });

    testWidgets('sin ningún puesto marcado no se puede reimprimir', (
      tester,
    ) async {
      final (h, impresora) = await abrirDialogo(tester);

      await _tocar(tester, h, 'reimprimir-motivo-copia');
      await _tocar(tester, h, 'reimprimir-puesto-cocina');
      expect(aceptar(tester).onPressed, isNull);
      await tester.tap(find.text('Cancelar'));
      await h.settle(tester);
      expect(impresora.jobs, isEmpty);

      await h.dispose(tester);
    });
  });

  group('comensales', () {
    testWidgets('con la mesa abierta se fijan en la comanda', (tester) async {
      final clock = FakeClock();
      final h = await _montar(
        tester,
        comandas: [
          comandaPrueba('m1', [linea('l1', 'CANA', 1)], clock: clock),
        ],
      );

      await _tocar(tester, h, 'editar-comensales');
      await _tocar(tester, h, 'comensales-4');

      expect(h.runtime.sala.comandaDeMesa('m1')!.comensales, 4);
      expect(find.text('4 comensales'), findsWidgets);

      await h.dispose(tester);
    });

    testWidgets('con la mesa libre esperan al primer envío', (tester) async {
      final h = await _montar(tester, mesaId: 'm2');

      await _tocar(tester, h, 'editar-comensales');
      await _tocar(tester, h, 'comensales-3');

      expect(h.runtime.sala.comandaDeMesa('m2'), isNull);
      expect(find.text('3 comensales'), findsOneWidget);

      await _tocar(tester, h, 'articulo-CANA');
      await _tocar(tester, h, 'enviar-pendientes');

      final comanda = h.runtime.sala.comandaDeMesa('m2')!;
      expect(comanda.comensales, 3);
      expect(comanda.camarero, _tpv);

      await h.dispose(tester);
    });
  });

  group('precuenta', () {
    List<Comanda> conLineas() => [
      comandaPrueba('m1', [linea('l1', 'PAELLA', 1)], clock: FakeClock()),
    ];

    testWidgets('registra la precuenta y la imprime', (tester) async {
      final impresora = FakePrinterPort();
      final h = await _montar(
        tester,
        comandas: conLineas(),
        impresora: impresora,
      );

      await _tocar(tester, h, 'precuenta');
      await h.runtime.printing.idle();

      final comanda = h.runtime.sala.comandaDeMesa('m1')!;
      expect(comanda.precuentas, hasLength(1));
      expect(comanda.precuentas.single.emitidaPor, _tpv);
      expect(
        impresora.jobs.map((j) => j.description),
        contains('Precuenta nº 1 · Mesa 1'),
      );
      expect(
        find.text('Precuenta nº 1 enviada a la impresora'),
        findsOneWidget,
      );

      await h.dispose(tester);
    });

    testWidgets('sin impresora de tickets muestra el error y no registra '
        'nada', (tester) async {
      final h = await _montar(
        tester,
        comandas: conLineas(),
        conImpresora: false,
      );

      await _tocar(tester, h, 'precuenta');

      expect(
        find.text('No hay impresora de tickets configurada'),
        findsOneWidget,
      );
      expect(h.runtime.sala.comandaDeMesa('m1')!.precuentas, isEmpty);

      await h.dispose(tester);
    });

    testWidgets('si la impresión falla, la precuenta queda registrada y el '
        'mensaje lo dice', (tester) async {
      final impresora = FakePrinterPort()
        ..errorAlEncolar = const PrinterException('La cola está llena');
      final h = await _montar(
        tester,
        comandas: conLineas(),
        impresora: impresora,
      );

      await _tocar(tester, h, 'precuenta');

      expect(h.runtime.sala.comandaDeMesa('m1')!.precuentas, hasLength(1));
      expect(
        find.textContaining(
          'La precuenta nº 1 quedó registrada, pero no se pudo imprimir',
        ),
        findsOneWidget,
      );

      await h.dispose(tester);
    });
  });

  group('vaciar', () {
    testWidgets('con precuentas avisa de que quedarán como precuentas sin '
        'cobro', (tester) async {
      final h = await _montar(
        tester,
        comandas: [
          comandaPrueba('m1', [linea('l1', 'PAELLA', 1)], clock: FakeClock()),
        ],
      );
      await h.runtime.sala.emitirPrecuenta('m1');
      await h.runtime.sala.emitirPrecuenta('m1');
      await h.settle(tester);

      await _tocar(tester, h, 'vaciar-mesa');
      expect(
        find.textContaining(
          'Tiene 2 precuentas impresas: quedarán registradas como precuentas '
          'sin cobro y saldrán en el Cierre Z',
        ),
        findsOneWidget,
      );
      await _tocar(tester, h, 'confirmar-aceptar');

      expect(h.runtime.sala.comandaDeMesa('m1'), isNull);
      expect(h.runtime.store.snapshot.precuentasSinCobro, hasLength(2));

      await h.dispose(tester);
    });

    testWidgets('con una sola precuenta el aviso va en singular y sin '
        'precuentas no hay aviso', (tester) async {
      final h = await _montar(
        tester,
        comandas: [
          comandaPrueba('m1', [linea('l1', 'PAELLA', 1)], clock: FakeClock()),
        ],
      );

      await _tocar(tester, h, 'vaciar-mesa');
      expect(find.textContaining('precuenta'), findsNothing);
      await tester.tap(find.text('Cancelar'));
      await h.settle(tester);

      await h.runtime.sala.emitirPrecuenta('m1');
      await h.settle(tester);
      await _tocar(tester, h, 'vaciar-mesa');
      expect(
        find.textContaining(
          'Tiene 1 precuenta impresa: quedará registrada como precuenta sin '
          'cobro y saldrá en el Cierre Z',
        ),
        findsOneWidget,
      );

      await h.dispose(tester);
    });
  });

  group('revisión', () {
    testWidgets('los comensales de la mesa libre no pisan los de la comanda '
        'que otro camarero abrió entre medias', (tester) async {
      final h = await _montar(tester, mesaId: 'm2');
      await _tocar(tester, h, 'editar-comensales');
      await _tocar(tester, h, 'comensales-3');

      await h.runtime.sala.aceptarLineas(
        ComandaSubmitPayload(
          mesaId: 'm2',
          camarero: 'Otro',
          comensales: 5,
          lineas: [linea('x1', 'CANA', 1)],
        ),
      );
      await h.settle(tester);
      expect(find.text('5 comensales'), findsOneWidget);
      expect(find.text('3 comensales'), findsNothing);

      await _tocar(tester, h, 'articulo-PAELLA');
      await _tocar(tester, h, 'enviar-pendientes');

      final comanda = h.runtime.sala.comandaDeMesa('m2')!;
      expect(comanda.comensales, 5);
      expect(comanda.camarero, 'Otro');

      await h.dispose(tester);
    });

    testWidgets('al salir con comensales sin enviar pide confirmación', (
      tester,
    ) async {
      final h = await _montar(tester, mesaId: 'm2');
      await _tocar(tester, h, 'editar-comensales');
      await _tocar(tester, h, 'comensales-3');

      await tester.tap(find.byType(BackButton));
      await h.settle(tester);
      expect(find.text('Comensales sin guardar'), findsOneWidget);
      await _tocar(tester, h, 'confirmar-aceptar');

      expect(_clave('mesa-m2'), findsOneWidget);
      expect(h.runtime.sala.comandaDeMesa('m2'), isNull);

      await h.dispose(tester);
    });

    testWidgets('dos toques seguidos en «Marchar» dejan una sola marcha', (
      tester,
    ) async {
      final h = await _montar(
        tester,
        comandas: [
          comandaPrueba('m1', [
            linea('l3', 'PAELLA', 2, pase: 2),
          ], clock: FakeClock()),
        ],
      );

      await tester.ensureVisible(_clave('marchar-2'));
      await tester.pump();
      await tester.tap(_clave('marchar-2'));
      await tester.tap(_clave('marchar-2'));
      await h.settle(tester);

      final marchas = h.runtime.sala.comandaDeMesa('m1')!.marchas;
      expect(marchas.where((m) => m.pase == 2), hasLength(1));
      expect(marchas.single.repetida, isFalse);

      await h.dispose(tester);
    });

    testWidgets('mientras la marcha espera al diario, el pase muestra el '
        'indicador y un segundo toque no marcha otra vez', (tester) async {
      final repo = _RepoLento(
        snapshotPrueba(
          comandas: [
            comandaPrueba('m1', [
              linea('l3', 'PAELLA', 2, pase: 2),
            ], clock: FakeClock()),
          ],
        ),
      );
      final h = await _montar(tester, repo: repo);
      final bloqueo = repo.bloqueo = Completer<void>();

      await tester.ensureVisible(_clave('marchar-2'));
      await tester.pump();
      await tester.tap(_clave('marchar-2'));
      await tester.tap(_clave('marchar-2'));
      await tester.pump();
      expect(_clave('marchando-2'), findsOneWidget);
      expect(_clave('marchar-2'), findsNothing);
      expect(
        tester
            .widget<CircularProgressIndicator>(
              find.descendant(
                of: _clave('marchando-2'),
                matching: find.byType(CircularProgressIndicator),
              ),
            )
            .semanticsLabel,
        'Marchando 2. Segundos',
      );

      repo.bloqueo = null;
      bloqueo.complete();
      await h.settle(tester);

      final marchas = h.runtime.sala.comandaDeMesa('m1')!.marchas;
      expect(marchas, hasLength(1));
      expect(_clave('marchando-2'), findsNothing);
      expect(_clave('pase-menu-2'), findsOneWidget);

      await h.dispose(tester);
    });

    testWidgets('un pase fuera de la configuración se rotula «7. Pase 7» y se '
        'puede marchar', (tester) async {
      final h = await _montar(
        tester,
        comandas: [
          comandaPrueba('m1', [
            linea('l1', 'PAELLA', 1, pase: 7),
          ], clock: FakeClock()),
        ],
      );

      expect(
        _textoCabecera(tester, 'comanda-pase-7'),
        contains('7. Pase 7 · en espera'),
      );
      expect(find.byTooltip('Marchar 7. Pase 7'), findsOneWidget);
      await _tocar(tester, h, 'marchar-7');

      expect(h.runtime.sala.comandaDeMesa('m1')!.marchas.single.pase, 7);
      expect(find.text('Pase 7 marchado'), findsOneWidget);

      await h.dispose(tester);
    });

    testWidgets('el menú «Pase» ofrece un pase fuera de la configuración', (
      tester,
    ) async {
      final elegidos = <int?>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: MenuPase(
                pases: const PasesConfig(),
                pase: 7,
                onCambio: elegidos.add,
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.byType(MenuPase));
      await tester.pumpAndSettle();
      expect(_clave('menu-pase-directo'), findsOneWidget);
      expect(_clave('menu-pase-3'), findsOneWidget);
      expect(
        find.descendant(
          of: _clave('menu-pase-7'),
          matching: find.text('7. Pase 7'),
        ),
        findsOneWidget,
      );
      await tester.tap(_clave('menu-pase-directo'));
      await tester.pumpAndSettle();
      expect(elegidos, [null]);
    });

    testWidgets('el mismo artículo en «Directo» y en el pase 2 da dos filas', (
      tester,
    ) async {
      final h = await _montar(tester);

      await _tocar(tester, h, 'articulo-PAELLA');
      await _tocar(tester, h, 'pase-2');
      await _tocar(tester, h, 'articulo-PAELLA');

      expect(_clave('pendiente-PAELLA'), findsNWidgets(2));
      expect(_clave('pendientes-pase-directo'), findsOneWidget);
      expect(_clave('pendientes-pase-2'), findsOneWidget);

      await _tocar(tester, h, 'enviar-pendientes');
      final lineas = h.runtime.sala.comandaDeMesa('m1')!.lineas;
      expect(lineas.map((l) => l.pase), unorderedEquals([null, 2]));

      await h.dispose(tester);
    });

    testWidgets('anular una línea pide el motivo y el pase se queda sin '
        '«Marchar»', (tester) async {
      final h = await _montar(
        tester,
        comandas: [
          comandaPrueba('m1', [
            linea('l1', 'PAELLA', 1, pase: 1),
          ], clock: FakeClock()),
        ],
      );
      expect(_clave('marchar-1'), findsOneWidget);

      await _tocar(tester, h, 'anular-l1');
      await tester.tap(find.text('Cliente cancela'));
      await tester.pump();
      await _tocar(tester, h, 'texto-aceptar');

      final l1 = h.runtime.sala.comandaDeMesa('m1')?.lineaPorId('l1');
      expect(l1?.anulada, isTrue);
      expect(l1?.motivoAnulacion, 'Cliente cancela');
      expect(find.textContaining('Anulada: Cliente cancela'), findsOneWidget);
      expect(_clave('marchar-1'), findsNothing);

      await h.dispose(tester);
    });

    testWidgets('en vertical la carta comparte el pase activo', (tester) async {
      final h = await _montar(tester);
      tester.view.physicalSize = const Size(400, 800);
      await h.settle(tester);
      expect(_clave('pase-directo'), findsNothing);

      await _tocar(tester, h, 'abrir-carta');
      await _tocar(tester, h, 'pase-2');
      await _tocar(tester, h, 'articulo-PAELLA');
      await tester.tap(find.byType(BackButton));
      await h.settle(tester);
      expect(_clave('pendientes-pase-2'), findsOneWidget);

      await _tocar(tester, h, 'abrir-carta');
      expect(tester.widget<ChoiceChip>(_clave('pase-2')).selected, isTrue);
      await tester.tap(find.byType(BackButton));
      await h.settle(tester);

      await h.dispose(tester);
    });
  });

  group('reimprimir con la comanda cambiando', () {
    Future<(HostHarness, FakePrinterPort)> montar(
      WidgetTester tester,
      List<LineaComanda> lineas,
    ) async {
      final impresora = FakePrinterPort();
      final h = await _montar(
        tester,
        comandas: [comandaPrueba('m1', lineas, clock: FakeClock())],
        impresora: impresora,
      );
      return (h, impresora);
    }

    Iterable<String> reimpresiones(FakePrinterPort impresora) => impresora.jobs
        .map((j) => j.description)
        .where((d) => d.startsWith('Reimpresión'));

    testWidgets('«Último envío» ofrece solo sus puestos y «Todo» también la '
        'barra', (tester) async {
      final (h, impresora) = await montar(tester, [
        linea(
          'l1',
          'CANA',
          1,
          destino: DestinoPreparacion.barra,
        ).copyWith(envio: 1),
        linea('l2', 'PAELLA', 1).copyWith(envio: 2),
      ]);

      await _tocar(tester, h, 'reimprimir-comanda');
      expect(_clave('reimprimir-puesto-barra'), findsOneWidget);
      expect(_clave('reimprimir-puesto-cocina'), findsOneWidget);
      await _tocar(tester, h, 'reimprimir-alcance-ultimo');
      expect(_clave('reimprimir-puesto-barra'), findsNothing);
      await _tocar(tester, h, 'reimprimir-motivo-nosalio');
      await _tocar(tester, h, 'reimprimir-aceptar');
      await h.runtime.printing.idle();
      expect(reimpresiones(impresora), [
        'Reimpresión de comanda · Mesa 1 · cocina',
      ]);

      impresora.jobs.clear();
      await _tocar(tester, h, 'reimprimir-comanda');
      await _tocar(tester, h, 'reimprimir-motivo-nosalio');
      await _tocar(tester, h, 'reimprimir-aceptar');
      await h.runtime.printing.idle();
      expect(
        reimpresiones(impresora),
        unorderedEquals([
          'Reimpresión de comanda · Mesa 1 · cocina',
          'Reimpresión de comanda · Mesa 1 · barra',
        ]),
      );

      await h.dispose(tester);
    });

    testWidgets('si llega un envío con el diálogo abierto, avisa y no '
        'reimprime', (tester) async {
      final (h, impresora) = await montar(tester, [
        linea('l1', 'PAELLA', 1).copyWith(envio: 1),
      ]);

      await _tocar(tester, h, 'reimprimir-comanda');
      await _tocar(tester, h, 'reimprimir-alcance-ultimo');
      await _tocar(tester, h, 'reimprimir-motivo-nosalio');
      await h.runtime.sala.aceptarLineas(
        ComandaSubmitPayload(mesaId: 'm1', lineas: [linea('x1', 'PAELLA', 1)]),
      );
      await h.settle(tester);
      await _tocar(tester, h, 'reimprimir-aceptar');
      await h.runtime.printing.idle();

      expect(find.textContaining('La comanda ha cambiado'), findsOneWidget);
      expect(reimpresiones(impresora), isEmpty);

      await h.dispose(tester);
    });

    testWidgets('si la mesa se vacía con el diálogo abierto, avisa y no '
        'reimprime', (tester) async {
      final (h, impresora) = await montar(tester, [linea('l1', 'PAELLA', 1)]);

      await _tocar(tester, h, 'reimprimir-comanda');
      await _tocar(tester, h, 'reimprimir-motivo-copia');
      await h.runtime.sala.vaciarMesa('m1');
      await h.settle(tester);
      await _tocar(tester, h, 'reimprimir-aceptar');
      await h.runtime.printing.idle();

      expect(find.text('La mesa ya no tiene comanda'), findsOneWidget);
      expect(
        impresora.jobs.where((j) => j.description.startsWith('Copia')),
        isEmpty,
      );

      await h.dispose(tester);
    });
  });
}

/// Diario en memoria cuya escritura puede quedarse esperando.
final class _RepoLento implements HostStateRepository {
  _RepoLento(HostSnapshot inicial)
    : _interno = InMemoryHostStateRepository(inicial);

  final InMemoryHostStateRepository _interno;

  /// Mientras no sea nulo, cada escritura espera a que se complete.
  Completer<void>? bloqueo;

  @override
  Future<HostSnapshot?> load() => _interno.load();

  @override
  Future<void> save(HostSnapshot snapshot) async {
    final espera = bloqueo;
    if (espera != null) await espera.future;
    await _interno.save(snapshot);
  }
}
