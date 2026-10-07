/// Motor de Cierre Z: a partir de los tickets del turno calcula el informe
/// diario (ventas por forma de pago y por IVA, arqueo de caja) y el asiento
/// contable propuesto, cuadrado al céntimo.
///
/// Es una función pura pensada para ejecutarse en un isolate mediante
/// [calcularCierreZEnIsolate]: no hace E/S ni toca estado global.
library;

import '../../errors/app_exception.dart';
import '../../money/money.dart';
import '../isolate_runner.dart';
import 'cierre_z_models.dart';

export 'cierre_z_models.dart';

/// Calcula el cierre. Lanza [ValidationException] ante datos incoherentes.
CierreZResult calcularCierreZ(CierreZRequest request) {
  _validar(request);

  final validos = request.tickets.where((t) => !t.anulado).toList()
    ..sort((a, b) => a.fechaHora.compareTo(b.fechaHora));
  final anulados = request.tickets.where((t) => t.anulado);
  final avisos = <String>[];

  var ventasEfectivo = 0;
  var ventasTarjeta = 0;
  var mixtos = 0;
  final porIva = <String, _AcumuladoIva>{};
  for (final ticket in validos) {
    // Cada parte del cobro va a su forma de pago: en un ticket mixto solo
    // la parte en efectivo entra en caja.
    ventasEfectivo += ticket.efectivoCents;
    ventasTarjeta += ticket.tarjetaCents;
    if (ticket.esMixto) mixtos++;
    final vistos = <String>{};
    for (final iva in ticket.desglose) {
      final clave = '${iva.codimpuesto}|${iva.ivaBp}';
      final acumulado = porIva.putIfAbsent(
        clave,
        () => _AcumuladoIva(iva.codimpuesto, iva.ivaBp),
      );
      acumulado.base += iva.baseCents;
      acumulado.cuota += iva.cuotaCents;
      if (vistos.add(clave)) acumulado.tickets++;
    }
  }

  final ventasTotal = ventasEfectivo + ventasTarjeta;
  final importeAnulado = anulados.fold(0, (sum, t) => sum + t.totalCents);
  final efectivoEsperado =
      request.fondoCajaCents + ventasEfectivo - request.retiradasCents;
  final contado = request.efectivoContadoCents;
  final descuadre = contado == null ? 0 : contado - efectivoEsperado;
  if (contado == null) {
    avisos.add('Sin arqueo de caja: no se calcula el descuadre.');
  }

  final informe = InformeCierreZ(
    idCierre: request.idCierre,
    fecha: _soloFecha(request.fecha),
    numTickets: validos.length,
    numAnulados: anulados.length,
    ventasTotalCents: ventasTotal,
    ventasEfectivoCents: ventasEfectivo,
    ventasTarjetaCents: ventasTarjeta,
    numTicketsMixtos: mixtos,
    ticketMedioCents: validos.isEmpty
        ? 0
        : divideRounding(ventasTotal, validos.length),
    porIva: [
      for (final acumulado
          in porIva.values.toList()..sort((a, b) {
            final porTipo = a.ivaBp.compareTo(b.ivaBp);
            if (porTipo != 0) return porTipo;
            return (a.codimpuesto ?? '').compareTo(b.codimpuesto ?? '');
          }))
        VentasPorIva(
          codimpuesto: acumulado.codimpuesto,
          ivaBp: acumulado.ivaBp,
          baseCents: acumulado.base,
          cuotaCents: acumulado.cuota,
          numTickets: acumulado.tickets,
        ),
    ],
    fondoCajaCents: request.fondoCajaCents,
    retiradasCents: request.retiradasCents,
    efectivoEsperadoCents: efectivoEsperado,
    efectivoContadoCents: contado,
    descuadreCents: descuadre,
    importeAnuladoCents: importeAnulado,
    primerTicket: validos.isEmpty ? null : validos.first.fechaHora,
    ultimoTicket: validos.isEmpty ? null : validos.last.fechaHora,
    avisos: avisos,
  );

  final asiento = _construirAsiento(request, informe);
  if (!asiento.cuadrado) {
    throw ValidationException(
      'El asiento del cierre no cuadra: Debe ${formatCents(asiento.debeCents)} '
      '≠ Haber ${formatCents(asiento.haberCents)}',
    );
  }
  return CierreZResult(informe: informe, asiento: asiento);
}

/// Ejecuta [calcularCierreZ] fuera del isolate de UI.
Future<CierreZResult> calcularCierreZEnIsolate(
  CierreZRequest request, {
  IsolateRunner runner = const SpawningIsolateRunner(),
}) => runner.run(calcularCierreZ, request, debugName: 'cierre-z');

AsientoPropuesto _construirAsiento(
  CierreZRequest request,
  InformeCierreZ informe,
) {
  final cuentas = request.cuentas;
  final fecha = _soloFecha(request.fecha);
  final etiqueta = request.nombreTpv == null
      ? 'Cierre Z ${_formatoFecha(fecha)}'
      : 'Cierre Z ${_formatoFecha(fecha)} ${request.nombreTpv}';
  final documento =
      'Z-${_formatoFechaCompacta(fecha)}-${_claveCorta(request.idCierre)}';
  final descuadre = informe.descuadreCents;
  final partidas = <PartidaPropuesta>[];

  switch (request.modo) {
    case ModoAsientoZ.soloDescuadre:
      if (descuadre < 0) {
        partidas
          ..add(
            PartidaPropuesta(
              codsubcuenta: cuentas.subcuentaPerdidas,
              concepto: '$etiqueta - faltante de caja',
              debeCents: -descuadre,
            ),
          )
          ..add(
            PartidaPropuesta(
              codsubcuenta: cuentas.subcuentaCaja,
              concepto: '$etiqueta - faltante de caja',
              haberCents: -descuadre,
            ),
          );
      } else if (descuadre > 0) {
        partidas
          ..add(
            PartidaPropuesta(
              codsubcuenta: cuentas.subcuentaCaja,
              concepto: '$etiqueta - sobrante de caja',
              debeCents: descuadre,
            ),
          )
          ..add(
            PartidaPropuesta(
              codsubcuenta: cuentas.subcuentaIngresos,
              concepto: '$etiqueta - sobrante de caja',
              haberCents: descuadre,
            ),
          );
      }
    case ModoAsientoZ.resumenCompleto:
      // Debe: tesorería real. El sobrante entra en caja; el faltante sale
      // de caja y se lleva a pérdidas, de modo que 570 refleja el efectivo
      // que de verdad hay.
      final efectivoEnCaja = informe.ventasEfectivoCents + descuadre;
      _add(
        partidas,
        cuentas.subcuentaCaja,
        '$etiqueta - ventas en efectivo',
        debe: efectivoEnCaja,
      );
      _add(
        partidas,
        cuentas.subcuentaBanco,
        '$etiqueta - ventas con tarjeta',
        debe: informe.ventasTarjetaCents,
      );
      if (descuadre < 0) {
        _add(
          partidas,
          cuentas.subcuentaPerdidas,
          '$etiqueta - faltante de caja',
          debe: -descuadre,
        );
      }
      // Haber: ventas e IVA repercutido por tipo.
      final bases = informe.porIva.fold(0, (sum, iva) => sum + iva.baseCents);
      _add(
        partidas,
        cuentas.subcuentaVentas,
        '$etiqueta - ventas',
        haber: bases,
      );
      for (final iva in informe.porIva) {
        partidas.add(
          PartidaPropuesta(
            codsubcuenta: cuentas.subcuentaIva(iva.codimpuesto),
            concepto:
                '$etiqueta - IVA repercutido ${basisPointsToPercent(iva.ivaBp)} %',
            haberCents: iva.cuotaCents,
            baseCents: iva.baseCents,
            ivaPct: basisPointsToPercent(iva.ivaBp),
          ),
        );
      }
      if (descuadre > 0) {
        _add(
          partidas,
          cuentas.subcuentaIngresos,
          '$etiqueta - sobrante de caja',
          haber: descuadre,
        );
      }
  }

  return AsientoPropuesto(
    documento: documento,
    fecha: fecha,
    concepto: etiqueta,
    partidas: partidas
        .where((p) => p.debeCents != 0 || p.haberCents != 0)
        .toList(),
    modo: request.modo,
  );
}

void _add(
  List<PartidaPropuesta> partidas,
  String codsubcuenta,
  String concepto, {
  int debe = 0,
  int haber = 0,
}) {
  partidas.add(
    PartidaPropuesta(
      codsubcuenta: codsubcuenta,
      concepto: concepto,
      debeCents: debe,
      haberCents: haber,
    ),
  );
}

void _validar(CierreZRequest request) {
  if (request.idCierre.trim().isEmpty) {
    throw const ValidationException('El cierre necesita un identificador');
  }
  if (request.fondoCajaCents < 0) {
    throw const ValidationException('El fondo de caja no puede ser negativo');
  }
  if (request.retiradasCents < 0) {
    throw const ValidationException('Las retiradas no pueden ser negativas');
  }
  if ((request.efectivoContadoCents ?? 0) < 0) {
    throw const ValidationException(
      'El efectivo contado no puede ser negativo',
    );
  }
  final ids = <String>{};
  for (final ticket in request.tickets) {
    if (!ids.add(ticket.id)) {
      throw ValidationException('Ticket repetido en el cierre: ${ticket.id}');
    }
    if (ticket.totalCents < 0) {
      throw ValidationException('Ticket ${ticket.id} con total negativo');
    }
    final sumaDesglose = ticket.desglose.fold(
      0,
      (sum, iva) => sum + iva.baseCents + iva.cuotaCents,
    );
    if (sumaDesglose != ticket.totalCents) {
      throw ValidationException(
        'Ticket ${ticket.id}: el desglose de IVA suma '
        '${formatCents(sumaDesglose)} y el total es ${formatCents(ticket.totalCents)}',
      );
    }
    _validarPagos(ticket);
  }
}

void _validarPagos(TicketCierre ticket) {
  final pagos = ticket.pagos;
  if (pagos.isEmpty) {
    throw ValidationException('Ticket ${ticket.id} sin desglose de cobro');
  }
  if (pagos.map((p) => p.metodo).toSet().length != pagos.length) {
    throw ValidationException(
      'Ticket ${ticket.id}: forma de pago repetida en el cobro',
    );
  }
  if (pagos.length > 1 && pagos.any((p) => p.importeCents <= 0)) {
    throw ValidationException(
      'Ticket ${ticket.id}: cobro mixto con un importe no positivo',
    );
  }
  final suma = pagos.fold(0, (sum, p) => sum + p.importeCents);
  if (suma != ticket.totalCents) {
    throw ValidationException(
      'Ticket ${ticket.id}: los pagos suman ${formatCents(suma)} y el total '
      'es ${formatCents(ticket.totalCents)}',
    );
  }
}

final class _AcumuladoIva {
  _AcumuladoIva(this.codimpuesto, this.ivaBp);

  final String? codimpuesto;
  final int ivaBp;
  int base = 0;
  int cuota = 0;
  int tickets = 0;
}

DateTime _soloFecha(DateTime fecha) =>
    DateTime(fecha.year, fecha.month, fecha.day);

String _dos(int value) => value.toString().padLeft(2, '0');

String _formatoFecha(DateTime fecha) =>
    '${_dos(fecha.day)}-${_dos(fecha.month)}-${fecha.year}';

String _formatoFechaCompacta(DateTime fecha) =>
    '${fecha.year}${_dos(fecha.month)}${_dos(fecha.day)}';

/// Fragmento del id apto para `documento` (máximo 50 caracteres en total):
/// solo letras y dígitos, 12 como máximo.
String _claveCorta(String id) {
  final limpio = id.replaceAll(RegExp('[^A-Za-z0-9]'), '');
  return limpio.length <= 12 ? limpio : limpio.substring(0, 12);
}
