/// Configuración efectiva del host (tablet).
///
/// Es la vista que el runtime del host necesita de los ajustes de la
/// aplicación. La feature `settings` persiste y edita los ajustes del usuario;
/// este tipo es Dart puro y se construye a partir de ellos para que
/// `HostRuntime` no dependa de la forma en que se guardan.
library;

import 'package:equatable/equatable.dart';

import '../../../core/database/mysql_config.dart';
import '../../../core/facturascripts/accounting/accounting_models.dart';
import '../../../core/facturascripts/fs_api_config.dart';
import '../../../core/isolates/cierre_z/cierre_z_models.dart' show ModoAsientoZ;
import '../../../core/isolates/escpos/escpos_builder.dart' show PaperWidth;
import '../../../core/isolates/escpos/ticket_documents.dart' show EmpresaTicket;
import '../../../core/isolates/reposicion/reposicion_models.dart';
import '../../../core/network/printing/raw_printer_transport.dart';
import '../../sala/domain/enrutamiento_comandas.dart';
import '../../sala/domain/linea_comanda.dart' show DestinoPreparacion;
import '../../sala/domain/mesa.dart';

/// Datos fiscales y de facturación que viajan en cada factura.
final class FiscalSettings extends Equatable {
  const FiscalSettings({
    required this.codcliente,
    this.codserie = 'S',
    required this.codpagoEfectivo,
    required this.codpagoTarjeta,
    required this.codalmacen,
    this.idempresa = 1,
    this.emitirFacturas = true,
    this.codimpuestoPorDefecto,
  });

  /// Cliente genérico de contado (no existe en FS de fábrica).
  final String codcliente;

  /// Serie simplificada.
  final String codserie;
  final String codpagoEfectivo;
  final String codpagoTarjeta;
  final String codalmacen;
  final int idempresa;

  /// Pasar cada factura al estado no editable "Emitida" tras cobrarla.
  final bool emitirFacturas;

  /// Impuesto de los artículos sin `codimpuesto` resoluble (normalmente el
  /// `codimpuesto` de `settings/default`).
  final String? codimpuestoPorDefecto;

  /// La configuración basta para facturar.
  bool get completa =>
      codcliente.trim().isNotEmpty &&
      codserie.trim().isNotEmpty &&
      codpagoEfectivo.trim().isNotEmpty &&
      codpagoTarjeta.trim().isNotEmpty &&
      codalmacen.trim().isNotEmpty;

  @override
  List<Object?> get props => [
    codcliente,
    codserie,
    codpagoEfectivo,
    codpagoTarjeta,
    codalmacen,
    idempresa,
    emitirFacturas,
    codimpuestoPorDefecto,
  ];
}

/// Ajustes del Cierre Z.
final class CierreSettings extends Equatable {
  const CierreSettings({
    this.modoAsientoZ = ModoAsientoZ.soloDescuadre,
    this.overridesSubcuentas = const {},
  });

  final ModoAsientoZ modoAsientoZ;

  /// `codsubcuenta` forzado por papel contable.
  final Map<CuentaZ, String> overridesSubcuentas;

  @override
  List<Object?> get props => [modoAsientoZ, overridesSubcuentas];
}

/// Impresoras y comportamiento de impresión.
final class ImpresionSettings extends Equatable {
  const ImpresionSettings({
    this.cocina,
    this.barra,
    this.tickets,
    this.imprimirComandas = true,
    this.imprimirTicketAlCobrar = true,
    this.abrirCajonEfectivo = false,
    this.paper = PaperWidth.mm80,
    this.enrutamiento = const EnrutamientoComandas(),
  });

  final PrinterEndpoint? cocina;

  /// Si es nulo, las líneas de barra salen por la impresora de cocina.
  final PrinterEndpoint? barra;

  /// Si es nulo, los tickets salen por la de cocina.
  final PrinterEndpoint? tickets;
  final bool imprimirComandas;
  final bool imprimirTicketAlCobrar;
  final bool abrirCajonEfectivo;
  final PaperWidth paper;

  /// Familia → cocina/barra. El host lo aplica a cada línea que acepta.
  final EnrutamientoComandas enrutamiento;

  bool get hayImpresora => cocina != null || barra != null || tickets != null;

  /// Impresora efectiva de un destino de preparación (`cocina` | `barra`).
  PrinterEndpoint? paraDestino(String destino) =>
      destino == 'barra' ? (barra ?? cocina) : (cocina ?? barra);

  /// Impresora efectiva de [destino] y si es la de **respaldo** (la del otro
  /// puesto, porque [destino] no tiene impresora propia). `null` si no hay
  /// ninguna impresora de comandas.
  ({PrinterEndpoint endpoint, bool respaldo})? impresoraDe(
    DestinoPreparacion destino,
  ) {
    final (propia, otra) = switch (destino) {
      DestinoPreparacion.cocina => (cocina, barra),
      DestinoPreparacion.barra => (barra, cocina),
    };
    if (propia != null) return (endpoint: propia, respaldo: false);
    if (otra != null) return (endpoint: otra, respaldo: true);
    return null;
  }

  PrinterEndpoint? get paraTickets => tickets ?? cocina ?? barra;

  @override
  List<Object?> get props => [
    cocina,
    barra,
    tickets,
    imprimirComandas,
    imprimirTicketAlCobrar,
    abrirCajonEfectivo,
    paper,
    enrutamiento,
  ];
}

/// Reaprovisionamiento automático.
final class ReposicionSettings extends Equatable {
  const ReposicionSettings({
    this.automatica = false,
    this.enCierre = true,
    this.politica = const PoliticaReposicion(),
    this.debounce = const Duration(seconds: 30),
  });

  /// Crear pedidos a proveedor automáticamente tras cada descuento de stock.
  final bool automatica;

  /// Auditar (y pedir si [automatica]) al cerrar el turno.
  final bool enCierre;
  final PoliticaReposicion politica;

  /// Espera tras el último descuento antes de auditar.
  final Duration debounce;

  @override
  List<Object?> get props => [automatica, enCierre, politica, debounce];
}

/// Configuración completa del host.
final class HostSettings extends Equatable {
  HostSettings({
    required this.deviceId,
    required this.nombreTpv,
    this.tcpPort = 4040,
    this.discoveryPort = 4041,
    this.pairingCode,
    this.erp,
    this.mysql,
    required this.fiscal,
    this.cierre = const CierreSettings(),
    this.impresion = const ImpresionSettings(),
    this.reposicion = const ReposicionSettings(),
    this.empresa,
    List<Mesa> mesas = const [],
  }) : mesas = List.unmodifiable(mesas);

  /// Identificador estable de la instalación (`hostId` en la red).
  final String deviceId;

  /// Nombre visible (`hostName`).
  final String nombreTpv;
  final int tcpPort;
  final int discoveryPort;

  /// Código de emparejamiento; nulo o vacío lo desactiva.
  final String? pairingCode;

  /// API REST del ERP; nulo = sin ERP (la sala funciona igualmente).
  final FsApiConfig? erp;

  /// MySQL directo para stock y escandallos; nulo = sin descuento de stock.
  final MysqlConfig? mysql;
  final FiscalSettings fiscal;
  final CierreSettings cierre;
  final ImpresionSettings impresion;
  final ReposicionSettings reposicion;

  /// Cabecera del ticket. Si es nula se intenta leer de FS al arrancar.
  final EmpresaTicket? empresa;

  /// Mesas configuradas.
  final List<Mesa> mesas;

  bool get requiresPairing {
    final code = pairingCode;
    return code != null && code.isNotEmpty;
  }

  HostSettings copyWith({
    String? nombreTpv,
    int? tcpPort,
    int? discoveryPort,
    String? pairingCode,
    FsApiConfig? erp,
    MysqlConfig? mysql,
    FiscalSettings? fiscal,
    CierreSettings? cierre,
    ImpresionSettings? impresion,
    ReposicionSettings? reposicion,
    EmpresaTicket? empresa,
    List<Mesa>? mesas,
    bool quitarErp = false,
    bool quitarMysql = false,
  }) => HostSettings(
    deviceId: deviceId,
    nombreTpv: nombreTpv ?? this.nombreTpv,
    tcpPort: tcpPort ?? this.tcpPort,
    discoveryPort: discoveryPort ?? this.discoveryPort,
    pairingCode: pairingCode ?? this.pairingCode,
    erp: quitarErp ? null : (erp ?? this.erp),
    mysql: quitarMysql ? null : (mysql ?? this.mysql),
    fiscal: fiscal ?? this.fiscal,
    cierre: cierre ?? this.cierre,
    impresion: impresion ?? this.impresion,
    reposicion: reposicion ?? this.reposicion,
    empresa: empresa ?? this.empresa,
    mesas: mesas ?? this.mesas,
  );

  @override
  List<Object?> get props => [
    deviceId,
    nombreTpv,
    tcpPort,
    discoveryPort,
    pairingCode,
    erp,
    mysql,
    fiscal,
    cierre,
    impresion,
    reposicion,
    empresa,
    mesas,
  ];
}
