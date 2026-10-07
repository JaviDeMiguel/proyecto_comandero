import 'package:equatable/equatable.dart';

import '../../../core/facturascripts/accounting/accounting_models.dart';
import '../../../core/isolates/cierre_z/cierre_z_models.dart';
import '../../../core/utils/json_map.dart';
import 'settings_json.dart';

/// Ajustes fiscales y de facturación contra FacturaScripts.
final class FiscalSettings extends Equatable {
  const FiscalSettings({
    this.codserie = 'S',
    this.codcliente = 'TPV',
    this.codalmacen,
    this.codpagoEfectivo = 'CONT',
    this.codpagoTarjeta = 'TARJETA',
    this.idempresa,
    this.emitirFacturas = true,
    this.modoAsientoZ = ModoAsientoZ.soloDescuadre,
    this.subcuentasOverride = const {},
    this.nombreTpv = 'TPV 1',
  });

  /// Lee los ajustes guardados. Campos ausentes → valor por defecto. Lanza
  /// [FormatException] si un campo presente es inválido.
  factory FiscalSettings.fromJson(Map<String, Object?> json) {
    const defaults = FiscalSettings();
    final overrideJson = json.optionalMap('subcuentasOverride') ?? const {};
    final override = <CuentaZ, String>{};
    for (final entry in overrideJson.entries) {
      final cuenta = CuentaZ.values.asNameMap()[entry.key];
      if (cuenta == null) {
        throw FormatException(
          "Campo 'subcuentasOverride': papel contable desconocido "
          "'${entry.key}'",
        );
      }
      final value = entry.value;
      if (value is! String || value.trim().isEmpty) {
        throw FormatException(
          "Campo 'subcuentasOverride.${entry.key}': se esperaba un "
          'código de subcuenta no vacío',
        );
      }
      override[cuenta] = value.trim();
    }
    return FiscalSettings(
      codserie: json.optionalString('codserie') ?? defaults.codserie,
      codcliente: json.optionalString('codcliente') ?? defaults.codcliente,
      codalmacen: json.optionalString('codalmacen'),
      codpagoEfectivo:
          json.optionalString('codpagoEfectivo') ?? defaults.codpagoEfectivo,
      codpagoTarjeta:
          json.optionalString('codpagoTarjeta') ?? defaults.codpagoTarjeta,
      idempresa: json.optionalInt('idempresa'),
      emitirFacturas:
          json.optionalBool('emitirFacturas') ?? defaults.emitirFacturas,
      modoAsientoZ: enumPorNombre(
        ModoAsientoZ.values,
        json['modoAsientoZ'],
        defaults.modoAsientoZ,
        campo: 'modoAsientoZ',
      ),
      subcuentasOverride: override,
      nombreTpv: json.optionalString('nombreTpv') ?? defaults.nombreTpv,
    );
  }

  /// Serie de las facturas simplificadas (`codserie`).
  final String codserie;

  /// Cliente genérico de los tickets (`codcliente`).
  final String codcliente;

  /// Almacén del TPV (`codalmacen`). `null` = almacén por defecto de FS.
  final String? codalmacen;

  /// Forma de pago para cobros en efectivo.
  final String codpagoEfectivo;

  /// Forma de pago para cobros con tarjeta.
  final String codpagoTarjeta;

  /// Empresa de FS (`idempresa`); `null` = la única / por defecto.
  final int? idempresa;

  /// Tras crear la factura, pasarla al estado "Emitida" (no editable).
  final bool emitirFacturas;

  /// Qué asiento genera el Cierre Z.
  final ModoAsientoZ modoAsientoZ;

  /// Subcuentas forzadas por papel contable; las que no estén aquí se
  /// resuelven automáticamente por ejercicio.
  final Map<CuentaZ, String> subcuentasOverride;

  /// Nombre del punto de venta en observaciones y tickets.
  final String nombreTpv;

  Map<String, Object?> toJson() => {
    'codserie': codserie,
    'codcliente': codcliente,
    if (codalmacen != null) 'codalmacen': codalmacen,
    'codpagoEfectivo': codpagoEfectivo,
    'codpagoTarjeta': codpagoTarjeta,
    if (idempresa != null) 'idempresa': idempresa,
    'emitirFacturas': emitirFacturas,
    'modoAsientoZ': modoAsientoZ.name,
    'subcuentasOverride': {
      for (final entry in subcuentasOverride.entries)
        entry.key.name: entry.value,
    },
    'nombreTpv': nombreTpv,
  };

  FiscalSettings copyWith({
    String? codserie,
    String? codcliente,
    String? codalmacen,
    bool borrarCodalmacen = false,
    String? codpagoEfectivo,
    String? codpagoTarjeta,
    int? idempresa,
    bool borrarIdempresa = false,
    bool? emitirFacturas,
    ModoAsientoZ? modoAsientoZ,
    Map<CuentaZ, String>? subcuentasOverride,
    String? nombreTpv,
  }) => FiscalSettings(
    codserie: codserie ?? this.codserie,
    codcliente: codcliente ?? this.codcliente,
    codalmacen: borrarCodalmacen ? null : (codalmacen ?? this.codalmacen),
    codpagoEfectivo: codpagoEfectivo ?? this.codpagoEfectivo,
    codpagoTarjeta: codpagoTarjeta ?? this.codpagoTarjeta,
    idempresa: borrarIdempresa ? null : (idempresa ?? this.idempresa),
    emitirFacturas: emitirFacturas ?? this.emitirFacturas,
    modoAsientoZ: modoAsientoZ ?? this.modoAsientoZ,
    subcuentasOverride: subcuentasOverride ?? this.subcuentasOverride,
    nombreTpv: nombreTpv ?? this.nombreTpv,
  );

  @override
  List<Object?> get props => [
    codserie,
    codcliente,
    codalmacen,
    codpagoEfectivo,
    codpagoTarjeta,
    idempresa,
    emitirFacturas,
    modoAsientoZ,
    // Equatable compara mapas por contenido (DeepCollectionEquality).
    subcuentasOverride,
    nombreTpv,
  ];
}
