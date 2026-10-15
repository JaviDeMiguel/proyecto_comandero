/// Traducción de los ajustes persistidos de la aplicación ([AppSettings]) a
/// la configuración efectiva del host ([HostSettings]).
///
/// Es una función pura: no lee plugins ni almacenamiento, de modo que el
/// proveedor del runtime puede compararla con la vigente y aplicar solo lo
/// que cambió.
library;

import '../../settings/domain/app_settings.dart' as app;
import '../domain/host_settings.dart';

/// Empresa por defecto de FacturaScripts cuando los ajustes no fijan una.
const int kIdEmpresaPorDefecto = 1;

/// Construye la configuración del host a partir de los ajustes de la app.
///
/// * Identidad: `deviceId`; el nombre visible es `fiscal.nombreTpv` (o el
///   nombre del dispositivo si está vacío).
/// * Red: puertos TCP/UDP y código de emparejamiento (vacío = sin
///   emparejamiento).
/// * ERP y MySQL: se copian tal cual (nulos = sin configurar).
/// * Fiscal: serie, cliente, formas de pago, almacén (vacío si no se fijó:
///   la facturación y el stock quedan "no configurados" hasta completarlo),
///   empresa (1 por defecto) y emisión de facturas.
/// * Cierre: modo del asiento Z y subcuentas forzadas.
/// * Impresión (con el enrutamiento de comandas por familias y el formato:
///   perfiles por impresora, ticket, emisión, QR y pases), reposición y
///   mesas.
///
/// El fondo de caja (`fondoCajaCents`) no forma parte de [HostSettings]: lo
/// usa la pantalla de caja como propuesta al abrir el turno.
HostSettings hostSettingsFromApp(app.AppSettings s) {
  final nombre = s.fiscal.nombreTpv.trim();
  final pairing = s.red.pairingCode?.trim();
  return HostSettings(
    deviceId: s.deviceId,
    nombreTpv: nombre.isEmpty ? s.deviceName : nombre,
    tcpPort: s.red.tcpPort,
    discoveryPort: s.red.discoveryPort,
    pairingCode: (pairing == null || pairing.isEmpty) ? null : pairing,
    erp: s.fsApi,
    mysql: s.mysql,
    fiscal: FiscalSettings(
      codcliente: s.fiscal.codcliente,
      codserie: s.fiscal.codserie,
      codpagoEfectivo: s.fiscal.codpagoEfectivo,
      codpagoTarjeta: s.fiscal.codpagoTarjeta,
      codalmacen: s.fiscal.codalmacen?.trim() ?? '',
      idempresa: s.fiscal.idempresa ?? kIdEmpresaPorDefecto,
      emitirFacturas: s.fiscal.emitirFacturas,
    ),
    cierre: CierreSettings(
      modoAsientoZ: s.fiscal.modoAsientoZ,
      overridesSubcuentas: s.fiscal.subcuentasOverride,
    ),
    impresion: ImpresionSettings(
      cocina: s.impresion.cocina,
      barra: s.impresion.barra,
      tickets: s.impresion.tickets,
      imprimirComandas: s.impresion.imprimirComandaCocina,
      imprimirTicketAlCobrar: s.impresion.imprimirTicketAlCobrar,
      abrirCajonEfectivo: s.impresion.abrirCajon,
      paper: s.impresion.paper,
      enrutamiento: s.impresion.enrutamiento,
      formato: s.impresion.formato,
    ),
    reposicion: ReposicionSettings(
      automatica: s.reposicion.automatica,
      enCierre: s.reposicion.enCierre,
      politica: s.reposicion.politica,
    ),
    mesas: s.mesas,
  );
}
