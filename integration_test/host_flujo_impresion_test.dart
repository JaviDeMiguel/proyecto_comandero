// Prueba de flujo de punta a punta del HOST sobre la interfaz REAL en Windows.
//
//   flutter test integration_test/host_flujo_impresion_test.dart -d windows
//
// Arranca la app de verdad (`TpvComanderoApp` con su `AppShell`, en modo
// host) con el runtime real (sala, diario en fichero en un directorio
// temporal, cola de sincronización, facturación, cola de impresión con
// `PrintQueueAdapter` + `EscPosSocketPrinter` y generación ESC/POS en
// isolates reales). Solo se inyectan los ajustes (en memoria), el ERP y las
// impresoras: tres servidores TCP en 127.0.0.1 que se comportan como una
// impresora RAW 9100 (leen hasta el FIN y cierran) y guardan cada conexión
// como un trabajo, que la prueba decodifica con `escpos_decoder.dart`.
//
// Flujo (todo con toques en la interfaz):
//  1. Salón → Mesa 1 → 4 comensales; «Ensalada mixta» en Primeros, «Entrecot»
//     en Segundos y un «Refresco» directo; Enviar. La cocina recibe la
//     «COMANDA Nº 1» con Segundos bajo «ESPERAR» y la barra, el refresco.
//  2. «Marchar» Segundos → la cocina recibe el MARCHAR SEGUNDOS.
//  3. «Precuenta» → la impresora de tickets recibe la PRECUENTA Nº 1 («NO
//     VÁLIDO COMO FACTURA»).
//  4. Cobro en efectivo con 50 € → el documento provisional (nº local, «NO
//     VÁLIDO COMO FACTURA») con el pulso del cajón antes del texto.
//  5. La cola real emite la factura contra el ERP y el diálogo muestra su
//     código; «Imprimir factura» → ORIGINAL con «Nº F…» y sin DUPLICADO;
//     «Imprimir duplicado» → la banda DUPLICADO.
//  6. Caja y Cierre Z → detalle del ticket con su estado de impresión.
//  7. Fuera de la interfaz: el diario en disco (marchas, comensales,
//     precuenta copiada al ticket, ORIGINAL y 1 duplicado), la factura en el
//     ERP y el número de trabajos de cada impresora.
//  8. Con la Mesa 1 abierta encima del salón, `HostRuntime.dispose` termina
//     (antes se colgaba esperando a los oyentes en pausa del salón).
//
// El ERP del caso principal es un FacturaScripts SIMULADO en memoria
// (`apoyo/erp_simulado.dart`). La segunda prueba repite el cobro contra un
// FacturaScripts DE PRUEBAS real y se omite sola si no se pasan sus datos:
//
//   flutter test integration_test/host_flujo_impresion_test.dart -d windows \
//     --dart-define=TPV_FS_BASE_URL=http://localhost/fs_pruebas \
//     --dart-define=TPV_FS_TOKEN=<clave api de pruebas> \
//     [--dart-define=TPV_FS_REF=<referencia de un plato>] \
//     [--dart-define=TPV_FS_CODCLIENTE=TPV] [--dart-define=TPV_FS_CODALMACEN=ALG]
//
// El ERP de pruebas necesita el cliente, el almacén, la serie `S` y las
// formas de pago `TPVEFE`/`TPVTAR` del asistente del plugin, y la empresa
// con NIF (sin él no se imprime la factura). Sin `TPV_FS_REF` se vende el
// primer artículo vendible del catálogo.
//
// NUNCA la apuntes a la instalación de producción: crea una factura real
// (con su asiento y su cobro) y, al terminar, la BORRA por la API (la prueba
// falla si no puede borrarla, para que nadie la deje olvidada).
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:proyecto_comandero/app/app.dart';
import 'package:proyecto_comandero/core/facturascripts/fs_api.dart';
import 'package:proyecto_comandero/core/facturascripts/fs_http_api.dart';
import 'package:proyecto_comandero/core/facturascripts/fs_resources.dart';
import 'package:proyecto_comandero/core/isolates/escpos/escpos_decoder.dart';
import 'package:proyecto_comandero/core/money/money.dart';
import 'package:proyecto_comandero/features/host/application/host_runtime.dart';
import 'package:proyecto_comandero/features/host/data/file_host_state_repository.dart';
import 'package:proyecto_comandero/features/host/domain/host_snapshot.dart';
import 'package:proyecto_comandero/features/host/presentation/providers.dart';
import 'package:proyecto_comandero/features/sala/domain/ticket.dart';
import 'package:proyecto_comandero/features/settings/data/in_memory_settings_repository.dart';
import 'package:proyecto_comandero/features/settings/domain/app_settings.dart';
import 'package:proyecto_comandero/features/settings/presentation/settings_providers.dart';

import '../test/core/network/printing/fake_printer.dart';
import 'apoyo/erp_simulado.dart';

const String _fsBaseUrl = String.fromEnvironment('TPV_FS_BASE_URL');
const String _fsToken = String.fromEnvironment('TPV_FS_TOKEN');
const String _fsRef = String.fromEnvironment('TPV_FS_REF');
const String _fsCodcliente = String.fromEnvironment(
  'TPV_FS_CODCLIENTE',
  defaultValue: 'TPV',
);
const String _fsCodalmacen = String.fromEnvironment(
  'TPV_FS_CODALMACEN',
  defaultValue: 'ALG',
);

const String _nombreTpv = 'TPV E2E';

/// Total de la mesa: ensalada 8,00 + entrecot 18,00 + refresco 2,50.
const int _totalMesaCents = 2850;

/// Espera máxima de cada paso (red local, isolates y diario reales).
const Duration _limitePaso = Duration(seconds: 30);

Finder _clave(String clave) => find.byKey(Key(clave));

/// Texto de un trabajo de impresión, una línea impresa por línea.
String _textoDe(Uint8List bytes) => decodeEscPos(bytes).texts.join('\n');

/// Bombea frames hasta que se cumple [condicion] (operaciones reales de red,
/// isolates y disco) o falla tras [limite] describiendo [que] y, si se
/// pasa, el [estado] en ese momento.
Future<void> _esperarA(
  WidgetTester tester,
  bool Function() condicion,
  String que, {
  Duration limite = _limitePaso,
  String Function()? estado,
}) async {
  final fin = DateTime.now().add(limite);
  while (!condicion()) {
    if (DateTime.now().isAfter(fin)) {
      final detalle = estado == null ? '' : '\n${estado()}';
      throw TestFailure('No ocurrió en ${limite.inSeconds} s: $que$detalle');
    }
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _esperarClave(WidgetTester tester, String clave) => _esperarA(
  tester,
  () => _clave(clave).evaluate().isNotEmpty,
  'aparece «$clave»',
);

/// Algunos frames para que la interfaz procese el gesto (sin
/// `pumpAndSettle`: hay indicadores de progreso que no terminan).
Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _tocar(WidgetTester tester, String clave) async {
  await _esperarClave(tester, clave);
  await tester.ensureVisible(_clave(clave).first);
  await tester.pump();
  // Como haría el usuario: si algo lo tapa (p. ej. un SnackBar sobre los
  // botones del pie), espera a que se retire.
  await _esperarA(
    tester,
    () => _clave(clave).hitTestable().evaluate().isNotEmpty,
    'se puede tocar «$clave» (nada lo tapa)',
  );
  await tester.tap(_clave(clave).hitTestable().first);
  await _frames(tester);
}

String? _textoClave(WidgetTester tester, String clave) =>
    tester.widget<Text>(_clave(clave)).data;

bool _botonActivo(WidgetTester tester, String clave) =>
    tester.widget<ButtonStyleButton>(_clave(clave)).onPressed != null;

/// Espera a que la impresora reciba [cuantos] trabajos en total y devuelve el
/// texto del último.
Future<String> _esperarTrabajo(
  WidgetTester tester,
  FakePrinter impresora,
  int cuantos,
  String que,
) async {
  await _esperarA(
    tester,
    () => impresora.jobs.length >= cuantos,
    que,
    estado: () =>
        'Trabajos recibidos: ${impresora.jobs.length} de $cuantos\n'
        '${impresora.jobs.map(_textoDe).join('\n-----\n')}',
  );
  return _textoDe(impresora.jobs[cuantos - 1]);
}

Future<int> _puertoLibre() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final puerto = socket.port;
  await socket.close();
  return puerto;
}

/// Banco de la prueba: impresoras falsas, diario en un directorio temporal y
/// el runtime que construye la app.
final class _Banco {
  _Banco._(this.tickets, this.cocina, this.barra, this.directorio);

  final FakePrinter tickets;
  final FakePrinter cocina;
  final FakePrinter barra;
  final Directory directorio;
  HostRuntime? _runtime;

  HostRuntime get runtime =>
      _runtime ?? (throw StateError('La app aún no ha creado el runtime'));

  /// Arranca las impresoras y monta la app en modo host. Con [api], el ERP
  /// es ese doble; con [erpReal], el runtime crea su cliente HTTP real.
  static Future<_Banco> montar(
    WidgetTester tester, {
    FsApi? api,
    FsApiConfig? erpReal,
    required String codcliente,
    required String codalmacen,
  }) async {
    final banco = _Banco._(
      await FakePrinter.start(),
      await FakePrinter.start(),
      await FakePrinter.start(),
      await Directory.systemTemp.createTemp('tpv_host_e2e_'),
    );
    // Los `addTearDown` van en orden inverso: primero se desmonta la app y
    // se cierra el runtime (aunque la prueba falle a medias) y después se
    // liberan las impresoras y el diario.
    addTearDown(banco._liberar);
    addTearDown(() => banco.desmontar(tester));

    final ajustes = AppSettings(
      deviceId: 'tablet-e2e',
      deviceName: 'Tablet E2E',
      rol: DeviceRole.host,
      red: NetworkSettings(
        tcpPort: await _puertoLibre(),
        discoveryPort: await _puertoLibre(),
      ),
      fsApi: erpReal,
      fiscal: FiscalSettings(
        codcliente: codcliente,
        codalmacen: codalmacen,
        nombreTpv: _nombreTpv,
      ),
      impresion: PrintingSettings(
        tickets: banco.tickets.endpoint,
        cocina: banco.cocina.endpoint,
        barra: banco.barra.endpoint,
      ),
      mesas: const [
        Mesa(id: 'm1', nombre: 'Mesa 1', orden: 1),
        Mesa(id: 'm2', nombre: 'Mesa 2', orden: 2),
      ],
    );

    tester.view
      ..physicalSize = const Size(1280, 800)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsRepositoryProvider.overrideWith(
            (ref) => InMemorySettingsRepository(initial: ajustes),
          ),
          // La fábrica de producción salvo el directorio del diario, la
          // interfaz de escucha (solo 127.0.0.1: sin aviso del cortafuegos)
          // y el descubrimiento UDP (apagado).
          hostRuntimeFactoryProvider.overrideWithValue((ref, settings) async {
            final runtime = await HostRuntime.create(
              settings: settings,
              stateRepo: FileHostStateRepository(banco.directorio),
              api: api,
              runner: ref.read(isolateRunnerProvider),
              bindAddress: InternetAddress.loopbackIPv4,
              discoveryEnabled: false,
            );
            banco._runtime = runtime;
            return runtime;
          }),
        ],
        child: const TpvComanderoApp(),
      ),
    );
    await _esperarA(
      tester,
      () => banco._runtime?.isRunning ?? false,
      'el runtime del host arranca',
    );
    await _esperarA(
      tester,
      () => banco.runtime.catalog.disponible,
      'el catálogo se descarga del ERP',
    );
    await _esperarClave(tester, 'mesa-m1');
    return banco;
  }

  /// Diario guardado en disco (lo que sobreviviría a un reinicio).
  Future<HostSnapshot> diarioEnDisco() async {
    final snapshot = await FileHostStateRepository(directorio).load();
    if (snapshot == null) throw TestFailure('El diario no está en disco');
    return snapshot;
  }

  /// Desmonta la app y cierra el runtime; idempotente.
  ///
  /// Red de seguridad: la interfaz primero y el cierre con plazo, para que
  /// un cierre colgado (como el de los oyentes en pausa, ya corregido y
  /// comprobado en el paso 8) sea un fallo explícito en lugar de agotar el
  /// tiempo de la prueba.
  Future<void> desmontar(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 100));
    await _runtime?.dispose().timeout(_limitePaso);
  }

  Future<void> _liberar() async {
    await tickets.close();
    await cocina.close();
    await barra.close();
    if (directorio.existsSync()) await directorio.delete(recursive: true);
  }
}

/// Cobra la mesa abierta en efectivo con [billeteCents] (o el importe
/// exacto si es nulo) y espera al diálogo de resultado.
Future<void> _cobrarEnEfectivo(WidgetTester tester, {int? billeteCents}) async {
  await _tocar(tester, 'cobrar');
  await _esperarClave(tester, 'cobro-confirmar');
  if (billeteCents != null) await _tocar(tester, 'billete-$billeteCents');
  await _tocar(tester, 'cobro-confirmar');
  await _esperarA(
    tester,
    () => find.text('Ticket nº 1 cobrado').evaluate().isNotEmpty,
    'el diálogo de resultado del cobro',
  );
}

/// Espera a que el diálogo de resultado muestre la factura de FS y a que
/// «Imprimir factura» se active; devuelve el código.
Future<String> _esperarFactura(WidgetTester tester) async {
  await _esperarA(
    tester,
    () =>
        _clave('resultado-factura').evaluate().isNotEmpty &&
        (_textoClave(tester, 'resultado-factura') ?? '').startsWith(
          'Factura F',
        ) &&
        _botonActivo(tester, 'imprimir-factura'),
    'la factura llega de FacturaScripts y se puede imprimir',
    limite: const Duration(seconds: 60),
  );
  return _textoClave(tester, 'resultado-factura')!.substring('Factura '.length);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('flujo de mesa con pases, precuenta, cobro en efectivo y factura '
      'ORIGINAL y DUPLICADO por impresoras TCP reales y un ERP simulado', (
    tester,
  ) async {
    final erp = ErpSimulado.crear();
    final banco = await _Banco.montar(
      tester,
      api: erp,
      codcliente: 'TPVVARIOS',
      codalmacen: 'ALG',
    );

    // 1. Mesa 1 con 4 comensales y un plato por pase.
    await _tocar(tester, 'mesa-m1');
    await _esperarClave(tester, 'articulo-ENSALADA');
    await _tocar(tester, 'editar-comensales');
    await _tocar(tester, 'comensales-4');
    await _tocar(tester, 'pase-1');
    await _tocar(tester, 'articulo-ENSALADA');
    await _tocar(tester, 'pase-2');
    await _tocar(tester, 'articulo-ENTRECOT');
    await _tocar(tester, 'pase-directo');
    await _tocar(tester, 'articulo-REFRESCO');
    expect(_clave('pendientes-pase-1'), findsOneWidget);
    expect(_clave('pendientes-pase-2'), findsOneWidget);
    expect(_clave('pendientes-pase-directo'), findsOneWidget);
    await _tocar(tester, 'enviar-pendientes');

    final comandaCocina = await _esperarTrabajo(
      tester,
      banco.cocina,
      1,
      'la comanda llega a la cocina',
    );
    expect(comandaCocina, contains('COMANDA Nº 1'));
    expect(comandaCocina, contains('Ensalada mixta'));
    expect(comandaCocina, contains('Entrecot'));
    expect(comandaCocina, contains('2. SEGUNDOS · ESPERAR'));
    expect(comandaCocina, isNot(contains('1. PRIMEROS · ESPERAR')));
    expect(comandaCocina, isNot(contains('Refresco')));
    final comandaBarra = await _esperarTrabajo(
      tester,
      banco.barra,
      1,
      'la comanda llega a la barra',
    );
    expect(comandaBarra, contains('COMANDA Nº 1'));
    expect(comandaBarra, contains('Refresco'));
    expect(comandaBarra, isNot(contains('Entrecot')));
    expect(_clave('comanda-pase-1'), findsOneWidget);
    expect(_clave('comanda-pase-2'), findsOneWidget);

    // 2. Marchar los Segundos.
    await _tocar(tester, 'marchar-2');
    final marchar = await _esperarTrabajo(
      tester,
      banco.cocina,
      2,
      'el MARCHAR llega a la cocina',
    );
    expect(marchar, contains('MARCHAR SEGUNDOS'));
    expect(marchar, contains('Entrecot'));
    expect(marchar, isNot(contains('Ensalada mixta')));
    // La marcha está en el diario en disco (con la automática de Primeros).
    final comandaEnDisco = (await banco.diarioEnDisco()).comandas.singleWhere(
      (c) => c.mesaId == 'm1',
    );
    expect(comandaEnDisco.comensales, 4);
    expect(
      comandaEnDisco.marchas.map((m) => (m.pase, m.automatica)),
      containsAll([(1, true), (2, false)]),
    );

    // 3. Precuenta.
    await _tocar(tester, 'precuenta');
    final precuenta = await _esperarTrabajo(
      tester,
      banco.tickets,
      1,
      'la precuenta llega a la impresora de tickets',
    );
    expect(precuenta, contains('PRECUENTA Nº 1'));
    expect(precuenta, contains('NO VÁLIDO COMO FACTURA'));
    expect(precuenta, contains('Entrecot'));
    expect(precuenta, contains(formatCents(_totalMesaCents)));

    // 4. Cobro en efectivo con un billete de 50 €.
    await _tocar(tester, 'cobrar');
    await _esperarClave(tester, 'cobro-total');
    expect(_textoClave(tester, 'cobro-total'), formatCents(_totalMesaCents));
    await tester.tap(find.text('Cancelar'));
    await _frames(tester);
    await _cobrarEnEfectivo(tester, billeteCents: 5000);
    expect(
      _textoClave(tester, 'resultado-cambio'),
      contains(formatCents(5000 - _totalMesaCents)),
    );
    final textoProvisional = await _esperarTrabajo(
      tester,
      banco.tickets,
      2,
      'el documento provisional llega a la impresora de tickets',
    );
    final provisional = decodeEscPos(banco.tickets.jobs[1]);
    expect(textoProvisional, contains('NO VÁLIDO COMO FACTURA'));
    expect(textoProvisional, contains('Ticket nº 1'));
    expect(textoProvisional, isNot(contains('DUPLICADO')));
    // El pulso del cajón va antes de cualquier línea de texto.
    final primerCajon = provisional.elements.indexWhere(
      (e) => e is ElementoMarca && e.comando.name == 'drawer',
    );
    final primerTexto = provisional.elements.indexWhere(
      (e) => e is ElementoTexto,
    );
    expect(primerCajon, isNonNegative, reason: 'sin pulso del cajón');
    expect(primerCajon, lessThan(primerTexto));

    // 5. La factura llega del ERP: ORIGINAL y después DUPLICADO.
    final codigo = await _esperarFactura(tester);
    expect(codigo, matches(RegExp(r'^F\d{4}S1$')));
    await _tocar(tester, 'imprimir-factura');
    final original = await _esperarTrabajo(
      tester,
      banco.tickets,
      3,
      'el ORIGINAL de la factura llega a la impresora',
    );
    expect(original, contains('Nº $codigo'));
    expect(original, contains(kNifEmisorSimulado));
    expect(original, isNot(contains('DUPLICADO')));
    expect(original, isNot(contains('NO VÁLIDO COMO FACTURA')));
    expect(decodeEscPos(banco.tickets.jobs[2]).named('drawer'), isEmpty);

    await _esperarA(
      tester,
      () => _botonActivo(tester, 'imprimir-factura'),
      '«Imprimir duplicado» se activa',
    );
    expect(
      find.descendant(
        of: _clave('imprimir-factura'),
        matching: find.text('Imprimir duplicado'),
      ),
      findsOneWidget,
    );
    await _tocar(tester, 'imprimir-factura');
    final duplicado = await _esperarTrabajo(
      tester,
      banco.tickets,
      4,
      'el DUPLICADO de la factura llega a la impresora',
    );
    expect(duplicado, contains('Nº $codigo'));
    expect(duplicado, contains('DUPLICADO'));
    expect(duplicado, contains('Duplicado nº 1'));
    await _esperarA(
      tester,
      () =>
          _textoClave(tester, 'resultado-impresion') ==
          'Factura impresa (original) · 1 duplicado',
      'el resultado muestra el ORIGINAL y 1 duplicado',
    );

    // 6. Caja y Cierre Z: detalle del ticket desde su fila.
    await _tocar(tester, 'volver-salon');
    await _esperarClave(tester, 'accion-cierre-z');
    await _tocar(tester, 'accion-cierre-z');
    final ticketId = banco.runtime.store.snapshot.ticketsTurno.single.id;
    await _tocar(tester, 'ticket-$ticketId');
    await _esperarClave(tester, 'detalle-impresion');
    expect(_textoClave(tester, 'detalle-titulo'), 'Ticket nº 1');
    expect(_textoClave(tester, 'detalle-factura'), 'Factura $codigo');
    final impresionDetalle = _textoClave(tester, 'detalle-impresion')!;
    expect(impresionDetalle, contains('Provisional impreso'));
    expect(impresionDetalle, contains('Original impreso'));
    expect(impresionDetalle, contains('Duplicados: 1'));
    expect(_clave('detalle-precuenta-1'), findsOneWidget);
    await _tocar(tester, 'detalle-cerrar');

    // 7. Verificación fuera de la interfaz.
    await banco.runtime.printing.idle();
    await banco.runtime.outbox.idle();
    final diario = await banco.diarioEnDisco();
    expect(diario.comandas.where((c) => c.mesaId == 'm1'), isEmpty);
    final ticket = diario.ticketsTurno.single;
    expect(ticket.numeroLocal, 1);
    expect(ticket.comensales, 4);
    expect(ticket.totalCents, _totalMesaCents);
    expect(ticket.metodoPago, MetodoPago.efectivo);
    expect(ticket.precuentas.single.numero, 1);
    expect(ticket.precuentas.single.totales.totalCents, _totalMesaCents);
    expect(ticket.factura?.estado, EstadoSincronizacion.sincronizado);
    expect(ticket.factura?.codigo, codigo);
    expect(ticket.factura?.totalFsCents, _totalMesaCents);
    expect(ticket.impresion.provisionalEn, isNotNull);
    expect(ticket.impresion.facturaOriginalEn, isNotNull);
    expect(ticket.impresion.duplicados, 1);

    final factura = erp.facturas.single;
    expect(factura['codigo'], codigo);
    expect(factura['total'], _totalMesaCents / 100);
    expect(factura['pagada'], isTrue);
    expect('${factura['numero2']}', startsWith('TPV-'));

    expect(banco.cocina.jobs, hasLength(2), reason: 'comanda y MARCHAR');
    expect(banco.barra.jobs, hasLength(1), reason: 'comanda');
    expect(
      banco.tickets.jobs,
      hasLength(4),
      reason: 'precuenta, provisional, ORIGINAL y DUPLICADO',
    );

    // 8. El runtime se cierra con la interfaz montada y la Mesa 1 abierta
    // encima del salón: Riverpod tiene en pausa las suscripciones del salón
    // a los streams del runtime y, antes del arreglo, `dispose` se quedaba
    // esperando a que les llegara el «done».
    await tester.tap(find.byType(BackButton));
    await _frames(tester);
    await _tocar(tester, 'mesa-m1');
    await _esperarClave(tester, 'articulo-ENSALADA');
    await expectLater(
      banco.runtime.dispose().timeout(const Duration(seconds: 10)),
      completes,
    );
    expect(banco.runtime.isRunning, isFalse);

    await banco.desmontar(tester);
  }, timeout: const Timeout(Duration(minutes: 5)));

  testWidgets(
    'cobro en efectivo con un FacturaScripts DE PRUEBAS real: la factura '
    'llega y se imprime el ORIGINAL',
    (tester) async {
      final config = FsApiConfig(baseUrl: _fsBaseUrl, token: _fsToken);
      final banco = await _Banco.montar(
        tester,
        erpReal: config,
        codcliente: _fsCodcliente,
        codalmacen: _fsCodalmacen,
      );
      // Limpieza de la factura de prueba (se registra antes de crearla: los
      // `addTearDown` se ejecutan en orden inverso, antes de cerrar el
      // banco).
      int? idfactura;
      addTearDown(() async {
        final id = idfactura;
        if (id == null) return;
        final api = FsHttpApi(config);
        try {
          final borrada = await api.delete(FsResources.facturaClientes, id);
          if (!borrada) {
            throw TestFailure('La factura de prueba $id ya no existía');
          }
        } finally {
          await api.close();
        }
      });

      final catalogo = banco.runtime.store.snapshot.catalogo;
      final referencia = _fsRef.isNotEmpty
          ? _fsRef
          : catalogo?.vendibles.first.referencia;
      if (referencia == null) {
        throw TestFailure('El ERP de pruebas no tiene artículos vendibles');
      }

      await _tocar(tester, 'mesa-m2');
      await _tocar(tester, 'articulo-$referencia');
      await _tocar(tester, 'enviar-pendientes');
      await _cobrarEnEfectivo(tester);
      await _esperarA(
        tester,
        () => banco.tickets.jobs.isNotEmpty,
        'el documento provisional llega a la impresora de tickets',
      );
      idfactura =
          banco.runtime.store.snapshot.ticketsTurno.single.factura?.idfactura;

      final codigo = await _esperarFactura(tester);
      idfactura =
          banco.runtime.store.snapshot.ticketsTurno.single.factura?.idfactura;
      await _tocar(tester, 'imprimir-factura');
      final original = await _esperarTrabajo(
        tester,
        banco.tickets,
        2,
        'el ORIGINAL de la factura llega a la impresora',
      );
      expect(original, contains('Nº $codigo'));
      expect(original, isNot(contains('DUPLICADO')));

      await banco.desmontar(tester);
    },
    skip: _fsBaseUrl.isEmpty || _fsToken.isEmpty,
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
