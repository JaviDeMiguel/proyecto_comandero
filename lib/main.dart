import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/app.dart';
import 'app/platform/registro_app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Registro (consola y fichero rotativo) y manejadores globales de errores.
  // No lanza: si el fichero no se puede abrir, la app arranca sin él.
  await iniciarRegistro();
  runApp(const ProviderScope(child: TpvComanderoApp()));
}
