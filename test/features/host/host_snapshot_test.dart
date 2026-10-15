import 'dart:convert';
import 'dart:io';

import 'package:proyecto_comandero/core/facturascripts/master_data/fs_master_models.dart';
import 'package:proyecto_comandero/features/host/domain/empresa_emisora.dart';
import 'package:proyecto_comandero/features/host/domain/host_snapshot.dart';
import 'package:proyecto_comandero/features/sala/domain/precuenta_emitida.dart';
import 'package:proyecto_comandero/features/sala/domain/ticket.dart';
import 'package:test/test.dart';

/// Lee una fixture de compatibilidad y devuelve su texto normalizado (los
/// finales de línea dependen de `core.autocrlf` al clonar).
String fixture(String nombre) =>
    File('test/fixtures/compat/$nombre')
        .readAsStringSync()
        .replaceAll('\r\n', '\n')
        .trimRight();

const JsonEncoder encoder = JsonEncoder.withIndent('  ');

/// Serializa y vuelve a leer pasando por texto JSON, como en el diario.
Map<String, Object?> ida(Map<String, Object?> json) =>
    jsonDecode(jsonEncode(json)) as Map<String, Object?>;

final DateTime obtenida = DateTime(2026, 10, 9, 8, 0, 12);

final EmpresaEmisora empresaCompleta = EmpresaEmisora(
  idempresa: 1,
  nombre: 'MANOLO GARCÍA HOSTELERÍA, S.L.',
  nombrecorto: 'BAR MANOLO',
  cifnif: 'B12345678',
  direccion: 'C/ Mayor, 12, bajo',
  codpostal: '28001',
  ciudad: 'Madrid',
  provincia: 'Madrid',
  telefono: '910 000 000',
  email: 'info@barmanolo.es',
  web: 'barmanolo.es',
  obtenidaEn: obtenida,
);

final DateTime emitida = DateTime(2026, 10, 9, 14, 10);
final DateTime vaciada = DateTime(2026, 10, 9, 15, 2);

/// Precuenta nº [numero] de la mesa 7 (4 cañas, 8,00 €).
PrecuentaEmitida precuenta(int numero) => PrecuentaEmitida(
  numero: numero,
  emitidaEn: emitida,
  comandaId: 'c-7f3a',
  nombreMesa: 'Mesa 7',
  lineas: const [
    LineaPrecuenta(
      descripcion: 'Caña',
      cantidad: 4,
      pvpUnitarioCents: 200,
      importeCents: 800,
      ivaBp: 1000,
      codimpuesto: 'IVA10',
      referencia: 'CANA',
    ),
  ],
  totales: TotalesTicket(
    netoCents: 727,
    ivaCents: 73,
    totalCents: 800,
    desglose: const [
      DesgloseIva(
        codimpuesto: 'IVA10',
        ivaBp: 1000,
        baseCents: 727,
        cuotaCents: 73,
      ),
    ],
  ),
  comensales: 4,
  emitidaPor: 'Caja 1',
);

final PrecuentaSinCobro sinCobroConMotivo = PrecuentaSinCobro(
  precuenta: precuenta(1),
  vaciadaEn: vaciada,
  motivo: 'se fueron sin pagar',
);

final PrecuentaSinCobro sinCobroSinMotivo = PrecuentaSinCobro(
  precuenta: precuenta(2),
  vaciadaEn: vaciada,
);

/// Resumen de un Cierre Z como los de la fixture, con [precuentasSinCobro].
ResumenCierre resumen({
  List<PrecuentaSinCobro> precuentasSinCobro = const [],
}) => ResumenCierre(
  id: 'z-20261009',
  abiertoEn: DateTime(2026, 10, 9, 9),
  cerradoEn: DateTime(2026, 10, 9, 23, 30),
  numTickets: 42,
  numAnulados: 1,
  ventasTotalCents: 123450,
  ventasEfectivoCents: 60000,
  ventasTarjetaCents: 63450,
  numTicketsMixtos: 2,
  fondoCajaCents: 10000,
  retiradasCents: 20000,
  efectivoEsperadoCents: 50000,
  efectivoContadoCents: 49950,
  descuadreCents: -50,
  documentoAsiento: 'Z-20261009-z-20261009',
  asientoEncolado: true,
  precuentasSinCobro: precuentasSinCobro,
);

void main() {
  group('HostSnapshot.numeroEnvioSiguiente', () {
    test('vale 1 por defecto y no se escribe si es 1', () {
      final snapshot = HostSnapshot();
      expect(snapshot.numeroEnvioSiguiente, 1);
      expect(snapshot.toJson().containsKey('numeroEnvioSiguiente'), isFalse);
      expect(
        HostSnapshot.fromJson(ida(snapshot.toJson())).numeroEnvioSiguiente,
        1,
      );
      expect(HostSnapshot.fromJson(const {}).numeroEnvioSiguiente, 1);
    });

    test('se escribe y se lee si no es 1', () {
      final snapshot = HostSnapshot(numeroEnvioSiguiente: 13);
      final json = ida(snapshot.toJson());
      expect(json['numeroEnvioSiguiente'], 13);
      final leido = HostSnapshot.fromJson(json);
      expect(leido, snapshot);
      expect(leido.numeroEnvioSiguiente, 13);
    });

    test('"x", 0 o -3 (y otros valores raros) leen 1 sin invalidar el '
        'diario', () {
      for (final raro in <Object?>[
        'x',
        0,
        -3,
        2.5,
        true,
        null,
        <Object?>[],
        <String, Object?>{},
      ]) {
        final leido = HostSnapshot.fromJson({
          'numeroLocalSiguiente': 4,
          'numeroEnvioSiguiente': raro,
        });
        expect(leido.numeroEnvioSiguiente, 1, reason: '$raro');
        expect(leido.numeroLocalSiguiente, 4);
      }
      // numeroLocalSiguiente sigue siendo estricto, como hasta ahora.
      expect(
        () => HostSnapshot.fromJson({'numeroLocalSiguiente': 'x'}),
        throwsFormatException,
      );
    });

    test('copyWith y props', () {
      final base = HostSnapshot(numeroLocalSiguiente: 8);
      final con = base.copyWith(numeroEnvioSiguiente: 5);
      expect(con.numeroEnvioSiguiente, 5);
      expect(con.numeroLocalSiguiente, 8);
      expect(con.copyWith(numeroLocalSiguiente: 9).numeroEnvioSiguiente, 5);
      expect(con, isNot(base));
      expect(con.copyWith(numeroEnvioSiguiente: 1), base);
    });
  });

  group('EmpresaEmisora', () {
    test('ida y vuelta completa: toJson escribe todos los campos no nulos', () {
      final json = ida(empresaCompleta.toJson());
      expect(json, {
        'idempresa': 1,
        'nombre': 'MANOLO GARCÍA HOSTELERÍA, S.L.',
        'nombrecorto': 'BAR MANOLO',
        'cifnif': 'B12345678',
        'direccion': 'C/ Mayor, 12, bajo',
        'codpostal': '28001',
        'ciudad': 'Madrid',
        'provincia': 'Madrid',
        'telefono': '910 000 000',
        'email': 'info@barmanolo.es',
        'web': 'barmanolo.es',
        'obtenidaEn': '2026-10-09T08:00:12.000',
      });
      expect(EmpresaEmisora.tolerante(json), empresaCompleta);
    });

    test('mínima: solo nombre y obtenidaEn', () {
      final minima = EmpresaEmisora(nombre: 'Bar Pepe', obtenidaEn: obtenida);
      final json = ida(minima.toJson());
      expect(json, {
        'nombre': 'Bar Pepe',
        'obtenidaEn': '2026-10-09T08:00:12.000',
      });
      expect(EmpresaEmisora.tolerante(json), minima);
      expect(minima, isNot(empresaCompleta));
    });

    test('tieneNif', () {
      expect(empresaCompleta.tieneNif, isTrue);
      expect(
        EmpresaEmisora(nombre: 'X', obtenidaEn: obtenida).tieneNif,
        isFalse,
      );
      expect(
        EmpresaEmisora(nombre: 'X', cifnif: '', obtenidaEn: obtenida).tieneNif,
        isFalse,
      );
      expect(
        EmpresaEmisora(
          nombre: 'X',
          cifnif: '   ',
          obtenidaEn: obtenida,
        ).tieneNif,
        isFalse,
      );
    });

    test('tolerante: null si no es un objeto o falta nombre u obtenidaEn', () {
      for (final raw in <Object?>[
        null,
        'x',
        3,
        <Object?>[],
        <String, Object?>{},
        {'nombre': 'X'},
        {'obtenidaEn': '2026-10-09T08:00:12.000'},
        {'nombre': 5, 'obtenidaEn': '2026-10-09T08:00:12.000'},
        {'nombre': 'X', 'obtenidaEn': 'ayer'},
        {'nombre': 'X', 'obtenidaEn': 20261009},
        <Object?, Object?>{1: 2},
      ]) {
        expect(EmpresaEmisora.tolerante(raw), isNull, reason: '$raw');
      }
    });

    test('tolerante: un campo opcional con tipo raro se trata como ausente y '
        'las claves desconocidas se ignoran', () {
      final leida = EmpresaEmisora.tolerante({
        'idempresa': '1',
        'nombre': 'Bar Pepe',
        'nombrecorto': 3,
        'cifnif': ['B1'],
        'direccion': null,
        'codpostal': 28001,
        'ciudad': 'Madrid',
        'provincia': false,
        'telefono': 910000000,
        'email': <String, Object?>{},
        'web': 'pepe.es',
        'obtenidaEn': '2026-10-09T08:00:12.000',
        'desconocido': 'se ignora',
      });
      expect(
        leida,
        EmpresaEmisora(
          nombre: 'Bar Pepe',
          ciudad: 'Madrid',
          web: 'pepe.es',
          obtenidaEn: obtenida,
        ),
      );
      expect(leida!.tieneNif, isFalse);
    });

    test('desdeFs copia todos los campos y la fecha de lectura', () {
      const fs = FsEmpresa(
        idempresa: 2,
        nombre: 'MANOLO GARCÍA HOSTELERÍA, S.L.',
        nombrecorto: 'BAR MANOLO',
        cifnif: 'B12345678',
        direccion: 'C/ Mayor, 12, bajo',
        codpostal: '28001',
        ciudad: 'Madrid',
        provincia: 'Madrid',
        telefono1: '910 000 000',
        email: 'info@barmanolo.es',
        web: 'barmanolo.es',
      );
      final empresa = EmpresaEmisora.desdeFs(fs, obtenida);
      expect(
        empresa,
        EmpresaEmisora(
          idempresa: 2,
          nombre: 'MANOLO GARCÍA HOSTELERÍA, S.L.',
          nombrecorto: 'BAR MANOLO',
          cifnif: 'B12345678',
          direccion: 'C/ Mayor, 12, bajo',
          codpostal: '28001',
          ciudad: 'Madrid',
          provincia: 'Madrid',
          telefono: '910 000 000',
          email: 'info@barmanolo.es',
          web: 'barmanolo.es',
          obtenidaEn: obtenida,
        ),
      );
      expect(empresa.telefono, fs.telefono1);
      expect(empresa.tieneNif, isTrue);
      // Sin opcionales en el ERP.
      const escueta = FsEmpresa(idempresa: 1, nombre: 'Bar Pepe');
      final leida = EmpresaEmisora.desdeFs(escueta, obtenida);
      expect(
        leida,
        EmpresaEmisora(idempresa: 1, nombre: 'Bar Pepe', obtenidaEn: obtenida),
      );
      expect(leida.tieneNif, isFalse);
      expect(EmpresaEmisora.tolerante(ida(leida.toJson())), leida);
    });
  });

  group('HostSnapshot.empresa', () {
    test('se escribe solo si no es nula, e ida y vuelta', () {
      expect(HostSnapshot().toJson().containsKey('empresa'), isFalse);
      expect(HostSnapshot.fromJson(const {}).empresa, isNull);
      final snapshot = HostSnapshot(
        empresa: empresaCompleta,
        numeroEnvioSiguiente: 3,
      );
      final json = ida(snapshot.toJson());
      expect(json['empresa'], empresaCompleta.toJson());
      final leido = HostSnapshot.fromJson(json);
      expect(leido, snapshot);
      expect(leido.empresa, empresaCompleta);
      expect(leido.numeroEnvioSiguiente, 3);
    });

    test('una empresa rara se lee como nula sin invalidar el diario', () {
      for (final raro in <Object?>[
        'x',
        1,
        <Object?>[],
        <String, Object?>{},
        {'nombre': 'Sin fecha'},
      ]) {
        final leido = HostSnapshot.fromJson({
          'numeroLocalSiguiente': 4,
          'empresa': raro,
        });
        expect(leido.empresa, isNull, reason: '$raro');
        expect(leido.numeroLocalSiguiente, 4);
      }
    });

    test('copyWith y props', () {
      final base = HostSnapshot(numeroLocalSiguiente: 8);
      final con = base.copyWith(empresa: empresaCompleta);
      expect(con.empresa, empresaCompleta);
      expect(con.numeroLocalSiguiente, 8);
      expect(con.copyWith(numeroLocalSiguiente: 9).empresa, empresaCompleta);
      expect(con, isNot(base));
      final otra = EmpresaEmisora(nombre: 'Otra', obtenidaEn: obtenida);
      expect(con.copyWith(empresa: otra).empresa, otra);
      expect(con.copyWith(empresa: otra), isNot(con));
    });
  });

  group('HostSnapshot.precuentasSinCobro', () {
    test('vacía por defecto y no se escribe si está vacía', () {
      final snapshot = HostSnapshot();
      expect(snapshot.precuentasSinCobro, isEmpty);
      expect(snapshot.toJson().containsKey('precuentasSinCobro'), isFalse);
      expect(HostSnapshot.fromJson(const {}).precuentasSinCobro, isEmpty);
      expect(
        HostSnapshot.fromJson(ida(snapshot.toJson())).precuentasSinCobro,
        isEmpty,
      );
    });

    test('ida y vuelta si no está vacía, en el orden de vaciado', () {
      final snapshot = HostSnapshot(
        numeroEnvioSiguiente: 3,
        precuentasSinCobro: [sinCobroConMotivo, sinCobroSinMotivo],
      );
      final json = ida(snapshot.toJson());
      expect(json['precuentasSinCobro'], [
        sinCobroConMotivo.toJson(),
        sinCobroSinMotivo.toJson(),
      ]);
      final leido = HostSnapshot.fromJson(json);
      expect(leido, snapshot);
      expect(leido.precuentasSinCobro, [sinCobroConMotivo, sinCobroSinMotivo]);
      expect(leido.precuentasSinCobro.first.motivo, 'se fueron sin pagar');
      expect(leido.precuentasSinCobro.first.precuenta.totalCents, 800);
      expect(leido.precuentasSinCobro.last.motivo, isNull);
      expect(leido.numeroEnvioSiguiente, 3);
    });

    test('una lista rara se lee vacía y un elemento ilegible se descarta '
        'sin invalidar el diario', () {
      for (final raro in <Object?>[
        'x',
        1,
        true,
        <String, Object?>{},
        {'precuenta': precuenta(1).toJson()},
      ]) {
        final leido = HostSnapshot.fromJson({
          'numeroLocalSiguiente': 4,
          'precuentasSinCobro': raro,
        });
        expect(leido.precuentasSinCobro, isEmpty, reason: '$raro');
        expect(leido.numeroLocalSiguiente, 4);
      }
      final leido = HostSnapshot.fromJson({
        'numeroLocalSiguiente': 4,
        'precuentasSinCobro': [
          'x', // no es un objeto
          <String, Object?>{}, // sin precuenta ni fecha
          {'precuenta': 'x', 'vaciadaEn': vaciada.toIso8601String()},
          {'precuenta': precuenta(1).toJson(), 'vaciadaEn': 'ayer'},
          {
            'precuenta': {...precuenta(1).toJson(), 'numero': 0},
            'vaciadaEn': vaciada.toIso8601String(),
          },
          sinCobroConMotivo.toJson(),
        ],
      });
      expect(leido.precuentasSinCobro, [sinCobroConMotivo]);
      expect(leido.numeroLocalSiguiente, 4);
    });

    test('copyWith, conPrecuentasSinCobro (añade al final) y props', () {
      final base = HostSnapshot(numeroLocalSiguiente: 8);
      final con = base.copyWith(precuentasSinCobro: [sinCobroConMotivo]);
      expect(con.precuentasSinCobro, [sinCobroConMotivo]);
      expect(con.numeroLocalSiguiente, 8);
      expect(con.copyWith(numeroLocalSiguiente: 9).precuentasSinCobro, [
        sinCobroConMotivo,
      ]);
      expect(con, isNot(base));
      expect(con.copyWith(precuentasSinCobro: const []), base);

      final mas = con.conPrecuentasSinCobro([sinCobroSinMotivo]);
      expect(mas.precuentasSinCobro, [sinCobroConMotivo, sinCobroSinMotivo]);
      expect(con.conPrecuentasSinCobro(const []), con);
      expect(con.precuentasSinCobro, [sinCobroConMotivo], reason: 'inmutable');
      expect(
        () => mas.precuentasSinCobro.add(sinCobroConMotivo),
        throwsUnsupportedError,
      );
    });
  });

  group('ResumenCierre.precuentasSinCobro', () {
    test('vacía por defecto y no se escribe si está vacía: un cierre antiguo '
        'se reescribe igual', () {
      final cierre = resumen();
      expect(cierre.precuentasSinCobro, isEmpty);
      final json = ida(cierre.toJson());
      expect(json.containsKey('precuentasSinCobro'), isFalse);
      final leido = ResumenCierre.fromJson(json);
      expect(leido, cierre);
      expect(leido.precuentasSinCobro, isEmpty);
    });

    test('ida y vuelta si no está vacía, también dentro del historial del '
        'diario', () {
      final cierre = resumen(
        precuentasSinCobro: [sinCobroConMotivo, sinCobroSinMotivo],
      );
      final json = ida(cierre.toJson());
      expect(json['precuentasSinCobro'], [
        sinCobroConMotivo.toJson(),
        sinCobroSinMotivo.toJson(),
      ]);
      final leido = ResumenCierre.fromJson(json);
      expect(leido, cierre);
      expect(leido.precuentasSinCobro, [sinCobroConMotivo, sinCobroSinMotivo]);
      expect(leido.copyWith(precuentasSinCobro: const []), resumen());

      final snapshot = HostSnapshot(historialCierres: [cierre, resumen()]);
      final leidoDiario = HostSnapshot.fromJson(ida(snapshot.toJson()));
      expect(leidoDiario, snapshot);
      expect(leidoDiario.historialCierres.first.precuentasSinCobro, [
        sinCobroConMotivo,
        sinCobroSinMotivo,
      ]);
      expect(leidoDiario.historialCierres.last.precuentasSinCobro, isEmpty);
    });

    test('una lista rara se lee vacía y un elemento ilegible se descarta '
        'sin invalidar el cierre', () {
      final json = resumen().toJson();
      for (final raro in <Object?>['x', 1, <String, Object?>{}]) {
        expect(
          ResumenCierre.fromJson({...json, 'precuentasSinCobro': raro}),
          resumen(),
          reason: '$raro',
        );
      }
      final leido = ResumenCierre.fromJson({
        ...json,
        'precuentasSinCobro': [
          'x',
          <String, Object?>{},
          {'precuenta': precuenta(1).toJson(), 'vaciadaEn': 'ayer'},
          sinCobroSinMotivo.toJson(),
        ],
      });
      expect(leido.precuentasSinCobro, [sinCobroSinMotivo]);
      expect(leido.numTickets, 42);
      expect(leido.copyWith(precuentasSinCobro: const []), resumen());
    });

    test('copyWith conserva el resto de campos y props', () {
      final base = resumen();
      final con = base.copyWith(precuentasSinCobro: [sinCobroConMotivo]);
      expect(con.precuentasSinCobro, [sinCobroConMotivo]);
      expect(con.id, base.id);
      expect(con.cerradoEn, base.cerradoEn);
      expect(con.ventasTotalCents, base.ventasTotalCents);
      expect(con.numTicketsMixtos, base.numTicketsMixtos);
      expect(con.efectivoContadoCents, base.efectivoContadoCents);
      expect(con.documentoAsiento, base.documentoAsiento);
      expect(con.asientoEncolado, base.asientoEncolado);
      expect(con, isNot(base));
      expect(con.copyWith(), con);
      expect(con.copyWith(precuentasSinCobro: const []), base);
      expect(
        () => con.precuentasSinCobro.add(sinCobroSinMotivo),
        throwsUnsupportedError,
      );
    });
  });

  group('compatibilidad', () {
    test('host_snapshot_v1.json se lee y se reescribe byte a byte igual', () {
      final texto = fixture('host_snapshot_v1.json');
      final json = jsonDecode(texto) as Map<String, Object?>;
      final snapshot = HostSnapshot.fromJson(json);
      expect(snapshot.mesas, hasLength(4));
      expect(snapshot.comandas, hasLength(2));
      expect(snapshot.ticketsTurno, hasLength(2));
      expect(snapshot.cierreAbierto, isNotNull);
      expect(snapshot.historialCierres, hasLength(2));
      expect(snapshot.catalogo, isNotNull);
      expect(snapshot.recetas, isNotNull);
      expect(snapshot.cola, hasLength(2));
      // Un diario de la versión anterior no trae los campos nuevos: toman su
      // valor por defecto y no se escriben al volver a guardar.
      expect(texto, isNot(contains('numeroEnvioSiguiente')));
      expect(texto, isNot(contains('"empresa"')));
      expect(snapshot.numeroEnvioSiguiente, 1);
      expect(snapshot.empresa, isNull);
      expect(texto, isNot(contains('precuentasSinCobro')));
      expect(snapshot.precuentasSinCobro, isEmpty);
      expect(
        snapshot.historialCierres.map((c) => c.precuentasSinCobro),
        everyElement(isEmpty),
      );
      expect(encoder.convert(snapshot.toJson()), texto);
    });

    test(
      'el mismo diario con los campos nuevos los conserva al reescribirse',
      () {
        final json = jsonDecode(
          fixture('host_snapshot_v1.json'),
        ) as Map<String, Object?>;
        json['numeroEnvioSiguiente'] = 27;
        json['empresa'] = empresaCompleta.toJson();
        json['precuentasSinCobro'] = [sinCobroConMotivo.toJson()];
        final cierres = json['historialCierres'] as List<Object?>;
        (cierres.first as Map<String, Object?>)['precuentasSinCobro'] = [
          sinCobroSinMotivo.toJson(),
        ];
        final snapshot = HostSnapshot.fromJson(json);
        expect(snapshot.numeroEnvioSiguiente, 27);
        expect(snapshot.empresa, empresaCompleta);
        expect(snapshot.precuentasSinCobro, [sinCobroConMotivo]);
        expect(snapshot.historialCierres.first.precuentasSinCobro, [
          sinCobroSinMotivo,
        ]);
        final reescrito = ida(snapshot.toJson());
        expect(reescrito['numeroEnvioSiguiente'], 27);
        expect(reescrito['empresa'], empresaCompleta.toJson());
        expect(reescrito['precuentasSinCobro'], [sinCobroConMotivo.toJson()]);
        expect(HostSnapshot.fromJson(reescrito), snapshot);
      },
    );
  });
}
