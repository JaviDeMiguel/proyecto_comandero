/// Modelos del asiento del Cierre Z y de la resolución de subcuentas
/// (`FsAccountingService`).
library;

import 'package:equatable/equatable.dart';

import '../../errors/app_exception.dart';
import '../documents/fs_idempotency_key.dart';

/// Papeles contables del Cierre Z. Cada uno se resuelve a una subcuenta del
/// ejercicio por su `codcuenta` (nunca a fuego: el plan puede ser distinto).
enum CuentaZ {
  caja570('570', 'caja'),
  banco572('572', 'bancos'),
  ventas700('700', 'ventas'),
  ivaRepercutido477('477', 'IVA repercutido'),
  perdidas659('659', 'pérdidas por descuadre'),
  ingresos759('759', 'ingresos por descuadre');

  const CuentaZ(this.codcuenta, this.descripcion);

  /// Código de la cuenta padre (`subcuentas.codcuenta`).
  final String codcuenta;
  final String descripcion;
}

/// Subcuentas resueltas para un ejercicio.
final class SubcuentasCierre extends Equatable {
  const SubcuentasCierre({
    required this.codejercicio,
    required this.porCuenta,
    required this.ivaPorCodimpuesto,
  });

  final String codejercicio;

  /// `codsubcuenta` de cada papel (completo, con la longitud del ejercicio).
  final Map<CuentaZ, String> porCuenta;

  /// `impuestos.codsubcuentarep` por `codimpuesto` (`IVA10` → `4770000010`).
  final Map<String, String> ivaPorCodimpuesto;

  String operator [](CuentaZ cuenta) => porCuenta[cuenta]!;

  /// Subcuenta de IVA repercutido del impuesto; sin impuesto (o impuesto sin
  /// subcuenta propia, como `IVA0`) cae a la 477 genérica.
  String subcuentaIva(String? codimpuesto) =>
      (codimpuesto == null ? null : ivaPorCodimpuesto[codimpuesto]) ??
      porCuenta[CuentaZ.ivaRepercutido477]!;

  @override
  List<Object?> get props => [codejercicio, porCuenta, ivaPorCodimpuesto];
}

/// Partida (línea) del asiento Z. Importes en céntimos; `baseCents` e
/// `ivaPct` solo en partidas de IVA repercutido (libro de IVA).
final class PartidaZ extends Equatable {
  PartidaZ({
    required this.codsubcuenta,
    required this.concepto,
    this.debeCents = 0,
    this.haberCents = 0,
    this.baseCents,
    this.ivaPct,
  }) {
    if (codsubcuenta.trim().isEmpty) {
      throw const ValidationException('Partida sin codsubcuenta');
    }
    if (concepto.trim().isEmpty) {
      throw ValidationException('Partida $codsubcuenta sin concepto');
    }
    if (debeCents < 0 || haberCents < 0) {
      throw ValidationException(
        'Partida $codsubcuenta con importe negativo '
        '(debe $debeCents, haber $haberCents)',
      );
    }
    if (debeCents == 0 && haberCents == 0) {
      throw ValidationException('Partida $codsubcuenta sin importe');
    }
  }

  final String codsubcuenta;

  /// El concepto NO se hereda del asiento en un POST en crudo: cada partida
  /// lleva el suyo.
  final String concepto;
  final int debeCents;
  final int haberCents;
  final int? baseCents;
  final double? ivaPct;

  @override
  List<Object?> get props => [
    codsubcuenta,
    concepto,
    debeCents,
    haberCents,
    baseCents,
    ivaPct,
  ];
}

/// Asiento del Cierre Z listo para contabilizar.
final class AsientoZ extends Equatable {
  AsientoZ({
    required String clave,
    required this.fecha,
    required this.concepto,
    required this.lineas,
  }) : clave = validarClaveIdempotente(clave, campo: 'documento') {
    if (concepto.trim().isEmpty) {
      throw const ValidationException('El asiento no tiene concepto');
    }
    if (lineas.isEmpty) {
      throw const ValidationException('El asiento no tiene partidas');
    }
  }

  /// Clave guardada en `asientos.documento` y en cada partida
  /// (p. ej. `Z-20261006-T1`; ≤ 50, no parece una fecha).
  final String clave;

  /// Fecha de negocio del cierre; decide el ejercicio.
  final DateTime fecha;
  final String concepto;
  final List<PartidaZ> lineas;

  int get debeTotalCents =>
      lineas.fold(0, (sum, linea) => sum + linea.debeCents);

  int get haberTotalCents =>
      lineas.fold(0, (sum, linea) => sum + linea.haberCents);

  /// FacturaScripts guarda asientos descuadrados sin protestar: el cuadre se
  /// exige aquí, en céntimos enteros.
  bool get cuadrado => debeTotalCents == haberTotalCents;

  @override
  List<Object?> get props => [clave, fecha, concepto, lineas];
}

/// Resultado de contabilizar (o reanudar) el asiento Z.
final class ResultadoAsiento extends Equatable {
  const ResultadoAsiento({
    required this.idasiento,
    required this.numero,
    required this.yaExistia,
    required this.partidasCreadas,
    required this.verificado,
  });

  final int idasiento;

  /// Número del asiento dentro del ejercicio (lo asigna FacturaScripts).
  final int? numero;

  /// El asiento ya existía completo y no se tocó.
  final bool yaExistia;

  /// Partidas enviadas en esta llamada (0 si [yaExistia]).
  final int partidasCreadas;

  /// `GET partidas` confirmó número de partidas y sumas. `false` solo si la
  /// lectura de verificación falló por red después de crear todo.
  final bool verificado;

  @override
  List<Object?> get props => [
    idasiento,
    numero,
    yaExistia,
    partidasCreadas,
    verificado,
  ];
}
