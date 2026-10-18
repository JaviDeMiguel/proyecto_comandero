import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';

/// Registro en fichero con rotación por tamaño, para soporte en producción.
///
/// Escribe cada [LogRecord] como una línea de texto (más el error y la traza,
/// si los hay) en `<directorio>/<nombre>`. Cuando el fichero va a superar
/// [maxBytes], lo renombra a `<nombre>.1` (y `.1` a `.2`, etc.) y empieza
/// otro; conserva como mucho [maxFiles] ficheros contando el actual.
///
/// Las escrituras son síncronas para que el último mensaje antes de un cierre
/// inesperado quede en disco. Un fallo de escritura no se propaga nunca: el
/// registro se desactiva y la app sigue funcionando.
///
/// No filtra contenido: quien registra es responsable de no incluir secretos
/// (los `toString` de la configuración ya los enmascaran).
final class RotatingFileLog {
  RotatingFileLog._(
    this.directory,
    this.fileName,
    this.maxBytes,
    this.maxFiles,
    this._file,
    this._size,
  );

  /// Abre (o crea) el fichero de registro en [directory], creando la carpeta
  /// si no existe. Lanza [FileSystemException] si no se puede abrir: el
  /// arranque de la app debe capturarla y seguir sin registro en fichero.
  static RotatingFileLog open({
    required String directory,
    String fileName = defaultFileName,
    int maxBytes = defaultMaxBytes,
    int maxFiles = defaultMaxFiles,
  }) {
    if (maxBytes < 1024) {
      throw ArgumentError.value(maxBytes, 'maxBytes', 'mínimo 1024');
    }
    if (maxFiles < 1) {
      throw ArgumentError.value(maxFiles, 'maxFiles', 'mínimo 1');
    }
    Directory(directory).createSync(recursive: true);
    final path = _join(directory, fileName);
    final file = File(path).openSync(mode: FileMode.append);
    return RotatingFileLog._(
      directory,
      fileName,
      maxBytes,
      maxFiles,
      file,
      file.lengthSync(),
    );
  }

  static const String defaultFileName = 'tpv_comandero.log';

  /// 2 MB por fichero.
  static const int defaultMaxBytes = 2 * 1024 * 1024;

  /// El actual y cuatro anteriores (≈ 10 MB como mucho).
  static const int defaultMaxFiles = 5;

  final String directory;
  final String fileName;
  final int maxBytes;
  final int maxFiles;

  RandomAccessFile? _file;
  int _size;

  /// Ruta del fichero actual.
  String get path => _join(directory, fileName);

  /// `false` tras [close] o tras un fallo de escritura.
  bool get isOpen => _file != null;

  /// Escribe [record]. Apto como manejador de `Logger.root.onRecord`.
  void write(LogRecord record) {
    if (_file == null) return;
    final bytes = utf8.encode(format(record));
    try {
      if (_size > 0 && _size + bytes.length > maxBytes) _rotate();
      final file = _file;
      if (file == null) return;
      file.writeFromSync(bytes);
      _size += bytes.length;
    } on FileSystemException {
      _disable();
    }
  }

  /// Cierra el fichero. Las escrituras posteriores se ignoran.
  void close() => _disable();

  /// Formato de una entrada: `2026-10-16T15:16:02.123 INFO tpv.x: mensaje`,
  /// seguido del error y la traza en líneas aparte.
  static String format(LogRecord record) {
    final buffer = StringBuffer()
      ..write(record.time.toIso8601String())
      ..write(' ')
      ..write(record.level.name)
      ..write(' ')
      ..write(record.loggerName)
      ..write(': ')
      ..writeln(record.message);
    final error = record.error;
    if (error != null) buffer.writeln('  Error: $error');
    final stack = record.stackTrace;
    if (stack != null) {
      for (final line in stack.toString().trimRight().split('\n')) {
        buffer.writeln('  $line');
      }
    }
    return buffer.toString();
  }

  void _rotate() {
    _file?.closeSync();
    _file = null;
    final oldest = File('$path.${maxFiles - 1}');
    if (maxFiles == 1) {
      File(path).deleteSync();
    } else {
      if (oldest.existsSync()) oldest.deleteSync();
      for (var i = maxFiles - 2; i >= 1; i--) {
        final f = File('$path.$i');
        if (f.existsSync()) f.renameSync('$path.${i + 1}');
      }
      File(path).renameSync('$path.1');
    }
    _file = File(path).openSync(mode: FileMode.append);
    _size = 0;
  }

  void _disable() {
    final file = _file;
    _file = null;
    if (file == null) return;
    try {
      file.closeSync();
    } on FileSystemException {
      // Ya no hay nada que hacer con un fichero que no se puede cerrar.
    }
  }

  static String _join(String directory, String name) =>
      directory.endsWith(Platform.pathSeparator) || directory.endsWith('/')
      ? '$directory$name'
      : '$directory${Platform.pathSeparator}$name';
}
