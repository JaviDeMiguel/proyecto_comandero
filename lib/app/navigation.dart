import 'package:flutter/material.dart';

import '../features/host/presentation/enrutamiento_page.dart';
import '../features/host/presentation/tickets_comandas_page.dart';
import '../features/settings/presentation/settings_page.dart';

/// Abre la pantalla de ajustes encima de la actual.
///
/// [mesasOcupadas] (solo host) devuelve las mesas con comanda abierta, que
/// la pantalla no permite quitar. [onAbrirEnrutamiento] y
/// [onAbrirTicketsYComandas] (solo host) muestran en Ajustes > Impresoras
/// los accesos al enrutamiento por familias y a «Tickets y comandas».
Future<void> abrirAjustes(
  BuildContext context, {
  Set<String> Function()? mesasOcupadas,
  void Function(BuildContext context)? onAbrirEnrutamiento,
  void Function(BuildContext context)? onAbrirTicketsYComandas,
}) => Navigator.of(context).push<void>(
  MaterialPageRoute(
    settings: const RouteSettings(name: '/ajustes'),
    builder: (_) => SettingsPage(
      mesasOcupadas: mesasOcupadas,
      onAbrirEnrutamiento: onAbrirEnrutamiento,
      onAbrirTicketsYComandas: onAbrirTicketsYComandas,
    ),
  ),
);

/// Abre la pantalla de enrutamiento de comandas por familias (host).
Future<void> abrirEnrutamiento(BuildContext context) =>
    Navigator.of(context).push<void>(
      MaterialPageRoute(
        settings: const RouteSettings(name: '/enrutamiento'),
        builder: (_) => const EnrutamientoPage(),
      ),
    );

/// Abre «Tickets y comandas» (host): perfiles por impresora, formato del
/// ticket, emisión al cobrar, QR VeriFactu y pases.
Future<void> abrirTicketsYComandas(BuildContext context) =>
    Navigator.of(context).push<void>(
      MaterialPageRoute(
        settings: const RouteSettings(name: '/tickets-comandas'),
        builder: (_) => const TicketsComandasPage(),
      ),
    );
