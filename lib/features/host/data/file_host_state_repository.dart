import 'dart:convert';
import 'dart:io';

import '../../../core/logging/app_logger.dart';
import '../application/host_state_repository.dart';
import '../domain/host_snapshot.dart';

/// Diario local en un fichero JSON dentro de [directory].
///
/// * **Escritura atómica y durable.** Se escribe `host_state.json.tmp` con
///   un `RandomAccessFile` y se sincroniza a disco (`flush`, que hace
///   `fsync`/`FlushFileBuffers`) ANTES de renombrarlo: sin eso, tras un corte
///   de luz el rename (metadato) puede haber llegado al disco y los datos
///   no, y el diario quedaría vacío. El fichero anterior se conserva como
///   `host_state.json.bak`.
/// * **Lectura tolerante.** Si el fichero no existe devuelve `null`; si está
///   corrupto (JSON inválido, UTF-8 inválido o forma inesperada) se aparta
///   como `host_state.json.corrupto-<timestamp>` y se prueba el `.tmp` (un
///   renombrado que no llegó a completarse) y después el `.bak`.
/// * **Nunca se pisa un diario que no se pudo leer.** Si leerlo falla por
///   E/S (bloqueo de un antivirus o de una copia de seguridad), se reintenta
///   unas veces; si sigue sin poder leerse se copia como
///   `host_state.json.ilegible-<timestamp>` y, si ni eso se puede, [load]
///   lanza y los guardados siguientes se niegan a sobrescribirlo hasta que
///   se pueda apartar una copia.
///
/// El directorio lo decide la capa de presentación (p. ej. con
/// `path_provider`); este fichero no depende de Flutter.
final class FileHostStateRepository implements HostStateRepository {
  FileHostStateRepository(
    this.directory, {
    this.fileName = 'host_state.json',
    this.reintentosLectura = 3,
    this.esperaReintento = const Duration(milliseconds: 200),
  });

  static final Logger _log = appLogger('host.state.file');

  final Directory directory;
  final String fileName;

  /// Lecturas adicionales ante un error de E/S antes de rendirse.
  final int reintentosLectura;
  final Duration esperaReintento;

  /// El diario principal existe pero no se pudo leer ni copiar: no se
  /// sobrescribe hasta poder apartar una copia.
  bool _protegido = false;

  File get file => File('${directory.path}${Platform.pathSeparator}$fileName');
  File get _tmp => File('${file.path}.tmp');
  File get _bak => File('${file.path}.bak');

  @override
  Future<HostSnapshot?> load() async {
    final primary = await _read(file);
    if (primary != null) return primary;
    // Un .tmp completo que no llegó a renombrarse es más reciente que el
    // definitivo (si este faltaba o estaba corrupto).
    final pending = await _read(_tmp);
    if (pending != null) {
      _log.warning('Diario recuperado del fichero temporal ${_tmp.path}');
      return pending;
    }
    final backup = await _read(_bak);
    if (backup != null) {
      _log.warning('Diario recuperado de la copia anterior ${_bak.path}');
      return backup;
    }
    return null;
  }

  Future<HostSnapshot?> _read(File source) async {
    if (!await source.exists()) return null;
    final List<int> bytes;
    try {
      bytes = await _leerConReintentos(source);
    } on FileSystemException catch (error) {
      await _apartarIlegible(source, error);
      return null;
    }
    final String text;
    try {
      text = utf8.decode(bytes);
    } on FormatException catch (error) {
      await _quarantine(source, 'UTF-8 inválido: ${error.message}');
      return null;
    }
    if (text.trim().isEmpty) {
      await _quarantine(source, 'vacío');
      return null;
    }
    try {
      final decoded = jsonDecode(text);
      if (decoded is! Map<String, Object?>) {
        throw const FormatException('El JSON raíz no es un objeto');
      }
      return HostSnapshot.fromJson(decoded);
    } on FormatException catch (error) {
      await _quarantine(source, error.message);
      return null;
    }
  }

  Future<List<int>> _leerConReintentos(File source) async {
    for (var intento = 0; ; intento++) {
      try {
        return await source.readAsBytes();
      } on FileSystemException catch (error) {
        if (intento >= reintentosLectura) rethrow;
        _log.warning(
          'No se pudo leer ${source.path} (intento ${intento + 1}); '
          'se reintenta',
          error,
        );
        await Future<void>.delayed(esperaReintento);
      }
    }
  }

  /// El fichero existe pero no se puede leer: se copia aparte (copia y no
  /// rename, por si está bloqueado) antes de dar el diario por perdido. Si
  /// tampoco se puede copiar y es el principal, se protege y se lanza.
  Future<void> _apartarIlegible(File source, FileSystemException error) async {
    _log.severe('No se pudo leer ${source.path}', error);
    if (await _copiarIlegible(source)) return;
    if (source.path != file.path) return;
    _protegido = true;
    throw FileSystemException(
      'El diario local existe pero no se puede leer ni copiar; no se '
      'sobrescribirá hasta poder apartarlo: ${error.message}',
      source.path,
      error.osError,
    );
  }

  Future<bool> _copiarIlegible(File source) async {
    final target = '${file.path}.ilegible-${_stamp()}';
    try {
      await source.copy(target);
      _log.severe('Diario ilegible ${source.path} copiado como $target');
      return true;
    } on FileSystemException catch (error) {
      _log.severe('No se pudo copiar el diario ilegible ${source.path}', error);
      return false;
    }
  }

  Future<void> _quarantine(File source, String reason) async {
    final target = '${file.path}.corrupto-${_stamp()}';
    _log.severe(
      'Diario ${source.path} ilegible ($reason); se aparta como $target',
    );
    try {
      await source.rename(target);
    } on FileSystemException catch (error) {
      _log.warning('No se pudo apartar el fichero corrupto', error);
    }
  }

  static String _stamp() =>
      DateTime.now().toIso8601String().replaceAll(':', '-');

  @override
  Future<void> save(HostSnapshot snapshot) async {
    final bytes = utf8.encode(jsonEncode(snapshot.toJson()));
    try {
      if (_protegido) {
        if (!await file.exists() || await _copiarIlegible(file)) {
          _protegido = false;
        } else {
          throw FileSystemException(
            'El diario anterior no se pudo leer ni copiar; no se sobrescribe',
            file.path,
          );
        }
      }
      if (!await directory.exists()) await directory.create(recursive: true);
      final tmp = _tmp;
      final raf = await tmp.open(mode: FileMode.write);
      try {
        await raf.writeFrom(bytes);
        // RandomAccessFile.flush sincroniza con el disco (fsync /
        // FlushFileBuffers), a diferencia de IOSink.flush.
        await raf.flush();
      } finally {
        await raf.close();
      }
      if (await file.exists()) await file.rename(_bak.path);
      await tmp.rename(file.path);
    } on FileSystemException catch (error) {
      throw FileSystemException(
        'No se pudo guardar el diario local en ${file.path}: ${error.message}',
        error.path,
        error.osError,
      );
    }
  }
}
