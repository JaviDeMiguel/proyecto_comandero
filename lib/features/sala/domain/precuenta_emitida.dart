import 'package:equatable/equatable.dart';

import '../../../core/utils/json_map.dart';
import '../../../core/utils/json_tolerante.dart';
import 'linea_comanda.dart';
import 'ticket.dart';

/// Datos imprimibles de una línea activa en el momento de la precuenta.
///
/// Es una copia, no una referencia a la [LineaComanda]: si después se anula
/// la línea, la precuenta sigue reconstruyéndose tal como salió.
final class LineaPrecuenta extends Equatable {
  const LineaPrecuenta({
    required this.descripcion,
    required this.cantidad,
    required this.pvpUnitarioCents,
    required this.importeCents,
    required this.ivaBp,
    this.codimpuesto,
    this.referencia,
    this.nota,
  });

  /// Copia los datos imprimibles de [linea] (con su [LineaComanda.importeCents]).
  factory LineaPrecuenta.desde(LineaComanda linea) => LineaPrecuenta(
    descripcion: linea.descripcion,
    cantidad: linea.cantidad,
    pvpUnitarioCents: linea.pvpUnitarioCents,
    importeCents: linea.importeCents,
    ivaBp: linea.ivaBp,
    codimpuesto: linea.codimpuesto,
    referencia: linea.referencia,
    nota: linea.nota,
  );

  /// Lectura estricta ([FormatException]); `PrecuentaEmitida.fromJson` la
  /// envuelve con `listaTolerante` y descarta la línea ilegible.
  factory LineaPrecuenta.fromJson(Map<String, Object?> json) => LineaPrecuenta(
    descripcion: json.requireString('descripcion'),
    cantidad: json.requireDouble('cantidad'),
    pvpUnitarioCents: json.requireInt('pvpUnitarioCents'),
    importeCents: json.requireInt('importeCents'),
    ivaBp: json.requireInt('ivaBp'),
    codimpuesto: json.optionalString('codimpuesto'),
    referencia: json.optionalString('referencia'),
    nota: json.optionalString('nota'),
  );

  final String descripcion;
  final double cantidad;

  /// Precio unitario con IVA, en céntimos.
  final int pvpUnitarioCents;

  /// Importe con IVA de la línea, en céntimos.
  final int importeCents;

  /// Tipo de IVA en puntos básicos (`1000` = 10 %).
  final int ivaBp;
  final String? codimpuesto;
  final String? referencia;
  final String? nota;

  /// [codimpuesto], [referencia] y [nota] solo si no son nulos.
  Map<String, Object?> toJson() => {
    'descripcion': descripcion,
    'cantidad': cantidad,
    'pvpUnitarioCents': pvpUnitarioCents,
    'importeCents': importeCents,
    'ivaBp': ivaBp,
    if (codimpuesto != null) 'codimpuesto': codimpuesto,
    if (referencia != null) 'referencia': referencia,
    if (nota != null) 'nota': nota,
  };

  @override
  List<Object?> get props => [
    descripcion,
    cantidad,
    pvpUnitarioCents,
    importeCents,
    ivaBp,
    codimpuesto,
    referencia,
    nota,
  ];
}

/// Precuenta emitida a una mesa: documento autocontenido con lo que se
/// imprimió (líneas activas y totales de ese momento), no referencias a la
/// comanda. Si después se anula una línea o se vacía la mesa, la precuenta
/// sigue pudiéndose reconstruir y reimprimir tal cual salió.
final class PrecuentaEmitida extends Equatable {
  PrecuentaEmitida({
    required this.numero,
    required this.emitidaEn,
    required this.comandaId,
    required this.nombreMesa,
    required List<LineaPrecuenta> lineas,
    required this.totales,
    this.comensales,
    this.emitidaPor,
  }) : lineas = List.unmodifiable(lineas);

  /// Lectura estricta ([FormatException]) salvo en [lineas], donde una línea
  /// ilegible se descarta. `Comanda.fromJson` y `Ticket.fromJson` la
  /// envuelven con `listaTolerante` y descartan la precuenta ilegible.
  factory PrecuentaEmitida.fromJson(Map<String, Object?> json) {
    final numero = json.requireInt('numero');
    if (numero < 1) {
      throw FormatException(
        "Campo 'numero': se esperaba un entero positivo y llegó $numero",
      );
    }
    return PrecuentaEmitida(
      numero: numero,
      emitidaEn: DateTime.parse(json.requireString('emitidaEn')),
      comandaId: json.requireString('comandaId'),
      nombreMesa: json.requireString('nombreMesa'),
      lineas: listaTolerante(json['lineas'], LineaPrecuenta.fromJson),
      totales: TotalesTicket.fromJson(json.requireMap('totales')),
      comensales: json.optionalInt('comensales'),
      emitidaPor: json.optionalString('emitidaPor'),
    );
  }

  /// Ordinal dentro de la comanda (1, 2, 3…).
  final int numero;

  /// Reloj del host al emitirla.
  final DateTime emitidaEn;
  final String comandaId;
  final String nombreMesa;

  /// Líneas activas en el momento de la precuenta.
  final List<LineaPrecuenta> lineas;

  /// Totales legales de ese momento (réplica del `Calculator` de
  /// FacturaScripts), con el mismo JSON que en el ticket.
  final TotalesTicket totales;
  final int? comensales;

  /// Dispositivo o camarero que la pidió.
  final String? emitidaPor;

  int get totalCents => totales.totalCents;

  /// [comensales] y [emitidaPor] solo si no son nulos.
  Map<String, Object?> toJson() => {
    'numero': numero,
    'emitidaEn': emitidaEn.toIso8601String(),
    'comandaId': comandaId,
    'nombreMesa': nombreMesa,
    'lineas': [for (final linea in lineas) linea.toJson()],
    'totales': totales.toJson(),
    if (comensales != null) 'comensales': comensales,
    if (emitidaPor != null) 'emitidaPor': emitidaPor,
  };

  @override
  List<Object?> get props => [
    numero,
    emitidaEn,
    comandaId,
    nombreMesa,
    lineas,
    totales,
    comensales,
    emitidaPor,
  ];
}

/// Precuenta de una mesa que se vació sin cobrar: queda registrada en el
/// diario del host y sale en el Cierre Z.
final class PrecuentaSinCobro extends Equatable {
  const PrecuentaSinCobro({
    required this.precuenta,
    required this.vaciadaEn,
    this.motivo,
  });

  /// Lectura estricta ([FormatException]); quien guarda la lista la envuelve
  /// con `listaTolerante`.
  factory PrecuentaSinCobro.fromJson(Map<String, Object?> json) =>
      PrecuentaSinCobro(
        precuenta: PrecuentaEmitida.fromJson(json.requireMap('precuenta')),
        vaciadaEn: DateTime.parse(json.requireString('vaciadaEn')),
        motivo: json.optionalString('motivo'),
      );

  final PrecuentaEmitida precuenta;

  /// Reloj del host al vaciar la mesa.
  final DateTime vaciadaEn;

  /// El motivo con el que se vació la mesa, si se indicó.
  final String? motivo;

  /// [motivo] solo si no es nulo.
  Map<String, Object?> toJson() => {
    'precuenta': precuenta.toJson(),
    'vaciadaEn': vaciadaEn.toIso8601String(),
    if (motivo != null) 'motivo': motivo,
  };

  @override
  List<Object?> get props => [precuenta, vaciadaEn, motivo];
}
