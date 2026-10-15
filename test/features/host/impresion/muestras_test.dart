/// Documentos de muestra de la página «Tickets y comandas» (§5.18 del
/// diseño): caben en los tres papeles, llevan la banda MUESTRA, siguen el
/// borrador de los ajustes y la factura usa siempre el entorno de pruebas,
/// con la regla de 40 mm.
library;

import 'dart:typed_data';

import 'package:proyecto_comandero/core/errors/app_exception.dart';
import 'package:proyecto_comandero/core/fiscal/verifactu_qr.dart';
import 'package:proyecto_comandero/core/isolates/escpos/escpos.dart';
import 'package:proyecto_comandero/core/isolates/escpos/qr_raster.dart';
import 'package:proyecto_comandero/core/isolates/isolate_runner.dart';
import 'package:proyecto_comandero/features/host/application/impresion/muestras.dart';
import 'package:proyecto_comandero/features/host/domain/host_settings.dart';
import 'package:proyecto_comandero/features/impresion/domain/formato_impresion.dart';
import 'package:proyecto_comandero/features/sala/domain/pases.dart';
import 'package:test/test.dart';

import '../../../core/isolates/escpos/escpos_decoder.dart';

final ahora = DateTime(2026, 10, 9, 21, 40);

const cabecera = EmpresaTicket(
  nombre: 'MANOLO GARCÍA HOSTELERÍA, S.L.',
  nombreComercial: 'BAR MANOLO',
  cifnif: 'B12345678',
  direccion: 'C/ Mayor, 12, bajo',
  codpostal: '28001',
  ciudad: 'Madrid',
  provincia: 'Madrid',
  telefono: '910 000 000',
  pie: 'Gracias por su visita',
);

ImpresionSettings ajustesCon({
  ModoQrVerifactu modo = ModoQrVerifactu.verifactu,
  EntornoVerifactu entorno = EntornoVerifactu.produccion,
  FormatoTicket ticket = const FormatoTicket(),
  PasesConfig pases = const PasesConfig(),
}) => ImpresionSettings(
  formato: FormatoImpresion(
    ticket: ticket,
    verifactu: QrVerifactuConfig(modo: modo, entorno: entorno),
    pases: pases,
  ),
);

Future<Uint8List> muestra(
  DocumentoMuestra tipo, {
  ImpresionSettings? ajustes,
  EmpresaTicket empresa = cabecera,
  PaperWidth papel = PaperWidth.mm80,
  int avanceInicial = 0,
  IsolateRunner runner = const InlineIsolateRunner(),
}) => generarMuestra(
  tipo,
  ajustes: ajustes ?? ajustesCon(),
  cabecera: empresa,
  papel: papel,
  ahora: ahora,
  runner: runner,
  avanceInicial: avanceInicial,
);

/// Texto de la muestra con las líneas unidas por espacios (las frases
/// partidas por palabras se leen enteras).
Future<String> textoDe(
  DocumentoMuestra tipo, {
  ImpresionSettings? ajustes,
  EmpresaTicket empresa = cabecera,
}) async =>
    decodeEscPos(await muestra(tipo, ajustes: ajustes, empresa: empresa)).texts
        .join(' ');

/// Líneas en blanco con las que empieza el papel (`ESC d n` tras el init).
int? avanceInicialDe(Uint8List bytes) {
  final primero = decodeEscPos(bytes).elements.first;
  return primero is ElementoMarca && primero.comando.name == 'feed'
      ? primero.comando.args.single
      : null;
}

void main() {
  group('todas las muestras', () {
    for (final papel in PaperWidth.values) {
      test(
        'caben en ${papel.etiqueta} (${papel.columns} columnas), empiezan '
        'por la banda MUESTRA · SIN VALIDEZ y nunca abren el cajón',
        () async {
          for (final tipo in DocumentoMuestra.values) {
            final decoded = decodeEscPos(await muestra(tipo, papel: papel));
            expectWidthsWithin(decoded, papel);
            final primera = decoded.lines.first;
            expect(
              primera.text.trim(),
              'MUESTRA · SIN VALIDEZ',
              reason: '$tipo',
            );
            expect(primera.inverse, isTrue, reason: '$tipo');
            expect(primera.printedWidth, papel.columns, reason: '$tipo');
            expect(decoded.named('drawer'), isEmpty, reason: '$tipo');
            expect(decoded.named('beep'), isEmpty, reason: '$tipo');
            expect(decoded.named('cut'), hasLength(1), reason: '$tipo');
          }
        },
      );
    }

    test('el avance inicial solo va en las de preparación', () async {
      for (final tipo in DocumentoMuestra.values) {
        final bytes = await muestra(tipo, avanceInicial: 3);
        expect(
          avanceInicialDe(bytes),
          tipo.preparacion ? 3 : isNull,
          reason: '$tipo',
        );
      }
    });

    test('son deterministas y salen igual en un isolate real', () async {
      for (final tipo in DocumentoMuestra.values) {
        expect(await muestra(tipo), await muestra(tipo), reason: '$tipo');
      }
      expect(
        await muestra(
          DocumentoMuestra.factura,
          runner: const SpawningIsolateRunner(),
        ),
        await muestra(DocumentoMuestra.factura),
      );
    });

    test('etiqueta, impresora por defecto y documentos de preparación', () {
      expect(DocumentoMuestra.values.map((d) => d.name), [
        'provisional',
        'factura',
        'duplicado',
        'precuenta',
        'comandaCocina',
        'comandaBarra',
        'marchar',
        'anulacion',
        'reimpresion',
      ]);
      expect(DocumentoMuestra.values.where((d) => d.preparacion), [
        DocumentoMuestra.comandaCocina,
        DocumentoMuestra.comandaBarra,
        DocumentoMuestra.marchar,
        DocumentoMuestra.anulacion,
        DocumentoMuestra.reimpresion,
      ]);
      expect(DocumentoMuestra.provisional.rol, RolImpresora.tickets);
      expect(DocumentoMuestra.comandaBarra.rol, RolImpresora.barra);
      expect(DocumentoMuestra.marchar.rol, RolImpresora.cocina);
      for (final d in DocumentoMuestra.values) {
        expect(d.etiqueta.trim(), isNotEmpty);
      }
      expect(DocumentoMuestra.factura.etiqueta, 'Factura simplificada');
    });
  });

  group('factura de muestra', () {
    const urlPruebas =
        'https://prewww2.aeat.es/wlpl/TIKE-CONT/ValidarQR'
        '?nif=B12345678&numserie=MUESTRA-1&fecha=09-10-2026&importe=67.00';

    test(
      'usa el entorno de pruebas aunque el ajuste diga producción, con la '
      'serie MUESTRA-1, y lleva la regla de 40 mm (33,8 mm a 203 ppp)',
      () async {
        final qr = qrMuestra(
          const QrVerifactuConfig(
            modo: ModoQrVerifactu.verifactu,
            entorno: EntornoVerifactu.produccion,
          ),
          cabecera: cabecera,
          ahora: ahora,
        )!;
        expect(qr.url, urlPruebas);
        expect(qr.leyenda, 'VERI*FACTU');

        final decoded = decodeEscPos(await muestra(DocumentoMuestra.factura));
        final rasters = decoded.rasters.toList();
        expect(rasters, hasLength(2));
        expect(
          rasters.first.bits,
          rasterizarQr(
            urlPruebas,
            dpi: 203,
            anchoMaximoPuntos: 576,
          ).imagen.bits,
        );
        final texto = decoded.texts.join(' ');
        expect(decoded.texts, contains('VERI*FACTU'));
        expect(
          texto,
          contains(
            'Regla de 40 mm. Este QR debe medir 33,8 mm: compruébelo con una '
            'regla',
          ),
        );
        expect(decoded.texts, contains('Nº MUESTRA-1'));
        expect(decoded.texts, contains('FACTURA SIMPLIFICADA'));
        expect(texto, isNot(contains('Sin NIF válido')));
        expect(texto, isNot(contains('DUPLICADO')));

        // A 180 ppp, la misma URL mide 38,1 mm.
        final a180 = decodeEscPos(
          await muestra(DocumentoMuestra.factura, papel: PaperWidth.mm80Dpi180),
        );
        expect(a180.texts.join(' '), contains('Este QR debe medir 38,1 mm'));
      },
    );

    test('NO VERI*FACTU: la URL de pruebas sin verificación y sin leyenda', () {
      final qr = qrMuestra(
        const QrVerifactuConfig(modo: ModoQrVerifactu.noVerifactu),
        cabecera: cabecera,
        ahora: ahora,
      )!;
      expect(qr.url, startsWith('$urlBaseNoVerifactuPruebas?'));
      expect(qr.leyenda, isNull);
      expect(
        qrMuestra(const QrVerifactuConfig(), cabecera: cabecera, ahora: ahora),
        isNull,
      );
    });

    test('el duplicado lleva el mismo QR, la banda DUPLICADO y ninguna '
        'regla', () async {
      final decoded = decodeEscPos(await muestra(DocumentoMuestra.duplicado));
      expect(decoded.rasters, hasLength(1));
      expect(
        decoded.rasters.single.bits,
        rasterizarQr(urlPruebas, dpi: 203, anchoMaximoPuntos: 576).imagen.bits,
      );
      final texto = decoded.texts.join('|');
      expect(texto, contains('DUPLICADO'));
      expect(texto, contains('Duplicado nº 1'));
      expect(texto, isNot(contains('Regla de 40 mm')));
    });

    test('sin NIF válido sale sin QR y con la línea de aviso', () async {
      for (final nif in ['B1234567', '', '   ']) {
        final empresa = EmpresaTicket(nombre: 'Bar Manolo', cifnif: nif);
        for (final tipo in [
          DocumentoMuestra.factura,
          DocumentoMuestra.duplicado,
        ]) {
          final decoded = decodeEscPos(await muestra(tipo, empresa: empresa));
          expect(decoded.rasters, isEmpty, reason: '«$nif» $tipo');
          expect(
            decoded.texts.join(' '),
            contains('Sin NIF válido: la factura real no se podrá imprimir'),
            reason: '«$nif» $tipo',
          );
        }
      }
      expect(
        () => qrMuestra(
          const QrVerifactuConfig(modo: ModoQrVerifactu.verifactu),
          cabecera: const EmpresaTicket(nombre: 'Bar', cifnif: 'B1234567'),
          ahora: ahora,
        ),
        throwsA(isA<ValidationException>()),
      );
    });

    test(
      'con el QR desactivado: sin QR; el aviso solo si falta el NIF',
      () async {
        final desactivado = ajustesCon(modo: ModoQrVerifactu.desactivado);
        final conNif = decodeEscPos(
          await muestra(DocumentoMuestra.factura, ajustes: desactivado),
        );
        expect(conNif.rasters, isEmpty);
        expect(conNif.texts.join(' '), isNot(contains('Sin NIF válido')));
        expect(
          await textoDe(
            DocumentoMuestra.factura,
            ajustes: desactivado,
            empresa: const EmpresaTicket(nombre: 'Bar Manolo'),
          ),
          contains('Sin NIF válido: la factura real no se podrá imprimir'),
        );
      },
    );
  });

  group('contenido de cada muestra', () {
    test('provisional: título, nº local, referencia corta, líneas '
        'consolidadas y el cobro', () async {
      final texto = await textoDe(DocumentoMuestra.provisional);
      expect(texto, contains('DOCUMENTO PROVISIONAL'));
      expect(texto, contains('NO VÁLIDO COMO FACTURA'));
      expect(texto, contains('Ticket nº 15'));
      expect(texto, contains('Ref. TPV-1a2b3c4d'));
      expect(texto, contains('Mesa 7 · Terraza'));
      expect(texto, contains('Camarero: Ana'));
      expect(texto, contains('4 x Caña'));
      expect(texto, contains('8,00 A'));
      expect(texto, contains('12,00 B'));
      expect(texto, contains('IVA incluido'));
      expect(texto, contains('Gracias por su visita'));
      expect(texto, isNot(contains('1 poco hecho')));
    });

    test('siguen el borrador: camarero, comensales y notas', () async {
      final apagados = ajustesCon(
        ticket: const FormatoTicket(
          mostrarCamarero: false,
          mostrarComensales: false,
          mostrarNotas: true,
          ivaIncluido: false,
        ),
      );
      final provisional = await textoDe(
        DocumentoMuestra.provisional,
        ajustes: apagados,
      );
      expect(provisional, isNot(contains('Camarero')));
      expect(provisional, contains('1 poco hecho, 1 al punto'));
      expect(provisional, isNot(contains('IVA incluido')));
      final precuenta = await textoDe(
        DocumentoMuestra.precuenta,
        ajustes: apagados,
      );
      expect(precuenta, isNot(contains('comensales')));
      expect(precuenta, isNot(contains('Por comensal')));
      expect(precuenta, isNot(contains('Camarero')));
    });

    test('precuenta: nº 2, comensales y el importe por comensal', () async {
      final texto = await textoDe(DocumentoMuestra.precuenta);
      expect(texto, contains('PRECUENTA Nº 2'));
      expect(texto, contains('4 comensales'));
      expect(texto, contains('Por comensal (4)'));
      expect(texto, contains('DOCUMENTO SIN VALIDEZ FISCAL'));
    });

    test('comandas: cocina por pases con ESPERAR, el 2º envío y barra '
        'plana', () async {
      final cocina = await textoDe(DocumentoMuestra.comandaCocina);
      expect(cocina, contains('COCINA'));
      expect(cocina, contains('COMANDA Nº 12 · 21:02'));
      expect(cocina, contains('2º envío de la mesa · abierta 20:50'));
      expect(cocina, contains('1. PRIMEROS'));
      expect(cocina, contains('2. SEGUNDOS · ESPERAR'));
      expect(cocina, contains('2 x Entrecot a la brasa'));
      expect(cocina, isNot(contains('Caña')));

      final barra = await textoDe(DocumentoMuestra.comandaBarra);
      expect(barra, contains('BARRA'));
      expect(barra, contains('COMANDA Nº 12 · 21:02'));
      // Las líneas de la maqueta (f), en su orden, con la nota del tinto.
      expect(
        barra,
        stringContainsInOrder([
          '4 x Caña',
          '1 x Agua con gas',
          '1 x Tinto de verano',
          'con limón',
        ]),
      );
      expect(barra, isNot(contains('ESPERAR')));
      expect(barra, isNot(contains('Entrecot')));
      expect(barra, isNot(contains('Aceitunas')));

      final sinPases = await textoDe(
        DocumentoMuestra.comandaCocina,
        ajustes: ajustesCon(pases: const PasesConfig(activos: false)),
      );
      expect(sinPases, isNot(contains('ESPERAR')));
      expect(sinPases, isNot(contains('PRIMEROS')));

      final nombres = await textoDe(
        DocumentoMuestra.comandaCocina,
        ajustes: ajustesCon(
          pases: const PasesConfig(nombres: ['Entrantes', 'Principales']),
        ),
      );
      expect(nombres, contains('2. PRINCIPALES · ESPERAR'));
    });

    test('MARCHAR, anulación y reimpresión', () async {
      final marchar = await textoDe(DocumentoMuestra.marchar);
      expect(marchar, contains('MARCHAR SEGUNDOS'));
      expect(marchar, contains('Comanda nº 12 (21:02)'));
      expect(marchar, contains('Marcha 21:40'));
      expect(marchar, contains('1 x Lubina a la sal'));

      final anulacion = await textoDe(DocumentoMuestra.anulacion);
      expect(anulacion, contains('ANULACIÓN COCINA'));
      expect(anulacion, contains('-1 x Lubina a la sal'));
      expect(anulacion, contains('Motivo: el cliente cambia de plato'));
      expect(anulacion, contains('Anulada 21:40'));

      final reimpresion = await textoDe(DocumentoMuestra.reimpresion);
      expect(reimpresion, contains('REIMPRESIÓN · PREPARAR'));
      expect(reimpresion, contains('Reimpresa 09/10/2026 21:40 · Caja 1'));
      expect(reimpresion, contains('ENVÍOS Nº 9, 12'));
      expect(reimpresion, contains('1 x Aceitunas'));
    });
  });
}
