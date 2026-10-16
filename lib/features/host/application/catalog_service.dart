import 'dart:async';
import 'dart:convert';

import '../../../core/errors/app_exception.dart';
import '../../../core/facturascripts/catalog/catalog_models.dart';
import '../../../core/logging/app_logger.dart';
import '../../../core/utils/streams.dart';
import '../../sala/protocol/sala_messages.dart';
import 'alert_bus.dart';
import 'host_state_store.dart';
import 'ports.dart';

/// Catálogo vigente del host: caché en el diario local y refresco desde el
/// ERP. La versión es un hash del contenido, así que un refresco que no
/// cambia nada no obliga a los comanderos a volver a descargarlo.
final class CatalogService {
  CatalogService({
    required this._store,
    required this._alerts,
    CatalogPort? port,
    String? codimpuestoPorDefecto,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now {
    configurar(port: port, codimpuestoPorDefecto: codimpuestoPorDefecto);
  }

  static final Logger _log = appLogger('host.catalogo');

  final HostStateStore _store;
  final AlertBus _alerts;
  CatalogPort? _port;
  String? _codimpuestoPorDefecto;
  final DateTime Function() _now;
  final StreamController<CatalogoChangedEvent> _changes =
      StreamController<CatalogoChangedEvent>.broadcast();
  Future<CatalogSnapshot>? _refreshing;

  CatalogSnapshot? get catalogo => _store.snapshot.catalogo;
  String? get version => _store.snapshot.catalogoVersion;
  bool get disponible => catalogo != null;

  /// Hay una fuente de la que refrescar.
  bool get configurado => _port != null;

  /// Se emite cuando cambia la versión del catálogo.
  Stream<CatalogoChangedEvent> get changes => _changes.stream;

  ArticuloCatalogo? articulo(String referencia) =>
      catalogo?.porReferencia(referencia);

  /// Reconfigura en caliente; el puerto se sustituye siempre (nulo = sin ERP).
  void configurar({CatalogPort? port, String? codimpuestoPorDefecto}) {
    _port = port;
    _codimpuestoPorDefecto = codimpuestoPorDefecto;
  }

  /// Descarga el catálogo del ERP, lo guarda y avisa si cambió la versión.
  /// Varias llamadas simultáneas comparten la misma descarga.
  ///
  /// Lanza [ConfigException] si no hay ERP configurado y [ErpApiException]
  /// si falla la API (el catálogo anterior sigue vigente).
  Future<CatalogSnapshot> refrescar() {
    final port = _port;
    if (port == null) {
      throw const ConfigException('No hay ERP configurado para el catálogo');
    }
    return _refreshing ??= _refrescar(port)
        .whenComplete(() => _refreshing = null);
  }

  Future<CatalogSnapshot> _refrescar(CatalogPort port) async {
    final snapshot = await port.cargar(
      now: _now,
      codimpuestoPorDefecto: _codimpuestoPorDefecto,
    );
    final version = versionDe(snapshot);
    final cambio = version != _store.snapshot.catalogoVersion;
    await _store.update(
      (s) => s.copyWith(catalogo: snapshot, catalogoVersion: version),
    );
    for (final aviso in snapshot.avisos) {
      _alerts.aviso('Catálogo: $aviso', origen: 'catalogo');
    }
    if (cambio) {
      _log.info(
        'Catálogo actualizado: versión $version '
        '(${snapshot.articulos.length} artículos)',
      );
      if (!_changes.isClosed) {
        _changes.add(CatalogoChangedEvent(version: version));
      }
    }
    return snapshot;
  }

  /// Hash estable (FNV-1a de 64 bits) del contenido del catálogo, sin la
  /// fecha de descarga ni los avisos.
  static String versionDe(CatalogSnapshot snapshot) {
    final json = snapshot.toJson()
      ..remove('obtenidoEn')
      ..remove('avisos');
    final bytes = utf8.encode(jsonEncode(json));
    var hash = 0xcbf29ce484222325;
    for (final byte in bytes) {
      hash ^= byte;
      // La multiplicación desborda y envuelve en 64 bits, como manda FNV.
      hash *= 0x100000001b3;
    }
    final alto = (hash >>> 32).toRadixString(16).padLeft(8, '0');
    final bajo = (hash & 0xFFFFFFFF).toRadixString(16).padLeft(8, '0');
    return '$alto$bajo';
  }

  Future<void> dispose() async {
    cerrarSinEsperar(_changes);
  }
}
