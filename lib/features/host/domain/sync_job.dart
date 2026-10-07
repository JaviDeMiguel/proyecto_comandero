import 'package:equatable/equatable.dart';

import '../../../core/utils/json_map.dart';

/// Tipo de trabajo de la cola de sincronización con el ERP.
enum SyncJobTipo {
  /// Descuento (o devolución) de materias primas por MySQL directo.
  descuentoStock,

  /// Factura simplificada del ticket (`crearFacturaCliente`).
  factura,

  /// Pedido a proveedor del reaprovisionamiento automático.
  pedidoProveedor,

  /// Asiento del Cierre Z.
  asientoZ;

  static SyncJobTipo parse(String value) => SyncJobTipo.values.firstWhere(
    (tipo) => tipo.name == value,
    orElse: () => throw FormatException("Tipo de trabajo desconocido '$value'"),
  );
}

/// Ciclo de vida de un [SyncJob].
enum SyncJobEstado {
  /// A la espera de turno (o de que venza el backoff).
  pendiente,

  /// Ejecutándose ahora mismo. Tras un reinicio vuelve a `pendiente`: los
  /// servicios del ERP son idempotentes por clave.
  enCurso,

  /// Completado.
  hecho,

  /// Rechazado definitivamente (validación): requiere decisión del usuario.
  error,

  /// La cola está en pausa (fallo de credenciales o ERP sin configurar) y el
  /// trabajo espera a que el usuario la reanude.
  bloqueado;

  static SyncJobEstado parse(String value) => SyncJobEstado.values.firstWhere(
    (estado) => estado.name == value,
    orElse: () =>
        throw FormatException("Estado de trabajo desconocido '$value'"),
  );

  /// El trabajo ya no cambiará por sí solo.
  bool get terminal => this == hecho;
}

/// Trabajo persistente e idempotente de la cola de sincronización.
///
/// El [payload] es JSON plano y autosuficiente: el trabajo debe poder
/// ejecutarse aunque la entidad que lo originó ya no esté en el diario (p. ej.
/// la factura de un ticket cuyo turno ya se cerró).
final class SyncJob extends Equatable {
  SyncJob({
    required this.id,
    required this.tipo,
    required Map<String, Object?> payload,
    required this.creadoEn,
    this.intentos = 0,
    this.estado = SyncJobEstado.pendiente,
    this.ultimoError,
    this.proximoIntentoEn,
    this.terminadoEn,
    List<String> avisos = const [],
  }) : payload = Map.unmodifiable(payload),
       avisos = List.unmodifiable(avisos);

  factory SyncJob.fromJson(Map<String, Object?> json) => SyncJob(
    id: json.requireString('id'),
    tipo: SyncJobTipo.parse(json.requireString('tipo')),
    payload: json.requireMap('payload'),
    creadoEn: DateTime.parse(json.requireString('creadoEn')),
    intentos: json.optionalInt('intentos') ?? 0,
    estado: SyncJobEstado.parse(json.optionalString('estado') ?? 'pendiente'),
    ultimoError: json.optionalString('ultimoError'),
    proximoIntentoEn: _fecha(json.optionalString('proximoIntentoEn')),
    terminadoEn: _fecha(json.optionalString('terminadoEn')),
    avisos: [
      for (final aviso in json.optionalList('avisos') ?? const [])
        aviso.toString(),
    ],
  );

  final String id;
  final SyncJobTipo tipo;
  final Map<String, Object?> payload;
  final DateTime creadoEn;

  /// Ejecuciones intentadas hasta ahora.
  final int intentos;
  final SyncJobEstado estado;
  final String? ultimoError;

  /// Antes de este instante no se vuelve a intentar (backoff).
  final DateTime? proximoIntentoEn;
  final DateTime? terminadoEn;

  /// Avisos no bloqueantes del último intento completado.
  final List<String> avisos;

  /// Clave de negocio del trabajo, para mostrar en la interfaz.
  String get descripcion => switch (tipo) {
    SyncJobTipo.descuentoStock =>
      'Stock ${payload['operacion'] ?? ''}'.trimRight(),
    SyncJobTipo.factura => switch (payload['ticket']) {
      final Map<String, Object?> ticket =>
        'Factura ticket ${ticket['numeroLocal'] ?? ''}'.trimRight(),
      _ => 'Factura',
    },
    SyncJobTipo.pedidoProveedor =>
      'Pedido ${payload['codproveedor'] ?? ''}'.trimRight(),
    SyncJobTipo.asientoZ => 'Asiento ${payload['clave'] ?? ''}'.trimRight(),
  };

  SyncJob copyWith({
    int? intentos,
    SyncJobEstado? estado,
    String? ultimoError,
    DateTime? proximoIntentoEn,
    DateTime? terminadoEn,
    List<String>? avisos,
    bool limpiarError = false,
    bool limpiarProximoIntento = false,
  }) => SyncJob(
    id: id,
    tipo: tipo,
    payload: payload,
    creadoEn: creadoEn,
    intentos: intentos ?? this.intentos,
    estado: estado ?? this.estado,
    ultimoError: limpiarError ? null : (ultimoError ?? this.ultimoError),
    proximoIntentoEn: limpiarProximoIntento
        ? null
        : (proximoIntentoEn ?? this.proximoIntentoEn),
    terminadoEn: terminadoEn ?? this.terminadoEn,
    avisos: avisos ?? this.avisos,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'tipo': tipo.name,
    'payload': payload,
    'creadoEn': creadoEn.toIso8601String(),
    'intentos': intentos,
    'estado': estado.name,
    if (ultimoError != null) 'ultimoError': ultimoError,
    if (proximoIntentoEn != null)
      'proximoIntentoEn': proximoIntentoEn!.toIso8601String(),
    if (terminadoEn != null) 'terminadoEn': terminadoEn!.toIso8601String(),
    'avisos': avisos,
  };

  @override
  List<Object?> get props => [
    id,
    tipo,
    payload,
    creadoEn,
    intentos,
    estado,
    ultimoError,
    proximoIntentoEn,
    terminadoEn,
    avisos,
  ];
}

DateTime? _fecha(String? text) => text == null ? null : DateTime.parse(text);
