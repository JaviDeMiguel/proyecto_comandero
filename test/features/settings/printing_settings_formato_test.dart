import 'dart:convert';
import 'dart:io';

import 'package:proyecto_comandero/core/errors/app_exception.dart';
import 'package:proyecto_comandero/core/fiscal/verifactu_qr.dart';
import 'package:proyecto_comandero/core/isolates/escpos/escpos_builder.dart';
import 'package:proyecto_comandero/features/impresion/domain/formato_impresion.dart';
import 'package:proyecto_comandero/features/sala/domain/pases.dart';
import 'package:proyecto_comandero/features/settings/domain/app_settings.dart';
import 'package:test/test.dart';

/// Lee una fixture de compatibilidad y devuelve su texto normalizado (los
/// finales de línea dependen de `core.autocrlf` al clonar).
String fixture(String nombre) =>
    File('test/fixtures/compat/$nombre')
        .readAsStringSync()
        .replaceAll('\r\n', '\n')
        .trimRight();

const JsonEncoder encoder = JsonEncoder.withIndent('  ');

/// Pasa por texto JSON real, como en los ajustes guardados.
Map<String, Object?> ida(Map<String, Object?> json) =>
    jsonDecode(jsonEncode(json)) as Map<String, Object?>;

final PrinterEndpoint tickets = PrinterEndpoint('10.0.0.1');
final PrinterEndpoint cocina = PrinterEndpoint('10.0.0.2');

const FormatoImpresion formatoCompleto = FormatoImpresion(
  perfiles: {
    RolImpresora.cocina: PerfilImpresora(
      papel: PaperWidth.mm80,
      lineasIniciales: 3,
      copias: 2,
      zumbador: ZumbadorModo.generico,
      pitidos: 4,
      direccion: '10.0.0.2:9100',
    ),
  },
  ticket: FormatoTicket(nombreComercial: 'BAR MANOLO', ivaIncluido: false),
  emision: EmisionTicket(modo: ModoEmision.facturaAlCobrar, esperaSegundos: 15),
  verifactu: QrVerifactuConfig(
    modo: ModoQrVerifactu.noVerifactu,
    entorno: EntornoVerifactu.pruebas,
  ),
  pases: PasesConfig(nombres: ['Entrantes', 'Principales']),
);

/// El JSON que escribe el código anterior a `formato` para unos ajustes con
/// una impresora de tickets y papel de 58 mm.
Map<String, Object?> jsonDeHoy() => {
  'tickets': {'host': '10.0.0.1', 'port': 9100},
  'paper': 'mm58',
  'abrirCajon': true,
  'imprimirTicketAlCobrar': true,
  'imprimirComandaCocina': true,
  'enrutamiento': {'porDefecto': 'cocina', 'porFamilia': <String, Object?>{}},
};

void main() {
  group('PrintingSettings.formato', () {
    test('por defecto el formato está vacío y el JSON es idéntico al de '
        'hoy', () {
      expect(const PrintingSettings().formato, const FormatoImpresion());
      final ajustes = PrintingSettings(
        tickets: tickets,
        paper: PaperWidth.mm58,
      );
      expect(ajustes.formato.esPorDefecto, isTrue);
      expect(ida(ajustes.toJson()), jsonDeHoy());
      expect(ajustes.toJson().containsKey('formato'), isFalse);
    });

    test('ajustes guardados sin formato (versión anterior) cargan con el '
        'defecto y paper intacto', () {
      final leido = PrintingSettings.fromJson(jsonDeHoy());
      expect(leido.formato, const FormatoImpresion());
      expect(leido.paper, PaperWidth.mm58);
      expect(leido.tickets, tickets);
      expect(leido, PrintingSettings(tickets: tickets, paper: PaperWidth.mm58));
    });

    test('formato se escribe solo si no es por defecto, e ida y vuelta', () {
      final ajustes = PrintingSettings(
        tickets: tickets,
        cocina: cocina,
        paper: PaperWidth.mm58,
        formato: formatoCompleto,
      );
      final json = ida(ajustes.toJson());
      expect(json['formato'], ida(formatoCompleto.toJson()));
      expect(json['paper'], 'mm58');
      final leido = PrintingSettings.fromJson(json);
      expect(leido, ajustes);
      expect(leido.formato, formatoCompleto);
      expect(leido.formato.pases.nombres, ['Entrantes', 'Principales']);
    });

    test('un formato que no es un mapa da el formato por defecto sin '
        'lanzar', () {
      for (final raro in <Object?>['x', 1, true, <Object?>[], null]) {
        final leido = PrintingSettings.fromJson({
          ...jsonDeHoy(),
          'formato': raro,
        });
        expect(leido.formato, const FormatoImpresion(), reason: '$raro');
        expect(leido.paper, PaperWidth.mm58);
      }
    });

    test('un formato con valores raros se acota en vez de lanzar; paper '
        'sigue siendo estricto', () {
      final leido = PrintingSettings.fromJson({
        'paper': 'mm58',
        'formato': {
          'perfiles': {
            'cocina': {'papel': 'mm999', 'copias': 99, 'pitidos': 0},
          },
          'emision': {'esperaSegundos': 1},
          'pases': {'nombres': <Object?>[]},
        },
      });
      // Un papel que esta versión no conoce no rompe: queda el por defecto.
      expect(
        leido.formato.perfiles[RolImpresora.cocina],
        const PerfilImpresora(copias: 3, pitidos: 1),
      );
      expect(leido.formato.emision.esperaSegundos, 3);
      expect(leido.formato.pases, const PasesConfig());
      expect(
        () => PrintingSettings.fromJson({'paper': 'mm999'}),
        throwsFormatException,
      );
    });

    test('paper es el papel heredado: el de las impresoras sin perfil', () {
      const perfilCocina = PerfilImpresora(
        papel: PaperWidth.mm80,
        direccion: '10.0.0.2:9100',
      );
      final ajustes = PrintingSettings(
        tickets: tickets,
        cocina: cocina,
        paper: PaperWidth.mm58,
        formato: const FormatoImpresion(
          perfiles: {RolImpresora.cocina: perfilCocina},
        ),
      );
      final leido = PrintingSettings.fromJson(ida(ajustes.toJson()));
      expect(leido.paper, PaperWidth.mm58);
      PerfilImpresora perfilDe(PrinterEndpoint endpoint) => resolverPerfil(
        endpoint,
        direcciones: {
          RolImpresora.tickets: leido.tickets,
          RolImpresora.cocina: leido.cocina,
          RolImpresora.barra: leido.barra,
        },
        formato: leido.formato,
        papelHeredado: leido.paper,
      );
      expect(perfilDe(tickets), const PerfilImpresora(papel: PaperWidth.mm58));
      expect(perfilDe(cocina), perfilCocina);
    });

    test('copyWith(formato:) cambia solo el formato y lo conserva al cambiar '
        'otras cosas', () {
      final base = PrintingSettings(tickets: tickets, paper: PaperWidth.mm58);
      final conFormato = base.copyWith(formato: formatoCompleto);
      expect(conFormato.formato, formatoCompleto);
      expect(conFormato.tickets, tickets);
      expect(conFormato.paper, PaperWidth.mm58);
      expect(conFormato, isNot(base));
      final otros = conFormato.copyWith(cocina: cocina, abrirCajon: false);
      expect(otros.formato, formatoCompleto);
      expect(conFormato.copyWith(), conFormato);
      expect(conFormato.copyWith(formato: const FormatoImpresion()), base);
    });
  });

  group('AppSettings con formato', () {
    AppSettings base() =>
        const AppSettings(deviceId: 'tablet-1', deviceName: 'Tablet');

    test('ida y vuelta por JSON', () {
      final ajustes = base().copyWith(
        impresion: base().impresion.copyWith(formato: formatoCompleto),
      );
      final leido = AppSettings.fromJson(ida(ajustes.toJson()));
      expect(leido.impresion.formato, formatoCompleto);
      expect(leido, ajustes);
    });

    test('un formato ilegible no es un error de configuración', () {
      final json = ida(base().toJson());
      (json['impresion']! as Map<String, Object?>)['formato'] = 'roto';
      expect(
        AppSettings.fromJson(json).impresion.formato,
        const FormatoImpresion(),
      );
      // El resto de la sección sigue siendo estricto.
      (json['impresion']! as Map<String, Object?>)['paper'] = 'mm999';
      expect(() => AppSettings.fromJson(json), throwsA(isA<ConfigException>()));
    });
  });

  group('compatibilidad', () {
    test('app_settings_v1.json se lee y se reescribe byte a byte igual', () {
      final texto = fixture('app_settings_v1.json');
      final json = jsonDecode(texto) as Map<String, Object?>;
      final ajustes = AppSettings.fromJson(json);
      expect(ajustes.rol, DeviceRole.host);
      expect(ajustes.impresion.tickets, PrinterEndpoint('192.168.1.40'));
      expect(ajustes.impresion.paper, PaperWidth.mm58);
      expect(ajustes.mesas, hasLength(3));
      // Unos ajustes de la versión anterior no traen formato: toma su valor
      // por defecto y no se escribe al volver a guardar.
      expect(texto, isNot(contains('formato')));
      expect(ajustes.impresion.formato, const FormatoImpresion());
      // Se guardó sin secretos: se reescribe del mismo modo.
      expect(encoder.convert(ajustes.toJson(incluirSecretos: false)), texto);
    });

    test('los mismos ajustes con formato lo conservan al reescribirse', () {
      final json =
          jsonDecode(fixture('app_settings_v1.json')) as Map<String, Object?>;
      (json['impresion']! as Map<String, Object?>)['formato'] = ida(
        formatoCompleto.toJson(),
      );
      final ajustes = AppSettings.fromJson(json);
      expect(ajustes.impresion.formato, formatoCompleto);
      final reescrito = ida(ajustes.toJson(incluirSecretos: false));
      expect(
        (reescrito['impresion']! as Map<String, Object?>)['formato'],
        ida(formatoCompleto.toJson()),
      );
      expect(AppSettings.fromJson(reescrito), ajustes);
    });
  });
}
