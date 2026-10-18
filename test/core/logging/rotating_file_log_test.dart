import 'dart:io';

import 'package:logging/logging.dart';
import 'package:proyecto_comandero/core/logging/rotating_file_log.dart';
import 'package:test/test.dart';

LogRecord _registro(
  String mensaje, {
  Level level = Level.INFO,
  Object? error,
  StackTrace? stackTrace,
}) => LogRecord(level, mensaje, 'tpv.prueba', error, stackTrace);

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('rotating_file_log_test');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  String ruta(String nombre) => '${tmp.path}${Platform.pathSeparator}$nombre';

  test('crea la carpeta y escribe una línea por registro', () {
    final carpeta = ruta('logs');
    final log = RotatingFileLog.open(directory: carpeta);
    addTearDown(log.close);

    log.write(_registro('primero'));
    log.write(_registro('segundo', level: Level.WARNING));

    final lineas = File(log.path).readAsLinesSync();
    expect(log.path, endsWith(RotatingFileLog.defaultFileName));
    expect(lineas, hasLength(2));
    expect(lineas[0], endsWith(' INFO tpv.prueba: primero'));
    expect(lineas[1], endsWith(' WARNING tpv.prueba: segundo'));
  });

  test('formato con error y traza en líneas sangradas', () {
    final texto = RotatingFileLog.format(
      _registro(
        'falló',
        level: Level.SEVERE,
        error: StateError('roto'),
        stackTrace: StackTrace.fromString('#0 a (a.dart:1)\n#1 b (b.dart:2)'),
      ),
    );
    final lineas = texto.trimRight().split('\n');
    expect(lineas[0], contains(' SEVERE tpv.prueba: falló'));
    expect(lineas[1], '  Error: Bad state: roto');
    expect(lineas.sublist(2), ['  #0 a (a.dart:1)', '  #1 b (b.dart:2)']);
  });

  test('añade al fichero existente al reabrir', () {
    final primero = RotatingFileLog.open(directory: tmp.path)
      ..write(_registro('antes'));
    primero.close();
    final segundo = RotatingFileLog.open(directory: tmp.path)
      ..write(_registro('después'));
    addTearDown(segundo.close);

    final lineas = File(segundo.path).readAsLinesSync();
    expect(lineas.map((l) => l.split(': ').last), ['antes', 'después']);
  });

  test('rota al superar el tope y conserva como mucho maxFiles ficheros', () {
    final log = RotatingFileLog.open(
      directory: tmp.path,
      fileName: 'app.log',
      maxBytes: 1024,
      maxFiles: 3,
    );
    addTearDown(log.close);

    // ~100 bytes por línea: unas 10 líneas por fichero, 60 líneas = 6 rotaciones.
    for (var i = 0; i < 60; i++) {
      log.write(_registro('línea ${i.toString().padLeft(2, '0')} ${'x' * 50}'));
    }

    final nombres = tmp.listSync().map((e) => e.uri.pathSegments.last).toList()
      ..sort();
    expect(nombres, ['app.log', 'app.log.1', 'app.log.2']);
    for (final nombre in nombres) {
      expect(File(ruta(nombre)).lengthSync(), lessThanOrEqualTo(1024));
    }
    // El actual tiene lo último; los anteriores, por orden de antigüedad.
    final actual = File(ruta('app.log')).readAsStringSync();
    final anterior = File(ruta('app.log.1')).readAsStringSync();
    expect(actual, contains('línea 59'));
    expect(anterior, isNot(contains('línea 59')));
    expect(
      File(ruta('app.log.2')).readAsStringSync(),
      isNot(contains('línea 00')),
    );
  });

  test('con maxFiles = 1 solo queda el fichero actual', () {
    final log = RotatingFileLog.open(
      directory: tmp.path,
      fileName: 'app.log',
      maxBytes: 1024,
      maxFiles: 1,
    );
    addTearDown(log.close);
    for (var i = 0; i < 40; i++) {
      log.write(_registro('línea $i ${'y' * 60}'));
    }
    expect(tmp.listSync().map((e) => e.uri.pathSegments.last), ['app.log']);
    expect(File(log.path).readAsStringSync(), contains('línea 39'));
  });

  test('rota en la primera escritura si el fichero heredado ya está lleno', () {
    File(ruta('app.log')).writeAsStringSync('z' * 2000);
    final log = RotatingFileLog.open(
      directory: tmp.path,
      fileName: 'app.log',
      maxBytes: 1024,
      maxFiles: 2,
    );
    addTearDown(log.close);

    log.write(_registro('nuevo'));

    expect(File(ruta('app.log.1')).lengthSync(), 2000);
    expect(File(ruta('app.log')).readAsStringSync(), contains('nuevo'));
  });

  test('open lanza FileSystemException si no se puede crear la carpeta', () {
    final fichero = File(ruta('soy_un_fichero'))..writeAsStringSync('');
    expect(
      () => RotatingFileLog.open(directory: '${fichero.path}/logs'),
      throwsA(isA<FileSystemException>()),
    );
  });

  test('rechaza límites absurdos', () {
    expect(
      () => RotatingFileLog.open(directory: tmp.path, maxBytes: 10),
      throwsArgumentError,
    );
    expect(
      () => RotatingFileLog.open(directory: tmp.path, maxFiles: 0),
      throwsArgumentError,
    );
  });

  test('tras close las escrituras se ignoran sin lanzar', () {
    final log = RotatingFileLog.open(directory: tmp.path)
      ..write(_registro('dentro'))
      ..close();
    expect(log.isOpen, isFalse);
    expect(() => log.write(_registro('fuera')), returnsNormally);
    expect(File(log.path).readAsStringSync(), isNot(contains('fuera')));
  });

  test('un fallo al rotar desactiva el registro sin propagar el error', () {
    final log = RotatingFileLog.open(
      directory: tmp.path,
      fileName: 'app.log',
      maxBytes: 1024,
      maxFiles: 2,
    );
    addTearDown(log.close);
    // Una carpeta con el nombre del fichero rotado impide el renombrado.
    Directory(ruta('app.log.1')).createSync();
    Directory(ruta('app.log.1${Platform.pathSeparator}dentro')).createSync();

    expect(() {
      for (var i = 0; i < 30; i++) {
        log.write(_registro('línea $i ${'w' * 60}'));
      }
    }, returnsNormally);
    expect(log.isOpen, isFalse);
  });
}
