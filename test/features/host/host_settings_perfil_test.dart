import 'package:proyecto_comandero/core/isolates/escpos/escpos_builder.dart';
import 'package:proyecto_comandero/core/network/printing/raw_printer_transport.dart';
import 'package:proyecto_comandero/features/host/domain/host_settings.dart';
import 'package:proyecto_comandero/features/impresion/domain/formato_impresion.dart';
import 'package:proyecto_comandero/features/sala/domain/linea_comanda.dart';
import 'package:proyecto_comandero/features/sala/domain/pases.dart';
import 'package:test/test.dart';

void main() {
  final a = PrinterEndpoint('192.168.1.40');
  final b = PrinterEndpoint('192.168.1.50');
  final c = PrinterEndpoint('192.168.1.51', port: 9101);
  const perfilA = PerfilImpresora(copias: 3, direccion: '192.168.1.40:9100');
  const perfilB = PerfilImpresora(
    papel: PaperWidth.mm80,
    lineasIniciales: 2,
    copias: 2,
    zumbador: ZumbadorModo.generico,
    direccion: '192.168.1.50:9100',
  );
  const cajon = PerfilImpresora(zumbador: ZumbadorModo.puertoCajon, pitidos: 3);

  group('ImpresionSettings.formato', () {
    test('por defecto: formato vacío, pases por defecto y perfil del papel '
        'heredado', () {
      const ajustes = ImpresionSettings();
      expect(ajustes.formato, const FormatoImpresion());
      expect(ajustes.pases, const PasesConfig());
      expect(ajustes.perfilPara(a), const PerfilImpresora());
      expect(
        const ImpresionSettings(paper: PaperWidth.mm58).perfilPara(a),
        const PerfilImpresora(papel: PaperWidth.mm58),
      );
    });

    test('pases viene del formato', () {
      const pases = PasesConfig(activos: false, nombres: ['Único']);
      const ajustes = ImpresionSettings(
        formato: FormatoImpresion(pases: pases),
      );
      expect(ajustes.pases, pases);
    });

    test('props incluyen el formato', () {
      const base = ImpresionSettings();
      const conFormato = ImpresionSettings(
        formato: FormatoImpresion(
          ticket: FormatoTicket(nombreComercial: 'BAR'),
        ),
      );
      expect(conFormato, isNot(base));
      expect(
        conFormato,
        const ImpresionSettings(
          formato: FormatoImpresion(
            ticket: FormatoTicket(nombreComercial: 'BAR'),
          ),
        ),
      );
    });
  });

  group('ImpresionSettings.perfilPara', () {
    test('usa las tres direcciones configuradas y el papel heredado', () {
      final ajustes = ImpresionSettings(
        tickets: a,
        cocina: b,
        barra: c,
        paper: PaperWidth.mm58,
        formato: const FormatoImpresion(
          perfiles: {RolImpresora.cocina: perfilB},
        ),
      );
      expect(ajustes.perfilPara(b), perfilB);
      // Sin perfil propio: el papel heredado.
      expect(
        ajustes.perfilPara(a),
        const PerfilImpresora(papel: PaperWidth.mm58),
      );
      expect(
        ajustes.perfilPara(c),
        const PerfilImpresora(papel: PaperWidth.mm58),
      );
      // Es la misma regla que resolverPerfil.
      for (final endpoint in [a, b, c]) {
        expect(
          ajustes.perfilPara(endpoint),
          resolverPerfil(
            endpoint,
            direcciones: {
              RolImpresora.tickets: a,
              RolImpresora.cocina: b,
              RolImpresora.barra: c,
            },
            formato: ajustes.formato,
            papelHeredado: PaperWidth.mm58,
          ),
        );
      }
    });

    test('la barra con impresora propia usa el perfil guardado para ella', () {
      final perfilC = PerfilImpresora(copias: 2, direccion: claveImpresora(c));
      final ajustes = ImpresionSettings(
        tickets: a,
        cocina: b,
        barra: c,
        formato: FormatoImpresion(perfiles: {RolImpresora.barra: perfilC}),
      );
      final barra = ajustes.impresoraDe(DestinoPreparacion.barra)!;
      expect(barra.endpoint, c);
      expect(barra.respaldo, isFalse);
      expect(ajustes.perfilPara(c), perfilC);
      // Las impresoras de tickets y de cocina no lo heredan.
      expect(ajustes.perfilPara(a), const PerfilImpresora());
      expect(ajustes.perfilPara(b), const PerfilImpresora());
    });

    test('la barra sin impresora sale por la de cocina con el perfil de '
        'cocina', () {
      final ajustes = ImpresionSettings(
        tickets: a,
        cocina: b,
        formato: const FormatoImpresion(
          perfiles: {
            RolImpresora.tickets: perfilA,
            RolImpresora.cocina: perfilB,
          },
        ),
      );
      final barra = ajustes.impresoraDe(DestinoPreparacion.barra)!;
      expect(barra.endpoint, b);
      expect(barra.respaldo, isTrue);
      expect(ajustes.perfilPara(barra.endpoint), perfilB);
      expect(ajustes.perfilPara(ajustes.paraTickets!), perfilA);
    });

    test('un rol re-apuntado desde Ajustes a otra impresora usa el perfil '
        'guardado para esa dirección', () {
      // tickets (perfil guardado para A) pasa a apuntar a B.
      final ajustes = ImpresionSettings(
        tickets: b,
        cocina: b,
        formato: const FormatoImpresion(
          perfiles: {
            RolImpresora.tickets: perfilA,
            RolImpresora.cocina: perfilB,
          },
        ),
      );
      expect(ajustes.perfilPara(b), perfilB);
      expect(ajustes.perfilPara(a), const PerfilImpresora());
    });

    test('guarda del cajón: sin zumbador del conector en la impresora que '
        'sirve a paraTickets', () {
      // Bar de una sola impresora.
      final una = ImpresionSettings(
        tickets: a,
        cocina: a,
        barra: a,
        formato: const FormatoImpresion(
          perfiles: {
            RolImpresora.tickets: cajon,
            RolImpresora.cocina: cajon,
            RolImpresora.barra: cajon,
          },
        ),
      );
      expect(una.paraTickets, a);
      expect(una.perfilPara(a), cajon.copyWith(zumbador: ZumbadorModo.ninguno));
      // Sin impresora de tickets, la de cocina es la que sirve a los tickets.
      final soloCocina = ImpresionSettings(
        cocina: b,
        formato: const FormatoImpresion(perfiles: {RolImpresora.cocina: cajon}),
      );
      expect(soloCocina.paraTickets, b);
      expect(soloCocina.perfilPara(b).zumbador, ZumbadorModo.ninguno);
      // Cocina distinta de la de tickets: conserva el zumbador.
      final dos = ImpresionSettings(
        tickets: a,
        cocina: b,
        formato: const FormatoImpresion(perfiles: {RolImpresora.cocina: cajon}),
      );
      expect(dos.perfilPara(b), cajon);
      expect(dos.perfilPara(a), const PerfilImpresora());
    });
  });
}
