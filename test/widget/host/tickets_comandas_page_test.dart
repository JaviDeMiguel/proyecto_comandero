/// Página «Tickets y comandas» (§7.2 del diseño de impresión): borrador y
/// guardado de `impresion.formato`, perfiles por impresora física, vista
/// previa sin runtime, muestra impresa, emisor, QR, pases y navegación.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proyecto_comandero/app/app.dart';
import 'package:proyecto_comandero/app/navigation.dart';
import 'package:proyecto_comandero/core/errors/app_exception.dart';
import 'package:proyecto_comandero/core/fiscal/verifactu_qr.dart';
import 'package:proyecto_comandero/core/isolates/escpos/escpos_builder.dart'
    show PaperWidth, ZumbadorModo;
import 'package:proyecto_comandero/core/isolates/isolate_runner.dart';
import 'package:proyecto_comandero/features/host/domain/empresa_emisora.dart';
import 'package:proyecto_comandero/features/host/presentation/providers.dart';
import 'package:proyecto_comandero/features/host/presentation/tickets_comandas_page.dart';
import 'package:proyecto_comandero/features/host/presentation/widgets/vista_previa_escpos.dart';
import 'package:proyecto_comandero/features/impresion/domain/formato_impresion.dart';
import 'package:proyecto_comandero/features/sala/domain/pases.dart';
import 'package:proyecto_comandero/features/settings/data/in_memory_settings_repository.dart';
import 'package:proyecto_comandero/features/settings/domain/app_settings.dart';
import 'package:proyecto_comandero/features/settings/presentation/settings_diagnostics.dart';
import 'package:proyecto_comandero/features/settings/presentation/settings_providers.dart';

import '../../core/facturascripts/fake_fs_api.dart';
import '../app/app_fakes.dart';
import 'support/host_harness.dart';

Finder clave(String k) => find.byKey(Key(k));

/// Texto [texto] dentro del control con clave [k] (un segmento, un chip).
Finder dentro(String k, String texto) =>
    find.descendant(of: clave(k), matching: find.text(texto));

/// Texto que contiene [texto] dentro de la vista previa.
Finder enVista(String texto) => find.descendant(
  of: clave('tc-vista-previa'),
  matching: find.textContaining(texto),
);

Future<void> tocar(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
  await tester.pump();
}

/// Deja pasar la espera de la vista previa y su generación.
/// Primero reconstruye (la espera cuenta desde el último cambio).
Future<void> regenerar(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pump();
  await tester.pump();
}

AppSettings guardados(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(MaterialApp)))
        .read(appSettingsProvider)
        .value!;

bool activoBoton(WidgetTester tester, String k) =>
    tester.widget<ButtonStyleButton>(clave(k)).onPressed != null;

/// Ajustes con impresora por rol y la barra en la impresora de cocina.
AppSettings ajustesBarraEnCocina({
  FormatoImpresion formato = const FormatoImpresion(),
}) {
  final base = ajustesPrueba(conImpresora: true, formato: formato);
  return base.copyWith(
    impresion: base.impresion.copyWith(barra: impresoraCocinaPrueba),
  );
}

/// Una sola impresora para tickets y cocina (sin barra).
AppSettings ajustesUnaImpresora({
  required bool abrirCajon,
  FormatoImpresion formato = const FormatoImpresion(),
}) {
  final base = ajustesPrueba(conImpresora: true, formato: formato);
  return base.copyWith(
    impresion: base.impresion.copyWith(
      cocina: impresoraTicketsPrueba,
      borrarBarra: true,
      abrirCajon: abrirCajon,
    ),
  );
}

Widget lanzador() => Builder(
  builder: (context) => Scaffold(
    body: Center(
      child: TextButton(
        key: const Key('abrir'),
        onPressed: () => unawaited(abrirTicketsYComandas(context)),
        child: const Text('Abrir'),
      ),
    ),
  ),
);

/// [secuencia] aparece seguida en [bytes].
bool contiene(List<int> bytes, List<int> secuencia) {
  for (var i = 0; i + secuencia.length <= bytes.length; i++) {
    var igual = true;
    for (var j = 0; j < secuencia.length && igual; j++) {
      igual = bytes[i + j] == secuencia[j];
    }
    if (igual) return true;
  }
  return false;
}

/// Ejecutor que retiene cada trabajo hasta que el test abre su puerta (o la
/// abre con un error).
final class RunnerRetenido implements IsolateRunner {
  final List<Completer<void>> puertas = [];

  @override
  Future<R> run<M, R>(
    IsolateEntryPoint<M, R> entryPoint,
    M message, {
    String? debugName,
  }) async {
    final puerta = Completer<void>();
    puertas.add(puerta);
    await puerta.future;
    return entryPoint(message);
  }
}

/// Monta la página sin runtime (su fábrica falla) con [runner].
Future<void> montarSinRuntime(
  WidgetTester tester, {
  IsolateRunner runner = const InlineIsolateRunner(),
}) async {
  tester.view
    ..physicalSize = const Size(1280, 800)
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        settingsRepositoryProvider.overrideWith(
          (ref) => InMemorySettingsRepository(
            initial: ajustesPrueba(conImpresora: true),
          ),
        ),
        isolateRunnerProvider.overrideWithValue(runner),
        hostAutoStartProvider.overrideWithValue(false),
        hostRuntimeFactoryProvider.overrideWithValue(
          (ref, settings) async =>
              throw const ConfigException('Diario corrupto'),
        ),
      ],
      child: const TpvComanderoApp(home: TicketsComandasPage()),
    ),
  );
  // Carga de los ajustes y primera petición de la vista previa.
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 10));
  }
}

VistaPreviaEscPos vistaActual(WidgetTester tester) =>
    tester.widget<VistaPreviaEscPos>(find.byType(VistaPreviaEscPos));

EmpresaEmisora empresaSinNif() => EmpresaEmisora(
  nombre: 'Hostelería Manolo SL',
  nombrecorto: 'Bar Manolo',
  ciudad: 'Toledo',
  obtenidaEn: DateTime(2026, 10, 7, 12),
);

void main() {
  testWidgets('carga el borrador, edita los perfiles y guarda solo '
      'impresion.formato en todos los roles de cada dirección', (tester) async {
    const formato = FormatoImpresion(
      ticket: FormatoTicket(nombreComercial: 'La Tasca'),
    );
    final h = HostHarness(ajustes: ajustesBarraEnCocina(formato: formato));
    await h.pump(tester, home: const TicketsComandasPage());

    final nombre = tester.widget<TextField>(clave('tc-nombre-comercial'));
    expect(nombre.controller!.text, 'La Tasca');
    expect(find.textContaining('Cocina · Barra'), findsOneWidget);
    expect(activoBoton(tester, 'tc-guardar'), isFalse);

    await tocar(tester, dentro('tc-papel-tickets', '80 mm (180 ppp)'));
    await tocar(tester, dentro('tc-papel-cocina', '58 mm'));
    await tocar(tester, clave('tc-avance-cocina-mas'));
    await tocar(tester, clave('tc-avance-cocina-mas'));
    await tocar(tester, clave('tc-copias-cocina-mas'));
    await tocar(tester, dentro('tc-zumbador-cocina', 'Zumbador'));
    await tocar(tester, dentro('tc-pin-cocina', '2'));
    expect(activoBoton(tester, 'tc-guardar'), isTrue);

    final antes = guardados(tester);
    await tocar(tester, clave('tc-guardar'));
    await h.settle(tester);

    final perfilCocina = PerfilImpresora(
      papel: PaperWidth.mm58,
      lineasIniciales: 2,
      copias: 2,
      zumbador: ZumbadorModo.puertoCajon,
      pinZumbador: 2,
      direccion: claveImpresora(impresoraCocinaPrueba),
    );
    final esperado = formato.copyWith(
      perfiles: {
        RolImpresora.tickets: PerfilImpresora(
          papel: PaperWidth.mm80Dpi180,
          direccion: claveImpresora(impresoraTicketsPrueba),
        ),
        RolImpresora.cocina: perfilCocina,
        RolImpresora.barra: perfilCocina,
      },
    );
    expect(
      guardados(tester),
      antes.copyWith(impresion: antes.impresion.copyWith(formato: esperado)),
    );
    expect(activoBoton(tester, 'tc-guardar'), isFalse);
    await h.dispose(tester);
  });

  testWidgets('avisa de perfiles distintos en una dirección compartida y '
      'guardar los unifica', (tester) async {
    final direccion = claveImpresora(impresoraCocinaPrueba);
    final formato = FormatoImpresion(
      perfiles: {
        RolImpresora.cocina: PerfilImpresora(
          papel: PaperWidth.mm58,
          direccion: direccion,
        ),
        RolImpresora.barra: PerfilImpresora(copias: 3, direccion: direccion),
      },
    );
    final h = HostHarness(ajustes: ajustesBarraEnCocina(formato: formato));
    await h.pump(tester, home: const TicketsComandasPage());

    expect(clave('tc-aviso-perfiles-cocina'), findsOneWidget);
    expect(
      find.textContaining(
        'Cocina y Barra comparten esta impresora con '
        'perfiles distintos',
      ),
      findsOneWidget,
    );
    final papel = tester.widget<SegmentedButton<PaperWidth>>(
      clave('tc-papel-cocina'),
    );
    expect(papel.selected, {PaperWidth.mm58});
    expect(activoBoton(tester, 'tc-guardar'), isTrue);

    await tocar(tester, clave('tc-guardar'));
    await h.settle(tester);

    final perfiles = guardados(tester).impresion.formato.perfiles;
    expect(perfiles[RolImpresora.cocina], perfiles[RolImpresora.barra]);
    expect(perfiles[RolImpresora.cocina]!.papel, PaperWidth.mm58);
    expect(clave('tc-aviso-perfiles-cocina'), findsNothing);
    expect(activoBoton(tester, 'tc-guardar'), isFalse);
    await h.dispose(tester);
  });

  for (final abrirCajon in [true, false]) {
    testWidgets('el zumbador del conector del cajón no se ofrece en la '
        'impresora de tickets (abrir el cajón: $abrirCajon)', (tester) async {
      final formato = FormatoImpresion(
        perfiles: {
          RolImpresora.tickets: PerfilImpresora(
            zumbador: ZumbadorModo.puertoCajon,
            direccion: claveImpresora(impresoraTicketsPrueba),
          ),
        },
      );
      final h = HostHarness(
        ajustes: ajustesUnaImpresora(abrirCajon: abrirCajon, formato: formato),
      );
      await h.pump(tester, home: const TicketsComandasPage());

      final aviso = tester.widget<SegmentedButton<ZumbadorModo>>(
        clave('tc-zumbador-tickets'),
      );
      final zumbador = aviso.segments.singleWhere(
        (s) => s.value == ZumbadorModo.puertoCajon,
      );
      expect(zumbador.enabled, isFalse);
      // El perfil antiguo con el zumbador se muestra ya anulado.
      expect(aviso.selected, {ZumbadorModo.ninguno});
      expect(clave('tc-zumbador-bloqueado-tickets'), findsOneWidget);

      await tocar(tester, dentro('tc-zumbador-tickets', 'Zumbador'));
      expect(
        tester
            .widget<SegmentedButton<ZumbadorModo>>(clave('tc-zumbador-tickets'))
            .selected,
        {ZumbadorModo.ninguno},
      );
      await h.dispose(tester);
    });
  }

  testWidgets('en una impresora solo de comandas sí se ofrece el zumbador; '
      'la de tickets sola no tiene aviso', (tester) async {
    final h = HostHarness(ajustes: ajustesPrueba(conImpresora: true));
    await h.pump(tester, home: const TicketsComandasPage());

    expect(clave('tc-zumbador-tickets'), findsNothing);
    expect(clave('tc-copias-tickets'), findsNothing);
    final aviso = tester.widget<SegmentedButton<ZumbadorModo>>(
      clave('tc-zumbador-cocina'),
    );
    expect(
      aviso.segments
          .singleWhere((s) => s.value == ZumbadorModo.puertoCajon)
          .enabled,
      isTrue,
    );
    await tocar(tester, dentro('tc-zumbador-cocina', 'Zumbador'));
    expect(clave('tc-pin-cocina'), findsOneWidget);
    expect(clave('tc-pitidos-cocina'), findsOneWidget);
    await h.dispose(tester);
  });

  testWidgets('«Mostrar el camarero» y «Mostrar los comensales» cambian la '
      'vista previa del provisional y de la precuenta', (tester) async {
    final h = HostHarness();
    await h.pump(tester, home: const TicketsComandasPage());
    await regenerar(tester);

    expect(enVista('MUESTRA'), findsWidgets);
    expect(enVista('Camarero: Ana'), findsOneWidget);
    await tocar(tester, clave('tc-camarero'));
    await regenerar(tester);
    expect(enVista('Camarero: Ana'), findsNothing);

    await tocar(tester, clave('tc-documento-precuenta'));
    await regenerar(tester);
    expect(enVista('4 comensales'), findsOneWidget);
    expect(enVista('Por comensal'), findsOneWidget);
    expect(enVista('Camarero: Ana'), findsNothing);

    await tocar(tester, clave('tc-comensales'));
    await regenerar(tester);
    expect(enVista('comensales'), findsNothing);
    expect(enVista('Por comensal'), findsNothing);

    await tocar(tester, clave('tc-camarero'));
    await regenerar(tester);
    expect(enVista('Camarero: Ana'), findsOneWidget);
    await h.dispose(tester);
  });

  testWidgets('el QR está desactivado por defecto y muestra la nota de '
      'validarlo antes', (tester) async {
    final h = HostHarness();
    await h.pump(tester, home: const TicketsComandasPage());

    final modo = tester.widget<SegmentedButton<ModoQrVerifactu>>(
      clave('tc-qr-modo'),
    );
    expect(modo.selected, {ModoQrVerifactu.desactivado});
    await tester.ensureVisible(clave('tc-qr-nota'));
    expect(
      find.descendant(
        of: clave('tc-qr-nota'),
        matching: find.textContaining(
          'Antes de activarlo, imprime la factura '
          'de muestra en la impresora real',
        ),
      ),
      findsOneWidget,
    );

    await tocar(tester, dentro('tc-qr-modo', 'VERI*FACTU'));
    await tocar(tester, dentro('tc-qr-entorno', 'Pruebas'));
    await tocar(tester, clave('tc-guardar'));
    await h.settle(tester);
    expect(
      guardados(tester).impresion.formato.verifactu,
      const QrVerifactuConfig(
        modo: ModoQrVerifactu.verifactu,
        entorno: EntornoVerifactu.pruebas,
      ),
    );
    await h.dispose(tester);
  });

  testWidgets('pide confirmación al salir con cambios sin guardar', (
    tester,
  ) async {
    final h = HostHarness();
    await h.pump(tester, home: lanzador());

    // Sin cambios sale directamente.
    await tocar(tester, clave('abrir'));
    await h.settle(tester);
    expect(find.byType(TicketsComandasPage), findsOneWidget);
    await tester.tap(find.byType(BackButton));
    await h.settle(tester);
    expect(find.byType(TicketsComandasPage), findsNothing);

    await tocar(tester, clave('abrir'));
    await h.settle(tester);
    await tocar(tester, clave('tc-iva-incluido'));
    await tester.tap(find.byType(BackButton));
    await h.settle(tester);
    expect(find.text('Cambios sin guardar'), findsOneWidget);
    await tester.tap(find.text('Cancelar'));
    await h.settle(tester);
    expect(find.byType(TicketsComandasPage), findsOneWidget);

    await tester.tap(find.byType(BackButton));
    await h.settle(tester);
    await tester.tap(find.text('Salir sin guardar'));
    await h.settle(tester);
    expect(find.byType(TicketsComandasPage), findsNothing);
    expect(guardados(tester).impresion.formato, const FormatoImpresion());
    await h.dispose(tester);
  });

  testWidgets('la vista previa cambia con el documento y el papel sin '
      'runtime', (tester) async {
    tester.view
      ..physicalSize = const Size(1280, 800)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsRepositoryProvider.overrideWith(
            (ref) => InMemorySettingsRepository(
              initial: ajustesPrueba(conImpresora: true),
            ),
          ),
          isolateRunnerProvider.overrideWithValue(const InlineIsolateRunner()),
          hostAutoStartProvider.overrideWithValue(false),
          hostRuntimeFactoryProvider.overrideWithValue(
            (ref, settings) async =>
                throw const ConfigException('Diario corrupto'),
          ),
        ],
        child: const TpvComanderoApp(home: TicketsComandasPage()),
      ),
    );
    await regenerar(tester);
    await tester.pumpAndSettle();

    VistaPreviaEscPos vista() =>
        tester.widget<VistaPreviaEscPos>(find.byType(VistaPreviaEscPos));
    expect(enVista('Camarero: Ana'), findsOneWidget);
    final provisional = vista().bytes;
    expect(vista().papel, PaperWidth.mm80);

    await tocar(tester, clave('tc-documento-comandaCocina'));
    await regenerar(tester);
    expect(vista().bytes, isNot(provisional));
    expect(enVista('COCINA'), findsWidgets);

    await tocar(tester, dentro('tc-papel-vista', '58 mm'));
    await regenerar(tester);
    expect(vista().papel, PaperWidth.mm58);

    // Cambiar el papel de la tarjeta de cocina vuelve a sincronizar la vista
    // previa de la comanda con él, aunque se hubiera elegido otro allí.
    await tocar(tester, dentro('tc-papel-cocina', '80 mm (180 ppp)'));
    await regenerar(tester);
    expect(vista().papel, PaperWidth.mm80Dpi180);

    // El papel del perfil de la impresora manda en la vista previa.
    await tocar(tester, clave('tc-documento-provisional'));
    await tocar(tester, dentro('tc-papel-tickets', '80 mm (180 ppp)'));
    await regenerar(tester);
    expect(vista().papel, PaperWidth.mm80Dpi180);

    expect(activoBoton(tester, 'tc-imprimir-muestra'), isFalse);
    expect(activoBoton(tester, 'tc-actualizar-empresa'), isFalse);
    expect(find.text('El TPV no está en marcha'), findsNWidgets(2));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('«Imprimir muestra» encola en la impresora del documento con '
      'el borrador', (tester) async {
    final impresora = FakePrinterPort();
    final h = HostHarness(
      ajustes: ajustesPrueba(conImpresora: true),
      impresora: impresora,
    );
    await h.pump(tester, home: const TicketsComandasPage());
    await regenerar(tester);

    expect(activoBoton(tester, 'tc-imprimir-muestra'), isTrue);
    await tocar(tester, clave('tc-imprimir-muestra'));
    await h.settle(tester);
    expect(impresora.jobs, hasLength(1));
    expect(
      impresora.jobs.single.description,
      'Muestra · Documento provisional',
    );
    expect(impresora.jobs.single.endpoint, impresoraTicketsPrueba);

    ScaffoldMessenger.of(tester.element(find.byType(TicketsComandasPage)))
        .removeCurrentSnackBar();
    await tester.pump();
    await tocar(tester, clave('tc-documento-comandaBarra'));
    await tocar(tester, clave('tc-imprimir-muestra'));
    await h.settle(tester);
    expect(impresora.jobs, hasLength(2));
    expect(impresora.jobs.last.description, 'Muestra · Comanda de barra');
    expect(impresora.jobs.last.endpoint, impresoraBarraPrueba);

    // La muestra usa el perfil del BORRADOR: con el avance guardado (0) no
    // hay ESC d 4; tras subirlo a 4 sin guardar, sí.
    Future<void> imprimirComandaCocina() async {
      ScaffoldMessenger.of(tester.element(find.byType(TicketsComandasPage)))
          .removeCurrentSnackBar();
      await tester.pump();
      await tocar(tester, clave('tc-documento-comandaCocina'));
      await tocar(tester, clave('tc-imprimir-muestra'));
      await h.settle(tester);
    }

    const avance4 = [0x1B, 0x64, 4];
    await imprimirComandaCocina();
    expect(impresora.jobs.last.endpoint, impresoraCocinaPrueba);
    expect(contiene(impresora.jobs.last.bytes, avance4), isFalse);
    for (var i = 0; i < 4; i++) {
      await tocar(tester, clave('tc-avance-cocina-mas'));
    }
    await imprimirComandaCocina();
    expect(impresora.jobs, hasLength(4));
    expect(contiene(impresora.jobs.last.bytes, avance4), isTrue);
    // Nada se ha guardado.
    expect(guardados(tester).impresion.formato, const FormatoImpresion());
    await h.dispose(tester);
  });

  testWidgets('sin impresora para el documento, «Imprimir muestra» está '
      'desactivado', (tester) async {
    final h = HostHarness();
    await h.pump(tester, home: const TicketsComandasPage());

    expect(clave('tc-sin-impresoras'), findsOneWidget);
    expect(activoBoton(tester, 'tc-imprimir-muestra'), isFalse);
    expect(find.text('No hay impresora de Tickets'), findsOneWidget);
    await h.dispose(tester);
  });

  testWidgets('tarjeta del emisor: aviso sin NIF y «Actualizar» lee la '
      'empresa con el runtime', (tester) async {
    final api = FakeFsApi.conDatosBasicos()
      ..seed('empresas', {
        'idempresa': 1,
        'nombre': 'Hostelería Manolo SL',
        'nombrecorto': 'Bar Manolo',
        'cifnif': 'B12345678',
        'ciudad': 'Toledo',
      });
    final h = HostHarness(
      api: api,
      inicial: snapshotPrueba(
        extra: (base) => base.copyWith(empresa: empresaSinNif()),
      ),
    );
    await h.pump(tester, home: const TicketsComandasPage());

    await tester.ensureVisible(clave('tc-emisor'));
    expect(dentro('tc-emisor', 'Hostelería Manolo SL'), findsOneWidget);
    expect(dentro('tc-emisor', 'NIF: —'), findsOneWidget);
    expect(find.text('Actualizado el 07/10/2026 12:00'), findsOneWidget);
    expect(clave('tc-aviso-sin-nif'), findsOneWidget);
    expect(
      find.text('Sin NIF no se pueden imprimir facturas simplificadas'),
      findsOneWidget,
    );
    final campo = tester.widget<TextField>(clave('tc-nombre-comercial'));
    expect(campo.decoration!.hintText, 'Bar Manolo');

    await tocar(tester, clave('tc-actualizar-empresa'));
    await h.settle(tester);

    expect(api.callsTo('empresas'), isNotEmpty);
    expect(dentro('tc-emisor', 'NIF: B12345678'), findsOneWidget);
    // La vista previa se regenera con la cabecera nueva.
    await regenerar(tester);
    expect(enVista('B12345678'), findsOneWidget);
    expect(clave('tc-aviso-sin-nif'), findsNothing);
    expect(find.text('Datos de la empresa actualizados'), findsOneWidget);
    await h.dispose(tester);
  });

  testWidgets('edita los nombres de los pases, como mucho 5', (tester) async {
    final h = HostHarness();
    await h.pump(tester, home: const TicketsComandasPage());

    expect(clave('tc-pase-nombre-3'), findsOneWidget);
    await tocar(tester, clave('tc-pase-anadir'));
    await tocar(tester, clave('tc-pase-anadir'));
    expect(clave('tc-pase-nombre-5'), findsOneWidget);
    expect(activoBoton(tester, 'tc-pase-anadir'), isFalse);

    await tester.ensureVisible(clave('tc-pase-nombre-4'));
    await tester.enterText(clave('tc-pase-nombre-4'), 'Cafés');
    await tester.pump();
    await tester.enterText(clave('tc-pase-nombre-2'), '  ');
    await tester.pump();
    expect(clave('tc-pases-error'), findsOneWidget);
    expect(activoBoton(tester, 'tc-guardar'), isFalse);

    await tocar(tester, clave('tc-pase-quitar-2'));
    await tocar(tester, clave('tc-marchar-primero'));
    expect(clave('tc-pases-error'), findsNothing);
    expect(clave('tc-pase-nombre-5'), findsNothing);
    expect(activoBoton(tester, 'tc-pase-anadir'), isTrue);

    await tocar(tester, clave('tc-guardar'));
    await h.settle(tester);
    expect(
      guardados(tester).impresion.formato.pases,
      const PasesConfig(
        nombres: ['Primeros', 'Postres', 'Cafés', 'Pase 5'],
        marcharAlEnviar: false,
      ),
    );
    await h.dispose(tester);
  });

  testWidgets('emisión al cobrar, nombre comercial y pie se guardan en el '
      'formato y cambian la vista previa', (tester) async {
    final h = HostHarness();
    await h.pump(tester, home: const TicketsComandasPage());

    expect(clave('tc-espera'), findsNothing);
    await tocar(tester, find.text('Emitir factura al cobrar'));
    expect(find.text('10'), findsOneWidget);
    await tocar(tester, clave('tc-espera-mas'));
    await tester.ensureVisible(clave('tc-nombre-comercial'));
    await tester.enterText(clave('tc-nombre-comercial'), ' La Tasca ');
    await tester.enterText(clave('tc-pie'), 'Gracias por venir');
    await regenerar(tester);
    expect(enVista('La Tasca'), findsWidgets);
    expect(enVista('Gracias por venir'), findsOneWidget);

    await tocar(tester, clave('tc-guardar'));
    await h.settle(tester);
    final formato = guardados(tester).impresion.formato;
    expect(
      formato.emision,
      const EmisionTicket(
        modo: ModoEmision.facturaAlCobrar,
        esperaSegundos: 11,
      ),
    );
    expect(
      formato.ticket,
      const FormatoTicket(
        nombreComercial: 'La Tasca',
        pie: 'Gracias por venir',
      ),
    );

    // Vaciar el nombre comercial vuelve al de FacturaScripts.
    await tester.enterText(clave('tc-nombre-comercial'), '');
    await tocar(tester, clave('tc-guardar'));
    await h.settle(tester);
    expect(guardados(tester).impresion.formato.ticket.nombreComercial, isNull);
    await h.dispose(tester);
  });

  testWidgets('en pantallas estrechas, ajustes y vista previa van en '
      'pestañas', (tester) async {
    final h = HostHarness();
    await h.pump(tester, home: const TicketsComandasPage());
    tester.view.physicalSize = const Size(600, 900);
    await tester.pumpAndSettle();

    expect(find.text('Ajustes'), findsOneWidget);
    expect(find.text('Vista previa'), findsOneWidget);
    expect(clave('tc-papel-vista'), findsNothing);
    await tester.tap(find.text('Vista previa'));
    await tester.pumpAndSettle();
    await regenerar(tester);
    expect(clave('tc-papel-vista'), findsOneWidget);
    expect(enVista('Camarero: Ana'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await h.dispose(tester);
  });

  for (final ancho in [360.0, 411.0]) {
    testWidgets('a $ancho px de ancho nada desborda', (tester) async {
      final h = HostHarness(ajustes: ajustesBarraEnCocina());
      await h.pump(tester, home: const TicketsComandasPage());
      tester.view.physicalSize = Size(ancho, 800);
      await tester.pumpAndSettle();

      await tocar(tester, dentro('tc-zumbador-cocina', 'Zumbador'));
      expect(clave('tc-pin-cocina'), findsOneWidget);
      await tocar(tester, dentro('tc-papel-cocina', '80 mm (180 ppp)'));
      await tester.ensureVisible(clave('tc-qr-modo'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(clave('tc-pase-anadir'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Vista previa'));
      await tester.pumpAndSettle();
      await regenerar(tester);
      expect(find.byType(VistaPreviaEscPos), findsOneWidget);
      expect(tester.takeException(), isNull);
      await h.dispose(tester);
    });
  }

  testWidgets('los contadores dicen qué cambian', (tester) async {
    final h = HostHarness(ajustes: ajustesPrueba(conImpresora: true));
    await h.pump(tester, home: const TicketsComandasPage());

    expect(find.byTooltip('Más copias de comandas'), findsNWidgets(2));
    expect(find.byTooltip('Menos avance inicial'), findsNWidgets(2));
    final semantica = tester.getSemantics(clave('tc-copias-cocina-valor'));
    expect(semantica.label, 'copias de comandas');
    expect(semantica.value, '1');
    await h.dispose(tester);
  });

  testWidgets('la vista previa descarta el resultado de una petición '
      'anterior', (tester) async {
    final runner = RunnerRetenido();
    await montarSinRuntime(tester, runner: runner);
    expect(runner.puertas, hasLength(1)); // provisional, en curso

    await tocar(tester, clave('tc-documento-comandaCocina'));
    await tester.pump(const Duration(milliseconds: 350));
    expect(runner.puertas, hasLength(2)); // comanda, en curso

    runner.puertas[1].complete();
    await regenerar(tester);
    final comanda = vistaActual(tester).bytes;
    expect(enVista('DOCUMENTO PROVISIONAL'), findsNothing);

    // El provisional termina tarde: no sustituye a la comanda.
    runner.puertas[0].complete();
    await regenerar(tester);
    expect(vistaActual(tester).bytes, same(comanda));
    expect(enVista('DOCUMENTO PROVISIONAL'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('dos cambios en menos de 300 ms generan una sola muestra', (
    tester,
  ) async {
    final runner = RunnerRetenido();
    await montarSinRuntime(tester, runner: runner);
    runner.puertas.single.complete();
    await regenerar(tester);

    await tocar(tester, clave('tc-documento-precuenta'));
    await tester.pump(const Duration(milliseconds: 100));
    await tocar(tester, clave('tc-documento-comandaBarra'));
    await tester.pump(const Duration(milliseconds: 200));
    expect(runner.puertas, hasLength(1));
    await tester.pump(const Duration(milliseconds: 150));
    expect(runner.puertas, hasLength(2));
    runner.puertas.last.complete();
    await regenerar(tester);
    expect(runner.puertas, hasLength(2));
    expect(enVista('BARRA'), findsWidgets);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('si la muestra falla, se ve el error sin el documento '
      'anterior', (tester) async {
    final runner = RunnerRetenido();
    await montarSinRuntime(tester, runner: runner);
    runner.puertas.single.complete();
    await regenerar(tester);
    expect(find.byType(VistaPreviaEscPos), findsOneWidget);

    await tocar(tester, clave('tc-documento-factura'));
    await regenerar(tester);
    runner.puertas.last.completeError(
      const ValidationException('No se pudo generar la muestra'),
    );
    await regenerar(tester);
    expect(clave('tc-vista-error'), findsOneWidget);
    expect(find.text('No se pudo generar la muestra'), findsOneWidget);
    expect(find.byType(VistaPreviaEscPos), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('guardar conserva otros campos de los ajustes cambiados '
      'mientras la página estaba abierta', (tester) async {
    final h = HostHarness(ajustes: ajustesBarraEnCocina());
    await h.pump(tester, home: const TicketsComandasPage());
    final container = ProviderScope.containerOf(
      tester.element(find.byType(MaterialApp)),
    );
    await tocar(tester, clave('tc-iva-incluido'));
    await container
        .read(appSettingsProvider.notifier)
        .actualizar(
          (s) => s.copyWith(
            impresion: s.impresion.copyWith(
              abrirCajon: !s.impresion.abrirCajon,
              imprimirComandaCocina: false,
            ),
          ),
        );
    await h.settle(tester);
    final antes = guardados(tester);

    await tocar(tester, clave('tc-guardar'));
    await h.settle(tester);
    final despues = guardados(tester);
    expect(despues.impresion.abrirCajon, antes.impresion.abrirCajon);
    expect(despues.impresion.imprimirComandaCocina, isFalse);
    expect(despues.impresion.formato.ticket.ivaIncluido, isFalse);
    expect(
      despues,
      antes.copyWith(
        impresion: antes.impresion.copyWith(formato: despues.impresion.formato),
      ),
    );
    await h.dispose(tester);
  });

  testWidgets('con los pases apagados, los nombres siguen editables y un '
      'nombre vacío se puede corregir', (tester) async {
    final h = HostHarness();
    await h.pump(tester, home: const TicketsComandasPage());

    await tocar(tester, clave('tc-pases-activos'));
    final campo = tester.widget<TextField>(clave('tc-pase-nombre-2'));
    expect(campo.enabled ?? true, isTrue);
    await tester.ensureVisible(clave('tc-pase-nombre-2'));
    await tester.enterText(clave('tc-pase-nombre-2'), '');
    await tester.pump();
    expect(clave('tc-pases-error'), findsOneWidget);
    expect(activoBoton(tester, 'tc-guardar'), isFalse);

    await tester.enterText(clave('tc-pase-nombre-2'), 'Carnes');
    await tester.pump();
    expect(clave('tc-pases-error'), findsNothing);
    await tocar(tester, clave('tc-guardar'));
    await h.settle(tester);
    expect(
      guardados(tester).impresion.formato.pases,
      const PasesConfig(
        activos: false,
        nombres: ['Primeros', 'Carnes', 'Postres'],
      ),
    );
    await h.dispose(tester);
  });

  testWidgets('Ajustes > Impresoras abre «Tickets y comandas»', (tester) async {
    final h = HostHarness();
    await tester.pumpWidget(const SizedBox.shrink());
    tester.view
      ..physicalSize = const Size(1280, 800)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...h.overrides,
          settingsDiagnosticsProvider.overrideWithValue(
            FakeSettingsDiagnostics(),
          ),
        ],
        child: TpvComanderoApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                key: const Key('ajustes'),
                onPressed: () => unawaited(
                  abrirAjustes(
                    context,
                    onAbrirTicketsYComandas: (c) =>
                        unawaited(abrirTicketsYComandas(c)),
                  ),
                ),
                child: const Text('Ajustes'),
              ),
            ),
          ),
        ),
      ),
    );
    await h.settle(tester);
    await tester.tap(clave('ajustes'));
    await h.settle(tester);
    await tocar(tester, clave('ajustes-tickets-comandas'));
    await h.settle(tester);

    expect(find.byType(TicketsComandasPage), findsOneWidget);
    expect(
      ModalRoute.of(tester.element(find.byType(TicketsComandasPage)))!
          .settings
          .name,
      '/tickets-comandas',
    );
    await h.dispose(tester);
  });
}
