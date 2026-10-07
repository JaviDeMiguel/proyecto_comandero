/// Motor de escandallos: explosión multinivel de recetas con factor de merma.
///
/// El grafo de recetas es una matriz dispersa `plato × ingrediente` cuyo
/// coeficiente es la cantidad BRUTA por unidad de plato,
/// `cantidadNeta / (1 - mermaPct / 100)`. Resolver una venta es propagar la
/// demanda por esa matriz: si un ingrediente es a su vez plato de otra receta
/// (subreceta) se expande; si no, es una HOJA (materia prima con stock) y su
/// cantidad se acumula.
///
/// Es una función pura pensada para ejecutarse en un isolate mediante
/// [resolverEscandallosEnIsolate]: no hace E/S ni toca estado global.
library;

import '../../errors/app_exception.dart';
import '../../money/money.dart';
import '../isolate_runner.dart';
import 'escandallo_models.dart';

export 'escandallo_models.dart';

/// Decimales con que se guardan las cantidades en `stocks` (y con que se
/// emiten los consumos).
const int decimalesStock = 3;

/// Decimales a los que se normaliza cada hoja ANTES del redondeo de salida,
/// para absorber el ruido de la suma en coma flotante (p. ej. `0.1 + 0.2`).
const int decimalesAcumulacion = 6;

/// Redondea una cantidad de stock a [decimalesStock] decimales, mitad hacia
/// fuera de cero, pasando primero por 6 decimales.
///
/// El doble redondeo es deliberado: la acumulación en `double` deja residuos
/// del orden de `1e-15` que, redondeando directamente a 3 decimales, podrían
/// decidir un caso `x.xxx5` hacia el lado equivocado. A 6 decimales ese ruido
/// desaparece y el segundo redondeo es estable. Los consumos del motor y los
/// cálculos que otros módulos hagan sobre ellos deben usar esta misma función
/// para que coincidan al milésimo.
double redondearCantidadStock(double cantidad) {
  if (!cantidad.isFinite) {
    throw ValidationException('Cantidad de stock no finita: $cantidad');
  }
  const escalaAcumulacion = 1000000; // 10^decimalesAcumulacion
  const escalaStock = 1000; // 10^decimalesStock
  final normalizada =
      roundHalfAwayFromZero(cantidad * escalaAcumulacion) / escalaAcumulacion;
  return roundHalfAwayFromZero(normalizada * escalaStock) / escalaStock;
}

/// Resuelve los consumos de materias primas de una lista de ventas.
///
/// Lanza [ValidationException] si la petición es incoherente (cantidades no
/// positivas, merma fuera de `[0, 100)`, receta cíclica, profundidad
/// excesiva...). Valida el grafo COMPLETO de recetas, no solo las ramas
/// vendidas, para que un escandallo corrupto aflore en la primera comanda y
/// no al vender ese plato semanas después.
EscandalloResult resolverEscandallos(EscandalloRequest request) {
  _validarRequest(request);

  final recetasPorPlato = _indexarRecetas(request.recetas);
  final platos = recetasPorPlato.keys.toList()..sort();

  // Matriz resuelta: hojas (y cantidad bruta) por UNA unidad de cada plato.
  final resolutor = _Resolutor(recetasPorPlato, request.maxProfundidad);
  for (final plato in platos) {
    resolutor.hojasPorUnidad(plato);
  }

  // Ventas agregadas por referencia, en orden de referencia.
  final ventas = <String, double>{};
  for (final venta in request.ventas) {
    ventas[venta.referencia] = (ventas[venta.referencia] ?? 0) + venta.cantidad;
  }
  final referenciasVendidas = ventas.keys.toList()..sort();

  final acumulado = <String, double>{};
  final detalle = <ConsumoDetalle>[];
  final sinReceta = <String>[];
  for (final referencia in referenciasVendidas) {
    final hojas = resolutor.memo[referencia];
    if (hojas == null) {
      sinReceta.add(referencia);
      continue;
    }
    final cantidadVendida = ventas[referencia]!;
    for (final entrada in hojas.entries) {
      final bruta = entrada.value * cantidadVendida;
      acumulado[entrada.key] = (acumulado[entrada.key] ?? 0) + bruta;
      detalle.add(
        ConsumoDetalle(
          refIngrediente: entrada.key,
          refPlato: referencia,
          cantidadBruta: bruta,
        ),
      );
    }
  }

  final avisos = <String>[];
  final consumos = <ConsumoStock>[];
  for (final hoja in acumulado.keys.toList()..sort()) {
    final exacta = acumulado[hoja]!;
    final redondeada = redondearCantidadStock(exacta);
    if (redondeada <= 0) {
      avisos.add(
        'Consumo de $hoja ($exacta) inferior a la precisión de stock '
        '(0.001): se omite.',
      );
      continue;
    }
    consumos.add(ConsumoStock(referencia: hoja, cantidad: redondeada));
  }

  detalle.sort((a, b) {
    final porHoja = a.refIngrediente.compareTo(b.refIngrediente);
    return porHoja != 0 ? porHoja : a.refPlato.compareTo(b.refPlato);
  });

  final costes = _calcularCostes(
    request.costeUnitario,
    referenciasVendidas,
    resolutor.memo,
    avisos,
  );

  return EscandalloResult(
    consumos: consumos,
    detalle: detalle,
    sinReceta: sinReceta,
    costes: costes,
    avisos: avisos,
  );
}

/// Ejecuta [resolverEscandallos] fuera del isolate de UI.
Future<EscandalloResult> resolverEscandallosEnIsolate(
  EscandalloRequest request, {
  IsolateRunner runner = const SpawningIsolateRunner(),
}) => runner.run(resolverEscandallos, request, debugName: 'escandallos');

// ---------------------------------------------------------------------------
// Resolución del grafo
// ---------------------------------------------------------------------------

/// Recorre el grafo con memoización: cada plato se expande una sola vez a su
/// vector de hojas por unidad, aunque lo usen muchas recetas. Detecta ciclos
/// con la pila del recorrido y limita la profundidad por la altura de cada
/// nodo (número de niveles de subreceta por debajo de él, incluido él).
final class _Resolutor {
  _Resolutor(this.recetasPorPlato, this.maxProfundidad);

  final Map<String, List<RecetaLinea>> recetasPorPlato;
  final int maxProfundidad;

  /// Hojas y cantidad bruta por UNA unidad de cada plato ya resuelto.
  final Map<String, Map<String, double>> memo = {};

  /// Altura de cada plato resuelto (1 = todos sus ingredientes son hojas).
  final Map<String, int> _altura = {};

  final List<String> _pila = [];

  Map<String, double> hojasPorUnidad(String plato) {
    final memoizado = memo[plato];
    if (memoizado != null) return memoizado;

    final posicionEnPila = _pila.indexOf(plato);
    if (posicionEnPila >= 0) {
      final ciclo = [..._pila.sublist(posicionEnPila), plato];
      throw ValidationException('Receta cíclica: ${ciclo.join(' -> ')}');
    }
    _pila.add(plato);
    if (_pila.length > maxProfundidad) {
      throw ValidationException(
        'Escandallo demasiado profundo (más de $maxProfundidad niveles de '
        'subreceta): ${_pila.join(' -> ')}',
      );
    }

    final hojas = <String, double>{};
    var altura = 1;
    for (final linea in recetasPorPlato[plato]!) {
      final bruta = linea.cantidadNeta / (1 - linea.mermaPct / 100);
      if (!bruta.isFinite) {
        throw ValidationException(
          'La cantidad bruta de ${linea.refIngrediente} en ${linea.refPlato} '
          'no es finita (neta ${linea.cantidadNeta}, merma ${linea.mermaPct} %)',
        );
      }
      if (recetasPorPlato.containsKey(linea.refIngrediente)) {
        final sub = hojasPorUnidad(linea.refIngrediente);
        final alturaSub = _altura[linea.refIngrediente]! + 1;
        if (alturaSub > altura) altura = alturaSub;
        for (final entrada in sub.entries) {
          hojas[entrada.key] =
              (hojas[entrada.key] ?? 0) + bruta * entrada.value;
        }
      } else {
        hojas[linea.refIngrediente] =
            (hojas[linea.refIngrediente] ?? 0) + bruta;
      }
    }

    _pila.removeLast();
    if (altura > maxProfundidad) {
      // Solo alcanzable si una subreceta memoizada por un camino corto se
      // reutiliza desde uno más largo; la comprobación de la pila ya cubre
      // el resto de casos.
      throw ValidationException(
        'Escandallo demasiado profundo (más de $maxProfundidad niveles de '
        'subreceta) en $plato',
      );
    }
    _altura[plato] = altura;
    memo[plato] = hojas;
    return hojas;
  }
}

Map<String, List<RecetaLinea>> _indexarRecetas(List<RecetaLinea> recetas) {
  final porPlato = <String, List<RecetaLinea>>{};
  final vistas = <String>{};
  for (final linea in recetas) {
    if (!vistas.add('${linea.refPlato}\u0000${linea.refIngrediente}')) {
      throw ValidationException(
        'Línea de receta duplicada: ${linea.refPlato} -> '
        '${linea.refIngrediente}',
      );
    }
    porPlato.putIfAbsent(linea.refPlato, () => []).add(linea);
  }
  // Orden estable dentro de cada plato: la acumulación en coma flotante no es
  // asociativa y el resultado debe ser idéntico entre ejecuciones.
  for (final lineas in porPlato.values) {
    lineas.sort((a, b) => a.refIngrediente.compareTo(b.refIngrediente));
  }
  return porPlato;
}

List<CostePlato> _calcularCostes(
  Map<String, double> costeUnitario,
  List<String> referenciasVendidas,
  Map<String, Map<String, double>> memo,
  List<String> avisos,
) {
  if (costeUnitario.isEmpty) return const [];
  final costes = <CostePlato>[];
  for (final referencia in referenciasVendidas) {
    final hojas = memo[referencia];
    if (hojas == null) continue;
    var coste = 0.0;
    final sinCoste = <String>[];
    for (final entrada in hojas.entries) {
      final unitario = costeUnitario[entrada.key];
      if (unitario == null) {
        sinCoste.add(entrada.key);
      } else {
        coste += unitario * entrada.value;
      }
    }
    if (sinCoste.isNotEmpty) {
      sinCoste.sort();
      avisos.add(
        'Coste incompleto de $referencia: falta el coste de '
        '${sinCoste.join(', ')}.',
      );
    }
    costes.add(
      CostePlato(
        referencia: referencia,
        costeUnitario: coste,
        completo: sinCoste.isEmpty,
      ),
    );
  }
  return costes;
}

// ---------------------------------------------------------------------------
// Validación de entrada
// ---------------------------------------------------------------------------

void _validarRequest(EscandalloRequest request) {
  if (request.maxProfundidad < 1) {
    throw ValidationException(
      'maxProfundidad debe ser al menos 1 (recibido ${request.maxProfundidad})',
    );
  }
  for (final venta in request.ventas) {
    if (venta.referencia.trim().isEmpty) {
      throw const ValidationException('Venta con referencia vacía');
    }
    if (!(venta.cantidad > 0) || !venta.cantidad.isFinite) {
      throw ValidationException(
        'Cantidad vendida de ${venta.referencia} inválida '
        '(${venta.cantidad}): debe ser un número finito mayor que 0',
      );
    }
  }
  for (final linea in request.recetas) {
    if (linea.refPlato.trim().isEmpty) {
      throw ValidationException(
        'Línea de receta con plato vacío (ingrediente ${linea.refIngrediente})',
      );
    }
    if (linea.refIngrediente.trim().isEmpty) {
      throw ValidationException(
        'Línea de receta de ${linea.refPlato} con ingrediente vacío',
      );
    }
    if (linea.refPlato == linea.refIngrediente) {
      throw ValidationException(
        'La receta de ${linea.refPlato} se contiene a sí misma como '
        'ingrediente',
      );
    }
    if (!(linea.cantidadNeta > 0) || !linea.cantidadNeta.isFinite) {
      throw ValidationException(
        'Cantidad neta de ${linea.refIngrediente} en ${linea.refPlato} '
        'inválida (${linea.cantidadNeta}): debe ser un número finito mayor '
        'que 0',
      );
    }
    if (!(linea.mermaPct >= 0) || !(linea.mermaPct < 100)) {
      throw ValidationException(
        'Merma de ${linea.refIngrediente} en ${linea.refPlato} fuera de rango '
        '(${linea.mermaPct} %): debe estar en [0, 100)',
      );
    }
  }
  for (final entrada in request.costeUnitario.entries) {
    if (entrada.key.trim().isEmpty) {
      throw const ValidationException('Coste unitario con referencia vacía');
    }
    if (!(entrada.value >= 0) || !entrada.value.isFinite) {
      throw ValidationException(
        'Coste unitario de ${entrada.key} inválido (${entrada.value}): debe '
        'ser un número finito no negativo',
      );
    }
  }
}
