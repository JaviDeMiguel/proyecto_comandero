import 'package:equatable/equatable.dart';

/// Forma de cobro de un ticket, a efectos del cierre.
enum MetodoPago { efectivo, tarjeta }

/// Modo de contabilización del cierre (ver DESIGN_BRIEF §5).
enum ModoAsientoZ {
  /// Solo el descuadre de caja (659/759 contra 570). Es el modo correcto
  /// cuando cada ticket es una factura con asiento automático en el ERP.
  soloDescuadre,

  /// Asiento resumen completo (570/572 al Debe; 700/477 al Haber). Solo si
  /// las facturas NO generan asiento: de lo contrario duplica la contabilidad.
  resumenCompleto,
}

/// Base y cuota de un tipo de IVA dentro de un ticket (ya redondeadas).
final class DesgloseIvaTicket extends Equatable {
  const DesgloseIvaTicket({
    this.codimpuesto,
    required this.ivaBp,
    required this.baseCents,
    required this.cuotaCents,
  });

  final String? codimpuesto;

  /// Tipo en puntos básicos (`1000` = 10 %).
  final int ivaBp;
  final int baseCents;
  final int cuotaCents;

  int get totalCents => baseCents + cuotaCents;

  @override
  List<Object?> get props => [codimpuesto, ivaBp, baseCents, cuotaCents];
}

/// Parte del cobro de un ticket con una forma de pago.
final class PagoCierre extends Equatable {
  const PagoCierre({required this.metodo, required this.importeCents});

  final MetodoPago metodo;
  final int importeCents;

  @override
  List<Object?> get props => [metodo, importeCents];
}

/// Ticket cobrado, con lo que el cierre necesita de él.
final class TicketCierre extends Equatable {
  /// [pagos] es el desglose del cobro (cobro mixto). Si se omite, todo el
  /// total se cobró con [metodoPago]. El motor valida que sume el total.
  TicketCierre({
    required this.id,
    required this.fechaHora,
    required this.totalCents,
    required this.metodoPago,
    required List<DesgloseIvaTicket> desglose,
    List<PagoCierre>? pagos,
    this.anulado = false,
    this.codigoFactura,
  }) : desglose = List.unmodifiable(desglose),
       pagos = List<PagoCierre>.unmodifiable(
         pagos ?? [PagoCierre(metodo: metodoPago, importeCents: totalCents)],
       );

  final String id;
  final DateTime fechaHora;
  final int totalCents;

  /// Forma de pago principal del ticket.
  final MetodoPago metodoPago;
  final List<DesgloseIvaTicket> desglose;

  /// Reparto del cobro por forma de pago (un elemento si no es mixto).
  final List<PagoCierre> pagos;
  final bool anulado;
  final String? codigoFactura;

  /// Parte cobrada en efectivo: la que entra en caja.
  int get efectivoCents => _importeDe(MetodoPago.efectivo);

  /// Parte cobrada con tarjeta.
  int get tarjetaCents => _importeDe(MetodoPago.tarjeta);

  bool get esMixto => pagos.length > 1;

  int _importeDe(MetodoPago metodo) => pagos
      .where((pago) => pago.metodo == metodo)
      .fold(0, (sum, pago) => sum + pago.importeCents);

  @override
  List<Object?> get props => [
    id,
    fechaHora,
    totalCents,
    metodoPago,
    desglose,
    pagos,
    anulado,
    codigoFactura,
  ];
}

/// Subcuentas (códigos completos del ejercicio) que usa el asiento.
final class CuentasCierre extends Equatable {
  const CuentasCierre({
    required this.subcuentaCaja,
    required this.subcuentaBanco,
    required this.subcuentaVentas,
    required this.subcuentaIvaGenerica,
    this.subcuentaIvaPorCodimpuesto = const {},
    required this.subcuentaPerdidas,
    required this.subcuentaIngresos,
  });

  /// 570: caja.
  final String subcuentaCaja;

  /// 572: bancos (cobros con tarjeta).
  final String subcuentaBanco;

  /// 700: ventas.
  final String subcuentaVentas;

  /// 477: IVA repercutido cuando el impuesto no tiene subcuenta propia.
  final String subcuentaIvaGenerica;

  /// 477 por `codimpuesto` (`IVA10` → `4770000010`).
  final Map<String, String> subcuentaIvaPorCodimpuesto;

  /// 659: faltante de caja.
  final String subcuentaPerdidas;

  /// 759: sobrante de caja.
  final String subcuentaIngresos;

  String subcuentaIva(String? codimpuesto) =>
      (codimpuesto == null ? null : subcuentaIvaPorCodimpuesto[codimpuesto]) ??
      subcuentaIvaGenerica;

  @override
  List<Object?> get props => [
    subcuentaCaja,
    subcuentaBanco,
    subcuentaVentas,
    subcuentaIvaGenerica,
    subcuentaIvaPorCodimpuesto,
    subcuentaPerdidas,
    subcuentaIngresos,
  ];
}

final class CierreZRequest extends Equatable {
  CierreZRequest({
    required this.idCierre,
    required this.fecha,
    required List<TicketCierre> tickets,
    this.fondoCajaCents = 0,
    this.efectivoContadoCents,
    this.retiradasCents = 0,
    this.modo = ModoAsientoZ.soloDescuadre,
    required this.cuentas,
    this.nombreTpv,
  }) : tickets = List.unmodifiable(tickets);

  final String idCierre;

  /// Fecha de negocio del cierre (solo se usa la parte de fecha).
  final DateTime fecha;
  final List<TicketCierre> tickets;

  /// Fondo de caja con el que se abrió el turno.
  final int fondoCajaCents;

  /// Efectivo contado en el arqueo; `null` si no se hizo arqueo.
  final int? efectivoContadoCents;

  /// Efectivo retirado de la caja durante el turno.
  final int retiradasCents;
  final ModoAsientoZ modo;
  final CuentasCierre cuentas;
  final String? nombreTpv;

  @override
  List<Object?> get props => [
    idCierre,
    fecha,
    tickets,
    fondoCajaCents,
    efectivoContadoCents,
    retiradasCents,
    modo,
    cuentas,
    nombreTpv,
  ];
}

final class PartidaPropuesta extends Equatable {
  const PartidaPropuesta({
    required this.codsubcuenta,
    required this.concepto,
    this.debeCents = 0,
    this.haberCents = 0,
    this.baseCents,
    this.ivaPct,
  });

  final String codsubcuenta;
  final String concepto;
  final int debeCents;
  final int haberCents;

  /// Base imponible (solo partidas de IVA repercutido).
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

final class AsientoPropuesto extends Equatable {
  AsientoPropuesto({
    required this.documento,
    required this.fecha,
    required this.concepto,
    required List<PartidaPropuesta> partidas,
    required this.modo,
  }) : partidas = List.unmodifiable(partidas);

  /// Clave idempotente del asiento en el ERP (`Z-20261006-TPV1`).
  final String documento;
  final DateTime fecha;
  final String concepto;
  final List<PartidaPropuesta> partidas;
  final ModoAsientoZ modo;

  int get debeCents => partidas.fold(0, (sum, p) => sum + p.debeCents);

  int get haberCents => partidas.fold(0, (sum, p) => sum + p.haberCents);

  bool get cuadrado => debeCents == haberCents;

  /// Sin partidas: no hay nada que contabilizar.
  bool get vacio => partidas.isEmpty;

  @override
  List<Object?> get props => [documento, fecha, concepto, partidas, modo];
}

final class VentasPorIva extends Equatable {
  const VentasPorIva({
    this.codimpuesto,
    required this.ivaBp,
    required this.baseCents,
    required this.cuotaCents,
    required this.numTickets,
  });

  final String? codimpuesto;
  final int ivaBp;
  final int baseCents;
  final int cuotaCents;
  final int numTickets;

  int get totalCents => baseCents + cuotaCents;

  @override
  List<Object?> get props => [
    codimpuesto,
    ivaBp,
    baseCents,
    cuotaCents,
    numTickets,
  ];
}

final class InformeCierreZ extends Equatable {
  InformeCierreZ({
    required this.idCierre,
    required this.fecha,
    required this.numTickets,
    required this.numAnulados,
    required this.ventasTotalCents,
    required this.ventasEfectivoCents,
    required this.ventasTarjetaCents,
    this.numTicketsMixtos = 0,
    required this.ticketMedioCents,
    required List<VentasPorIva> porIva,
    required this.fondoCajaCents,
    required this.retiradasCents,
    required this.efectivoEsperadoCents,
    this.efectivoContadoCents,
    required this.descuadreCents,
    required this.importeAnuladoCents,
    this.primerTicket,
    this.ultimoTicket,
    required List<String> avisos,
  }) : porIva = List.unmodifiable(porIva),
       avisos = List.unmodifiable(avisos);

  final String idCierre;
  final DateTime fecha;

  /// Tickets válidos (no anulados).
  final int numTickets;
  final int numAnulados;
  final int ventasTotalCents;

  /// Suma de las partes en efectivo de cada ticket (también de los mixtos).
  final int ventasEfectivoCents;

  /// Suma de las partes con tarjeta de cada ticket.
  final int ventasTarjetaCents;

  /// Tickets cobrados en parte con efectivo y en parte con tarjeta.
  final int numTicketsMixtos;
  final int ticketMedioCents;
  final List<VentasPorIva> porIva;
  final int fondoCajaCents;
  final int retiradasCents;

  /// `fondo + ventas en efectivo - retiradas`.
  final int efectivoEsperadoCents;
  final int? efectivoContadoCents;

  /// `contado - esperado` (`0` sin arqueo). Negativo = faltante.
  final int descuadreCents;
  final int importeAnuladoCents;
  final DateTime? primerTicket;
  final DateTime? ultimoTicket;
  final List<String> avisos;

  @override
  List<Object?> get props => [
    idCierre,
    fecha,
    numTickets,
    numAnulados,
    ventasTotalCents,
    ventasEfectivoCents,
    ventasTarjetaCents,
    numTicketsMixtos,
    ticketMedioCents,
    porIva,
    fondoCajaCents,
    retiradasCents,
    efectivoEsperadoCents,
    efectivoContadoCents,
    descuadreCents,
    importeAnuladoCents,
    primerTicket,
    ultimoTicket,
    avisos,
  ];
}

final class CierreZResult extends Equatable {
  const CierreZResult({required this.informe, required this.asiento});

  final InformeCierreZ informe;
  final AsientoPropuesto asiento;

  @override
  List<Object?> get props => [informe, asiento];
}
