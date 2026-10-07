import 'dart:io';

import 'package:test/test.dart';

/// Reglas de arquitectura comprobadas automáticamente.
///
/// `lib/core` y las carpetas `domain/` y `application/` de cada feature deben
/// ser Dart puro: así se prueban con `dart test` y sus tipos pueden cruzar a
/// los isolates sin arrastrar el motor de Flutter.
void main() {
  final directive = RegExp(
    r'''^\s*(?:import|export)\s+['"]([^'"]+)['"]''',
    multiLine: true,
  );

  const flutterOnlyPrefixes = [
    'dart:ui',
    'package:flutter/',
    'package:flutter_',
    'package:shared_preferences',
    'package:path_provider',
    'package:wakelock_plus',
  ];

  List<File> dartFilesUnder(String path) {
    final directory = Directory(path);
    if (!directory.existsSync()) return const [];
    return directory
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'))
        .toList();
  }

  String normalize(String path) => path.replaceAll(r'\', '/');

  /// Devuelve la ruta bajo `lib/` a la que apunta [uri] importado desde
  /// [file], o `null` si es un paquete externo o una librería del SDK.
  String? resolveInLib(File file, String uri) {
    const self = 'package:proyecto_comandero/';
    if (uri.startsWith(self)) return 'lib/${uri.substring(self.length)}';
    if (uri.contains(':')) return null;
    final resolved = file.parent.uri.resolve(uri).toFilePath();
    final absolute = normalize(resolved);
    final root = normalize(Directory.current.absolute.path);
    return absolute.startsWith('$root/')
        ? absolute.substring(root.length + 1)
        : absolute;
  }

  Iterable<String> importsOf(File file) => directive
      .allMatches(file.readAsStringSync())
      .map((match) => match.group(1)!);

  List<String> flutterImports(Iterable<File> files) => [
    for (final file in files)
      for (final uri in importsOf(file))
        if (flutterOnlyPrefixes.any(uri.startsWith))
          '${normalize(file.path)} importa $uri',
  ];

  test('lib/core es Dart puro (sin Flutter ni plugins de plataforma)', () {
    expect(flutterImports(dartFilesUnder('lib/core')), isEmpty);
  });

  test('lib/core no depende de lib/features ni de lib/app', () {
    final violations = [
      for (final file in dartFilesUnder('lib/core'))
        for (final uri in importsOf(file))
          if (resolveInLib(file, uri) case final target?
              when target.startsWith('lib/features/') ||
                  target.startsWith('lib/app/'))
            '${normalize(file.path)} importa $uri',
    ];
    expect(violations, isEmpty);
  });

  test('domain/ y application/ de cada feature son Dart puro', () {
    final files = dartFilesUnder('lib/features').where((file) {
      final path = normalize(file.path);
      return path.contains('/domain/') || path.contains('/application/');
    });
    expect(flutterImports(files), isEmpty);
  });
}
