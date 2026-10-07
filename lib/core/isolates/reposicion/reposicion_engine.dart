/// Motor de reaprovisionamiento: detecta roturas de stock y propone pedidos
/// a proveedor agrupados por el proveedor más barato.
///
/// Es una función pura pensada para ejecutarse en un isolate mediante
/// [auditarReposicionEnIsolate]: no hace E/S ni toca estado global.
library;

import '../../errors/app_exception.dart';
import '../../money/money.dart';
import '../escandallos/escandallo_engine.dart' show redondearCantidadStock;
import '../isolate_runner.dart';
import 'reposicion_models.dart';

export 'reposicion_models.dart';

/// Audita los niveles de stock y propone pedidos.
///
/// Reglas (DESIGN_BRIEF §8):
/// - cobertura = `disponible + pterecibir` (lo pendiente de recibir ya está
///   pedido: no se vuelve a pedir);
/// - rotura si `stockmin > 0 && cobertura < stockmin`; con
///   `incluirSinMinimo` también si `stockmin == 0 && cobertura < 0`;
/// - objetivo = `stockmax` si `stockmax > stockmin`, si no
///   `stockmin * factorSinMaximo`;
/// - cantidad = `objetivo - cobertura`, redondeada hacia arriba al
///   `multiploPedido`, mínimo un múltiplo;
/// - proveedor = oferta de la referencia con menor `precioNeto` (empate:
///   `actualizado` más reciente; segundo empate: `codproveedor` menor); sin
///   ofertas la rotura va a `sinProveedor`.
///
/// Si una misma referencia rompe en varios almacenes, sus cantidades se suman
/// en una única línea de pedido (el pedido de FacturaScripts tiene un solo
/// `codalmacen`) y se avisa.
///
/// Lanza [ValidationException] ante una política o niveles incoherentes.
ReposicionResult auditarReposicion(ReposicionRequest request) {
  _validarRequest(request);
  final politica = request.politica;
  final avisos = <String>[];

  // Mejor oferta por referencia, decidida una sola vez.
  final mejorOferta = _elegirMejoresOfertas(request.ofertas);

  final roturas = <RoturaStock>[];
  final niveles = [...request.niveles]..sort(_compararNiveles);
  for (final nivel in niveles) {
    if (request.referenciasExcluidas.contains(nivel.referencia)) continue;
    final cobertura = nivel.disponible + nivel.pterecibir;
    final bajoMinimo = nivel.stockmin > 0 && cobertura < nivel.stockmin;
    final enNegativo =
        politica.incluirSinMinimo && nivel.stockmin == 0 && cobertura < 0;
    if (!bajoMinimo && !enNegativo) continue;

    final double objetivo;
    if (nivel.stockmax > nivel.stockmin) {
      objetivo = nivel.stockmax;
    } else {
      objetivo = nivel.stockmin * politica.factorSinMaximo;
      if (nivel.stockmax > 0) {
        avisos.add(
          'Stock máximo de ${nivel.referencia} en ${nivel.codalmacen} '
          '(${nivel.stockmax}) no supera el mínimo (${nivel.stockmin}): se '
          'repone a mínimo × ${politica.factorSinMaximo}.',
        );
      }
    }
    final cantidad = _redondearAlMultiplo(
      objetivo - cobertura,
      politica.multiploPedido,
    );
    roturas.add(
      RoturaStock(
        referencia: nivel.referencia,
        descripcion: nivel.descripcion,
        codalmacen: nivel.codalmacen,
        disponible: nivel.disponible,
        pterecibir: nivel.pterecibir,
        stockmin: nivel.stockmin,
        stockmax: nivel.stockmax,
        cantidadNecesaria: cantidad,
        codproveedor: mejorOferta[nivel.referencia]?.codproveedor,
      ),
    );
  }

  final sinProveedor = <RoturaStock>[];
  final porProveedor = <String, Map<String, _LineaAcumulada>>{};
  for (final rotura in roturas) {
    final oferta = mejorOferta[rotura.referencia];
    if (oferta == null) {
      sinProveedor.add(rotura);
      continue;
    }
    final lineas = porProveedor.putIfAbsent(oferta.codproveedor, () => {});
    final linea = lineas.putIfAbsent(
      rotura.referencia,
      () => _LineaAcumulada(oferta, rotura.descripcion),
    );
    linea.cantidad += rotura.cantidadNecesaria;
    linea.descripcion ??= rotura.descripcion;
    linea.almacenes.add(rotura.codalmacen);
  }

  final pedidos = <PedidoPropuesto>[];
  for (final codproveedor in porProveedor.keys.toList()..sort()) {
    final acumuladas = porProveedor[codproveedor]!;
    final lineas = <LineaPedidoPropuesta>[];
    String? nombreProveedor;
    var importe = 0;
    for (final referencia in acumuladas.keys.toList()..sort()) {
      final acumulada = acumuladas[referencia]!;
      nombreProveedor ??= acumulada.oferta.nombreProveedor;
      if (acumulada.almacenes.length > 1) {
        avisos.add(
          'Rotura de $referencia en varios almacenes '
          '(${acumulada.almacenes.join(', ')}): el pedido a $codproveedor '
          'agrupa las cantidades en una sola línea.',
        );
      }
      // Suma de múltiplos exactos: redondeada por si el múltiplo es
      // fraccionario (0.1 + 0.2...).
      final cantidad = redondearCantidadStock(acumulada.cantidad);
      final importeLinea = centsFromDecimal(
        cantidad * acumulada.oferta.precioNeto,
      );
      importe += importeLinea;
      lineas.add(
        LineaPedidoPropuesta(
          referencia: referencia,
          descripcion: acumulada.descripcion,
          cantidad: cantidad,
          precioNeto: acumulada.oferta.precioNeto,
          importeEstimadoCents: importeLinea,
        ),
      );
    }
    pedidos.add(
      PedidoPropuesto(
        codproveedor: codproveedor,
        nombreProveedor: nombreProveedor,
        lineas: lineas,
        importeEstimadoCents: importe,
      ),
    );
  }

  return ReposicionResult(
    roturas: roturas,
    pedidos: pedidos,
    sinProveedor: sinProveedor,
    avisos: avisos,
  );
}

/// Ejecuta [auditarReposicion] fuera del isolate de UI.
Future<ReposicionResult> auditarReposicionEnIsolate(
  ReposicionRequest request, {
  IsolateRunner runner = const SpawningIsolateRunner(),
}) => runner.run(auditarReposicion, request, debugName: 'reposicion');

// ---------------------------------------------------------------------------
// Cálculo
// ---------------------------------------------------------------------------

/// Redondea [cantidad] hacia arriba al múltiplo, con un mínimo de un múltiplo.
///
/// El cociente se normaliza a 12 cifras significativas antes del `ceil` para
/// que `0.3 / 0.1` (= `2.9999999999999996` en coma flotante) cuente como 3
/// múltiplos exactos y no como 4. El producto final se lleva a la precisión
/// de `stocks` (3 decimales) para que `3 × 0.1` no sea `0.30000000000000004`.
double _redondearAlMultiplo(double cantidad, double multiplo) {
  final cociente = double.parse((cantidad / multiplo).toStringAsPrecision(12));
  var multiplos = cociente.ceil();
  if (multiplos < 1) multiplos = 1;
  return redondearCantidadStock(multiplos * multiplo);
}

/// Oferta ganadora por referencia: menor precio; a igual precio, la
/// actualizada más recientemente (sin fecha cuenta como la más antigua); a
/// igual fecha, el `codproveedor` menor, para que el resultado no dependa
/// del orden de entrada.
Map<String, OfertaProveedor> _elegirMejoresOfertas(
  List<OfertaProveedor> ofertas,
) {
  final mejor = <String, OfertaProveedor>{};
  for (final oferta in ofertas) {
    final actual = mejor[oferta.referencia];
    if (actual == null || _compararOfertas(oferta, actual) < 0) {
      mejor[oferta.referencia] = oferta;
    }
  }
  return mejor;
}

/// Negativo si [a] es preferible a [b].
int _compararOfertas(OfertaProveedor a, OfertaProveedor b) {
  final porPrecio = a.precioNeto.compareTo(b.precioNeto);
  if (porPrecio != 0) return porPrecio;
  final fechaA = a.actualizado;
  final fechaB = b.actualizado;
  if (fechaA != fechaB) {
    if (fechaA == null) return 1;
    if (fechaB == null) return -1;
    // Más reciente primero.
    final porFecha = fechaB.compareTo(fechaA);
    if (porFecha != 0) return porFecha;
  }
  return a.codproveedor.compareTo(b.codproveedor);
}

int _compararNiveles(NivelStock a, NivelStock b) {
  final porReferencia = a.referencia.compareTo(b.referencia);
  return porReferencia != 0
      ? porReferencia
      : a.codalmacen.compareTo(b.codalmacen);
}

final class _LineaAcumulada {
  _LineaAcumulada(this.oferta, this.descripcion);

  final OfertaProveedor oferta;
  String? descripcion;
  double cantidad = 0;
  final List<String> almacenes = [];
}

// ---------------------------------------------------------------------------
// Validación de entrada
// ---------------------------------------------------------------------------

void _validarRequest(ReposicionRequest request) {
  final politica = request.politica;
  if (!(politica.factorSinMaximo > 0) || !politica.factorSinMaximo.isFinite) {
    throw ValidationException(
      'factorSinMaximo inválido (${politica.factorSinMaximo}): debe ser un '
      'número finito mayor que 0',
    );
  }
  if (!(politica.multiploPedido >= 0.001) ||
      !politica.multiploPedido.isFinite) {
    throw ValidationException(
      'multiploPedido inválido (${politica.multiploPedido}): debe ser un '
      'número finito de al menos 0.001 (precisión de stock)',
    );
  }

  final vistos = <String>{};
  for (final nivel in request.niveles) {
    if (nivel.referencia.trim().isEmpty) {
      throw ValidationException(
        'Nivel de stock con referencia vacía en el almacén '
        '"${nivel.codalmacen}"',
      );
    }
    if (nivel.codalmacen.trim().isEmpty) {
      throw ValidationException(
        'Nivel de stock de ${nivel.referencia} con almacén vacío',
      );
    }
    if (!vistos.add('${nivel.referencia}\u0000${nivel.codalmacen}')) {
      throw ValidationException(
        'Nivel de stock duplicado: ${nivel.referencia} en '
        '${nivel.codalmacen}',
      );
    }
    for (final (nombre, valor) in [
      ('disponible', nivel.disponible),
      ('pterecibir', nivel.pterecibir),
      ('stockmin', nivel.stockmin),
      ('stockmax', nivel.stockmax),
    ]) {
      if (!valor.isFinite) {
        throw ValidationException(
          '$nombre de ${nivel.referencia} en ${nivel.codalmacen} no es un '
          'número finito ($valor)',
        );
      }
    }
    if (nivel.stockmin < 0 || nivel.stockmax < 0) {
      throw ValidationException(
        'Mínimo/máximo de ${nivel.referencia} en ${nivel.codalmacen} '
        'negativos (${nivel.stockmin} / ${nivel.stockmax})',
      );
    }
  }

  for (final oferta in request.ofertas) {
    if (oferta.referencia.trim().isEmpty) {
      throw ValidationException(
        'Oferta del proveedor ${oferta.codproveedor} con referencia vacía',
      );
    }
    if (oferta.codproveedor.trim().isEmpty) {
      throw ValidationException(
        'Oferta de ${oferta.referencia} con código de proveedor vacío',
      );
    }
    if (!(oferta.precioNeto >= 0) || !oferta.precioNeto.isFinite) {
      throw ValidationException(
        'Precio neto de ${oferta.referencia} en ${oferta.codproveedor} '
        'inválido (${oferta.precioNeto}): debe ser un número finito no '
        'negativo',
      );
    }
  }
}
