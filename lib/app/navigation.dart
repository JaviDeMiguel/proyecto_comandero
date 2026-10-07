import 'package:flutter/material.dart';

import '../features/host/presentation/enrutamiento_page.dart';
import '../features/settings/presentation/settings_page.dart';

/// Abre la pantalla de ajustes encima de la actual.
///
/// [mesasOcupadas] (solo host) devuelve las mesas con comanda abierta, que
/// la pantalla no permite quitar. [onAbrirEnrutamiento] (solo host) muestra
/// en Ajustes > Impresoras el acceso al enrutamiento por familias.
Future<void> abrirAjustes(
  BuildContext context, {
  Set<String> Function()? mesasOcupadas,
  void Function(BuildContext context)? onAbrirEnrutamiento,
}) => Navigator.of(context).push<void>(
  MaterialPageRoute(
    settings: const RouteSettings(name: '/ajustes'),
    builder: (_) => SettingsPage(
      mesasOcupadas: mesasOcupadas,
      onAbrirEnrutamiento: onAbrirEnrutamiento,
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
