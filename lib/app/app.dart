import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'app_shell.dart';
import 'theme.dart';

/// Raíz de la aplicación TPV / Comandero.
///
/// Debe ir dentro de un `ProviderScope`. Sin [home] muestra el [AppShell]
/// (carga de ajustes, selector de rol y modo host o comandero).
class TpvComanderoApp extends StatelessWidget {
  const TpvComanderoApp({super.key, this.home});

  /// Pantalla inicial fija en lugar del shell (tests de pantallas sueltas).
  final Widget? home;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TPV Comandero',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      locale: const Locale('es', 'ES'),
      supportedLocales: const [Locale('es', 'ES')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: home ?? const AppShell(),
    );
  }
}
