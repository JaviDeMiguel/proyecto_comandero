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
Uint8List generarPaginaPrueba(PaginaPruebaData data) {
  final builder = EscPosBuilder(paper: data.paper)
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
    ..line(
      'Papel: ${data.paper == PaperWidth.mm58 ? '58' : '80'} mm '
      '(${data.paper.columns} columnas)',
    )
    ..line('Enviado por: ${data.dispositivo}')
    ..line('Fecha: ${data.fechaHora}')
    ..separator()
    ..line('Acentos: áéíóú ÁÉÍÓÚ ñÑ üÜ ¿¡ º €')
    ..line('1234567890' * (data.paper.columns ~/ 10))
    ..feed(3)
    ..cut();
  return builder.build();
}
