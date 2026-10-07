import 'dart:io';

import 'package:proyecto_comandero/features/comandero/data/file_comandero_cache_repository.dart';
import 'package:proyecto_comandero/features/comandero/data/in_memory_comandero_cache_repository.dart';
import 'package:proyecto_comandero/features/comandero/domain/comandero_cache_repository.dart';
import 'package:test/test.dart';

import '../fake_sala_host.dart';

void main() {
  late Directory dir;

  final cacheado = CatalogoCacheado(
    version: 'v7',
    catalogo: kCatalogoPrueba,
    guardadoEn: DateTime.utc(2026, 10, 7, 9, 30),
  );

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('comandero_cache_test_');
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  test('guarda y lee el catálogo con su versión (ida y vuelta JSON)', () async {
    final repo = FileComanderoCacheRepository(dir);
    expect(await repo.leerCatalogo(), isNull);

    await repo.guardarCatalogo(cacheado);
    expect(await repo.leerCatalogo(), cacheado);
    expect(File('${dir.path}/catalogo_cache.json').existsSync(), isTrue);
    expect(
      File('${dir.path}/catalogo_cache.json.tmp').existsSync(),
      isFalse,
      reason: 'la escritura es atómica: el temporal se renombra',
    );

    // Otra instancia sobre el mismo directorio ve lo guardado.
    expect(await FileComanderoCacheRepository(dir).leerCatalogo(), cacheado);

    await repo.borrarCatalogo();
    expect(await repo.leerCatalogo(), isNull);
  });

  test('crea el directorio si no existe y sobrescribe versiones', () async {
    final anidado = Directory('${dir.path}/a/b');
    final repo = FileComanderoCacheRepository(anidado, fileName: 'c.json');
    await repo.guardarCatalogo(cacheado);
    final v8 = CatalogoCacheado(
      version: 'v8',
      catalogo: kCatalogoPrueba,
      guardadoEn: DateTime.utc(2026, 10, 7, 10),
    );
    await repo.guardarCatalogo(v8);
    expect((await repo.leerCatalogo())?.version, 'v8');
  });

  test('un fichero corrupto o con otra forma equivale a caché vacía', () async {
    final repo = FileComanderoCacheRepository(dir);
    final file = File('${dir.path}/catalogo_cache.json');
    await file.writeAsString('{no es json');
    expect(await repo.leerCatalogo(), isNull);
    await file.writeAsString('[1,2,3]');
    expect(await repo.leerCatalogo(), isNull);
    await file.writeAsString('{"version":"x"}');
    expect(await repo.leerCatalogo(), isNull);
    // Y se puede sobrescribir sin problema.
    await repo.guardarCatalogo(cacheado);
    expect(await repo.leerCatalogo(), cacheado);
  });

  test('escrituras concurrentes se serializan y gana la última', () async {
    final repo = FileComanderoCacheRepository(dir);
    final versiones = List.generate(
      10,
      (i) => CatalogoCacheado(
        version: 'v$i',
        catalogo: kCatalogoPrueba,
        guardadoEn: DateTime.utc(2026, 10, 7, 9, i),
      ),
    );
    await Future.wait([for (final v in versiones) repo.guardarCatalogo(v)]);
    expect((await repo.leerCatalogo())?.version, 'v9');
  });

  test('InMemoryComanderoCacheRepository cuenta los guardados', () async {
    final repo = InMemoryComanderoCacheRepository();
    expect(await repo.leerCatalogo(), isNull);
    await repo.guardarCatalogo(cacheado);
    expect(repo.guardados, 1);
    expect(await repo.leerCatalogo(), cacheado);
    await repo.borrarCatalogo();
    expect(await repo.leerCatalogo(), isNull);
  });
}
