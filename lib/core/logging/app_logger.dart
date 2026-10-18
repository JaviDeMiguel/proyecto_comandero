import 'dart:async';
import 'dart:developer' as developer;

import 'package:logging/logging.dart';

export 'package:logging/logging.dart' show Level, LogRecord, Logger;

StreamSubscription<LogRecord>? _rootSubscription;

/// Crea un logger bajo la raíz `tpv` (p. ej. `appLogger('network.tcp')`).
Logger appLogger(String name) => Logger('tpv.$name');

/// Configura la salida de logs del proceso. Puede llamarse varias veces: la
/// última configuración sustituye a la anterior.
///
/// Por defecto los registros van a `dart:developer` (consola de depuración y
/// DevTools); [onRecord] permite redirigirlos (fichero, tests...). Para
/// enviarlos a varios sitios, combina [developerLogSink] con los demás.
void configureLogging({
  Level level = Level.INFO,
  void Function(LogRecord record)? onRecord,
}) {
  Logger.root.level = level;
  unawaited(_rootSubscription?.cancel());
  _rootSubscription = Logger.root.onRecord.listen(onRecord ?? developerLogSink);
}

/// Envía [record] a `dart:developer` (consola de depuración y DevTools; en
/// release no lo ve nadie, de ahí el registro en fichero de la app).
void developerLogSink(LogRecord record) {
  developer.log(
    record.message,
    time: record.time,
    level: record.level.value,
    name: record.loggerName,
    error: record.error,
    stackTrace: record.stackTrace,
  );
}
