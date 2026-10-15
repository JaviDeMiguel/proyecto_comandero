/// Impresión de los documentos de preparación (§5.2, §5.7, §5.9 y §5.10 del
/// diseño de impresión): un ticket por puesto con el perfil de la impresora
/// que lo imprime, el respaldo barra → cocina, los grupos por pase, el
/// MARCHAR, la anulación, la reimpresión y el aislamiento por puesto.
library;

import 'dart:math';
import 'dart:typed_data';

import 'package:proyecto_comandero/core/errors/app_exception.dart';
import 'package:proyecto_comandero/core/isolates/escpos/escpos.dart';
import 'package:proyecto_comandero/core/isolates/isolate_runner.dart';
import 'package:proyecto_comandero/core/network/printing/print_queue.dart'
    show PrintRetryPolicy;
import 'package:proyecto_comandero/core/network/printing/raw_printer_transport.dart';
import 'package:proyecto_comandero/features/host/application/alert_bus.dart';
import 'package:proyecto_comandero/features/host/application/impresion/canal_impresion.dart';
import 'package:proyecto_comandero/features/host/application/impresion/comandas_impresion.dart';
import 'package:proyecto_comandero/features/host/application/impresion/mapeo_documentos.dart';
import 'package:proyecto_comandero/features/host/application/ports.dart';
import 'package:proyecto_comandero/features/host/domain/host_settings.dart';
import 'package:proyecto_comandero/features/host/domain/operational_alert.dart';
import 'package:proyecto_comandero/features/impresion/domain/formato_impresion.dart';
import 'package:proyecto_comandero/features/sala/domain/comanda.dart';
import 'package:proyecto_comandero/features/sala/domain/linea_comanda.dart';
import 'package:proyecto_comandero/features/sala/domain/marcha_pase.dart';
import 'package:proyecto_comandero/features/sala/domain/mesa.dart';
import 'package:proyecto_comandero/features/sala/domain/pases.dart';
import 'package:test/test.dart';

import '../../../core/isolates/escpos/escpos_decoder.dart';
import '../fakes/fake_ports.dart';

final cocina = PrinterEndpoint('10.0.0.10');
final barra = PrinterEndpoint('10.0.0.11');
final tickets = PrinterEndpoint('10.0.0.12');

final abierta = DateTime(2026, 10, 9, 21, 2);
final aceptada = DateTime(2026, 10, 9, 21, 14);
final segundoEnvio = DateTime(2026, 10, 9, 21, 30);
final reimpresa = DateTime(2026, 10, 9, 21, 40);
final marchaSegundos = DateTime(2026, 10, 9, 21, 52);

const enCocina = DestinoPreparacion.cocina;
const enBarra = DestinoPreparacion.barra;

const mesa7 = Mesa(id: 'm7', nombre: 'Mesa 7', zona: 'Terraza');

/// Mesa de nombre numérico: los textos la nombran «Mesa 3».
const mesa3 = Mesa(id: 'm3', nombre: '3');

/// Línea aceptada en el envío [envio] (12 por defecto) a las 21:14.
LineaComanda lc(
  String id,
  String descripcion, {
  double cantidad = 1,
  DestinoPreparacion destino = enCocina,
  int? pase,
  int? envio = 12,
  String? nota,
  DateTime? creadaEn,
  String? camarero,
}) => LineaComanda(
  id: id,
  referencia: id.toUpperCase(),
  descripcion: descripcion,
  cantidad: cantidad,
  pvpUnitarioCents: 500,
  pvpUnitarioNeto: 4.54545,
  ivaBp: 1000,
  codimpuesto: 'IVA10',
  nota: nota,
  destino: destino,
  pase: pase,
  envio: envio,
  creadaEn: creadaEn ?? aceptada,
  camarero: camarero,
);

/// Comanda de la mesa 7 abierta a las 21:02 por Ana, con 4 comensales.
Comanda comandaCon(
  List<LineaComanda> lineas, {
  List<MarchaPase> marchas = const [],
}) => Comanda(
  id: 'c7',
  mesaId: 'm7',
  abiertaEn: abierta,
  lineas: lineas,
  camarero: 'Ana',
  comensales: 4,
  marchas: marchas,
);

/// Comanda con dos envíos: el 12 (croquetas de primero, marchadas solas al
/// enviar, y dos cañas) y el 15 (entrecot de segundo, sin marchar, y un
/// agua), más una sopa anulada.
Comanda dosEnvios() => comandaCon(
  [
    lc('c1', 'Croquetas de jamón', pase: 1),
    lc('b1', 'Caña', cantidad: 2, destino: enBarra),
    lc('c2', 'Sopa castellana', pase: 1).anular(cuando: segundoEnvio),
    lc('c3', 'Entrecot a la brasa', pase: 2, envio: 15, creadaEn: segundoEnvio),
    lc(
      'b2',
      'Agua con gas',
      destino: enBarra,
      envio: 15,
      creadaEn: segundoEnvio,
    ),
  ],
  marchas: [
    MarchaPase(id: 'auto-1', pase: 1, cuando: aceptada, automatica: true),
  ],
);

String textoDe(Uint8List bytes) => decodeEscPos(bytes).texts.join('|');

/// Líneas en blanco con las que empieza el papel (`ESC d n` tras el init), o
/// `null` si empieza directamente con el texto.
int? avanceInicialDe(Uint8List bytes) {
  final primero = decodeEscPos(bytes).elements.first;
  return primero is ElementoMarca && primero.comando.name == 'feed'
      ? primero.comando.args.single
      : null;
}

/// Anchura impresa de la línea más ancha: la del separador, que ocupa todo
/// el papel.
int anchoDe(Uint8List bytes) =>
    decodeEscPos(bytes).lines.map((linea) => linea.printedWidth).reduce(max);

/// Primera línea impresa que contiene [texto].
DecodedLine lineaCon(Uint8List bytes, String texto) =>
    decodeEscPos(bytes).lines.firstWhere((linea) => linea.text.contains(texto));

/// Los [textos] se imprimen todos y en ese orden.
void expectEnOrden(Uint8List bytes, List<String> textos) {
  final lineas = decodeEscPos(bytes).texts;
  final indices = [
    for (final texto in textos) lineas.indexWhere((l) => l.contains(texto)),
  ];
  expect(indices, everyElement(isNonNegative), reason: '$textos');
  expect(indices, orderedEquals([...indices]..sort()), reason: '$textos');
}

/// Ejecuta en línea salvo las llamadas (base 1) que indica [falla], que
/// terminan con un error no tipado, como un isolate que no arranca.
final class _RunnerQueFalla implements IsolateRunner {
  _RunnerQueFalla({bool Function(int llamada)? falla})
    : _falla = falla ?? ((llamada) => llamada == 1);

  final bool Function(int llamada) _falla;
  int llamadas = 0;

  @override
  Future<R> run<M, R>(
    IsolateEntryPoint<M, R> entryPoint,
    M message, {
    String? debugName,
  }) {
    llamadas++;
    if (_falla(llamadas)) return Future<R>.error(StateError('isolate caído'));
    return const InlineIsolateRunner().run(
      entryPoint,
      message,
      debugName: debugName,
    );
  }
}

void main() {
  late AlertBus alerts;
  late FakePrinterPort printer;
  late PrinterPort? puerto;
  late ImpresionSettings settings;
  late DateTime reloj;
  late CanalImpresion canal;
  late ComandasImpresion comandas;

  /// Colaborador sobre un canal nuevo con [runner]. El canal y el colaborador
  /// leen los ajustes, la cola y el reloj vigentes en cada llamada.
  ComandasImpresion crear({
    IsolateRunner runner = const InlineIsolateRunner(),
  }) {
    canal = CanalImpresion(
      alerts: alerts,
      runner: runner,
      settings: () => settings,
      printer: () => puerto,
    );
    return ComandasImpresion(
      canal: canal,
      alerts: alerts,
      settings: () => settings,
      now: () => reloj,
    );
  }

  setUp(() {
    reloj = aceptada;
    alerts = AlertBus(now: () => reloj);
    printer = FakePrinterPort();
    puerto = printer;
    settings = ImpresionSettings(
      tickets: tickets,
      cocina: cocina,
      barra: barra,
    );
    comandas = crear();
  });

  tearDown(() async {
    await canal.idle();
    await alerts.dispose();
  });

  PrintedJob trabajoEn(PrinterEndpoint endpoint) =>
      printer.jobs.singleWhere((job) => job.endpoint == endpoint);

  group('comanda de un envío', () {
    test('un ticket por puesto con solo sus líneas, la cabecera del envío con '
        'la hora del reloj y el nº de envío en la descripción', () async {
      final nuevas = [
        lc('c1', 'Croquetas de jamón', cantidad: 2),
        lc('b1', 'Caña', cantidad: 4, destino: enBarra),
        lc('c2', 'Ensalada de ventresca', nota: 'sin cebolla'),
      ];
      // La cabecera lleva la hora del reloj al aceptar (§5.2), no la de las
      // líneas (21:14).
      reloj = DateTime(2026, 10, 9, 21, 16);

      await comandas.imprimirEnvio(mesa7, comandaCon(nuevas), nuevas);

      expect(printer.jobs.map((job) => job.endpoint), [cocina, barra]);
      final deCocina = trabajoEn(cocina);
      expect(deCocina.description, 'Comanda Nº 12 · Mesa 7 · cocina');
      expect(deCocina.reintento, PrintRetryPolicy.always);
      final textoCocina = textoDe(deCocina.bytes);
      expect(textoCocina, startsWith('COCINA|Mesa 7|Terraza'));
      expect(textoCocina, contains('COMANDA Nº 12 · 21:16'));
      expect(textoCocina, contains('Camarero: Ana'));
      expect(textoCocina, contains('4 comensales'));
      expect(textoCocina, contains('1º envío de la mesa · abierta 21:02'));
      expect(textoCocina, contains('2 x Croquetas de jamón'));
      expect(textoCocina, contains('1 x Ensalada de ventresca'));
      expect(textoCocina, contains('   > sin cebolla'));
      expect(textoCocina, isNot(contains('Caña')));
      expect(textoCocina, isNot(contains('Sin impresora')));

      final deBarra = trabajoEn(barra);
      expect(deBarra.description, 'Comanda Nº 12 · Mesa 7 · barra');
      final textoBarra = textoDe(deBarra.bytes);
      expect(textoBarra, startsWith('BARRA'));
      expect(textoBarra, contains('4 x Caña'));
      expect(textoBarra, isNot(contains('Croquetas')));
      expect(alerts.recientes, isEmpty);
    });

    test('las líneas sin nº de envío (diario anterior) salen como «COMANDA · '
        'hh:mm» y la mesa numérica como «Mesa N»', () async {
      final nuevas = [lc('c1', 'Paella', envio: null)];

      await comandas.imprimirEnvio(mesa3, comandaCon(nuevas), nuevas);

      final job = printer.jobs.single;
      expect(job.description, 'Comanda Mesa 3 · cocina');
      expect(textoDe(job.bytes), contains('COMANDA · 21:14'));
    });

    test('papel por impresora: la cocina a 58 mm y la barra, que imprime en '
        'la impresora de los tickets, a 80', () async {
      settings = ImpresionSettings(
        tickets: tickets,
        cocina: cocina,
        barra: tickets,
        // Papel heredado: el de una impresora sin perfil.
        paper: PaperWidth.mm58,
        formato: FormatoImpresion(
          perfiles: {
            RolImpresora.cocina: PerfilImpresora(
              papel: PaperWidth.mm58,
              direccion: claveImpresora(cocina),
            ),
            RolImpresora.tickets: PerfilImpresora(
              direccion: claveImpresora(tickets),
            ),
          },
        ),
      );
      final nuevas = [
        lc('c1', 'Croquetas de jamón'),
        lc('b1', 'Caña', destino: enBarra),
      ];

      await comandas.imprimirEnvio(mesa7, comandaCon(nuevas), nuevas);

      final deCocina = trabajoEn(cocina).bytes;
      expect(anchoDe(deCocina), PaperWidth.mm58.columns);
      expectWidthsWithin(decodeEscPos(deCocina), PaperWidth.mm58);
      final deBarra = trabajoEn(tickets).bytes;
      expect(textoDe(deBarra), startsWith('BARRA'));
      expect(anchoDe(deBarra), PaperWidth.mm80.columns);
    });

    test('sin impresora de barra, su comanda sale aparte por la de cocina con '
        'el perfil de cocina (papel, avance, copias y aviso) y la nota de '
        'respaldo', () async {
      settings = ImpresionSettings(
        tickets: tickets,
        cocina: cocina,
        formato: FormatoImpresion(
          perfiles: {
            RolImpresora.cocina: PerfilImpresora(
              papel: PaperWidth.mm58,
              lineasIniciales: 2,
              copias: 2,
              zumbador: ZumbadorModo.generico,
              pitidos: 3,
              direccion: claveImpresora(cocina),
            ),
            // No cuenta: la barra no tiene impresora propia.
            RolImpresora.barra: const PerfilImpresora(
              lineasIniciales: 5,
              copias: 3,
            ),
          },
        ),
      );
      final nuevas = [
        lc('c1', 'Croquetas de jamón'),
        lc('b1', 'Caña', cantidad: 4, destino: enBarra),
      ];

      await comandas.imprimirEnvio(mesa7, comandaCon(nuevas), nuevas);

      expect(printer.jobs, hasLength(2));
      expect(printer.jobs.map((job) => job.endpoint), everyElement(cocina));
      final deBarra = printer.jobs.singleWhere(
        (job) => job.description.endsWith('barra'),
      );
      expect(deBarra.description, 'Comanda Nº 12 · Mesa 7 · barra');
      final decoded = decodeEscPos(deBarra.bytes);
      expect(decoded.texts.first, 'BARRA');
      final texto = textoDe(deBarra.bytes);
      expect(texto, contains('4 x Caña'));
      expect(texto, isNot(contains('Croquetas')));
      // A 58 mm la nota se parte en dos líneas.
      expect(
        decoded.texts.join(' '),
        contains('Sin impresora de barra: llevar a barra'),
      );
      expect(avanceInicialDe(deBarra.bytes), 2);
      expect(decoded.named('cut'), hasLength(2));
      expect(decoded.named('beep'), hasLength(1));
      expect(decoded.commands.last.name, 'beep');
      expect(anchoDe(deBarra.bytes), PaperWidth.mm58.columns);

      final deCocina = printer.jobs.singleWhere(
        (job) => job.description.endsWith('cocina'),
      );
      expect(textoDe(deCocina.bytes), isNot(contains('Sin impresora')));
    });

    test('avance inicial: con 3 líneas en el perfil de cocina el trabajo '
        'empieza con feed 3; con 0 en el de barra, sin feed', () async {
      settings = ImpresionSettings(
        tickets: tickets,
        cocina: cocina,
        barra: barra,
        formato: FormatoImpresion(
          perfiles: {
            RolImpresora.cocina: PerfilImpresora(
              lineasIniciales: 3,
              direccion: claveImpresora(cocina),
            ),
            RolImpresora.barra: PerfilImpresora(
              direccion: claveImpresora(barra),
            ),
          },
        ),
      );
      final nuevas = [
        lc('c1', 'Croquetas de jamón'),
        lc('b1', 'Caña', destino: enBarra),
      ];

      await comandas.imprimirEnvio(mesa7, comandaCon(nuevas), nuevas);

      expect(avanceInicialDe(trabajoEn(cocina).bytes), 3);
      final deBarra = trabajoEn(barra).bytes;
      expect(avanceInicialDe(deBarra), isNull);
      expect(decodeEscPos(deBarra).elements.first, isA<ElementoTexto>());
    });

    test('con los pases activos agrupa por pase: DIRECTO, el pase marchado '
        '(por la marcha automática del envío) normal y los demás en ESPERAR, '
        'sin imprimir ningún MARCHAR', () async {
      final nuevas = [
        lc('c1', 'Pan con tomate'),
        lc('c2', 'Entrecot a la brasa', pase: 2),
        lc('c3', 'Croquetas de jamón', pase: 1),
        lc('c4', 'Tarta de queso', pase: 4),
      ];
      // La marcha automática va en la misma escritura que las líneas: la
      // comanda llega ya con ella.
      final comanda = comandaCon(
        nuevas,
        marchas: [
          MarchaPase(id: 'auto-1', pase: 1, cuando: aceptada, automatica: true),
        ],
      );

      await comandas.imprimirEnvio(mesa7, comanda, nuevas);

      final bytes = printer.jobs.single.bytes;
      expectEnOrden(bytes, [
        'DIRECTO',
        '1 x Pan con tomate',
        '1. PRIMEROS',
        '1 x Croquetas de jamón',
        '2. SEGUNDOS · ESPERAR',
        '1 x Entrecot a la brasa',
        '4. PASE 4 · ESPERAR',
        '1 x Tarta de queso',
      ]);
      final primeros = lineaCon(bytes, '1. PRIMEROS');
      expect(primeros.text, isNot(contains('ESPERAR')));
      expect(primeros.inverse, isFalse);
      expect(lineaCon(bytes, '2. SEGUNDOS · ESPERAR').inverse, isTrue);
      expect(textoDe(bytes), isNot(contains('MARCHAR')));
    });

    test(
      'sin pases activos la comanda sale plana, en el orden de llegada',
      () async {
        settings = ImpresionSettings(
          tickets: tickets,
          cocina: cocina,
          barra: barra,
          formato: const FormatoImpresion(pases: PasesConfig(activos: false)),
        );
        final nuevas = [
          lc('c1', 'Pan con tomate'),
          lc('c2', 'Entrecot a la brasa', pase: 2),
          lc('c3', 'Croquetas de jamón', pase: 1),
        ];

        await comandas.imprimirEnvio(mesa7, comandaCon(nuevas), nuevas);

        final bytes = printer.jobs.single.bytes;
        final texto = textoDe(bytes);
        for (final rotulo in ['DIRECTO', 'PRIMEROS', 'SEGUNDOS', 'ESPERAR']) {
          expect(texto, isNot(contains(rotulo)));
        }
        expectEnOrden(bytes, [
          '1 x Pan con tomate',
          '1 x Entrecot a la brasa',
          '1 x Croquetas de jamón',
        ]);
      },
    );

    test('un fallo no tipado al generar la comanda de cocina no impide la de '
        'barra y avisa del puesto que falló', () async {
      final runner = _RunnerQueFalla();
      comandas = crear(runner: runner);
      final nuevas = [lc('c1', 'Paella'), lc('b1', 'Caña', destino: enBarra)];

      await comandas.imprimirEnvio(mesa7, comandaCon(nuevas), nuevas);

      expect(runner.llamadas, 2);
      expect(printer.jobs.single.endpoint, barra);
      expect(textoDe(printer.jobs.single.bytes), contains('Caña'));
      final aviso = alerts.recientes.single;
      expect(
        aviso.titulo,
        'No se pudo imprimir la comanda de cocina de Mesa 7',
      );
      expect(aviso.detalle, contains('isolate caído'));
      expect(aviso.origen, 'impresion');
      expect(aviso.nivel, AlertaNivel.error);
    });

    test('un dato que el generador rechaza lo avisa el canal una sola vez y el '
        'otro puesto imprime', () async {
      final nuevas = [
        lc('c1', 'Paella', cantidad: 0),
        lc('b1', 'Caña', destino: enBarra),
      ];

      await comandas.imprimirEnvio(mesa7, comandaCon(nuevas), nuevas);

      expect(printer.jobs.single.endpoint, barra);
      final aviso = alerts.recientes.single;
      expect(
        aviso.titulo,
        'No se pudo generar "Comanda Nº 12 · Mesa 7 · cocina"',
      );
      expect(aviso.origen, 'impresion');
    });
  });

  group('MARCHAR', () {
    test('un MARCHAR por puesto con solo las líneas activas de ese pase; un '
        'puesto sin líneas del pase no imprime nada', () async {
      final entrecot = lc(
        'c1',
        'Entrecot a la brasa',
        cantidad: 2,
        pase: 2,
        nota: '1 poco hecho, 1 al punto',
      );
      final lubina = lc('c2', 'Lubina a la sal', pase: 2);
      final vino = lc('b1', 'Copa de vino tinto', pase: 2, destino: enBarra);
      final croquetas = lc('c3', 'Croquetas de jamón', pase: 1);
      final merluza = lc(
        'c4',
        'Merluza en salsa',
        pase: 2,
      ).anular(cuando: segundoEnvio);
      final segundos = MarchaPase(
        id: 'm-2',
        pase: 2,
        cuando: marchaSegundos,
        camarero: 'Luis',
      );
      final comanda = comandaCon(
        [entrecot, lubina, vino, croquetas, merluza],
        marchas: [segundos],
      );

      // La sala pasa las líneas activas del pase; las anuladas y las de otro
      // pase no salen aunque lleguen.
      await comandas.imprimirMarcha(mesa7, comanda, segundos, comanda.lineas);

      expect(printer.jobs.map((job) => job.endpoint), [cocina, barra]);
      final deCocina = trabajoEn(cocina);
      expect(deCocina.description, 'Marchar Segundos · Mesa 7 · cocina');
      expect(deCocina.reintento, PrintRetryPolicy.always);
      final bytes = deCocina.bytes;
      final texto = textoDe(bytes);
      expect(texto, startsWith('COCINA'));
      expect(lineaCon(bytes, 'MARCHAR SEGUNDOS').inverse, isTrue);
      expect(texto, contains('Comanda nº 12 (21:14)'));
      expect(texto, contains('Marcha 21:52'));
      expect(texto, contains('Camarero: Luis'));
      expect(texto, contains('2 x Entrecot a la brasa'));
      expect(texto, contains('   > 1 poco hecho, 1 al punto'));
      expect(texto, contains('1 x Lubina a la sal'));
      for (final ajena in [
        'Copa de vino',
        'Croquetas',
        'Merluza',
        'REPETIDO',
      ]) {
        expect(texto, isNot(contains(ajena)));
      }
      final deBarra = trabajoEn(barra);
      expect(deBarra.description, 'Marchar Segundos · Mesa 7 · barra');
      expect(textoDe(deBarra.bytes), contains('1 x Copa de vino tinto'));
      expect(textoDe(deBarra.bytes), isNot(contains('Entrecot')));

      printer.jobs.clear();
      final primeros = MarchaPase(id: 'm-1', pase: 1, cuando: marchaSegundos);
      await comandas.imprimirMarcha(
        mesa7,
        comandaCon(comanda.lineas, marchas: [segundos, primeros]),
        primeros,
        [croquetas],
      );
      expect(printer.jobs.single.endpoint, cocina);
      expect(
        printer.jobs.single.description,
        'Marchar Primeros · Mesa 7 · cocina',
      );
    });

    test('MARCHAR repetido: REPETIDO con la hora de la marcha anterior y, a '
        'la derecha, la de esta', () async {
      final entrecot = lc('c1', 'Entrecot a la brasa', pase: 2);
      final primera = MarchaPase(id: 'm-1', pase: 2, cuando: marchaSegundos);
      final otra = MarchaPase(
        id: 'm-2',
        pase: 2,
        cuando: DateTime(2026, 10, 9, 22, 5),
        repetida: true,
      );
      final comanda = comandaCon([entrecot], marchas: [primera, otra]);

      await comandas.imprimirMarcha(mesa7, comanda, otra, [entrecot]);

      final job = printer.jobs.single;
      expect(job.description, 'Marchar Segundos (repetido) · Mesa 7 · cocina');
      final texto = textoDe(job.bytes);
      expect(texto, contains('MARCHAR SEGUNDOS'));
      expect(texto, contains('REPETIDO · ya marchado a las 21:52'));
      expect(texto, contains('Marcha 22:05'));
    });

    test('sin impresora de barra, el MARCHAR de barra sale por la de cocina '
        'con su perfil (avance, copias y aviso) y la nota de respaldo; un '
        'pase fuera de la configuración se rotula «Pase N»', () async {
      settings = ImpresionSettings(
        tickets: tickets,
        cocina: cocina,
        formato: FormatoImpresion(
          perfiles: {
            RolImpresora.cocina: PerfilImpresora(
              lineasIniciales: 1,
              copias: 2,
              zumbador: ZumbadorModo.generico,
              direccion: claveImpresora(cocina),
            ),
          },
        ),
      );
      final cava = lc('b1', 'Copa de cava', pase: 4, destino: enBarra);
      final marcha = MarchaPase(id: 'm-4', pase: 4, cuando: marchaSegundos);

      await comandas.imprimirMarcha(
        mesa7,
        comandaCon([cava], marchas: [marcha]),
        marcha,
        [cava],
      );

      final job = printer.jobs.single;
      expect(job.endpoint, cocina);
      expect(job.description, 'Marchar Pase 4 · Mesa 7 · barra');
      final texto = textoDe(job.bytes);
      expect(texto, startsWith('BARRA'));
      expect(texto, contains('MARCHAR PASE 4'));
      expect(texto, contains('1 x Copa de cava'));
      expect(texto, contains('Sin impresora de barra: llevar a barra'));
      expect(avanceInicialDe(job.bytes), 1);
      final decoded = decodeEscPos(job.bytes);
      expect(decoded.named('cut'), hasLength(2));
      expect(decoded.named('beep'), hasLength(1));
      expect(decoded.commands.last.name, 'beep');
    });

    test('sin líneas activas del pase no imprime nada', () async {
      final merluza = lc(
        'c1',
        'Merluza en salsa',
        pase: 2,
      ).anular(cuando: segundoEnvio);
      final marcha = MarchaPase(id: 'm-2', pase: 2, cuando: marchaSegundos);

      await comandas.imprimirMarcha(
        mesa7,
        comandaCon([merluza], marchas: [marcha]),
        marcha,
        [merluza],
      );

      expect(printer.jobs, isEmpty);
      expect(alerts.recientes, isEmpty);
    });
  });

  group('anulación', () {
    test('una anulación por puesto con la cantidad en negativo, la nota '
        'original, el motivo y el envío, como documento de '
        'preparación', () async {
      settings = ImpresionSettings(
        tickets: tickets,
        cocina: cocina,
        barra: barra,
        formato: FormatoImpresion(
          perfiles: {
            RolImpresora.cocina: PerfilImpresora(
              lineasIniciales: 2,
              copias: 2,
              zumbador: ZumbadorModo.generico,
              direccion: claveImpresora(cocina),
            ),
          },
        ),
      );
      reloj = segundoEnvio;
      final lubina = lc(
        'c1',
        'Lubina a la sal',
        nota: 'sin sal',
      ).anular(cuando: segundoEnvio, motivo: 'el cliente cambia de plato');
      final canas = lc(
        'b1',
        'Caña',
        cantidad: 2,
        destino: enBarra,
      ).anular(cuando: segundoEnvio, motivo: 'vaciar');

      await comandas.imprimirAnulacion(mesa7, comandaCon([lubina, canas]), [
        lubina,
        canas,
      ]);

      expect(printer.jobs.map((job) => job.endpoint), [cocina, barra]);
      final deCocina = trabajoEn(cocina);
      expect(deCocina.description, 'Anulación Mesa 7 · cocina');
      expect(deCocina.reintento, PrintRetryPolicy.always);
      final decoded = decodeEscPos(deCocina.bytes);
      expect(
        decoded.lines.first.text.trimLeft(),
        startsWith('ANULACIÓN COCINA'),
      );
      expect(decoded.lines.first.inverse, isTrue);
      final texto = textoDe(deCocina.bytes);
      expect(texto, contains('Comanda nº 12 (21:14)'));
      expect(texto, contains('Anulada 21:30'));
      expect(texto, contains('-1 x Lubina a la sal'));
      expect(texto, contains('   > sin sal'));
      expect(texto, contains('Motivo: el cliente cambia de plato'));
      expect(texto, isNot(contains('Caña')));
      expect(avanceInicialDe(deCocina.bytes), 2);
      expect(decoded.named('cut'), hasLength(2));
      expect(decoded.commands.last.name, 'beep');

      final deBarra = trabajoEn(barra);
      expect(deBarra.description, 'Anulación Mesa 7 · barra');
      final textoBarra = textoDe(deBarra.bytes);
      expect(textoBarra.trimLeft(), startsWith('ANULACIÓN BARRA'));
      expect(textoBarra, contains('-2 x Caña'));
      expect(textoBarra, contains('Motivo: mesa vaciada'));
      expect(textoBarra, isNot(contains('Lubina')));
    });

    test('sin impresora de barra, la anulación de barra sale por la de cocina '
        'con la nota de respaldo', () async {
      settings = ImpresionSettings(tickets: tickets, cocina: cocina);
      final canas = lc('b1', 'Caña', destino: enBarra).anular(cuando: aceptada);

      await comandas.imprimirAnulacion(mesa7, comandaCon([canas]), [canas]);

      final job = printer.jobs.single;
      expect(job.endpoint, cocina);
      expect(job.description, 'Anulación Mesa 7 · barra');
      final texto = textoDe(job.bytes);
      expect(texto.trimLeft(), startsWith('ANULACIÓN BARRA'));
      expect(texto, contains('-1 x Caña'));
      expect(texto, contains('Sin impresora de barra: llevar a barra'));
      expect(texto, isNot(contains('Motivo')));
    });
  });

  group('impresiones automáticas', () {
    test('con la impresión de comandas desactivada no imprime la comanda, el '
        'MARCHAR ni la anulación', () async {
      settings = ImpresionSettings(
        tickets: tickets,
        cocina: cocina,
        barra: barra,
        imprimirComandas: false,
      );
      final entrecot = lc('c1', 'Entrecot a la brasa', pase: 2);
      final marcha = MarchaPase(id: 'm-2', pase: 2, cuando: marchaSegundos);
      final comanda = comandaCon([entrecot], marchas: [marcha]);

      await comandas.imprimirEnvio(mesa7, comanda, [entrecot]);
      await comandas.imprimirMarcha(mesa7, comanda, marcha, [entrecot]);
      await comandas.imprimirAnulacion(mesa7, comanda, [
        entrecot.anular(cuando: segundoEnvio),
      ]);

      expect(printer.jobs, isEmpty);
      expect(alerts.recientes, isEmpty);
    });

    test('sin impresora de cocina ni de barra, o sin líneas, no imprime ni '
        'avisa', () async {
      final entrecot = lc('c1', 'Entrecot a la brasa', pase: 2);
      final marcha = MarchaPase(id: 'm-2', pase: 2, cuando: marchaSegundos);
      final comanda = comandaCon([entrecot], marchas: [marcha]);

      await comandas.imprimirEnvio(mesa7, comanda, const []);
      await comandas.imprimirMarcha(mesa7, comanda, marcha, const []);
      await comandas.imprimirAnulacion(mesa7, comanda, const []);
      settings = ImpresionSettings(tickets: tickets);
      await comandas.imprimirEnvio(mesa7, comanda, [entrecot]);
      await comandas.imprimirMarcha(mesa7, comanda, marcha, [entrecot]);
      await comandas.imprimirAnulacion(mesa7, comanda, [
        entrecot.anular(cuando: segundoEnvio),
      ]);

      expect(printer.jobs, isEmpty);
      expect(alerts.recientes, isEmpty);
    });

    test('sin cola de impresión no imprime ni avisa', () async {
      puerto = null;
      final nuevas = [lc('c1', 'Paella')];

      await comandas.imprimirEnvio(mesa7, comandaCon(nuevas), nuevas);

      expect(printer.jobs, isEmpty);
      expect(alerts.recientes, isEmpty);
    });

    test('el aislamiento por puesto vale también para el MARCHAR y la '
        'anulación, y sus descripciones y avisos nombran la mesa numérica '
        'como «Mesa N»', () async {
      comandas = crear(runner: _RunnerQueFalla(falla: (n) => n.isOdd));
      final entrecot = lc('c1', 'Entrecot a la brasa', pase: 2);
      final vino = lc('b1', 'Copa de vino tinto', pase: 2, destino: enBarra);
      final marcha = MarchaPase(id: 'm-2', pase: 2, cuando: marchaSegundos);
      final comanda = comandaCon([entrecot, vino], marchas: [marcha]);

      await comandas.imprimirMarcha(mesa3, comanda, marcha, [entrecot, vino]);
      await comandas.imprimirAnulacion(mesa3, comanda, [
        entrecot.anular(cuando: segundoEnvio),
        vino.anular(cuando: segundoEnvio),
      ]);

      expect(printer.jobs.map((job) => job.endpoint), [barra, barra]);
      expect(printer.jobs.map((job) => job.description), [
        'Marchar Segundos · Mesa 3 · barra',
        'Anulación Mesa 3 · barra',
      ]);
      expect(alerts.recientes.map((aviso) => aviso.titulo), [
        'No se pudo imprimir el MARCHAR de cocina de Mesa 3',
        'No se pudo imprimir la anulación de cocina de Mesa 3',
      ]);
      expect(
        alerts.recientes.map((aviso) => aviso.nivel),
        everyElement(AlertaNivel.error),
      );
    });
  });

  group('reimprimir comanda', () {
    Future<void> reimprimir({
      Mesa mesa = mesa7,
      Set<DestinoPreparacion> destinos = const {enCocina, enBarra},
      AlcanceReimpresion alcance = AlcanceReimpresion.todo,
      MotivoReimpresion motivo = MotivoReimpresion.noSalio,
      Comanda? comanda,
    }) => comandas.reimprimirComanda(
      mesa,
      comanda ?? dosEnvios(),
      destinos: destinos,
      alcance: alcance,
      motivo: motivo,
      dispositivo: 'Caja 1',
    );

    setUp(() => reloj = reimpresa);

    test('todo: las líneas activas del puesto elegido con la banda '
        '«REIMPRESIÓN · PREPARAR», los números de los envíos, ESPERAR según '
        'las marchas y una sola copia con el aviso', () async {
      settings = ImpresionSettings(
        tickets: tickets,
        cocina: cocina,
        barra: barra,
        formato: FormatoImpresion(
          perfiles: {
            RolImpresora.cocina: PerfilImpresora(
              lineasIniciales: 3,
              copias: 3,
              zumbador: ZumbadorModo.generico,
              direccion: claveImpresora(cocina),
            ),
          },
        ),
      );

      await reimprimir(destinos: {enCocina});

      final job = printer.jobs.single;
      expect(job.endpoint, cocina);
      expect(job.description, 'Reimpresión de comanda · Mesa 7 · cocina');
      expect(job.reintento, PrintRetryPolicy.always);
      final decoded = decodeEscPos(job.bytes);
      expect(decoded.lines.first.text.trim(), 'REIMPRESIÓN · PREPARAR');
      expect(decoded.lines.first.inverse, isTrue);
      final texto = textoDe(job.bytes);
      expect(texto, contains('Reimpresa 09/10/2026 21:40 · Caja 1'));
      expect(texto, contains('ENVÍOS Nº 12, 15'));
      expectEnOrden(job.bytes, [
        '1. PRIMEROS',
        '1 x Croquetas de jamón',
        '2. SEGUNDOS · ESPERAR',
        '1 x Entrecot a la brasa',
      ]);
      expect(
        lineaCon(job.bytes, '1. PRIMEROS').text,
        isNot(contains('ESPERAR')),
      );
      for (final ajena in ['Sopa', 'Caña', 'Agua']) {
        expect(texto, isNot(contains(ajena)));
      }
      expect(avanceInicialDe(job.bytes), 3);
      expect(decoded.named('cut'), hasLength(1));
      expect(decoded.commands.last.name, 'beep');
      expect(alerts.recientes, isEmpty);
    });

    test('copia: banda «COPIA · NO PREPARAR»; sin impresora de barra sale por '
        'la de cocina con la nota de respaldo', () async {
      settings = ImpresionSettings(tickets: tickets, cocina: cocina);

      await reimprimir(destinos: {enBarra}, motivo: MotivoReimpresion.copia);

      final job = printer.jobs.single;
      expect(job.endpoint, cocina);
      expect(job.description, 'Copia de comanda · Mesa 7 · barra');
      final decoded = decodeEscPos(job.bytes);
      expect(decoded.lines.first.text.trim(), 'COPIA · NO PREPARAR');
      expect(decoded.lines.first.inverse, isTrue);
      final texto = textoDe(job.bytes);
      expect(texto, contains('BARRA'));
      expect(texto, contains('2 x Caña'));
      expect(texto, contains('1 x Agua con gas'));
      expect(texto, isNot(contains('Croquetas')));
      expect(texto, contains('Sin impresora de barra: llevar a barra'));
    });

    test('último envío: el bloque final aunque su número se repita tras un '
        'Cierre Z, sin las anuladas, un ticket por puesto', () async {
      final noche = DateTime(2026, 10, 9, 23, 30);
      final comanda = comandaCon([
        lc('c1', 'Croquetas de jamón'),
        // Tras el Cierre Z el número de envío vuelve a empezar.
        lc('c2', 'Ensalada mixta', envio: 1, creadaEn: segundoEnvio),
        lc('c3', 'Flan de huevo', creadaEn: noche),
        lc('c4', 'Tarta de queso', creadaEn: noche).anular(cuando: noche),
        lc('b1', 'Café solo', destino: enBarra, creadaEn: noche),
      ]);

      await reimprimir(
        comanda: comanda,
        alcance: AlcanceReimpresion.ultimoEnvio,
      );

      expect(printer.jobs.map((job) => job.endpoint), [cocina, barra]);
      final texto = textoDe(trabajoEn(cocina).bytes);
      expect(texto, contains('1 x Flan de huevo'));
      expect(texto, contains('COMANDA Nº 12 · 23:30'));
      expect(texto, contains('3º envío de la mesa'));
      for (final ajena in ['Croquetas', 'Ensalada', 'Tarta', 'Café']) {
        expect(texto, isNot(contains(ajena)));
      }
      final textoBarra = textoDe(trabajoEn(barra).bytes);
      expect(textoBarra, contains('1 x Café solo'));
      expect(textoBarra, isNot(contains('Flan')));
    });

    test('sin nada que reimprimir lanza ValidationException, antes de mirar '
        'la impresora', () async {
      settings = ImpresionSettings(tickets: tickets);
      final comanda = comandaCon([
        lc('c1', 'Croquetas de jamón'),
        lc('b1', 'Caña', destino: enBarra, envio: 15).anular(cuando: aceptada),
      ]);

      Matcher validacion(String mensaje) => throwsA(
        isA<ValidationException>().having((e) => e.message, 'message', mensaje),
      );
      await expectLater(
        reimprimir(
          comanda: comanda,
          destinos: {enBarra},
          alcance: AlcanceReimpresion.ultimoEnvio,
        ),
        validacion('El último envío no tiene líneas de barra'),
      );
      await expectLater(
        reimprimir(comanda: comanda, alcance: AlcanceReimpresion.ultimoEnvio),
        validacion('El último envío no tiene líneas de cocina ni de barra'),
      );
      await expectLater(
        reimprimir(comanda: comanda, destinos: {enBarra}),
        validacion('La comanda no tiene líneas de barra'),
      );
      await expectLater(
        reimprimir(comanda: comanda, destinos: const {}),
        validacion('Elige al menos un puesto para reimprimir'),
      );
      expect(printer.jobs, isEmpty);
      expect(alerts.recientes, isEmpty);
    });

    test('sin impresora de comandas, o sin cola de impresión, lanza '
        'PrinterException', () async {
      settings = ImpresionSettings(tickets: tickets);
      await expectLater(
        reimprimir(),
        throwsA(
          isA<PrinterException>().having(
            (e) => e.message,
            'message',
            'No hay impresora de comandas configurada',
          ),
        ),
      );

      settings = ImpresionSettings(cocina: cocina);
      puerto = null;
      await expectLater(
        reimprimir(destinos: {enCocina}),
        throwsA(
          isA<PrinterException>().having(
            (e) => e.message,
            'message',
            contains('Reimpresión de comanda · Mesa 7 · cocina'),
          ),
        ),
      );
      expect(printer.jobs, isEmpty);
      expect(alerts.recientes, isEmpty);
    });

    test('es una acción explícita: imprime aunque la impresión de comandas '
        'esté desactivada', () async {
      settings = ImpresionSettings(
        cocina: cocina,
        barra: barra,
        imprimirComandas: false,
      );

      await reimprimir(destinos: {enCocina});

      expect(printer.jobs.single.endpoint, cocina);
    });

    test('si un puesto falla, los demás se imprimen igualmente y se relanza '
        'el primer error, sin aviso', () async {
      comandas = crear(runner: _RunnerQueFalla());

      await expectLater(
        reimprimir(),
        throwsA(
          isA<PrinterException>()
              .having(
                (e) => e.message,
                'message',
                'No se pudo generar "Reimpresión de comanda · Mesa 7 · cocina"',
              )
              .having((e) => e.cause, 'cause', isA<StateError>()),
        ),
      );
      expect(printer.jobs.single.endpoint, barra);
      expect(alerts.recientes, isEmpty);

      printer.errorAlEncolar = const PrinterException('La cola está llena');
      await expectLater(
        reimprimir(),
        throwsA(
          isA<PrinterException>().having(
            (e) => e.message,
            'message',
            'La cola está llena',
          ),
        ),
      );
      expect(printer.jobs, hasLength(1));
    });

    test('si fallan todos los puestos, los intenta todos y relanza el error '
        'del primero (cocina), con la mesa numérica como «Mesa N»', () async {
      final runner = _RunnerQueFalla(falla: (_) => true);
      comandas = crear(runner: runner);

      await expectLater(
        reimprimir(mesa: mesa3),
        throwsA(
          isA<PrinterException>()
              .having(
                (e) => e.message,
                'message',
                'No se pudo generar "Reimpresión de comanda · Mesa 3 · cocina"',
              )
              .having((e) => e.cause, 'cause', isA<StateError>()),
        ),
      );
      expect(runner.llamadas, 2);
      expect(printer.jobs, isEmpty);
      expect(alerts.recientes, isEmpty);
    });
  });
}
