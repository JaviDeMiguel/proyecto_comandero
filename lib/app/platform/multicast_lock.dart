import 'dart:io' show Platform;

import 'package:flutter/services.dart';

import '../../core/logging/app_logger.dart';

/// Lock de multidifusión Wi-Fi de Android (`WifiManager.MulticastLock`).
///
/// Muchos chipsets Wi-Fi descartan los datagramas UDP de broadcast para ahorrar
/// batería; el host debe mantener este lock mientras escucha los "probe" de
/// descubrimiento en el puerto 4041. En el resto de plataformas no hace nada.
class MulticastLock {
  const MulticastLock();

  static const MethodChannel _channel = MethodChannel(
    'proyecto_comandero/multicast_lock',
  );
  static final Logger _log = appLogger('platform.multicast_lock');

  /// Adquiere el lock. Devuelve `false` si la plataforma no lo necesita o si
  /// no se pudo adquirir (el descubrimiento sigue funcionando en modo degradado).
  Future<bool> acquire() => _invoke('acquire');

  /// Libera el lock si estaba adquirido.
  Future<bool> release() => _invoke('release');

  Future<bool> _invoke(String method) async {
    if (!Platform.isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>(method) ?? false;
    } on PlatformException catch (error, stackTrace) {
      _log.warning('MulticastLock.$method falló', error, stackTrace);
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}
