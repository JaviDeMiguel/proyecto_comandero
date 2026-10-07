import '../../../core/errors/app_exception.dart';
import '../../sala/domain/linea_comanda.dart' show DestinoPreparacion;
import '../../settings/domain/app_settings.dart';
import '../domain/comandero_config.dart';

/// Traduce los ajustes de la aplicación a la configuración que necesita el
/// [ComanderoConfig] del controlador. Función pura.
///
/// Los textos vacíos o con solo espacios del código de emparejamiento y del
/// host manual se tratan como ausentes. El enrutamiento por familias de los
/// ajustes de impresión es el de reserva del comandero (el del host, si lo
/// publica, tiene prioridad).
ComanderoConfig comanderoConfigFromApp(AppSettings s, {String? appVersion}) =>
    ComanderoConfig(
      deviceId: s.deviceId,
      deviceName: s.deviceName,
      appVersion: appVersion,
      pairingCode: _limpio(s.red.pairingCode),
      hostManual: _limpio(s.red.hostManual),
      discoveryPort: s.red.discoveryPort,
      destinoPorFamilia: s.impresion.enrutamiento.porFamilia,
      destinoPorDefecto: s.impresion.enrutamiento.porDefecto,
    );

/// La parte de la configuración que obliga a recrear el controlador si
/// cambia (identidad del dispositivo y puerto de descubrimiento). El código
/// de emparejamiento y el host manual se aplican al conectar, sin recrearlo,
/// y el enrutamiento local no lo recrea (el del host tiene prioridad).
ComanderoConfig identidadComandero(ComanderoConfig config) => config.copyWith(
  pairingCode: () => null,
  hostManual: () => null,
  destinoPorFamilia: const {},
  destinoPorDefecto: DestinoPreparacion.cocina,
);

/// Normaliza la dirección escrita por el usuario (`ip`, `ip:puerto` o
/// `[ipv6]:puerto`) al formato `host:puerto` que guardan los ajustes. Sin
/// puerto se asume el del host por defecto.
///
/// Lanza [ValidationException] si el texto no es una dirección válida.
String normalizarHostManual(String texto) {
  try {
    final endpoint = parseHostEndpoint(texto);
    if (endpoint.host.contains(RegExp(r'\s'))) {
      throw FormatException("Host no válido '${endpoint.host}'");
    }
    return endpoint.toString();
  } on FormatException catch (error) {
    throw ValidationException(
      'Dirección del host no válida: ${error.message}',
      cause: error,
    );
  }
}

String? _limpio(String? texto) {
  final limpio = texto?.trim();
  return (limpio == null || limpio.isEmpty) ? null : limpio;
}
