/// Página de prueba de impresora (ESC/POS), generada en un isolate.
library;

import 'dart:typed_data';

import '../../../core/isolates/escpos/escpos_builder.dart';

/// Datos planos de la página de prueba (cruzan al isolate).
final class PaginaPruebaData {
  const PaginaPruebaData({
    required this.paper,
    required this.destino,
    required this.impresora,
    required this.dispositivo,
    required this.fechaHora,
  });

  final PaperWidth paper;

  /// "Tickets", "Cocina" o "Barra".
  final String destino;

  /// Dirección configurada (`ip:puerto`).
  final String impresora;

  /// Nombre del TPV que la envía.
  final String dispositivo;

  /// Fecha y hora ya formateadas.
  final String fechaHora;
}

/// Genera los bytes de la página de prueba. Top-level: se ejecuta con
/// `IsolateRunner.run`.
///
/// Ninguna línea fija pasa del ancho de su propio papel, y la regla numerada
/// lo ocupa entero: si el papel del perfil no es el de la impresora, la regla
/// se parte o no llega al borde.
Uint8List generarPaginaPrueba(PaginaPruebaData data) {
  final paper = data.paper;
  final builder = EscPosBuilder(paper: paper)
    ..init()
    ..line(
      'PRUEBA DE IMPRESIÓN',
      align: EscPosAlign.center,
      bold: true,
      doubleHeight: true,
    )
    ..separator()
    ..line('Destino: ${data.destino}')
    ..line('Impresora: ${data.impresora}')
    ..line('Papel: ${paper.etiqueta}, ${paper.columns} columnas')
    ..line('Enviado por: ${data.dispositivo}')
    ..line('Fecha: ${data.fechaHora}')
    ..separator()
    ..line('Acentos: áéíóú ÁÉÍÓÚ ñÑ üÜ')
    ..line('Signos: ¿¡ º €')
    ..line(_regla(paper.columns))
    ..feed(3)
    ..cut();
  return builder.build();
}

/// `123456789012…` con [columnas] cifras: la regla de ancho completo.
String _regla(int columnas) =>
    List.generate(columnas, (i) => '${(i + 1) % 10}').join();
