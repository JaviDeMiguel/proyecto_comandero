/// Modelos del pedido a proveedor de reaprovisionamiento
/// (`FsSupplierOrderService`).
library;

import 'package:equatable/equatable.dart';

import '../../errors/app_exception.dart';
import 'fs_idempotency_key.dart';

/// Línea de pedido. Sin `pvpunitario`: FacturaScripts aplica el último precio
/// del proveedor (`productosprov`) o el coste de la variante, y así el pedido
/// no altera los costes que usa el motor de escandallos.
final class LineaPedido extends Equatable {
  LineaPedido({
    required this.referencia,
    required this.cantidad,
    this.descripcion,
  }) {
    if (referencia.trim().isEmpty) {
      throw const ValidationException(
        'Una línea de pedido necesita referencia',
      );
    }
    if (!cantidad.isFinite || cantidad <= 0) {
      throw ValidationException(
        "Cantidad no válida para '$referencia': $cantidad",
      );
    }
  }

  final String referencia;
  final double cantidad;
  final String? descripcion;

  Map<String, Object?> toFsJson() => {
    'referencia': referencia,
    'cantidad': cantidad,
    if (descripcion case final texto? when texto.trim().isNotEmpty)
      'descripcion': texto,
  };

  @override
  List<Object?> get props => [referencia, cantidad, descripcion];
}

/// Pedido a un proveedor pendiente de crear en FacturaScripts.
final class PedidoProveedorDraft extends Equatable {
  PedidoProveedorDraft({
    required String clave,
    required this.codproveedor,
    required this.codalmacen,
    required this.fechaHora,
    this.observaciones,
    required this.lineas,
  }) : clave = validarClaveIdempotente(clave, campo: 'numproveedor') {
    if (codproveedor.trim().isEmpty) {
      throw const ValidationException('El pedido no tiene codproveedor');
    }
    if (codalmacen.trim().isEmpty) {
      throw const ValidationException('El pedido no tiene codalmacen');
    }
    if (lineas.isEmpty) {
      throw const ValidationException('El pedido no tiene líneas');
    }
  }

  /// Clave guardada en `numproveedor` (≤ 50, no parece una fecha).
  final String clave;
  final String codproveedor;

  /// Almacén donde FacturaScripts apunta `stocks.pterecibir`.
  final String codalmacen;
  final DateTime fechaHora;
  final String? observaciones;
  final List<LineaPedido> lineas;

  @override
  List<Object?> get props => [
    clave,
    codproveedor,
    codalmacen,
    fechaHora,
    observaciones,
    lineas,
  ];
}

/// Resultado de crear (o reanudar) un pedido a proveedor.
final class ResultadoPedido extends Equatable {
  const ResultadoPedido({
    required this.idpedido,
    required this.codigo,
    required this.totalCents,
    required this.referenciasSinProducto,
    required this.yaExistia,
  });

  final int idpedido;
  final String codigo;
  final int totalCents;

  /// Referencias que FacturaScripts no reconoció: la línea se creó sin
  /// `idproducto`, con precio 0 y sin sumar a `pterecibir`.
  final List<String> referenciasSinProducto;
  final bool yaExistia;

  @override
  List<Object?> get props => [
    idpedido,
    codigo,
    totalCents,
    referenciasSinProducto,
    yaExistia,
  ];
}
