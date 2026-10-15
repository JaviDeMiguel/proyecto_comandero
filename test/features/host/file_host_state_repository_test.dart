import 'dart:convert';
import 'dart:io';

import 'package:proyecto_comandero/core/inventory/inventory_models.dart';
import 'package:proyecto_comandero/features/host/data/file_host_state_repository.dart';
import 'package:proyecto_comandero/features/host/data/in_memory_host_state_repository.dart';
import 'package:proyecto_comandero/features/host/domain/empresa_emisora.dart';
import 'package:proyecto_comandero/features/host/domain/host_snapshot.dart';
import 'package:proyecto_comandero/features/host/domain/sync_job.dart';
import 'package:proyecto_comandero/features/sala/domain/comanda.dart';
import 'package:proyecto_comandero/features/sala/domain/ticket.dart';
import 'package:test/test.dart';

import 'support/host_test_support.dart';

HostSnapshot snapshotCompleto() => HostSnapshot(
  mesas: mesasPrueba,
  comandas: [
    Comanda(
      id: 'c1',
      mesaId: 'm1',
      abiertaEn: DateTime(2026, 10, 7, 13),
      lineas: [linea('l1', 'CANA', 2, nota: 'sin espuma')],
      camarero: 'Ana',
      cuentaSolicitada: true,
    ),
  ],
  ticketsTurno: [
    Ticket(
      id: 't1',
      numeroLocal: 7,
      mesaId: 'm2',
      nombreMesa: 'Mesa 2',
      comandaId: 'c0',
      fechaHora: DateTime(2026, 10, 7, 12),
      lineas: [linea('l0', 'CAFE', 1)],
      totales: TotalesTicket(
        netoCents: 118,
        ivaCents: 12,
        totalCents: 130,
        desglose: const [
          DesgloseIva(
            codimpuesto: 'IVA10',
            ivaBp: 1000,
            baseCents: 118,
            cuotaCents: 12,
          ),
        ],
      ),
      metodoPago: MetodoPago.efectivo,
      entregadoCents: 200,
      factura: FacturaSincronizada(
        estado: EstadoSincronizacion.sincronizado,
        idfactura: 3,
        codigo: 'F2026S3',
        pagada: true,
      ),
    ),
  ],
  numeroLocalSiguiente: 8,
  numeroEnvioSiguiente: 13,
  cierreAbierto: CierreAbierto(
    id: 'z1',
    abiertoEn: DateTime(2026, 10, 7, 9),
    fondoCajaCents: 10000,
    retiradasCents: 2000,
  ),
  historialCierres: [
    ResumenCierre(
      id: 'z0',
      abiertoEn: DateTime(2026, 10, 6, 9),
      cerradoEn: DateTime(2026, 10, 6, 23),
      numTickets: 10,
      numAnulados: 0,
      ventasTotalCents: 50000,
      ventasEfectivoCents: 30000,
      ventasTarjetaCents: 20000,
      fondoCajaCents: 10000,
      retiradasCents: 0,
      efectivoEsperadoCents: 40000,
      efectivoContadoCents: 39900,
      descuadreCents: -100,
      documentoAsiento: 'Z-20261006-z0',
      asientoEncolado: true,
    ),
  ],
  catalogo: catalogoPrueba(),
  catalogoVersion: 'abc',
  recetas: RecetasCache(
    lineas: const [
      RecetaLinea(
        refPlato: 'PAELLA',
        refIngrediente: 'ARROZ',
        cantidadNeta: 0.1,
        mermaPct: 5,
      ),
    ],
    obtenidasEn: DateTime(2026, 10, 7, 12, 30),
  ),
  empresa: EmpresaEmisora(
    idempresa: 1,
    nombre: 'MANOLO GARCÍA HOSTELERÍA, S.L.',
    nombrecorto: 'BAR MANOLO',
    cifnif: 'B12345678',
    direccion: 'C/ Mayor, 12, bajo',
    codpostal: '28001',
    ciudad: 'Madrid',
    provincia: 'Madrid',
    telefono: '910 000 000',
    web: 'barmanolo.es',
    obtenidaEn: DateTime(2026, 10, 7, 8, 0, 12),
  ),
  cola: [
    SyncJob(
      id: 'j1',
      tipo: SyncJobTipo.factura,
      payload: const {'ticket': 't1'},
      creadoEn: DateTime(2026, 10, 7, 12, 1),
      intentos: 2,
      estado: SyncJobEstado.pendiente,
      ultimoError: 'timeout',
      proximoIntentoEn: DateTime(2026, 10, 7, 12, 2),
      avisos: const ['a'],
    ),
  ],
);

void main() {
  group('HostSnapshot', () {
    test('JSON ida y vuelta completa', () {
      final snapshot = snapshotCompleto();
      final json = jsonDecode(jsonEncode(snapshot.toJson()));
      expect(HostSnapshot.fromJson(json as Map<String, Object?>), snapshot);
    });

    test('tolera campos ausentes (fichero de una versión anterior)', () {
      final snapshot = HostSnapshot.fromJson({'numeroLocalSiguiente': 3});
      expect(snapshot.mesas, isEmpty);
      expect(snapshot.cola, isEmpty);
      expect(snapshot.numeroLocalSiguiente, 3);
      expect(snapshot.numeroEnvioSiguiente, 1);
      expect(snapshot.empresa, isNull);
    });

    test('conJob y conTicket sustituyen por id', () {
      final base = snapshotCompleto();
      final job = base.cola.single.copyWith(estado: SyncJobEstado.hecho);
      expect(base.conJob(job).cola.single.estado, SyncJobEstado.hecho);
      final otro = SyncJob(
        id: 'j2',
        tipo: SyncJobTipo.asientoZ,
        payload: const {},
        creadoEn: DateTime(2026),
      );
      expect(base.conJob(otro).cola.map((j) => j.id), ['j1', 'j2']);
      final ticket = base.ticketsTurno.single.conFactura(
        FacturaSincronizada(estado: EstadoSincronizacion.error, error: 'x'),
      );
      expect(base.conTicket(ticket).ticketsTurno.single.factura!.error, 'x');
    });
  });

  group('InMemoryHostStateRepository', () {
    test('guarda y recupera pasando por JSON', () async {
      final repo = InMemoryHostStateRepository();
      expect(await repo.load(), isNull);
      await repo.save(snapshotCompleto());
      expect(await repo.load(), snapshotCompleto());
      expect(repo.saves, 1);
    });
  });

  group('FileHostStateRepository', () {
    late Directory dir;
    late FileHostStateRepository repo;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('tpv_host_state_');
      repo = FileHostStateRepository(dir);
    });

    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    test('sin fichero devuelve null', () async {
      expect(await repo.load(), isNull);
    });

    test('escribe de forma atómica (sin .tmp residual) y relee', () async {
      final snapshot = snapshotCompleto();
      await repo.save(snapshot);
      await repo.save(snapshot.copyWith(numeroLocalSiguiente: 9));
      expect(await File('${repo.file.path}.tmp').exists(), isFalse);
      final leido = await repo.load();
      expect(leido, snapshot.copyWith(numeroLocalSiguiente: 9));
      // Crea el directorio si no existe.
      final anidado = FileHostStateRepository(
        Directory('${dir.path}${Platform.pathSeparator}sub'),
      );
      await anidado.save(snapshot);
      expect(await anidado.load(), snapshot);
    });

    test('ida y vuelta atómica con los campos nuevos (nº de envío y empresa '
        'emisora)', () async {
      final snapshot = snapshotCompleto();
      await repo.save(snapshot);
      expect(await File('${repo.file.path}.tmp').exists(), isFalse);
      final texto = await repo.file.readAsString();
      expect(texto, contains('"numeroEnvioSiguiente":13'));
      expect(texto, contains('"empresa":{"idempresa":1,'));
      final leido = (await repo.load())!;
      expect(leido, snapshot);
      expect(leido.numeroEnvioSiguiente, 13);
      expect(leido.empresa, snapshot.empresa);

      // Con los valores por defecto no se escriben.
      final sinNuevos = HostSnapshot(
        mesas: mesasPrueba,
        numeroLocalSiguiente: 8,
      );
      await repo.save(sinNuevos);
      final textoSin = await repo.file.readAsString();
      expect(textoSin, isNot(contains('numeroEnvioSiguiente')));
      expect(textoSin, isNot(contains('"empresa"')));
      expect(await repo.load(), sinNuevos);
    });

    test('fichero corrupto: se aparta y se devuelve null', () async {
      await repo.file.writeAsString('{"mesas": [1, 2');
      expect(await repo.load(), isNull);
      expect(await repo.file.exists(), isFalse);
      final apartados = dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.contains('.corrupto-'))
          .toList();
      expect(apartados, hasLength(1));
      // Y se puede volver a guardar.
      await repo.save(snapshotCompleto());
      expect(await repo.load(), snapshotCompleto());
    });

    test('JSON válido pero con forma inesperada → null', () async {
      await repo.file.writeAsString('{"mesas": "no es una lista"}');
      expect(await repo.load(), isNull);
      await repo.file.writeAsString('[]');
      expect(await repo.load(), isNull);
    });

    test('recupera un .tmp completo si falta el definitivo', () async {
      final snapshot = snapshotCompleto();
      await File('${repo.file.path}.tmp')
          .writeAsString(jsonEncode(snapshot.toJson()));
      expect(await repo.load(), snapshot);
    });

    test(
      'un directorio ilegible hace fallar save con FileSystemException',
      () async {
        final bloqueado = FileHostStateRepository(
          Directory('${dir.path}${Platform.pathSeparator}fichero'),
        );
        // Se ocupa la ruta del "directorio" con un fichero.
        await File(bloqueado.directory.path).writeAsString('x');
        expect(
          () => bloqueado.save(snapshotCompleto()),
          throwsA(isA<FileSystemException>()),
        );
      },
    );

    test('h9: conserva la versión anterior como .bak y la usa si el '
        'principal y el .tmp no se pueden leer', () async {
      final primero = snapshotCompleto();
      final segundo = primero.copyWith(numeroLocalSiguiente: 9);
      await repo.save(primero);
      await repo.save(segundo);
      final bak = File('${repo.file.path}.bak');
      expect(
        HostSnapshot.fromJson(
          jsonDecode(await bak.readAsString()) as Map<String, Object?>,
        ),
        primero,
      );
      expect(await repo.load(), segundo);

      // Corte de luz: el principal quedó vacío (datos no sincronizados).
      await repo.file.writeAsBytes(const []);
      expect(await repo.load(), primero);
    });

    test('h10: un diario con UTF-8 inválido se aparta (no se pierde) antes '
        'de empezar de cero', () async {
      const bytes = [0x7B, 0xFF, 0xFE, 0x7D];
      await repo.file.writeAsBytes(bytes);
      expect(await repo.load(), isNull);
      final apartados = dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.contains('.corrupto-'))
          .toList();
      expect(apartados, hasLength(1));
      expect(await apartados.single.readAsBytes(), bytes);
      await repo.save(snapshotCompleto());
      expect(await apartados.single.readAsBytes(), bytes);
    });

    test(
      'h10: un diario bloqueado se reintenta y, si sigue ilegible, no se '
      'sobrescribe',
      () async {
        final rapido = FileHostStateRepository(
          dir,
          esperaReintento: const Duration(milliseconds: 60),
        );
        final original = snapshotCompleto();
        await rapido.save(original);
        final bytesOriginales = await rapido.file.readAsBytes();

        // Bloqueo breve (antivirus): los reintentos lo superan.
        var raf = await rapido.file.open(mode: FileMode.append);
        await raf.lock(FileLock.exclusive);
        final cargando = rapido.load();
        await Future<void>.delayed(const Duration(milliseconds: 30));
        await raf.unlock();
        await raf.close();
        expect(await cargando, original);

        // Bloqueo persistente: load lanza y save no pisa el fichero.
        raf = await rapido.file.open(mode: FileMode.append);
        await raf.lock(FileLock.exclusive);
        await expectLater(rapido.load(), throwsA(isA<FileSystemException>()));
        await expectLater(
          rapido.save(original.copyWith(numeroLocalSiguiente: 99)),
          throwsA(isA<FileSystemException>()),
        );
        await raf.unlock();
        await raf.close();
        expect(await rapido.file.readAsBytes(), bytesOriginales);

        // Liberado: el siguiente guardado aparta una copia y escribe.
        await rapido.save(original.copyWith(numeroLocalSiguiente: 99));
        final copias = dir
            .listSync()
            .whereType<File>()
            .where((f) => f.path.contains('.ilegible-'))
            .toList();
        expect(copias, hasLength(1));
        expect(await copias.single.readAsBytes(), bytesOriginales);
        expect((await rapido.load())!.numeroLocalSiguiente, 99);
      },
      skip: Platform.isWindows
          ? false
          : 'los bloqueos de fichero solo son obligatorios en Windows',
    );
  });
}
