import 'package:proyecto_comandero/core/errors/app_exception.dart';
import 'package:proyecto_comandero/core/isolates/escandallos/escandallo_engine.dart';
import 'package:proyecto_comandero/core/isolates/isolate_runner.dart';
import 'package:test/test.dart';

/// PAELLA: 0.1 kg de ARROZ sin merma y 0.15 kg de POLLO con 20 % de merma
/// (bruto 0.1875 kg).
const _paella = [
  RecetaLinea(refPlato: 'PAELLA', refIngrediente: 'ARROZ', cantidadNeta: 0.1),
  RecetaLinea(
    refPlato: 'PAELLA',
    refIngrediente: 'POLLO',
    cantidadNeta: 0.15,
    mermaPct: 20,
  ),
];

/// BRAVAS -> PATATA + SALSA_BRAVA; SALSA_BRAVA -> TOMATE + ACEITE.
const _bravas = [
  RecetaLinea(
    refPlato: 'BRAVAS',
    refIngrediente: 'PATATA',
    cantidadNeta: 0.2,
    mermaPct: 25,
  ),
  RecetaLinea(
    refPlato: 'BRAVAS',
    refIngrediente: 'SALSA_BRAVA',
    cantidadNeta: 0.05,
  ),
  RecetaLinea(
    refPlato: 'SALSA_BRAVA',
    refIngrediente: 'TOMATE',
    cantidadNeta: 0.8,
    mermaPct: 10,
  ),
  RecetaLinea(
    refPlato: 'SALSA_BRAVA',
    refIngrediente: 'ACEITE',
    cantidadNeta: 0.2,
  ),
];

EscandalloResult _resolver(
  List<VentaLinea> ventas,
  List<RecetaLinea> recetas, {
  Map<String, double> costes = const {},
  int maxProfundidad = 20,
}) => resolverEscandallos(
  EscandalloRequest(
    ventas: ventas,
    recetas: recetas,
    costeUnitario: costes,
    maxProfundidad: maxProfundidad,
  ),
);

double _consumo(EscandalloResult r, String referencia) =>
    r.consumos.singleWhere((c) => c.referencia == referencia).cantidad;

Matcher _validacion(Pattern mensaje) => throwsA(
  isA<ValidationException>().having(
    (e) => e.message,
    'message',
    contains(mensaje),
  ),
);

/// Cadena P1 -> P2 -> ... -> Pn -> HOJA (n niveles de subreceta).
List<RecetaLinea> _cadena(int niveles) => [
  for (var i = 1; i < niveles; i++)
    RecetaLinea(refPlato: 'P$i', refIngrediente: 'P${i + 1}', cantidadNeta: 1),
  RecetaLinea(refPlato: 'P$niveles', refIngrediente: 'HOJA', cantidadNeta: 1),
];

/// Grafo grande: [platos] platos con [ingredientesPorPlato] ingredientes cada
/// uno, donde la mitad de los ingredientes son subrecetas de platos
/// anteriores (sin ciclos) y el resto materias primas.
List<RecetaLinea> _grafoGrande(int platos, int ingredientesPorPlato) {
  final recetas = <RecetaLinea>[];
  for (var p = 0; p < platos; p++) {
    final usados = <String>{};
    for (var i = 0; i < ingredientesPorPlato; i++) {
      final esSub = i.isEven && p > 0;
      final ingrediente = esSub
          ? 'PLATO${(p * 7 + i) % p}'
          : 'MP${(p * 13 + i) % 150}';
      if (!usados.add(ingrediente)) continue;
      recetas.add(
        RecetaLinea(
          refPlato: 'PLATO$p',
          refIngrediente: ingrediente,
          cantidadNeta: 0.01 + i / 100,
          mermaPct: (i * 5) % 40,
        ),
      );
    }
  }
  return recetas;
}

void main() {
  group('redondearCantidadStock', () {
    test('redondea a 3 decimales con la mitad hacia fuera de cero', () {
      expect(redondearCantidadStock(0.1875), 0.188);
      expect(redondearCantidadStock(0.18749), 0.187);
      // Efecto deliberado del doble redondeo: lo que a 6 decimales ya es una
      // mitad se resuelve hacia fuera de cero.
      expect(redondearCantidadStock(0.1874999), 0.188);
      expect(redondearCantidadStock(2), 2.0);
      expect(redondearCantidadStock(-0.0005), -0.001);
    });

    test('absorbe el ruido de la coma flotante antes del redondeo', () {
      // 0.1 + 0.2 = 0.30000000000000004; 1.0005 llega como 1.000499999...
      expect(redondearCantidadStock(0.1 + 0.2), 0.3);
      expect(redondearCantidadStock(1.0005), 1.001);
      expect(redondearCantidadStock(0.3 - 0.1 - 0.2 + 0.0005), 0.001);
    });

    test('rechaza valores no finitos', () {
      expect(
        () => redondearCantidadStock(double.infinity),
        _validacion('no finita'),
      );
    });
  });

  group('receta simple', () {
    test('una paella consume arroz neto y pollo bruto con merma', () {
      final r = _resolver([
        const VentaLinea(referencia: 'PAELLA', cantidad: 1),
      ], _paella);

      expect(r.consumos, [
        const ConsumoStock(referencia: 'ARROZ', cantidad: 0.1),
        const ConsumoStock(referencia: 'POLLO', cantidad: 0.188),
      ]);
      expect(r.sinReceta, isEmpty);
      expect(r.costes, isEmpty);
      expect(r.avisos, isEmpty);
      expect(r.detalle, hasLength(2));
      expect(
        r.detalle.singleWhere((d) => d.refIngrediente == 'POLLO').cantidadBruta,
        closeTo(0.1875, 1e-12),
      );
    });

    test('siete paellas escalan linealmente', () {
      final r = _resolver([
        const VentaLinea(referencia: 'PAELLA', cantidad: 7),
      ], _paella);
      expect(_consumo(r, 'ARROZ'), closeTo(0.7, 1e-12));
      expect(_consumo(r, 'POLLO'), closeTo(1.313, 1e-12)); // 1.3125 -> 1.313
    });

    test('las ventas repetidas de la misma referencia se agregan', () {
      final r = _resolver([
        const VentaLinea(referencia: 'PAELLA', cantidad: 3),
        const VentaLinea(referencia: 'PAELLA', cantidad: 4),
      ], _paella);
      expect(_consumo(r, 'ARROZ'), closeTo(0.7, 1e-12));
      expect(r.detalle.where((d) => d.refPlato == 'PAELLA'), hasLength(2));
    });

    test('cantidades fraccionarias (media ración)', () {
      final r = _resolver([
        const VentaLinea(referencia: 'PAELLA', cantidad: 0.5),
      ], _paella);
      expect(_consumo(r, 'ARROZ'), 0.05);
      expect(_consumo(r, 'POLLO'), 0.094); // 0.09375 -> 0.094
    });

    test('sin ventas no hay consumos', () {
      final r = _resolver(const [], _paella);
      expect(r.consumos, isEmpty);
      expect(r.detalle, isEmpty);
      expect(r.sinReceta, isEmpty);
    });
  });

  group('subrecetas', () {
    test('BRAVAS expande SALSA_BRAVA hasta las hojas', () {
      final r = _resolver([
        const VentaLinea(referencia: 'BRAVAS', cantidad: 2),
      ], _bravas);

      // PATATA: 0.2 / 0.75 = 0.26667 por ración -> 0.53333.
      // SALSA: 0.05 por ración -> TOMATE 0.05 * 0.8 / 0.9 = 0.04444 -> 0.08889
      //                            ACEITE 0.05 * 0.2 = 0.01 -> 0.02.
      expect(r.consumos.map((c) => c.referencia), [
        'ACEITE',
        'PATATA',
        'TOMATE',
      ]);
      expect(_consumo(r, 'PATATA'), 0.533);
      expect(_consumo(r, 'TOMATE'), 0.089);
      expect(_consumo(r, 'ACEITE'), 0.02);
      // SALSA_BRAVA no es hoja: no aparece como consumo.
      expect(r.consumos.any((c) => c.referencia == 'SALSA_BRAVA'), isFalse);
      // El detalle se atribuye al plato raíz, no a la subreceta.
      expect(r.detalle.map((d) => d.refPlato).toSet(), {'BRAVAS'});
    });

    test('vender la subreceta directamente también la resuelve', () {
      final r = _resolver([
        const VentaLinea(referencia: 'SALSA_BRAVA', cantidad: 1),
      ], _bravas);
      expect(_consumo(r, 'TOMATE'), 0.889);
      expect(_consumo(r, 'ACEITE'), 0.2);
    });

    test('el mismo ingrediente por dos caminos se agrega', () {
      const recetas = [
        RecetaLinea(refPlato: 'MENU', refIngrediente: 'PAN', cantidadNeta: 1),
        RecetaLinea(refPlato: 'MENU', refIngrediente: 'TOSTA', cantidadNeta: 2),
        RecetaLinea(
          refPlato: 'TOSTA',
          refIngrediente: 'PAN',
          cantidadNeta: 0.5,
        ),
        RecetaLinea(
          refPlato: 'TOSTA',
          refIngrediente: 'ACEITE',
          cantidadNeta: 0.01,
        ),
      ];
      final r = _resolver([
        const VentaLinea(referencia: 'MENU', cantidad: 3),
      ], recetas);
      // PAN: 1 directo + 2 * 0.5 vía TOSTA = 2 por menú -> 6.
      expect(_consumo(r, 'PAN'), 6);
      expect(_consumo(r, 'ACEITE'), 0.06);
      expect(
        r.detalle.where((d) => d.refIngrediente == 'PAN'),
        hasLength(1),
        reason: 'el detalle agrega por plato raíz, no por camino',
      );
    });

    test(
      'una subreceta compartida por varios platos se memoiza sin mezclar',
      () {
        final recetas = [
          ..._bravas,
          const RecetaLinea(
            refPlato: 'HUEVOS_ROTOS',
            refIngrediente: 'SALSA_BRAVA',
            cantidadNeta: 0.1,
          ),
          const RecetaLinea(
            refPlato: 'HUEVOS_ROTOS',
            refIngrediente: 'HUEVO',
            cantidadNeta: 2,
          ),
        ];
        final r = _resolver([
          const VentaLinea(referencia: 'BRAVAS', cantidad: 1),
          const VentaLinea(referencia: 'HUEVOS_ROTOS', cantidad: 1),
        ], recetas);
        // ACEITE: 0.05 * 0.2 + 0.1 * 0.2 = 0.03.
        expect(_consumo(r, 'ACEITE'), 0.03);
        expect(_consumo(r, 'HUEVO'), 2);
        expect(
          r.detalle
              .where((d) => d.refIngrediente == 'ACEITE')
              .map((d) => d.refPlato),
          ['BRAVAS', 'HUEVOS_ROTOS'],
        );
      },
    );
  });

  group('ciclos y profundidad', () {
    test('ciclo directo A -> B -> A', () {
      const recetas = [
        RecetaLinea(refPlato: 'A', refIngrediente: 'B', cantidadNeta: 1),
        RecetaLinea(refPlato: 'B', refIngrediente: 'A', cantidadNeta: 1),
      ];
      expect(
        () => _resolver([
          const VentaLinea(referencia: 'A', cantidad: 1),
        ], recetas),
        _validacion('Receta cíclica: A -> B -> A'),
      );
    });

    test('ciclo indirecto A -> B -> C -> A, con la cadena en el mensaje', () {
      const recetas = [
        RecetaLinea(refPlato: 'A', refIngrediente: 'B', cantidadNeta: 1),
        RecetaLinea(refPlato: 'B', refIngrediente: 'C', cantidadNeta: 1),
        RecetaLinea(refPlato: 'C', refIngrediente: 'A', cantidadNeta: 1),
        RecetaLinea(refPlato: 'C', refIngrediente: 'SAL', cantidadNeta: 1),
      ];
      expect(
        () => _resolver([
          const VentaLinea(referencia: 'B', cantidad: 1),
        ], recetas),
        _validacion('A -> B -> C -> A'),
      );
    });

    test('un ciclo se detecta aunque no se venda ningún plato implicado', () {
      final recetas = [
        ..._paella,
        const RecetaLinea(refPlato: 'X', refIngrediente: 'Y', cantidadNeta: 1),
        const RecetaLinea(refPlato: 'Y', refIngrediente: 'X', cantidadNeta: 1),
      ];
      expect(
        () => _resolver([
          const VentaLinea(referencia: 'PAELLA', cantidad: 1),
        ], recetas),
        _validacion('Receta cíclica'),
      );
    });

    test('la profundidad máxima admite exactamente maxProfundidad niveles', () {
      final r = _resolver(
        [const VentaLinea(referencia: 'P1', cantidad: 2)],
        _cadena(3),
        maxProfundidad: 3,
      );
      expect(_consumo(r, 'HOJA'), 2);
    });

    test('superar la profundidad máxima es un error', () {
      expect(
        () => _resolver(
          [const VentaLinea(referencia: 'P1', cantidad: 1)],
          _cadena(4),
          maxProfundidad: 3,
        ),
        _validacion('demasiado profundo'),
      );
    });

    test('la profundidad se mide por altura aunque haya memoización', () {
      // Z -> HOJA; Y -> Z; X -> Y. Si Z se resuelve primero por el camino
      // corto (venta directa) la altura de X sigue siendo 3.
      const recetas = [
        RecetaLinea(refPlato: 'Z', refIngrediente: 'HOJA', cantidadNeta: 1),
        RecetaLinea(refPlato: 'Y', refIngrediente: 'Z', cantidadNeta: 1),
        RecetaLinea(refPlato: 'X', refIngrediente: 'Y', cantidadNeta: 1),
      ];
      expect(
        () => _resolver(
          [const VentaLinea(referencia: 'Z', cantidad: 1)],
          recetas,
          maxProfundidad: 2,
        ),
        _validacion('demasiado profundo'),
      );
    });

    test('maxProfundidad por defecto es 20', () {
      const request = EscandalloRequest(ventas: [], recetas: []);
      expect(request.maxProfundidad, 20);
      expect(
        _consumo(
          _resolver([
            const VentaLinea(referencia: 'P1', cantidad: 1),
          ], _cadena(20)),
          'HOJA',
        ),
        1,
      );
      expect(
        () => _resolver([
          const VentaLinea(referencia: 'P1', cantidad: 1),
        ], _cadena(21)),
        _validacion('más de 20 niveles'),
      );
    });
  });

  group('ventas sin receta', () {
    test('una referencia sin receta va a sinReceta y no consume', () {
      final r = _resolver([
        const VentaLinea(referencia: 'COCA_COLA', cantidad: 2),
        const VentaLinea(referencia: 'PAELLA', cantidad: 1),
      ], _paella);
      expect(r.sinReceta, ['COCA_COLA']);
      expect(r.consumos.map((c) => c.referencia), ['ARROZ', 'POLLO']);
      expect(r.detalle.any((d) => d.refPlato == 'COCA_COLA'), isFalse);
    });

    test('vender un ingrediente hoja directamente no es un plato', () {
      final r = _resolver([
        const VentaLinea(referencia: 'ARROZ', cantidad: 1),
      ], _paella);
      expect(r.sinReceta, ['ARROZ']);
      expect(r.consumos, isEmpty);
    });

    test('sinReceta se ordena y deduplica', () {
      final r = _resolver([
        const VentaLinea(referencia: 'ZUMO', cantidad: 1),
        const VentaLinea(referencia: 'AGUA', cantidad: 1),
        const VentaLinea(referencia: 'ZUMO', cantidad: 1),
      ], _paella);
      expect(r.sinReceta, ['AGUA', 'ZUMO']);
    });
  });

  group('merma', () {
    test('merma 99.9 produce un bruto enorme pero finito', () {
      const recetas = [
        RecetaLinea(
          refPlato: 'CALDO',
          refIngrediente: 'HUESO',
          cantidadNeta: 0.001,
          mermaPct: 99.9,
        ),
      ];
      final r = _resolver([
        const VentaLinea(referencia: 'CALDO', cantidad: 1),
      ], recetas);
      // 0.001 / 0.001 = 1 (con ruido de coma flotante absorbido).
      expect(_consumo(r, 'HUESO'), 1);
    });

    test('merma 100 es inválida (división por cero)', () {
      const recetas = [
        RecetaLinea(
          refPlato: 'CALDO',
          refIngrediente: 'HUESO',
          cantidadNeta: 1,
          mermaPct: 100,
        ),
      ];
      expect(
        () => _resolver([
          const VentaLinea(referencia: 'CALDO', cantidad: 1),
        ], recetas),
        _validacion('Merma de HUESO en CALDO fuera de rango (100.0 %)'),
      );
    });

    test('merma negativa es inválida', () {
      const recetas = [
        RecetaLinea(
          refPlato: 'CALDO',
          refIngrediente: 'HUESO',
          cantidadNeta: 1,
          mermaPct: -1,
        ),
      ];
      expect(() => _resolver(const [], recetas), _validacion('fuera de rango'));
    });
  });

  group('validaciones de entrada', () {
    test('cantidad de venta cero o negativa', () {
      expect(
        () => _resolver([
          const VentaLinea(referencia: 'PAELLA', cantidad: 0),
        ], _paella),
        _validacion('Cantidad vendida de PAELLA inválida (0.0)'),
      );
      expect(
        () => _resolver([
          const VentaLinea(referencia: 'PAELLA', cantidad: -2),
        ], _paella),
        _validacion('mayor que 0'),
      );
      expect(
        () => _resolver([
          const VentaLinea(referencia: 'PAELLA', cantidad: double.nan),
        ], _paella),
        _validacion('finito'),
      );
    });

    test('referencia de venta vacía', () {
      expect(
        () => _resolver([
          const VentaLinea(referencia: '  ', cantidad: 1),
        ], _paella),
        _validacion('referencia vacía'),
      );
    });

    test('cantidad neta no positiva', () {
      const recetas = [
        RecetaLinea(refPlato: 'A', refIngrediente: 'B', cantidadNeta: 0),
      ];
      expect(
        () => _resolver(const [], recetas),
        _validacion('Cantidad neta de B en A inválida (0.0)'),
      );
    });

    test('referencias de receta vacías', () {
      expect(
        () => _resolver(const [], const [
          RecetaLinea(refPlato: '', refIngrediente: 'B', cantidadNeta: 1),
        ]),
        _validacion('plato vacío'),
      );
      expect(
        () => _resolver(const [], const [
          RecetaLinea(refPlato: 'A', refIngrediente: '', cantidadNeta: 1),
        ]),
        _validacion('ingrediente vacío'),
      );
    });

    test('receta que se contiene a sí misma', () {
      expect(
        () => _resolver(const [], const [
          RecetaLinea(refPlato: 'A', refIngrediente: 'A', cantidadNeta: 1),
        ]),
        _validacion('se contiene a sí misma'),
      );
    });

    test('línea de receta duplicada', () {
      expect(
        () => _resolver(const [], [..._paella, _paella.first]),
        _validacion('duplicada: PAELLA -> ARROZ'),
      );
    });

    test('maxProfundidad menor que 1', () {
      expect(
        () => _resolver(const [], _paella, maxProfundidad: 0),
        _validacion('maxProfundidad'),
      );
    });

    test('coste unitario negativo o con clave vacía', () {
      expect(
        () => _resolver(const [], _paella, costes: {'ARROZ': -1}),
        _validacion('Coste unitario de ARROZ inválido'),
      );
      expect(
        () => _resolver(const [], _paella, costes: {'': 1}),
        _validacion('Coste unitario con referencia vacía'),
      );
    });
  });

  group('costes', () {
    test('coste completo = suma de hojas brutas por su coste', () {
      final r = _resolver(
        [const VentaLinea(referencia: 'PAELLA', cantidad: 3)],
        _paella,
        costes: {'ARROZ': 2, 'POLLO': 8},
      );
      final coste = r.costes.single;
      expect(coste.referencia, 'PAELLA');
      expect(coste.completo, isTrue);
      // 0.1 * 2 + 0.1875 * 8 = 0.2 + 1.5 = 1.7 por unidad (no por 3).
      expect(coste.costeUnitario, closeTo(1.7, 1e-12));
      expect(r.avisos, isEmpty);
    });

    test('coste incompleto marca completo=false y avisa', () {
      final r = _resolver(
        [
          const VentaLinea(referencia: 'BRAVAS', cantidad: 1),
          const VentaLinea(referencia: 'AGUA', cantidad: 1),
        ],
        _bravas,
        costes: {'PATATA': 1.5, 'SALSA_BRAVA': 99},
      );
      final coste = r.costes.single;
      expect(coste.referencia, 'BRAVAS');
      expect(coste.completo, isFalse);
      // Solo PATATA: 0.2 / 0.75 * 1.5 = 0.4. El coste de SALSA_BRAVA (plato)
      // se ignora: el de un elaborado se deriva de sus materias primas.
      expect(coste.costeUnitario, closeTo(0.4, 1e-12));
      expect(r.avisos, [
        'Coste incompleto de BRAVAS: falta el coste de ACEITE, TOMATE.',
      ]);
    });

    test('sin mapa de costes no se calculan ni se avisa', () {
      final r = _resolver([
        const VentaLinea(referencia: 'PAELLA', cantidad: 1),
      ], _paella);
      expect(r.costes, isEmpty);
      expect(r.avisos, isEmpty);
    });

    test('costes de varios platos ordenados por referencia', () {
      final r = _resolver(
        [
          const VentaLinea(referencia: 'PAELLA', cantidad: 1),
          const VentaLinea(referencia: 'BRAVAS', cantidad: 1),
        ],
        [..._paella, ..._bravas],
        costes: {'ARROZ': 1, 'POLLO': 1, 'PATATA': 1, 'TOMATE': 1, 'ACEITE': 1},
      );
      expect(r.costes.map((c) => c.referencia), ['BRAVAS', 'PAELLA']);
      expect(r.costes.every((c) => c.completo), isTrue);
    });
  });

  group('precisión y avisos', () {
    test('un consumo por debajo de la milésima se omite con aviso', () {
      const recetas = [
        RecetaLinea(
          refPlato: 'TE',
          refIngrediente: 'AZAFRAN',
          cantidadNeta: 0.0001,
        ),
        RecetaLinea(refPlato: 'TE', refIngrediente: 'AGUA', cantidadNeta: 0.25),
      ];
      final r = _resolver([
        const VentaLinea(referencia: 'TE', cantidad: 1),
      ], recetas);
      expect(r.consumos, [
        const ConsumoStock(referencia: 'AGUA', cantidad: 0.25),
      ]);
      expect(r.avisos.single, contains('Consumo de AZAFRAN'));
      // El detalle conserva la cantidad exacta para trazabilidad.
      expect(
        r.detalle
            .singleWhere((d) => d.refIngrediente == 'AZAFRAN')
            .cantidadBruta,
        0.0001,
      );
    });

    test('la suma en coma flotante no deja residuos en la salida', () {
      // 10 ventas de 0.1 -> 1.0 exacto tras el doble redondeo.
      final ventas = [
        for (var i = 0; i < 10; i++)
          const VentaLinea(referencia: 'PAELLA', cantidad: 0.1),
      ];
      final r = _resolver(ventas, _paella);
      expect(_consumo(r, 'ARROZ'), 0.1);
      expect(_consumo(r, 'POLLO'), 0.188);
    });
  });

  group('propiedades', () {
    final recetas = _grafoGrande(60, 8);
    final ventas = [
      for (var p = 0; p < 60; p += 3)
        VentaLinea(referencia: 'PLATO$p', cantidad: 1 + p % 4 / 2),
      const VentaLinea(referencia: 'MP3', cantidad: 2),
      const VentaLinea(referencia: 'REFRESCO', cantidad: 1),
    ];

    test('determinismo: dos ejecuciones dan resultados idénticos', () {
      final request = EscandalloRequest(
        ventas: ventas,
        recetas: recetas,
        costeUnitario: {for (var i = 0; i < 150; i++) 'MP$i': 0.5 + i / 10},
      );
      final a = resolverEscandallos(request);
      final b = resolverEscandallos(request);
      expect(a, b);
      expect(a.consumos, b.consumos);
      expect(a.hashCode, b.hashCode);
    });

    test('el orden de las recetas y ventas de entrada no cambia la salida', () {
      final a = _resolver(ventas, recetas);
      final b = _resolver(ventas.reversed.toList(), recetas.reversed.toList());
      expect(a, b);
    });

    test('suma del detalle por hoja == consumo agregado', () {
      final r = _resolver(ventas, recetas);
      expect(r.consumos, isNotEmpty);
      final porHoja = <String, double>{};
      for (final d in r.detalle) {
        porHoja[d.refIngrediente] =
            (porHoja[d.refIngrediente] ?? 0) + d.cantidadBruta;
      }
      expect(porHoja.keys.toSet(), r.consumos.map((c) => c.referencia).toSet());
      for (final c in r.consumos) {
        expect(
          redondearCantidadStock(porHoja[c.referencia]!),
          closeTo(c.cantidad, 1e-9),
          reason: c.referencia,
        );
      }
    });

    test('invariantes de la salida', () {
      final r = _resolver(ventas, recetas);
      final referencias = r.consumos.map((c) => c.referencia).toList();
      expect(referencias, [...referencias]..sort());
      expect(referencias.toSet().length, referencias.length);
      for (final c in r.consumos) {
        expect(c.cantidad, greaterThan(0));
        expect(c.cantidad, redondearCantidadStock(c.cantidad));
        expect(c.referencia, startsWith('MP'), reason: 'solo hojas');
      }
      expect(r.sinReceta, ['MP3', 'REFRESCO']);
      expect(r.detalle.map((d) => d.refPlato).toSet().length, 20);
    });
  });

  group('isolates', () {
    test(
      'ejecuta en un isolate real (grafo 500 platos x 10 ingredientes)',
      () async {
        final recetas = _grafoGrande(500, 10);
        final ventas = [
          for (var p = 0; p < 500; p++)
            VentaLinea(referencia: 'PLATO$p', cantidad: 1),
        ];
        final request = EscandalloRequest(ventas: ventas, recetas: recetas);
        final cronometro = Stopwatch()..start();
        final r = await resolverEscandallosEnIsolate(request);
        cronometro.stop();
        expect(r, resolverEscandallos(request));
        expect(r.consumos, isNotEmpty);
        expect(cronometro.elapsed, lessThan(const Duration(seconds: 2)));
      },
    );

    test('los errores de validación atraviesan el isolate real', () async {
      await expectLater(
        resolverEscandallosEnIsolate(
          const EscandalloRequest(
            ventas: [VentaLinea(referencia: 'A', cantidad: 1)],
            recetas: [
              RecetaLinea(refPlato: 'A', refIngrediente: 'B', cantidadNeta: 1),
              RecetaLinea(refPlato: 'B', refIngrediente: 'A', cantidadNeta: 1),
            ],
          ),
        ),
        _validacion('Receta cíclica'),
      );
    });

    test(
      'con InlineIsolateRunner devuelve lo mismo que la función pura',
      () async {
        const request = EscandalloRequest(
          ventas: [VentaLinea(referencia: 'BRAVAS', cantidad: 2)],
          recetas: _bravas,
          costeUnitario: {'PATATA': 1, 'TOMATE': 2, 'ACEITE': 5},
        );
        final r = await resolverEscandallosEnIsolate(
          request,
          runner: const InlineIsolateRunner(),
        );
        expect(r, resolverEscandallos(request));
      },
    );
  });
}
