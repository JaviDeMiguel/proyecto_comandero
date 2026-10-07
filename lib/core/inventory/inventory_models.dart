import 'package:equatable/equatable.dart';

import '../utils/json_map.dart';

/// Modelos de inventario compartidos entre la capa de persistencia (MySQL
/// directo) y los motores en isolates. Son DTOs planos e inmutables: pueden
/// enviarse a un isolate tal cual.
///
/// Las referencias son las de `variantes.referencia` de FacturaScripts.

/// Línea de escandallo (receta): cuánto ingrediente lleva una unidad de plato.
final class RecetaLinea extends Equatable {
  const RecetaLinea({
    required this.refPlato,
    required this.refIngrediente,
    required this.cantidadNeta,
    this.mermaPct = 0,
  });

  /// Artículo elaborado (plato, bebida preparada o semielaborado).
  final String refPlato;

  /// Ingrediente: una materia prima con stock u otro elaborado (subreceta).
  final String refIngrediente;

  /// Cantidad NETA (ya limpia) por unidad de plato, expresada en la unidad
  /// de stock del ingrediente.
  final double cantidadNeta;

  /// Porcentaje de merma sobre el peso bruto, en `[0, 100)`. La cantidad
  /// bruta que sale del almacén es `cantidadNeta / (1 - mermaPct / 100)`.
  final double mermaPct;

  @override
  List<Object?> get props => [refPlato, refIngrediente, cantidadNeta, mermaPct];
}

/// Cantidad bruta (positiva) de una referencia que debe salir del almacén.
final class ConsumoStock extends Equatable {
  const ConsumoStock({required this.referencia, required this.cantidad});

  factory ConsumoStock.fromJson(Map<String, Object?> json) => ConsumoStock(
    referencia: json.requireString('referencia'),
    cantidad: json.requireDouble('cantidad'),
  );

  final String referencia;
  final double cantidad;

  Map<String, Object?> toJson() => {
    'referencia': referencia,
    'cantidad': cantidad,
  };

  @override
  List<Object?> get props => [referencia, cantidad];
}

/// Fila de `stocks`: existencias de una referencia en un almacén.
final class NivelStock extends Equatable {
  const NivelStock({
    required this.referencia,
    required this.codalmacen,
    required this.cantidad,
    this.reservada = 0,
    required this.disponible,
    this.pterecibir = 0,
    this.stockmin = 0,
    this.stockmax = 0,
    this.descripcion,
  });

  final String referencia;
  final String codalmacen;

  /// Stock físico. FacturaScripts admite que sea negativo.
  final double cantidad;

  /// Comprometido en pedidos de cliente.
  final double reservada;

  /// `max(0, cantidad - reservada)`.
  final double disponible;

  /// Pendiente de recibir de pedidos a proveedor abiertos.
  final double pterecibir;
  final double stockmin;
  final double stockmax;

  /// Descripción del producto, para avisos y pedidos.
  final String? descripcion;

  @override
  List<Object?> get props => [
    referencia,
    codalmacen,
    cantidad,
    reservada,
    disponible,
    pterecibir,
    stockmin,
    stockmax,
    descripcion,
  ];
}

/// Fila de `productosprov`: condiciones de un proveedor para una referencia.
final class OfertaProveedor extends Equatable {
  const OfertaProveedor({
    required this.referencia,
    required this.codproveedor,
    this.nombreProveedor,
    required this.precioNeto,
    this.actualizado,
  });

  final String referencia;
  final String codproveedor;
  final String? nombreProveedor;

  /// Precio de compra unitario tras descuentos (`productosprov.neto`).
  final double precioNeto;

  /// Última vez que se compró o se actualizó el precio.
  final DateTime? actualizado;

  @override
  List<Object?> get props => [
    referencia,
    codproveedor,
    nombreProveedor,
    precioNeto,
    actualizado,
  ];
}
