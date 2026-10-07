import 'package:equatable/equatable.dart';

import '../../../core/utils/json_map.dart';
import 'linea_comanda.dart';

/// Comanda abierta de una mesa: todo lo pedido desde que se ocupó hasta que
/// se cobra. Una mesa tiene como mucho una comanda abierta.
final class Comanda extends Equatable {
  Comanda({
    required this.id,
    required this.mesaId,
    required this.abiertaEn,
    List<LineaComanda> lineas = const [],
    this.camarero,
    this.comensales,
    this.cuentaSolicitada = false,
    this.observaciones,
  }) : lineas = List.unmodifiable(lineas);

  factory Comanda.fromJson(Map<String, Object?> json) => Comanda(
    id: json.requireString('id'),
    mesaId: json.requireString('mesaId'),
    abiertaEn: DateTime.parse(json.requireString('abiertaEn')),
    lineas: [
      for (final linea in json.requireMapList('lineas'))
        LineaComanda.fromJson(linea),
    ],
    camarero: json.optionalString('camarero'),
    comensales: json.optionalInt('comensales'),
    cuentaSolicitada: json.optionalBool('cuentaSolicitada') ?? false,
    observaciones: json.optionalString('observaciones'),
  );

  final String id;
  final String mesaId;
  final DateTime abiertaEn;

  /// Líneas en orden de llegada, incluidas las anuladas (quedan para la
  /// trazabilidad y para revertir su stock una sola vez).
  final List<LineaComanda> lineas;
  final String? camarero;
  final int? comensales;

  /// El cliente ha pedido la cuenta (la mesa se resalta en el host).
  final bool cuentaSolicitada;
  final String? observaciones;

  Iterable<LineaComanda> get lineasActivas =>
      lineas.where((linea) => !linea.anulada);

  bool get estaVacia => lineasActivas.isEmpty;

  /// Suma de PVP × cantidad de las líneas activas. Es el importe orientativo
  /// de la mesa; el total legal del ticket lo calcula la réplica del
  /// `Calculator` de FacturaScripts al cobrar y puede diferir en un céntimo.
  int get importeCents =>
      lineasActivas.fold(0, (total, linea) => total + linea.importeCents);

  LineaComanda? lineaPorId(String lineaId) {
    for (final linea in lineas) {
      if (linea.id == lineaId) return linea;
    }
    return null;
  }

  /// Añade las líneas cuyo [LineaComanda.id] no exista ya (idempotente ante
  /// retransmisiones). Devuelve la comanda resultante y las líneas que
  /// realmente se incorporaron.
  ({Comanda comanda, List<LineaComanda> nuevas}) conLineas(
    Iterable<LineaComanda> candidatas,
  ) {
    final existentes = {for (final linea in lineas) linea.id};
    final nuevas = <LineaComanda>[];
    for (final linea in candidatas) {
      if (existentes.add(linea.id)) nuevas.add(linea);
    }
    if (nuevas.isEmpty) return (comanda: this, nuevas: const []);
    return (comanda: copyWith(lineas: [...lineas, ...nuevas]), nuevas: nuevas);
  }

  /// Sustituye la línea con el mismo id.
  Comanda conLineaActualizada(LineaComanda actualizada) => copyWith(
    lineas: [
      for (final linea in lineas)
        if (linea.id == actualizada.id) actualizada else linea,
    ],
  );

  Comanda copyWith({
    List<LineaComanda>? lineas,
    String? camarero,
    int? comensales,
    bool? cuentaSolicitada,
    String? observaciones,
  }) => Comanda(
    id: id,
    mesaId: mesaId,
    abiertaEn: abiertaEn,
    lineas: lineas ?? this.lineas,
    camarero: camarero ?? this.camarero,
    comensales: comensales ?? this.comensales,
    cuentaSolicitada: cuentaSolicitada ?? this.cuentaSolicitada,
    observaciones: observaciones ?? this.observaciones,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'mesaId': mesaId,
    'abiertaEn': abiertaEn.toIso8601String(),
    'lineas': [for (final linea in lineas) linea.toJson()],
    if (camarero != null) 'camarero': camarero,
    if (comensales != null) 'comensales': comensales,
    'cuentaSolicitada': cuentaSolicitada,
    if (observaciones != null) 'observaciones': observaciones,
  };

  @override
  List<Object?> get props => [
    id,
    mesaId,
    abiertaEn,
    lineas,
    camarero,
    comensales,
    cuentaSolicitada,
    observaciones,
  ];
}
