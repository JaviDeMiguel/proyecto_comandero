/// DTOs del motor de reaprovisionamiento.
///
/// Son clases planas e inmutables (primitivos, cadenas, listas, conjuntos y
/// otros DTOs planos) para poder enviarse a un isolate sin copia problemática.
library;

import 'package:equatable/equatable.dart';

import '../../inventory/inventory_models.dart';

export '../../inventory/inventory_models.dart' show NivelStock, OfertaProveedor;

/// Parámetros de la política de pedidos.
final class PoliticaReposicion extends Equatable {
  const PoliticaReposicion({
    this.factorSinMaximo = 2.0,
    this.multiploPedido = 1.0,
    this.incluirSinMinimo = false,
  });

  /// Cuando `stockmax <= stockmin` (no hay máximo útil) el objetivo de
  /// reposición es `stockmin * factorSinMaximo`.
  final double factorSinMaximo;

  /// La cantidad a pedir se redondea hacia ARRIBA al múltiplo (cajas de 6,
  /// sacos de 25 kg...). `0.001` permite cualquier fracción con la precisión
  /// de `stocks`. Debe ser `>= 0.001`.
  final double multiploPedido;

  /// Si es `true`, una referencia con `stockmin == 0` y cobertura negativa
  /// (stock en negativo) también se considera rotura: se pide lo justo para
  /// volver a cero.
  final bool incluirSinMinimo;

  @override
  List<Object?> get props => [
    factorSinMaximo,
    multiploPedido,
    incluirSinMinimo,
  ];
}

/// Petición de auditoría de reposición.
final class ReposicionRequest extends Equatable {
  const ReposicionRequest({
    required this.niveles,
    required this.ofertas,
    this.politica = const PoliticaReposicion(),
    this.referenciasExcluidas = const {},
  });

  /// Filas de `stocks` a auditar (normalmente las de un almacén).
  final List<NivelStock> niveles;

  /// Condiciones de compra conocidas (`productosprov`), de cualquier
  /// referencia; el motor filtra.
  final List<OfertaProveedor> ofertas;

  final PoliticaReposicion politica;

  /// Referencias que no se auditan (p. ej. artículos descatalogados o que
  /// el usuario ha decidido no reponer).
  final Set<String> referenciasExcluidas;

  @override
  List<Object?> get props => [niveles, ofertas, politica, referenciasExcluidas];
}

/// Línea de un pedido propuesto.
final class LineaPedidoPropuesta extends Equatable {
  const LineaPedidoPropuesta({
    required this.referencia,
    this.descripcion,
    required this.cantidad,
    required this.precioNeto,
    required this.importeEstimadoCents,
  });

  final String referencia;
  final String? descripcion;

  /// Cantidad a pedir, `> 0`, múltiplo de `multiploPedido`.
  final double cantidad;

  /// Precio neto unitario de la oferta elegida (`double`: es el valor de FS
  /// y solo sirve para la estimación).
  final double precioNeto;

  /// `cantidad * precioNeto` al céntimo (mitad hacia fuera de cero).
  final int importeEstimadoCents;

  @override
  List<Object?> get props => [
    referencia,
    descripcion,
    cantidad,
    precioNeto,
    importeEstimadoCents,
  ];
}

/// Pedido propuesto a un proveedor.
final class PedidoPropuesto extends Equatable {
  const PedidoPropuesto({
    required this.codproveedor,
    this.nombreProveedor,
    required this.lineas,
    required this.importeEstimadoCents,
  });

  final String codproveedor;
  final String? nombreProveedor;

  /// Ordenadas por referencia, una por referencia.
  final List<LineaPedidoPropuesta> lineas;

  /// Suma de los importes estimados de las líneas.
  final int importeEstimadoCents;

  @override
  List<Object?> get props => [
    codproveedor,
    nombreProveedor,
    lineas,
    importeEstimadoCents,
  ];
}

/// Una referencia por debajo de su mínimo en un almacén.
final class RoturaStock extends Equatable {
  const RoturaStock({
    required this.referencia,
    this.descripcion,
    required this.codalmacen,
    required this.disponible,
    required this.pterecibir,
    required this.stockmin,
    required this.stockmax,
    required this.cantidadNecesaria,
    this.codproveedor,
  });

  final String referencia;
  final String? descripcion;
  final String codalmacen;
  final double disponible;
  final double pterecibir;
  final double stockmin;
  final double stockmax;

  /// Cantidad a pedir para alcanzar el objetivo, ya redondeada al múltiplo.
  final double cantidadNecesaria;

  /// Proveedor elegido, o `null` si no hay oferta para la referencia.
  final String? codproveedor;

  /// `disponible + pterecibir`: lo que habrá sin pedir nada más.
  double get cobertura => disponible + pterecibir;

  @override
  List<Object?> get props => [
    referencia,
    descripcion,
    codalmacen,
    disponible,
    pterecibir,
    stockmin,
    stockmax,
    cantidadNecesaria,
    codproveedor,
  ];
}

/// Resultado de la auditoría.
final class ReposicionResult extends Equatable {
  const ReposicionResult({
    required this.roturas,
    required this.pedidos,
    required this.sinProveedor,
    required this.avisos,
  });

  /// Todas las roturas detectadas, ordenadas por referencia y almacén.
  final List<RoturaStock> roturas;

  /// Pedidos propuestos, ordenados por `codproveedor`.
  final List<PedidoPropuesto> pedidos;

  /// Roturas sin ninguna oferta de proveedor: hay que resolverlas a mano.
  final List<RoturaStock> sinProveedor;

  /// Incidencias no bloqueantes (máximos mal configurados, roturas de una
  /// misma referencia en varios almacenes...).
  final List<String> avisos;

  @override
  List<Object?> get props => [roturas, pedidos, sinProveedor, avisos];
}
