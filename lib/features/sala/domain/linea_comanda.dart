import 'package:equatable/equatable.dart';

import '../../../core/money/money.dart';
import '../../../core/utils/json_map.dart';
import '../../../core/utils/json_tolerante.dart';

/// Ciclo de vida de una línea de comanda.
enum EstadoLinea {
  /// Aceptada por el host y enviada a cocina/barra.
  enviada,

  /// Marcada como servida (opcional, informativo).
  servida,

  /// Anulada antes de cobrar: no se factura y se revierte su stock.
  anulada;

  static EstadoLinea parse(String value) => EstadoLinea.values.firstWhere(
    (estado) => estado.name == value,
    orElse: () => throw FormatException("Estado de línea desconocido '$value'"),
  );
}

/// Destino de impresión de la línea en cocina.
enum DestinoPreparacion {
  cocina,
  barra;

  static DestinoPreparacion parse(String value) =>
      DestinoPreparacion.values.firstWhere(
        (destino) => destino.name == value,
        orElse: () => throw FormatException("Destino desconocido '$value'"),
      );
}

/// Una línea de comanda: un artículo pedido para una mesa.
///
/// El [id] lo genera el comandero al crear la línea y viaja con ella: si la
/// misma petición llega dos veces al host (retransmisión tras reconectar), la
/// segunda se reconoce por el id y no se duplica la línea.
///
/// Los precios se congelan al pedir (el catálogo puede cambiar después):
/// [pvpUnitarioCents] es lo que ve el cliente y [pvpUnitarioNeto] +
/// [codimpuesto] es lo que se enviará a FacturaScripts al facturar.
///
/// [pase] y [envio] son posteriores a la primera versión del diario: se leen
/// de forma tolerante y solo se escriben cuando no son nulos, de modo que un
/// JSON antiguo se reescribe igual.
final class LineaComanda extends Equatable {
  const LineaComanda({
    required this.id,
    required this.referencia,
    required this.descripcion,
    required this.cantidad,
    required this.pvpUnitarioCents,
    required this.pvpUnitarioNeto,
    required this.ivaBp,
    this.codimpuesto,
    this.nota,
    this.estado = EstadoLinea.enviada,
    this.destino = DestinoPreparacion.cocina,
    this.camarero,
    required this.creadaEn,
    this.anuladaEn,
    this.motivoAnulacion,
    this.pase,
    this.envio,
  });

  factory LineaComanda.fromJson(Map<String, Object?> json) => LineaComanda(
    id: json.requireString('id'),
    referencia: json.requireString('referencia'),
    descripcion: json.requireString('descripcion'),
    cantidad: json.requireDouble('cantidad'),
    pvpUnitarioCents: json.requireInt('pvpUnitarioCents'),
    pvpUnitarioNeto: json.requireDouble('pvpUnitarioNeto'),
    ivaBp: json.requireInt('ivaBp'),
    codimpuesto: json.optionalString('codimpuesto'),
    nota: json.optionalString('nota'),
    estado: EstadoLinea.parse(json.optionalString('estado') ?? 'enviada'),
    destino: DestinoPreparacion.parse(
      json.optionalString('destino') ?? 'cocina',
    ),
    camarero: json.optionalString('camarero'),
    creadaEn: DateTime.parse(json.requireString('creadaEn')),
    anuladaEn: switch (json.optionalString('anuladaEn')) {
      final String text => DateTime.parse(text),
      null => null,
    },
    motivoAnulacion: json.optionalString('motivoAnulacion'),
    // Un valor ausente, de otro tipo o no positivo se lee como «directo» y
    // «sin nº de envío»: nunca invalida la línea.
    pase: enteroPositivoTolerante(json['pase']),
    envio: enteroPositivoTolerante(json['envio']),
  );

  final String id;

  /// `variantes.referencia` del artículo en FacturaScripts.
  final String referencia;
  final String descripcion;

  /// Unidades pedidas (admite fracciones para artículos al peso).
  final double cantidad;

  /// Precio unitario con IVA, en céntimos.
  final int pvpUnitarioCents;

  /// Precio unitario sin IVA (hasta 5 decimales), tal como lo guarda el ERP.
  final double pvpUnitarioNeto;

  /// Tipo de IVA en puntos básicos (`1000` = 10 %).
  final int ivaBp;
  final String? codimpuesto;

  /// Indicaciones para cocina ("sin cebolla", "muy hecho").
  final String? nota;
  final EstadoLinea estado;
  final DestinoPreparacion destino;
  final String? camarero;
  final DateTime creadaEn;
  final DateTime? anuladaEn;
  final String? motivoAnulacion;

  /// Pase de la línea: `null` = directa (sale sin esperar a ninguna marcha);
  /// `1..n` = posición, en base 1, en `PasesConfig.nombres`. Un pase fuera
  /// de la configuración se conserva y se rotula «Pase N».
  final int? pase;

  /// Nº de envío del turno en el que el host aceptó la línea (`null` en las
  /// líneas de un diario anterior a este campo o aún no aceptadas).
  final int? envio;

  bool get anulada => estado == EstadoLinea.anulada;

  /// Importe con IVA de la línea (`0` si está anulada).
  int get importeCents =>
      anulada ? 0 : lineTotalCents(pvpUnitarioCents, cantidad);

  /// Copia con cambios; cubre todos los campos salvo la identidad ([id],
  /// [referencia], [descripcion] y [creadaEn]). [codimpuesto] y [pase]
  /// reciben un getter para poder dejarlos a `null`: `pase: () => null`
  /// devuelve la línea a «directa».
  LineaComanda copyWith({
    EstadoLinea? estado,
    DateTime? anuladaEn,
    String? motivoAnulacion,
    String? nota,
    double? cantidad,
    DestinoPreparacion? destino,
    int? pvpUnitarioCents,
    double? pvpUnitarioNeto,
    int? ivaBp,
    String? Function()? codimpuesto,
    String? camarero,
    int? Function()? pase,
    int? envio,
  }) => LineaComanda(
    id: id,
    referencia: referencia,
    descripcion: descripcion,
    cantidad: cantidad ?? this.cantidad,
    pvpUnitarioCents: pvpUnitarioCents ?? this.pvpUnitarioCents,
    pvpUnitarioNeto: pvpUnitarioNeto ?? this.pvpUnitarioNeto,
    ivaBp: ivaBp ?? this.ivaBp,
    codimpuesto: codimpuesto == null ? this.codimpuesto : codimpuesto(),
    nota: nota ?? this.nota,
    estado: estado ?? this.estado,
    destino: destino ?? this.destino,
    camarero: camarero ?? this.camarero,
    creadaEn: creadaEn,
    anuladaEn: anuladaEn ?? this.anuladaEn,
    motivoAnulacion: motivoAnulacion ?? this.motivoAnulacion,
    pase: pase == null ? this.pase : pase(),
    envio: envio ?? this.envio,
  );

  /// Devuelve la línea anulada; una línea ya anulada se devuelve tal cual.
  LineaComanda anular({required DateTime cuando, String? motivo}) => anulada
      ? this
      : copyWith(
          estado: EstadoLinea.anulada,
          anuladaEn: cuando,
          motivoAnulacion: motivo,
        );

  Map<String, Object?> toJson() => {
    'id': id,
    'referencia': referencia,
    'descripcion': descripcion,
    'cantidad': cantidad,
    'pvpUnitarioCents': pvpUnitarioCents,
    'pvpUnitarioNeto': pvpUnitarioNeto,
    'ivaBp': ivaBp,
    if (codimpuesto != null) 'codimpuesto': codimpuesto,
    if (nota != null) 'nota': nota,
    'estado': estado.name,
    'destino': destino.name,
    if (camarero != null) 'camarero': camarero,
    'creadaEn': creadaEn.toIso8601String(),
    if (anuladaEn != null) 'anuladaEn': anuladaEn!.toIso8601String(),
    if (motivoAnulacion != null) 'motivoAnulacion': motivoAnulacion,
    if (pase != null) 'pase': pase,
    if (envio != null) 'envio': envio,
  };

  @override
  List<Object?> get props => [
    id,
    referencia,
    descripcion,
    cantidad,
    pvpUnitarioCents,
    pvpUnitarioNeto,
    ivaBp,
    codimpuesto,
    nota,
    estado,
    destino,
    camarero,
    creadaEn,
    anuladaEn,
    motivoAnulacion,
    pase,
    envio,
  ];
}
