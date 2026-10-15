import 'package:equatable/equatable.dart';

import '../../../core/isolates/escpos/escpos_builder.dart';
import '../../../core/network/printing/raw_printer_transport.dart';
import '../../../core/utils/json_map.dart';
import '../../impresion/domain/formato_impresion.dart';
import '../../sala/domain/enrutamiento_comandas.dart';
import 'settings_json.dart';

/// Ajustes de impresión ESC/POS (impresoras de red, puerto 9100 por defecto).
final class PrintingSettings extends Equatable {
  const PrintingSettings({
    this.tickets,
    this.cocina,
    this.barra,
    this.paper = PaperWidth.mm80,
    this.abrirCajon = true,
    this.imprimirTicketAlCobrar = true,
    this.imprimirComandaCocina = true,
    this.enrutamiento = const EnrutamientoComandas(),
    this.formato = const FormatoImpresion(),
  });

  /// Lee los ajustes guardados. Campos ausentes → valor por defecto. Lanza
  /// [FormatException] si un campo es inválido o `ValidationException` si una
  /// dirección de impresora no es utilizable. `formato` es la excepción: se
  /// lee de forma tolerante y, si no es un objeto, queda por defecto.
  factory PrintingSettings.fromJson(Map<String, Object?> json) {
    const defaults = PrintingSettings();
    return PrintingSettings(
      tickets: _endpointFromJson(json.optionalMap('tickets')),
      cocina: _endpointFromJson(json.optionalMap('cocina')),
      barra: _endpointFromJson(json.optionalMap('barra')),
      paper: enumPorNombre(
        PaperWidth.values,
        json['paper'],
        defaults.paper,
        campo: 'paper',
      ),
      abrirCajon: json.optionalBool('abrirCajon') ?? defaults.abrirCajon,
      imprimirTicketAlCobrar:
          json.optionalBool('imprimirTicketAlCobrar') ??
          defaults.imprimirTicketAlCobrar,
      imprimirComandaCocina:
          json.optionalBool('imprimirComandaCocina') ??
          defaults.imprimirComandaCocina,
      enrutamiento: switch (json.optionalMap('enrutamiento')) {
        final Map<String, Object?> map => EnrutamientoComandas.fromJson(map),
        null => defaults.enrutamiento,
      },
      // No usa optionalMap: un `formato` que no fuera un mapa lanzaría y se
      // convertiría en ConfigException al arrancar.
      formato: switch (json['formato']) {
        final Map<String, Object?> map => FormatoImpresion.fromJson(map),
        _ => defaults.formato,
      },
    );
  }

  /// Impresora de tickets/facturas (normalmente junto a la caja).
  final PrinterEndpoint? tickets;

  /// Impresora de comandas de cocina.
  final PrinterEndpoint? cocina;

  /// Impresora de comandas de barra (bebidas). `null` = usar la de cocina.
  final PrinterEndpoint? barra;

  /// Papel **heredado** de los ajustes anteriores a los perfiles por
  /// impresora: solo sirve de valor por defecto para las impresoras sin
  /// perfil en [formato] (`resolverPerfil`).
  final PaperWidth paper;

  /// Abrir el cajón portamonedas al cobrar en efectivo.
  final bool abrirCajon;

  final bool imprimirTicketAlCobrar;
  final bool imprimirComandaCocina;

  /// Qué familias se preparan en cocina y cuáles en barra. Los ajustes
  /// guardados por versiones anteriores (sin este campo) cargan con todo a
  /// cocina, que era el comportamiento de entonces.
  final EnrutamientoComandas enrutamiento;

  /// Perfiles por impresora, formato del ticket, emisión al cobrar, QR
  /// VeriFactu y pases. Lo escribe solo la página «Tickets y comandas»; los
  /// ajustes anteriores (sin este campo) cargan con el formato por defecto.
  final FormatoImpresion formato;

  /// Serializa un [PrinterEndpoint] como `{host, port}`.
  static Map<String, Object?> endpointToJson(PrinterEndpoint endpoint) => {
    'host': endpoint.host,
    'port': endpoint.port,
  };

  static PrinterEndpoint? _endpointFromJson(Map<String, Object?>? json) {
    if (json == null) return null;
    return PrinterEndpoint(
      json.requireString('host'),
      port: json.optionalInt('port') ?? kRawPrintPort,
    );
  }

  Map<String, Object?> toJson() => {
    if (tickets != null) 'tickets': endpointToJson(tickets!),
    if (cocina != null) 'cocina': endpointToJson(cocina!),
    if (barra != null) 'barra': endpointToJson(barra!),
    'paper': paper.name,
    'abrirCajon': abrirCajon,
    'imprimirTicketAlCobrar': imprimirTicketAlCobrar,
    'imprimirComandaCocina': imprimirComandaCocina,
    'enrutamiento': enrutamiento.toJson(),
    // Se omite si todo está por defecto, de modo que el JSON de hoy no cambia.
    if (!formato.esPorDefecto) 'formato': formato.toJson(),
  };

  PrintingSettings copyWith({
    PrinterEndpoint? tickets,
    bool borrarTickets = false,
    PrinterEndpoint? cocina,
    bool borrarCocina = false,
    PrinterEndpoint? barra,
    bool borrarBarra = false,
    PaperWidth? paper,
    bool? abrirCajon,
    bool? imprimirTicketAlCobrar,
    bool? imprimirComandaCocina,
    EnrutamientoComandas? enrutamiento,
    FormatoImpresion? formato,
  }) => PrintingSettings(
    tickets: borrarTickets ? null : (tickets ?? this.tickets),
    cocina: borrarCocina ? null : (cocina ?? this.cocina),
    barra: borrarBarra ? null : (barra ?? this.barra),
    paper: paper ?? this.paper,
    abrirCajon: abrirCajon ?? this.abrirCajon,
    imprimirTicketAlCobrar:
        imprimirTicketAlCobrar ?? this.imprimirTicketAlCobrar,
    imprimirComandaCocina: imprimirComandaCocina ?? this.imprimirComandaCocina,
    enrutamiento: enrutamiento ?? this.enrutamiento,
    formato: formato ?? this.formato,
  );

  @override
  List<Object?> get props => [
    tickets,
    cocina,
    barra,
    paper,
    abrirCajon,
    imprimirTicketAlCobrar,
    imprimirComandaCocina,
    enrutamiento,
    formato,
  ];
}
