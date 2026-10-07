/// DTOs del motor de escandallos.
///
/// Son clases planas e inmutables (primitivos, cadenas, listas, mapas y otros
/// DTOs planos) para poder enviarse a un isolate sin copia problemática.
library;

import 'package:equatable/equatable.dart';

import '../../inventory/inventory_models.dart';

export '../../inventory/inventory_models.dart' show ConsumoStock, RecetaLinea;

/// Una referencia vendida (o enviada a cocina) y cuántas unidades.
final class VentaLinea extends Equatable {
  const VentaLinea({required this.referencia, required this.cantidad});

  /// `variantes.referencia` del artículo vendido.
  final String referencia;

  /// Unidades vendidas. Admite fracciones (media ración); debe ser `> 0`.
  final double cantidad;

  @override
  List<Object?> get props => [referencia, cantidad];
}

/// Petición de resolución de escandallos.
final class EscandalloRequest extends Equatable {
  const EscandalloRequest({
    required this.ventas,
    required this.recetas,
    this.costeUnitario = const {},
    this.maxProfundidad = 20,
  });

  /// Referencias vendidas. Las repeticiones de una misma referencia se agregan.
  final List<VentaLinea> ventas;

  /// Todas las líneas de receta conocidas (de cualquier plato). El motor
  /// filtra las que necesita y valida el grafo completo.
  final List<RecetaLinea> recetas;

  /// Coste por unidad de stock de cada ingrediente HOJA (materia prima), en
  /// euros. Opcional: si está vacío no se calculan costes. Las claves que
  /// correspondan a platos (subrecetas) se ignoran: el coste de un elaborado
  /// se deriva siempre de sus materias primas.
  final Map<String, double> costeUnitario;

  /// Niveles máximos de anidamiento de subrecetas que se toleran. Un plato
  /// cuyos ingredientes son todos materias primas tiene profundidad 1; si uno
  /// de ellos es a su vez un plato, 2; etc. Superarla es casi siempre señal
  /// de datos corruptos y se rechaza con `ValidationException`.
  final int maxProfundidad;

  @override
  List<Object?> get props => [ventas, recetas, costeUnitario, maxProfundidad];
}

/// Trazabilidad: cuánto consumo bruto de una hoja proviene de cada plato
/// raíz vendido.
final class ConsumoDetalle extends Equatable {
  const ConsumoDetalle({
    required this.refIngrediente,
    required this.refPlato,
    required this.cantidadBruta,
  });

  /// Materia prima (hoja del grafo de recetas).
  final String refIngrediente;

  /// Plato raíz vendido del que procede el consumo (no la subreceta
  /// intermedia).
  final String refPlato;

  /// Cantidad bruta SIN redondear, de modo que la suma de los detalles de una
  /// hoja reproduce exactamente su consumo agregado antes del redondeo.
  final double cantidadBruta;

  @override
  List<Object?> get props => [refIngrediente, refPlato, cantidadBruta];
}

/// Coste teórico de materias primas de un plato vendido.
final class CostePlato extends Equatable {
  const CostePlato({
    required this.referencia,
    required this.costeUnitario,
    required this.completo,
  });

  final String referencia;

  /// Coste de materias primas por unidad vendida, en euros (`double` porque
  /// multiplica cantidades fraccionarias de stock; se convierte a céntimos
  /// solo en el borde).
  final double costeUnitario;

  /// `false` si falta el coste de alguna hoja: [costeUnitario] es entonces
  /// una cota inferior.
  final bool completo;

  @override
  List<Object?> get props => [referencia, costeUnitario, completo];
}

/// Resultado de la resolución.
final class EscandalloResult extends Equatable {
  const EscandalloResult({
    required this.consumos,
    required this.detalle,
    required this.sinReceta,
    required this.costes,
    required this.avisos,
  });

  /// Una entrada por materia prima (hoja), agregada sobre todas las ventas,
  /// con cantidad `> 0` redondeada a 3 decimales y ordenada por referencia.
  final List<ConsumoStock> consumos;

  /// Desglose de [consumos] por plato raíz vendido, ordenado por hoja y plato.
  final List<ConsumoDetalle> detalle;

  /// Referencias vendidas que no son plato de ninguna receta, ordenadas. No
  /// generan consumo: su stock lo mueve FacturaScripts al facturar.
  final List<String> sinReceta;

  /// Coste de materias primas por plato vendido con receta, ordenado por
  /// referencia. Vacío si la petición no traía costes.
  final List<CostePlato> costes;

  /// Incidencias no bloqueantes (costes incompletos, consumos por debajo de
  /// la precisión de stock...).
  final List<String> avisos;

  @override
  List<Object?> get props => [consumos, detalle, sinReceta, costes, avisos];
}
