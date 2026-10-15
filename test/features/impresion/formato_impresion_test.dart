import 'dart:convert';

import 'package:proyecto_comandero/core/fiscal/verifactu_qr.dart';
import 'package:proyecto_comandero/core/isolates/escpos/escpos_builder.dart';
import 'package:proyecto_comandero/core/network/printing/raw_printer_transport.dart';
import 'package:proyecto_comandero/features/impresion/domain/formato_impresion.dart';
import 'package:proyecto_comandero/features/sala/domain/pases.dart';
import 'package:test/test.dart';

/// Pasa por texto JSON real, como en los ajustes guardados.
Map<String, Object?> ida(Map<String, Object?> json) =>
    jsonDecode(jsonEncode(json)) as Map<String, Object?>;

final PrinterEndpoint a = PrinterEndpoint('192.168.1.40');
final PrinterEndpoint b = PrinterEndpoint('192.168.1.50');
final PrinterEndpoint bPrima = PrinterEndpoint('192.168.1.60');
const String claveA = '192.168.1.40:9100';
const String claveB = '192.168.1.50:9100';

const PerfilImpresora perfilA = PerfilImpresora(
  papel: PaperWidth.mm80,
  copias: 3,
  direccion: claveA,
);
const PerfilImpresora perfilB = PerfilImpresora(
  papel: PaperWidth.mm58,
  copias: 2,
  zumbador: ZumbadorModo.generico,
  direccion: claveB,
);
const PerfilImpresora perfilCajon = PerfilImpresora(
  zumbador: ZumbadorModo.puertoCajon,
  pitidos: 3,
  pinZumbador: 2,
  direccion: claveA,
);

/// El JSON de `impresion.formato` del documento de diseño (§3.11), con dos
/// cambios: la cocina usa `mm58` porque `mm80Dpi180` lo añade WP-06b, y los
/// pases no son los por defecto (si lo fueran, `toJson` omitiría la clave).
final Map<String, Object?> ejemploDiseno = {
  'perfiles': {
    'tickets': {'papel': 'mm80', 'direccion': claveA},
    'cocina': {
      'papel': 'mm58',
      'lineasIniciales': 2,
      'copias': 2,
      'zumbador': 'puertoCajon',
      'pitidos': 1,
      'direccion': claveB,
    },
  },
  'ticket': {
    'nombreComercial': 'BAR MANOLO',
    'pie': 'Gracias por su visita',
    'mostrarComensales': false,
  },
  'emision': {'modo': 'facturaAlCobrar', 'esperaSegundos': 10},
  'verifactu': {'modo': 'verifactu', 'entorno': 'pruebas'},
  'pases': {
    'activos': true,
    'nombres': ['Primeros', 'Segundos', 'Postres'],
    'marcharAlEnviar': false,
  },
};

void main() {
  group('PerfilImpresora', () {
    test('valores por defecto', () {
      const perfil = PerfilImpresora();
      expect(perfil.papel, PaperWidth.mm80);
      expect(perfil.lineasIniciales, 0);
      expect(perfil.copias, 1);
      expect(perfil.zumbador, ZumbadorModo.ninguno);
      expect(perfil.pitidos, 2);
      expect(perfil.pinZumbador, 5);
      expect(perfil.pinZumbador, PerfilImpresora.pinZumbadorPorDefecto);
      expect(perfil.direccion, isNull);
      expect(PerfilImpresora.pinesZumbador, [5, 2]);
    });

    test('toJson escribe siempre papel y omite lo que está por defecto', () {
      expect(const PerfilImpresora().toJson(), {'papel': 'mm80'});
      expect(const PerfilImpresora(papel: PaperWidth.mm58).toJson(), {
        'papel': 'mm58',
      });
      expect(const PerfilImpresora(direccion: claveA).toJson(), {
        'papel': 'mm80',
        'direccion': claveA,
      });
      expect(PerfilImpresora.fromJson(const {}), const PerfilImpresora());
    });

    test('ida y vuelta completa', () {
      const perfil = PerfilImpresora(
        papel: PaperWidth.mm58,
        lineasIniciales: 2,
        copias: 2,
        zumbador: ZumbadorModo.puertoCajon,
        pitidos: 1,
        pinZumbador: 2,
        direccion: claveB,
      );
      final json = ida(perfil.toJson());
      expect(json, {
        'papel': 'mm58',
        'lineasIniciales': 2,
        'copias': 2,
        'zumbador': 'puertoCajon',
        'pitidos': 1,
        'pinZumbador': 2,
        'direccion': claveB,
      });
      expect(PerfilImpresora.fromJson(json), perfil);
    });

    test('lectura tolerante: los números se acotan', () {
      int copias(Object? raw) =>
          PerfilImpresora.fromJson({'copias': raw}).copias;
      int pitidos(Object? raw) =>
          PerfilImpresora.fromJson({'pitidos': raw}).pitidos;
      int lineas(Object? raw) =>
          PerfilImpresora.fromJson({'lineasIniciales': raw}).lineasIniciales;
      expect(copias(0), 1);
      expect(copias(7), 3);
      expect(copias(2), 2);
      expect(pitidos(0), 1);
      expect(pitidos(9), 8);
      expect(pitidos(8), 8);
      expect(lineas(-1), 0);
      expect(lineas(11), 10);
      expect(lineas(10), 10);
      // Otro tipo → valor por defecto.
      expect(copias('dos'), 1);
      expect(copias(2.0), 1);
      expect(pitidos(null), 2);
      expect(lineas(true), 0);
    });

    test('lectura tolerante: pin distinto de 2 y 5 → 5', () {
      int pin(Object? raw) =>
          PerfilImpresora.fromJson({'pinZumbador': raw}).pinZumbador;
      expect(pin(3), 5);
      expect(pin(0), 5);
      expect(pin(2), 2);
      expect(pin(5), 5);
      expect(pin('2'), 5);
      expect(pin(null), 5);
    });

    test('lectura tolerante: enum desconocido → defecto; dirección vacía → '
        'nula', () {
      final raro = PerfilImpresora.fromJson({
        'papel': 'mm999',
        'zumbador': 'turbo',
        'direccion': '   ',
      });
      expect(raro, const PerfilImpresora());
      expect(PerfilImpresora.fromJson({'papel': 42}).papel, PaperWidth.mm80);
      expect(PerfilImpresora.fromJson({'direccion': 5}).direccion, isNull);
      expect(
        PerfilImpresora.fromJson({'zumbador': 'generico'}).zumbador,
        ZumbadorModo.generico,
      );
    });

    test('maxPitidosDe: 8 con ESC B, 3 con el conector del cajón', () {
      expect(PerfilImpresora.maxPitidosDe(ZumbadorModo.generico), 8);
      expect(PerfilImpresora.maxPitidosDe(ZumbadorModo.ninguno), 8);
      expect(PerfilImpresora.maxPitidosDe(ZumbadorModo.puertoCajon), 3);
    });

    test('copyWith', () {
      final cambiado = perfilB.copyWith(copias: 1, pitidos: 4);
      expect(cambiado.copias, 1);
      expect(cambiado.pitidos, 4);
      expect(cambiado.papel, PaperWidth.mm58);
      expect(cambiado.zumbador, ZumbadorModo.generico);
      expect(cambiado.direccion, claveB);
      expect(perfilB.copyWith(), perfilB);
      expect(perfilB.copyWith(direccion: null).direccion, claveB);
      expect(perfilB.copyWith(borrarDireccion: true).direccion, isNull);
      expect(perfilB.copyWith(direccion: claveA).direccion, claveA);
    });
  });

  group('FormatoTicket', () {
    test('valores por defecto: camarero y comensales activados', () {
      const ticket = FormatoTicket();
      expect(ticket.nombreComercial, isNull);
      expect(ticket.pie, isNull);
      expect(ticket.mostrarNotas, isFalse);
      expect(ticket.ivaIncluido, isTrue);
      expect(ticket.mostrarCamarero, isTrue);
      expect(ticket.mostrarComensales, isTrue);
      expect(ticket.toJson(), isEmpty);
      expect(FormatoTicket.fromJson(const {}), ticket);
    });

    test('mostrarCamarero y mostrarComensales solo se escriben si son false '
        'y hacen la ida y vuelta', () {
      const apagados = FormatoTicket(
        mostrarCamarero: false,
        mostrarComensales: false,
      );
      final json = ida(apagados.toJson());
      expect(json, {'mostrarCamarero': false, 'mostrarComensales': false});
      expect(FormatoTicket.fromJson(json), apagados);
      expect(const FormatoTicket(mostrarComensales: false).toJson(), {
        'mostrarComensales': false,
      });
      expect(
        const FormatoTicket(mostrarCamarero: true).toJson().keys,
        isNot(contains('mostrarCamarero')),
      );
    });

    test('ida y vuelta completa', () {
      const ticket = FormatoTicket(
        nombreComercial: 'BAR MANOLO',
        pie: 'Gracias por su visita\nwww.barmanolo.es',
        mostrarNotas: true,
        ivaIncluido: false,
        mostrarCamarero: false,
      );
      final json = ida(ticket.toJson());
      expect(json, {
        'nombreComercial': 'BAR MANOLO',
        'pie': 'Gracias por su visita\nwww.barmanolo.es',
        'mostrarNotas': true,
        'ivaIncluido': false,
        'mostrarCamarero': false,
      });
      expect(FormatoTicket.fromJson(json), ticket);
    });

    test('lectura tolerante: textos vacíos → nulos, largos recortados y '
        'tipos raros → defecto', () {
      final largo = FormatoTicket.fromJson({
        'nombreComercial': 'X' * 40,
        'pie': 'P' * 250,
      });
      expect(largo.nombreComercial, 'X' * FormatoTicket.maxNombreComercial);
      expect(largo.pie, 'P' * FormatoTicket.maxPie);
      expect(FormatoTicket.maxNombreComercial, 32);
      expect(FormatoTicket.maxPie, 200);
      final raro = FormatoTicket.fromJson({
        'nombreComercial': '',
        'pie': 7,
        'mostrarNotas': 'si',
        'ivaIncluido': 0,
        'mostrarCamarero': null,
        'mostrarComensales': 'no',
      });
      expect(raro, const FormatoTicket());
      expect(
        FormatoTicket.fromJson({'nombreComercial': 'Bar Pepe'}).nombreComercial,
        'Bar Pepe',
      );
    });

    test('copyWith', () {
      const base = FormatoTicket(nombreComercial: 'BAR', pie: 'pie');
      expect(base.copyWith(), base);
      expect(base.copyWith(nombreComercial: null).nombreComercial, 'BAR');
      expect(
        base.copyWith(borrarNombreComercial: true).nombreComercial,
        isNull,
      );
      expect(base.copyWith(borrarPie: true).pie, isNull);
      final cambiado = base.copyWith(
        mostrarNotas: true,
        ivaIncluido: false,
        mostrarCamarero: false,
        mostrarComensales: false,
      );
      expect(cambiado.mostrarNotas, isTrue);
      expect(cambiado.ivaIncluido, isFalse);
      expect(cambiado.mostrarCamarero, isFalse);
      expect(cambiado.mostrarComensales, isFalse);
      expect(cambiado.pie, 'pie');
    });
  });

  group('EmisionTicket', () {
    test('valores por defecto y espera', () {
      const emision = EmisionTicket();
      expect(emision.modo, ModoEmision.alInstante);
      expect(emision.esperaSegundos, 10);
      expect(emision.espera, const Duration(seconds: 10));
      expect(emision.toJson(), {'modo': 'alInstante', 'esperaSegundos': 10});
      expect(EmisionTicket.fromJson(const {}), emision);
    });

    test('ida y vuelta', () {
      const emision = EmisionTicket(
        modo: ModoEmision.facturaAlCobrar,
        esperaSegundos: 20,
      );
      final json = ida(emision.toJson());
      expect(json, {'modo': 'facturaAlCobrar', 'esperaSegundos': 20});
      expect(EmisionTicket.fromJson(json), emision);
      expect(emision.espera, const Duration(seconds: 20));
    });

    test('lectura tolerante: espera acotada a 3..30 y modo desconocido → '
        'al instante', () {
      int espera(Object? raw) =>
          EmisionTicket.fromJson({'esperaSegundos': raw}).esperaSegundos;
      expect(espera(1), 3);
      expect(espera(99), 30);
      expect(espera(3), 3);
      expect(espera(30), 30);
      expect(espera('10'), 10);
      expect(
        EmisionTicket.fromJson({'modo': 'alCerrar'}).modo,
        ModoEmision.alInstante,
      );
      expect(EmisionTicket.fromJson({'modo': 2}).modo, ModoEmision.alInstante);
    });

    test('copyWith', () {
      const base = EmisionTicket();
      final cambiado = base.copyWith(modo: ModoEmision.facturaAlCobrar);
      expect(cambiado.modo, ModoEmision.facturaAlCobrar);
      expect(cambiado.esperaSegundos, 10);
      expect(
        cambiado.copyWith(esperaSegundos: 5).espera,
        const Duration(seconds: 5),
      );
      expect(base.copyWith(), base);
    });
  });

  group('QrVerifactuConfig', () {
    test('valores por defecto: desactivado y producción', () {
      const qr = QrVerifactuConfig();
      expect(qr.modo, ModoQrVerifactu.desactivado);
      expect(qr.entorno, EntornoVerifactu.produccion);
      expect(qr.activo, isFalse);
      expect(qr.toJson(), {'modo': 'desactivado', 'entorno': 'produccion'});
      expect(QrVerifactuConfig.fromJson(const {}), qr);
    });

    test('ida y vuelta y activo', () {
      const qr = QrVerifactuConfig(
        modo: ModoQrVerifactu.verifactu,
        entorno: EntornoVerifactu.pruebas,
      );
      final json = ida(qr.toJson());
      expect(json, {'modo': 'verifactu', 'entorno': 'pruebas'});
      expect(QrVerifactuConfig.fromJson(json), qr);
      expect(qr.activo, isTrue);
      expect(
        const QrVerifactuConfig(modo: ModoQrVerifactu.noVerifactu).activo,
        isTrue,
      );
    });

    test('lectura tolerante: enum desconocido → defecto', () {
      expect(
        QrVerifactuConfig.fromJson({'modo': 'si', 'entorno': 'local'}),
        const QrVerifactuConfig(),
      );
      expect(
        QrVerifactuConfig.fromJson({'modo': 'noVerifactu', 'entorno': 1}),
        const QrVerifactuConfig(modo: ModoQrVerifactu.noVerifactu),
      );
    });

    test('copyWith', () {
      const base = QrVerifactuConfig();
      expect(base.copyWith(), base);
      expect(
        base.copyWith(entorno: EntornoVerifactu.pruebas),
        const QrVerifactuConfig(entorno: EntornoVerifactu.pruebas),
      );
      expect(
        base.copyWith(modo: ModoQrVerifactu.verifactu).modo,
        ModoQrVerifactu.verifactu,
      );
    });
  });

  group('FormatoImpresion', () {
    test(
      'por defecto: esPorDefecto, JSON vacío y lectura de un JSON vacío',
      () {
        const formato = FormatoImpresion();
        expect(formato.esPorDefecto, isTrue);
        expect(formato.perfiles, isEmpty);
        expect(formato.ticket, const FormatoTicket());
        expect(formato.emision, const EmisionTicket());
        expect(formato.verifactu, const QrVerifactuConfig());
        expect(formato.pases, const PasesConfig());
        expect(formato.toJson(), isEmpty);
        expect(FormatoImpresion.fromJson(const {}), formato);
        expect(FormatoImpresion.fromJson(ida(formato.toJson())), formato);
      },
    );

    test('toJson escribe cada subobjeto solo si no es por defecto', () {
      const soloEmision = FormatoImpresion(
        emision: EmisionTicket(modo: ModoEmision.facturaAlCobrar),
      );
      expect(soloEmision.esPorDefecto, isFalse);
      expect(soloEmision.toJson().keys, ['emision']);
      const soloPases = FormatoImpresion(pases: PasesConfig(activos: false));
      expect(soloPases.toJson().keys, ['pases']);
      expect(soloPases.toJson()['pases'], {
        'activos': false,
        'nombres': ['Primeros', 'Segundos', 'Postres'],
        'marcharAlEnviar': true,
      });
      const soloTicket = FormatoImpresion(
        ticket: FormatoTicket(mostrarCamarero: false),
      );
      expect(soloTicket.toJson(), {
        'ticket': {'mostrarCamarero': false},
      });
      const soloQr = FormatoImpresion(
        verifactu: QrVerifactuConfig(modo: ModoQrVerifactu.verifactu),
      );
      expect(soloQr.toJson().keys, ['verifactu']);
    });

    test('ida y vuelta del JSON del diseño', () {
      final formato = FormatoImpresion.fromJson(ejemploDiseno);
      expect(formato.perfiles.keys, [
        RolImpresora.tickets,
        RolImpresora.cocina,
      ]);
      expect(
        formato.perfiles[RolImpresora.tickets],
        const PerfilImpresora(direccion: claveA),
      );
      expect(
        formato.perfiles[RolImpresora.cocina],
        const PerfilImpresora(
          papel: PaperWidth.mm58,
          lineasIniciales: 2,
          copias: 2,
          zumbador: ZumbadorModo.puertoCajon,
          pitidos: 1,
          direccion: claveB,
        ),
      );
      expect(formato.perfiles[RolImpresora.barra], isNull);
      expect(
        formato.ticket,
        const FormatoTicket(
          nombreComercial: 'BAR MANOLO',
          pie: 'Gracias por su visita',
          mostrarComensales: false,
        ),
      );
      expect(
        formato.emision,
        const EmisionTicket(modo: ModoEmision.facturaAlCobrar),
      );
      expect(
        formato.verifactu,
        const QrVerifactuConfig(
          modo: ModoQrVerifactu.verifactu,
          entorno: EntornoVerifactu.pruebas,
        ),
      );
      expect(formato.pases, const PasesConfig(marcharAlEnviar: false));
      expect(formato.esPorDefecto, isFalse);
      expect(ida(formato.toJson()), ejemploDiseno);
      expect(FormatoImpresion.fromJson(ida(formato.toJson())), formato);
    });

    test('los perfiles se escriben en el orden tickets, cocina, barra', () {
      const formato = FormatoImpresion(
        perfiles: {RolImpresora.barra: perfilB, RolImpresora.tickets: perfilA},
      );
      final perfiles = formato.toJson()['perfiles']! as Map<String, Object?>;
      expect(perfiles.keys, ['tickets', 'barra']);
    });

    test('lectura tolerante: subobjetos que no son mapas → defecto, sin '
        'lanzar', () {
      final formato = FormatoImpresion.fromJson({
        'perfiles': 'x',
        'ticket': 3,
        'emision': <Object?>[],
        'verifactu': true,
        'pases': 'no',
        'desconocido': 1,
      });
      expect(formato, const FormatoImpresion());
      expect(FormatoImpresion.fromJson({'perfiles': null}).perfiles, isEmpty);
    });

    test('lectura tolerante de perfiles: claves que no son un rol y valores '
        'que no son objetos se ignoran', () {
      final formato = FormatoImpresion.fromJson({
        'perfiles': {
          'cocina': {'papel': 'mm58'},
          'horno': {'papel': 'mm58'},
          'barra': 'mm58',
          'tickets': null,
        },
      });
      expect(formato.perfiles, {
        RolImpresora.cocina: const PerfilImpresora(papel: PaperWidth.mm58),
      });
    });

    test('lectura tolerante de pases: nombres inválidos → pases por '
        'defecto', () {
      PasesConfig pases(Object? raw) =>
          FormatoImpresion.fromJson({'pases': raw}).pases;
      expect(pases({'nombres': <Object?>[]}), const PasesConfig());
      expect(
        pases({
          'nombres': ['1', '2', '3', '4', '5', '6'],
        }),
        const PasesConfig(),
      );
      expect(
        pases({
          'nombres': ['Un nombre demasiado largo'],
        }),
        const PasesConfig(),
      );
      expect(
        pases({
          'nombres': ['Primeros', ''],
        }),
        const PasesConfig(),
      );
      expect(pases({'activos': 'si'}), const PasesConfig());
      expect(
        pases({
          'activos': false,
          'nombres': ['Entrantes', 'Principales'],
        }),
        const PasesConfig(
          activos: false,
          nombres: ['Entrantes', 'Principales'],
        ),
      );
    });

    test('los perfiles leídos y copiados no se pueden modificar', () {
      final leido = FormatoImpresion.fromJson(ejemploDiseno);
      expect(
        () => leido.perfiles[RolImpresora.barra] = perfilB,
        throwsUnsupportedError,
      );
      final copia = const FormatoImpresion().copyWith(
        perfiles: {RolImpresora.cocina: perfilB},
      );
      expect(
        () => copia.perfiles[RolImpresora.barra] = perfilB,
        throwsUnsupportedError,
      );
    });

    test('copyWith', () {
      final formato = FormatoImpresion.fromJson(ejemploDiseno);
      expect(formato.copyWith(), formato);
      final conBarra = formato.copyWith(
        perfiles: {...formato.perfiles, RolImpresora.barra: perfilB},
      );
      expect(conBarra.perfiles.keys, [
        RolImpresora.tickets,
        RolImpresora.cocina,
        RolImpresora.barra,
      ]);
      expect(conBarra.ticket, formato.ticket);
      final otro = formato.copyWith(
        ticket: const FormatoTicket(),
        emision: const EmisionTicket(),
        verifactu: const QrVerifactuConfig(),
        pases: const PasesConfig(),
      );
      expect(otro.perfiles, formato.perfiles);
      expect(otro.esPorDefecto, isFalse);
      expect(otro.copyWith(perfiles: const {}).esPorDefecto, isTrue);
    });
  });

  group('claveImpresora', () {
    test('host:puerto, con corchetes si el host es IPv6', () {
      expect(claveImpresora(a), claveA);
      expect(
        claveImpresora(PrinterEndpoint('cocina.local', port: 9101)),
        'cocina.local:9101',
      );
      expect(claveImpresora(PrinterEndpoint('fe80::1')), '[fe80::1]:9100');
    });
  });

  group('rolesDe', () {
    test('roles cuya dirección es la impresora, en orden tickets, cocina, '
        'barra, sea cual sea el orden del mapa', () {
      expect(
        rolesDe(a, {
          RolImpresora.barra: a,
          RolImpresora.cocina: b,
          RolImpresora.tickets: a,
        }),
        [RolImpresora.tickets, RolImpresora.barra],
      );
      expect(
        rolesDe(a, {
          RolImpresora.tickets: a,
          RolImpresora.cocina: a,
          RolImpresora.barra: a,
        }),
        RolImpresora.values,
      );
      expect(rolesDe(b, {RolImpresora.tickets: a}), isEmpty);
      expect(rolesDe(a, {RolImpresora.tickets: null}), isEmpty);
      expect(rolesDe(a, const {}), isEmpty);
    });

    test('compara como PrinterEndpoint: el puerto cuenta y el host no '
        'distingue mayúsculas', () {
      expect(
        rolesDe(a, {
          RolImpresora.tickets: PrinterEndpoint('192.168.1.40', port: 9101),
        }),
        isEmpty,
      );
      expect(
        rolesDe(PrinterEndpoint('Cocina.LOCAL'), {
          RolImpresora.cocina: PrinterEndpoint('cocina.local'),
        }),
        [RolImpresora.cocina],
      );
    });
  });

  group('resolverPerfil', () {
    PerfilImpresora resolver(
      PrinterEndpoint endpoint, {
      PrinterEndpoint? tickets,
      PrinterEndpoint? cocina,
      PrinterEndpoint? barra,
      Map<RolImpresora, PerfilImpresora> perfiles = const {},
      PaperWidth papelHeredado = PaperWidth.mm80,
    }) => resolverPerfil(
      endpoint,
      direcciones: {
        RolImpresora.tickets: tickets,
        RolImpresora.cocina: cocina,
        RolImpresora.barra: barra,
      },
      formato: FormatoImpresion(perfiles: perfiles),
      papelHeredado: papelHeredado,
    );

    test('re-apuntado: gana el primer rol con perfil, no el primer rol', () {
      // Solo cocina = A con perfil de 58 mm guardado para A; después se
      // añade tickets = A en Ajustes, sin perfil.
      const perfil58 = PerfilImpresora(
        papel: PaperWidth.mm58,
        direccion: claveA,
      );
      expect(
        resolver(
          a,
          tickets: a,
          cocina: a,
          perfiles: {RolImpresora.cocina: perfil58},
        ),
        perfil58,
      );
      // Sin dirección guardada tampoco cambia: es el único con perfil.
      expect(
        resolver(
          a,
          tickets: a,
          cocina: a,
          perfiles: {
            RolImpresora.cocina: const PerfilImpresora(papel: PaperWidth.mm58),
          },
        ).papel,
        PaperWidth.mm58,
      );
    });

    test('conflicto: gana el perfil guardado para esa dirección', () {
      // tickets, con perfil guardado para A, pasa a apuntar a B, donde
      // cocina tiene su perfil guardado para B.
      expect(
        resolver(
          b,
          tickets: b,
          cocina: b,
          perfiles: {
            RolImpresora.tickets: perfilA,
            RolImpresora.cocina: perfilB,
          },
        ),
        perfilB,
      );
      // Y también si el rol que coincide es el último del orden.
      expect(
        resolver(
          a,
          tickets: a,
          cocina: a,
          barra: a,
          perfiles: {
            RolImpresora.cocina: const PerfilImpresora(direccion: 'otra:9100'),
            RolImpresora.barra: perfilA,
          },
        ),
        perfilA,
      );
    });

    test('sin ningún perfil guardado para la dirección gana el primero del '
        'orden tickets, cocina, barra', () {
      const p1 = PerfilImpresora(copias: 2);
      const p2 = PerfilImpresora(copias: 3);
      expect(
        resolver(
          a,
          tickets: a,
          cocina: a,
          barra: a,
          perfiles: {RolImpresora.barra: p2, RolImpresora.cocina: p1},
        ),
        p1,
      );
      expect(
        resolver(
          a,
          tickets: a,
          cocina: a,
          barra: a,
          perfiles: {RolImpresora.tickets: p2, RolImpresora.cocina: p1},
        ),
        p2,
      );
    });

    test('cambio de IP: el rol conserva su perfil aunque se guardara para '
        'otra dirección', () {
      // La impresora de cocina cambia de IP (B → B') en Ajustes.
      expect(
        resolver(
          bPrima,
          tickets: a,
          cocina: bPrima,
          perfiles: {
            RolImpresora.tickets: perfilA,
            RolImpresora.cocina: perfilB,
          },
        ),
        perfilB,
      );
    });

    test('respaldo: la barra sin impresora sale por la de cocina con el '
        'perfil de cocina', () {
      expect(
        resolver(
          b,
          tickets: a,
          cocina: b,
          perfiles: {
            RolImpresora.tickets: perfilA,
            RolImpresora.cocina: perfilB,
          },
        ),
        perfilB,
      );
    });

    test('sin perfiles: el papel heredado', () {
      expect(
        resolver(a, tickets: a, cocina: b, papelHeredado: PaperWidth.mm58),
        const PerfilImpresora(papel: PaperWidth.mm58),
      );
      // Un rol con perfil no afecta a otra impresora sin él.
      expect(
        resolver(
          a,
          tickets: a,
          cocina: b,
          perfiles: {RolImpresora.cocina: perfilB},
          papelHeredado: PaperWidth.mm58,
        ),
        const PerfilImpresora(papel: PaperWidth.mm58),
      );
      // Una impresora que no es de ningún rol tampoco tiene perfil.
      expect(
        resolver(
          bPrima,
          tickets: a,
          cocina: b,
          perfiles: {
            RolImpresora.tickets: perfilA,
            RolImpresora.cocina: perfilB,
          },
        ),
        const PerfilImpresora(),
      );
    });

    test('guarda del cajón: el zumbador del conector se anula en la '
        'impresora que sirve a los tickets', () {
      const anulado = PerfilImpresora(
        zumbador: ZumbadorModo.ninguno,
        pitidos: 3,
        pinZumbador: 2,
        direccion: claveA,
      );
      // Bar de una sola impresora.
      expect(
        resolver(
          a,
          tickets: a,
          cocina: a,
          barra: a,
          perfiles: {
            RolImpresora.tickets: perfilCajon,
            RolImpresora.cocina: perfilCajon,
            RolImpresora.barra: perfilCajon,
          },
        ),
        anulado,
      );
      // tickets = A a secas.
      expect(
        resolver(a, tickets: a, perfiles: {RolImpresora.tickets: perfilCajon}),
        anulado,
      );
      // Sin impresora de tickets, la de cocina es la que sirve a los tickets.
      expect(
        resolver(
          a,
          cocina: a,
          perfiles: {RolImpresora.cocina: perfilCajon},
        ).zumbador,
        ZumbadorModo.ninguno,
      );
      // Sin tickets ni cocina, la de barra es la que sirve a los tickets.
      expect(
        resolver(a, barra: a, perfiles: {RolImpresora.barra: perfilCajon}),
        anulado,
      );
      // Con cocina, los tickets salen por la de cocina: la de barra conserva
      // el zumbador del conector.
      const cajonBarra = PerfilImpresora(
        zumbador: ZumbadorModo.puertoCajon,
        direccion: claveB,
      );
      expect(
        resolver(
          b,
          cocina: a,
          barra: b,
          perfiles: {RolImpresora.barra: cajonBarra},
        ),
        cajonBarra,
      );
      // Con «Pitido» (ESC B) no se anula nada.
      const pitido = PerfilImpresora(
        zumbador: ZumbadorModo.generico,
        pitidos: 5,
        direccion: claveA,
      );
      expect(
        resolver(
          a,
          tickets: a,
          cocina: a,
          perfiles: {RolImpresora.tickets: pitido},
        ),
        pitido,
      );
    });

    test('la impresora de cocina distinta de la de tickets conserva el '
        'zumbador del conector', () {
      const cajonB = PerfilImpresora(
        zumbador: ZumbadorModo.puertoCajon,
        direccion: claveB,
      );
      expect(
        resolver(
          b,
          tickets: a,
          cocina: b,
          perfiles: {RolImpresora.cocina: cajonB},
        ),
        cajonB,
      );
      // También cuando la barra sale por ella de respaldo.
      expect(
        resolver(
          b,
          tickets: a,
          cocina: b,
          perfiles: {
            RolImpresora.tickets: perfilCajon,
            RolImpresora.cocina: cajonB,
          },
        ).zumbador,
        ZumbadorModo.puertoCajon,
      );
    });

    test('la dirección guardada se compara sin distinguir mayúsculas', () {
      final impresora = PrinterEndpoint('Cocina.local');
      const guardado = PerfilImpresora(
        copias: 2,
        direccion: 'cocina.LOCAL:9100',
      );
      const otro = PerfilImpresora(copias: 3, direccion: 'otra:9100');
      expect(
        resolver(
          impresora,
          tickets: impresora,
          cocina: impresora,
          perfiles: {RolImpresora.tickets: otro, RolImpresora.cocina: guardado},
        ),
        guardado,
      );
    });
  });
}
