/// Presentación de la forma de cobro de un ticket (simple o mixto).
library;

import 'package:flutter/material.dart';

import '../../../../core/money/money.dart';
import '../../../sala/domain/ticket.dart';

/// Nombre visible de una forma de pago.
String nombreMetodoPago(MetodoPago metodo) => switch (metodo) {
  MetodoPago.efectivo => 'Efectivo',
  MetodoPago.tarjeta => 'Tarjeta',
};

/// `Efectivo`, `Tarjeta` o, en un cobro mixto,
/// `Mixto: efectivo 12,35 € + tarjeta 7,60 €`.
String formatFormaCobro(Ticket ticket) {
  if (!ticket.esMixto) return nombreMetodoPago(ticket.metodoPago);
  final partes = ticket.pagos.map(
    (pago) =>
        '${nombreMetodoPago(pago.metodo).toLowerCase()} '
        '${formatCents(pago.importeCents)}',
  );
  return 'Mixto: ${partes.join(' + ')}';
}

/// Icono de la forma de cobro del ticket.
IconData iconoFormaCobro(Ticket ticket) {
  if (ticket.esMixto) return Icons.call_split;
  return switch (ticket.metodoPago) {
    MetodoPago.efectivo => Icons.payments_outlined,
    MetodoPago.tarjeta => Icons.credit_card,
  };
}
