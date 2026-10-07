import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../../core/logging/app_logger.dart';
import '../domain/comandero_cache_repository.dart';

final Logger _log = appLogger('comandero.cache');

/// Caché del comandero en un fichero JSON dentro de un directorio inyectado
/// (la capa de presentación lo obtiene con `path_provider`; aquí solo
/// `dart:io`).
///
/// Escritura atómica: se escribe un fichero temporal y se renombra sobre el
/// definitivo, de modo que un cierre de la app a mitad nunca deja un JSON
/// truncado. Las operaciones no lanzan: un fallo de E/S se registra y la
/// caché se comporta como vacía.
final class FileComanderoCacheRepository implements ComanderoCacheRepository {
  FileComanderoCacheRepository(
    this.directory, {
    this.fileName = 'catalogo_cache.json',
  });

  final Directory directory;
  final String fileName;

  File get _file => File('${directory.path}${Platform.pathSeparator}$fileName');
  File get _tempFile =>
      File('${directory.path}${Platform.pathSeparator}$fileName.tmp');

  /// Serializa las operaciones para que una lectura no vea un `rename` a
  /// medias ni dos escrituras se pisen el temporal.
  Future<void> _lock = Future<void>.value();

  Future<T> _serialized<T>(Future<T> Function() action) {
    final previous = _lock;
    final completer = Completer<void>();
    _lock = completer.future;
    return previous.then((_) => action()).whenComplete(completer.complete);
  }

  @override
  Future<CatalogoCacheado?> leerCatalogo() => _serialized(() async {
    final file = _file;
    try {
      if (!await file.exists()) return null;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, Object?>) {
        _log.warning('Caché de catálogo con formato inesperado; se ignora');
        return null;
      }
      return CatalogoCacheado.fromJson(decoded);
    } on FormatException catch (error) {
      _log.warning('Caché de catálogo ilegible; se ignora: ${error.message}');
      return null;
    } on IOException catch (error) {
      _log.warning('No se pudo leer la caché de catálogo: $error');
      return null;
    }
  });

  @override
  Future<void> guardarCatalogo(CatalogoCacheado cacheado) =>
      _serialized(() async {
        try {
          await directory.create(recursive: true);
          final temp = _tempFile;
          await temp.writeAsString(jsonEncode(cacheado.toJson()), flush: true);
          await temp.rename(_file.path);
        } on IOException catch (error) {
          _log.warning('No se pudo guardar la caché de catálogo: $error');
        }
      });

  @override
  Future<void> borrarCatalogo() => _serialized(() async {
    for (final file in [_file, _tempFile]) {
      try {
        if (await file.exists()) await file.delete();
      } on IOException catch (error) {
        _log.warning('No se pudo borrar ${file.path}: $error');
      }
    }
  });
}
