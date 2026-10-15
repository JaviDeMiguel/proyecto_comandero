/// Mapeo dominio → DTO de impresión (§5.2-§5.10 y §5.13 del diseño): la
/// consolidación de líneas, las letras de IVA, la cabecera del emisor, el
/// motivo de «no imprimible» y los DTOs de cada documento.
library;

import 'dart:typed_data';

import 'package:proyecto_comandero/core/errors/app_exception.dart';
import 'package:proyecto_comandero/core/isolates/escpos/escpos.dart';
import 'package:proyecto_comandero/features/host/application/impresion/mapeo_documentos.dart';
import 'package:proyecto_comandero/features/host/domain/empresa_emisora.dart';
import 'package:proyecto_comandero/features/impresion/domain/formato_impresion.dart';
import 'package:proyecto_comandero/features/sala/domain/comanda.dart';
import 'package:proyecto_comandero/features/sala/domain/linea_comanda.dart';
import 'package:proyecto_comandero/features/sala/domain/marcha_pase.dart';
import 'package:proyecto_comandero/features/sala/domain/mesa.dart';
import 'package:proyecto_comandero/features/sala/domain/pases.dart';
import 'package:proyecto_comandero/features/sala/domain/precuenta_emitida.dart';
import 'package:proyecto_comandero/features/sala/domain/ticket.dart';
import 'package:test/test.dart';

import '../../../core/isolates/escpos/escpos_decoder.dart';

final cobro = DateTime(2026, 10, 9, 14, 32);
final expedicion = DateTime(2026, 10, 9, 14, 33);
final abierta = DateTime(2026, 10, 9, 21, 2);
final aceptada = DateTime(2026, 10, 9, 21, 14);

const mesa7 = Mesa(id: 'm7', nombre: 'Mesa 7', zona: 'Terraza');

const cabecera = EmpresaTicket(
  nombre: 'MANOLO GARCÍA HOSTELERÍA, S.L.',
  nombreComercial: 'BAR MANOLO',
  cifnif: 'B12345678',
);

LineaComanda lc(
  String id,
  String referencia,
  String descripcion,
  double cantidad,
  int pvpUnitarioCents, {
  int ivaBp = 1000,
  String? codimpuesto = 'IVA10',
  String? nota,
  DestinoPreparacion destino = DestinoPreparacion.cocina,
  int? pase,
  int? envio,
  DateTime? creadaEn,
  String? camarero,
}) => LineaComanda(
  id: id,
  referencia: referencia,
  descripcion: descripcion,
  cantidad: cantidad,
  pvpUnitarioCents: pvpUnitarioCents,
  pvpUnitarioNeto: pvpUnitarioCents / 100 / (1 + ivaBp / 10000),
  ivaBp: ivaBp,
  codimpuesto: codimpuesto,
  nota: nota,
  destino: destino,
  pase: pase,
  envio: envio,
  creadaEn: creadaEn ?? aceptada,
  camarero: camarero,
);

/// Las líneas de las maquetas, con la caña pedida en dos veces (se
/// consolidan en «4 x Caña») y una nota en el entrecot.
List<LineaComanda> lineasMaqueta() => [
  lc('a1', 'CANA', 'Caña', 2, 200),
  lc('a2', 'CROQ', 'Croquetas de jamón', 1, 900),
  lc('a3', 'CANA', 'Caña', 2, 200),
  lc('a4', 'ENTR', 'Entrecot a la brasa', 2, 1900, nota: '1 poco hecho'),
  lc(
    'a5',
    'VINO',
    'Vino Rioja crianza (llevar)',
    1,
    1200,
    ivaBp: 2100,
    codimpuesto: 'IVA21',
  ),
];

TotalesTicket totalesMaqueta() => TotalesTicket(
  netoCents: 5992,
  ivaCents: 708,
  totalCents: 6700,
  desglose: const [
    DesgloseIva(
      codimpuesto: 'IVA10',
      ivaBp: 1000,
      baseCents: 5000,
      cuotaCents: 500,
    ),
    DesgloseIva(
      codimpuesto: 'IVA21',
      ivaBp: 2100,
      baseCents: 992,
      cuotaCents: 208,
    ),
  ],
);

FacturaSincronizada facturaFs({
  EstadoSincronizacion estado = EstadoSincronizacion.sincronizado,
  String? codigo = 'F2026S12',
  DateTime? fecha,
  int? totalFsCents = 6700,
  bool sinFecha = false,
}) => FacturaSincronizada(
  estado: estado,
  codigo: codigo,
  fecha: sinFecha ? null : (fecha ?? expedicion),
  totalFsCents: totalFsCents,
);

Ticket ticketMaqueta({
  FacturaSincronizada? factura,
  List<PagoTicket>? pagos,
  MetodoPago metodo = MetodoPago.efectivo,
  int? entregadoCents = 7000,
  String? camarero = 'Ana',
}) => Ticket(
  id: '1a2b3c4d-5e6f-4a1b-9c2d-0123456789ab',
  numeroLocal: 15,
  mesaId: 'm7',
  nombreMesa: 'Mesa 7',
  comandaId: 'c1',
  fechaHora: cobro,
  lineas: lineasMaqueta(),
  totales: totalesMaqueta(),
  metodoPago: metodo,
  pagos: pagos,
  entregadoCents: entregadoCents,
  camarero: camarero,
  comensales: 4,
  factura: factura,
);

const lineasEsperadas = [
  LineaTicket(
    descripcion: 'Caña',
    cantidad: 4,
    pvpUnitarioCents: 200,
    importeCents: 800,
    letraIva: 'A',
  ),
  LineaTicket(
    descripcion: 'Croquetas de jamón',
    cantidad: 1,
    pvpUnitarioCents: 900,
    importeCents: 900,
    letraIva: 'A',
  ),
  LineaTicket(
    descripcion: 'Entrecot a la brasa',
    cantidad: 2,
    pvpUnitarioCents: 1900,
    importeCents: 3800,
    letraIva: 'A',
  ),
  LineaTicket(
    descripcion: 'Vino Rioja crianza (llevar)',
    cantidad: 1,
    pvpUnitarioCents: 1200,
    importeCents: 1200,
    letraIva: 'B',
  ),
];

const desgloseEsperado = [
  DesgloseIvaTicketPrint(
    ivaPct: 10,
    baseCents: 5000,
    cuotaCents: 500,
    letra: 'A',
  ),
  DesgloseIvaTicketPrint(
    ivaPct: 21,
    baseCents: 992,
    cuotaCents: 208,
    letra: 'B',
  ),
];

PrecuentaEmitida precuentaMaqueta({int? comensales = 4}) => PrecuentaEmitida(
  numero: 2,
  emitidaEn: DateTime(2026, 10, 9, 14, 10),
  comandaId: 'c1',
  nombreMesa: 'Mesa 7',
  lineas: [for (final l in lineasMaqueta()) LineaPrecuenta.desde(l)],
  totales: totalesMaqueta(),
  comensales: comensales,
  emitidaPor: 'Ana',
);

/// Comanda de la mesa 7: un primer envío (nº 9) con el agua de barra y el
/// segundo (nº 12) con la cocina en tres pases (el 4, fuera de la
/// configuración) y dos cañas de barra; el pase 1 ya está marchado.
Comanda comandaMaqueta({
  List<MarchaPase>? marchas,
  String? observaciones,
  List<LineaComanda> extra = const [],
}) => Comanda(
  id: 'c1',
  mesaId: 'm7',
  abiertaEn: abierta,
  camarero: 'Ana',
  comensales: 4,
  observaciones: observaciones,
  lineas: [
    lc(
      'b1',
      'AGUA',
      'Agua con gas',
      1,
      200,
      destino: DestinoPreparacion.barra,
      envio: 9,
      creadaEn: abierta,
    ),
    lc('l1', 'PAN', 'Pan con tomate', 1, 250, envio: 12, camarero: 'Luis'),
    lc('l2', 'CROQ', 'Croquetas de jamón', 2, 900, pase: 1, envio: 12),
    lc(
      'l3',
      'ENSA',
      'Ensalada de ventresca',
      1,
      1200,
      pase: 1,
      nota: 'sin cebolla',
      envio: 12,
    ),
    lc(
      'l4',
      'ENTR',
      'Entrecot a la brasa',
      2,
      1900,
      pase: 2,
      nota: '1 poco hecho, 1 al punto',
      envio: 12,
    ),
    lc('l5', 'LUBI', 'Lubina a la sal', 1, 2100, pase: 2, envio: 12),
    lc('l6', 'TART', 'Tarta de queso', 1, 550, pase: 4, envio: 12),
    lc(
      'b2',
      'CANA',
      'Caña',
      2,
      200,
      destino: DestinoPreparacion.barra,
      envio: 12,
    ),
    ...extra,
  ],
  marchas:
      marchas ??
      [MarchaPase(id: 'mp-1', pase: 1, cuando: aceptada, automatica: true)],
);

List<LineaComanda> cocinaDelEnvio12(Comanda c) => [
  for (final l in c.lineas)
    if (l.envio == 12 && l.destino == DestinoPreparacion.cocina) l,
];

const perfilCocina = PerfilImpresora(
  papel: PaperWidth.mm58,
  lineasIniciales: 3,
  copias: 2,
);

/// Líneas en blanco con las que empieza el papel (`ESC d n` justo tras el
/// init, antes de cualquier otro elemento), o `null` si no empieza así.
int? avanceInicialDe(Uint8List bytes) {
  final primero = decodeEscPos(bytes).elements.first;
  return primero is ElementoMarca && primero.comando.name == 'feed'
      ? primero.comando.args.single
      : null;
}

void main() {
  group('consolidación y letras de IVA', () {
    LineaVenta venta(
      String descripcion, {
      String? referencia = 'REF',
      double cantidad = 1,
      int pvp = 200,
      int ivaBp = 1000,
      String? codimpuesto = 'IVA10',
      String? nota,
    }) => (
      referencia: referencia,
      descripcion: descripcion,
      cantidad: cantidad,
      pvpUnitarioCents: pvp,
      importeCents: (pvp * cantidad).round(),
      ivaBp: ivaBp,
      codimpuesto: codimpuesto,
      nota: nota,
    );

    test('junta las líneas con la misma referencia, descripción, precio, IVA '
        'y codimpuesto; suma cantidad e importe en el orden de llegada', () {
      final r = consolidarLineas([
        venta('Caña', cantidad: 2),
        venta('Café', referencia: 'CAFE', pvp: 130),
        venta('Caña', cantidad: 3),
      ], conNotas: false);
      expect(r, hasLength(2));
      expect(r[0].descripcion, 'Caña');
      expect(r[0].cantidad, 5);
      expect(r[0].importeCents, 1000);
      expect(r[1].descripcion, 'Café');
    });

    test('dos líneas iguales salvo el IVA, el codimpuesto, el precio, la '
        'referencia o la descripción no se juntan', () {
      for (final distinta in [
        venta('Caña', ivaBp: 2100),
        venta('Caña', codimpuesto: 'IVA10B'),
        venta('Caña', pvp: 250),
        venta('Caña', referencia: 'OTRA'),
        venta('Caña grande'),
        venta('Caña', referencia: null),
      ]) {
        expect(
          consolidarLineas([venta('Caña'), distinta], conNotas: false),
          hasLength(2),
          reason: '$distinta',
        );
      }
    });

    test('las notas solo cuentan (y solo salen) si se muestran', () {
      final lineas = [
        venta('Entrecot', nota: 'poco hecho'),
        venta('Entrecot', nota: 'al punto'),
        venta('Entrecot', nota: ' poco hecho '),
        venta('Entrecot', nota: '  '),
      ];
      final sinNotas = consolidarLineas(lineas, conNotas: false);
      expect(sinNotas, hasLength(1));
      expect(sinNotas.single.cantidad, 4);
      expect(sinNotas.single.nota, isNull);

      final conNotas = consolidarLineas(lineas, conNotas: true);
      expect(
        [for (final l in conNotas) (l.nota, l.cantidad)],
        [('poco hecho', 2.0), ('al punto', 1.0), (null, 1.0)],
      );
    });

    test('letras A, B… por tipo ascendente en líneas y desglose; con un '
        'solo tipo, sin letras', () {
      final dos = lineasYDesglose(
        [for (final l in lineasMaqueta()) lineaVentaDe(l)],
        totalesMaqueta().desglose,
        conNotas: false,
      );
      expect(dos.lineas, lineasEsperadas);
      expect(dos.desglose, desgloseEsperado);

      final uno = lineasYDesglose(
        [lineaVentaDe(lc('x', 'CANA', 'Caña', 1, 200))],
        const [DesgloseIva(ivaBp: 1000, baseCents: 182, cuotaCents: 18)],
        conNotas: true,
      );
      expect(uno.lineas.single.letraIva, isNull);
      expect(uno.desglose.single.letra, isNull);
      expect(uno.desglose.single.ivaPct, 10);
    });

    test('una línea de precuenta se consolida igual que la del ticket', () {
      final p = precuentaMaqueta();
      final venta = [for (final l in p.lineas) lineaVentaDePrecuenta(l)];
      expect(
        lineasYDesglose(venta, p.totales.desglose, conNotas: false).lineas,
        lineasEsperadas,
      );
    });
  });

  group('cabecera del emisor (componerCabecera)', () {
    final erp = EmpresaEmisora(
      idempresa: 1,
      nombre: 'MANOLO GARCÍA HOSTELERÍA, S.L.',
      nombrecorto: 'Bar Manolo',
      cifnif: 'B12345678',
      direccion: 'C/ Mayor, 12, bajo',
      codpostal: '28001',
      ciudad: 'Madrid',
      provincia: 'Madrid',
      telefono: '910 000 000',
      email: 'hola@barmanolo.es',
      web: 'barmanolo.es',
      obtenidaEn: DateTime(2026, 10, 9, 9),
    );

    test('HostSettings.empresa manda sobre la caché y el formato', () {
      const ajustes = EmpresaTicket(nombre: 'Bar de pruebas', cifnif: 'X1');
      expect(
        componerCabecera(
          empresaAjustes: ajustes,
          empresaErp: erp,
          formato: const FormatoTicket(nombreComercial: 'OTRO', pie: 'Pie'),
          nombreTpv: 'Caja 1',
        ),
        same(ajustes),
      );
    });

    test('desde la empresa en caché: razón social, NIF, dirección, '
        'localidad, teléfono, web, el nombre corto como nombre comercial y '
        'el pie local', () {
      expect(
        componerCabecera(
          empresaErp: erp,
          formato: const FormatoTicket(pie: 'Gracias por su visita'),
          nombreTpv: 'Caja 1',
        ),
        const EmpresaTicket(
          nombre: 'MANOLO GARCÍA HOSTELERÍA, S.L.',
          nombreComercial: 'Bar Manolo',
          cifnif: 'B12345678',
          direccion: 'C/ Mayor, 12, bajo',
          codpostal: '28001',
          ciudad: 'Madrid',
          provincia: 'Madrid',
          telefono: '910 000 000',
          web: 'barmanolo.es',
          pie: 'Gracias por su visita',
        ),
      );
    });

    test('el nombre comercial del formato gana; el nombre corto igual a la '
        'razón social no se repite', () {
      expect(
        componerCabecera(
          empresaErp: erp,
          formato: const FormatoTicket(nombreComercial: 'BAR MANOLO'),
          nombreTpv: 'Caja 1',
        ).nombreComercial,
        'BAR MANOLO',
      );
      final igual = EmpresaEmisora(
        nombre: 'Bar Manolo',
        nombrecorto: ' BAR MANOLO ',
        cifnif: '  ',
        obtenidaEn: DateTime(2026),
      );
      final compuesta = componerCabecera(
        empresaErp: igual,
        formato: const FormatoTicket(),
        nombreTpv: 'Caja 1',
      );
      expect(compuesta, const EmpresaTicket(nombre: 'Bar Manolo'));
    });

    test('sin datos: el nombre del TPV (o el nombre comercial) y el pie', () {
      expect(
        componerCabecera(formato: const FormatoTicket(), nombreTpv: 'Caja 1'),
        const EmpresaTicket(nombre: 'Caja 1'),
      );
      expect(
        componerCabecera(
          formato: const FormatoTicket(
            nombreComercial: 'BAR MANOLO',
            pie: 'Gracias',
          ),
          nombreTpv: 'Caja 1',
        ),
        const EmpresaTicket(nombre: 'BAR MANOLO', pie: 'Gracias'),
      );
    });
  });

  group('textos sueltos', () {
    test('etiquetaMesa, tituloPuesto, formaDePago, referenciaCorta y '
        'motivoTexto', () {
      expect(etiquetaMesa('7'), 'Mesa 7');
      expect(etiquetaMesa(' 12 '), 'Mesa 12');
      expect(etiquetaMesa('Mesa 7'), 'Mesa 7');
      expect(etiquetaMesa('Terraza 3'), 'Terraza 3');
      expect(tituloPuesto(DestinoPreparacion.cocina), 'COCINA');
      expect(tituloPuesto(DestinoPreparacion.barra), 'BARRA');
      expect(formaDePago(MetodoPago.efectivo), 'Efectivo');
      expect(formaDePago(MetodoPago.tarjeta), 'Tarjeta');
      expect(referenciaCorta(ticketMaqueta()), 'TPV-1a2b3c4d');
      expect(ticketMaqueta().claveFactura, startsWith('TPV-1a2b3c4d'));

      final l = lc('x', 'LUBI', 'Lubina', 1, 2100);
      expect(motivoTexto(l), isNull);
      expect(
        motivoTexto(l.anular(cuando: aceptada, motivo: 'vaciar')),
        'mesa vaciada',
      );
      expect(motivoTexto(l.anular(cuando: aceptada, motivo: '  ')), isNull);
      expect(
        motivoTexto(l.anular(cuando: aceptada, motivo: ' cambia de plato ')),
        'cambia de plato',
      );
    });

    test('observaciones del puesto: el aviso de respaldo y las de la '
        'comanda', () {
      expect(
        observacionesPuesto(DestinoPreparacion.cocina, respaldo: false),
        isNull,
      );
      expect(
        observacionesPuesto(DestinoPreparacion.barra, respaldo: true),
        'Sin impresora de barra: llevar a barra',
      );
      expect(
        observacionesPuesto(
          DestinoPreparacion.cocina,
          respaldo: true,
          deLaComanda: ' Alergia al marisco ',
        ),
        'Sin impresora de cocina: llevar a cocina · Alergia al marisco',
      );
      expect(
        observacionesPuesto(
          DestinoPreparacion.cocina,
          respaldo: false,
          deLaComanda: '  ',
        ),
        isNull,
      );
    });

    test('motivos de reimpresión: banda y texto del diálogo', () {
      expect(MotivoReimpresion.noSalio.banda, 'REIMPRESIÓN · PREPARAR');
      expect(MotivoReimpresion.copia.banda, 'COPIA · NO PREPARAR');
      expect(MotivoReimpresion.noSalio.etiqueta, 'No salió / se perdió');
      expect(MotivoReimpresion.copia.etiqueta, 'Copia para el puesto');
    });
  });

  group('motivoNoImprimible', () {
    test('cada causa con su texto, en el orden de §5.5', () {
      String? motivo(Ticket t, [EmpresaTicket c = cabecera]) =>
          motivoNoImprimible(t, c);

      const sinNumero =
          'La factura del ticket nº 15 aún no tiene número de '
          'FacturaScripts';
      expect(motivo(ticketMaqueta()), sinNumero);
      expect(
        motivo(
          ticketMaqueta(
            factura: facturaFs(estado: EstadoSincronizacion.pendiente),
          ),
        ),
        sinNumero,
      );
      expect(
        motivo(
          ticketMaqueta(factura: facturaFs(estado: EstadoSincronizacion.error)),
        ),
        sinNumero,
      );
      expect(motivo(ticketMaqueta(factura: facturaFs(codigo: ' '))), sinNumero);

      const sinDatosFs =
          'La factura F2026S12 no tiene la fecha o el total de FacturaScripts '
          '(se sincronizó con una versión anterior): imprímela desde '
          'FacturaScripts';
      expect(
        motivo(ticketMaqueta(factura: facturaFs(sinFecha: true))),
        sinDatosFs,
      );
      expect(
        motivo(ticketMaqueta(factura: facturaFs(totalFsCents: null))),
        sinDatosFs,
      );

      expect(
        motivo(ticketMaqueta(factura: facturaFs(totalFsCents: 6701))),
        'El total de la factura F2026S12 en FacturaScripts (67,01 €) no '
        'coincide con el del ticket (67,00 €): revísala en el ERP',
      );

      const sinNif =
          'Falta el NIF del emisor: actualiza los datos de la empresa en '
          '«Tickets y comandas»';
      final buena = ticketMaqueta(factura: facturaFs());
      expect(motivo(buena, const EmpresaTicket(nombre: 'Bar')), sinNif);
      expect(
        motivo(buena, const EmpresaTicket(nombre: 'Bar', cifnif: '  ')),
        sinNif,
      );
      expect(motivo(buena), isNull);
    });

    test('con varias causas a la vez manda la primera del orden de §5.5: '
        'número, fecha o total de FS, totales distintos y NIF', () {
      // Cada factura tiene su causa y, además, todas las que van detrás
      // (siempre sin NIF del emisor).
      String? motivo(FacturaSincronizada factura) => motivoNoImprimible(
        ticketMaqueta(factura: factura),
        const EmpresaTicket(nombre: 'Bar'),
      );
      const sinNumero =
          'La factura del ticket nº 15 aún no tiene número de '
          'FacturaScripts';
      expect(
        motivo(facturaFs(codigo: null, sinFecha: true, totalFsCents: 6701)),
        sinNumero,
      );
      expect(
        motivo(
          facturaFs(
            estado: EstadoSincronizacion.pendiente,
            sinFecha: true,
            totalFsCents: 6701,
          ),
        ),
        sinNumero,
      );
      expect(
        motivo(facturaFs(sinFecha: true, totalFsCents: 6701)),
        startsWith('La factura F2026S12 no tiene la fecha o el total'),
      );
      expect(
        motivo(facturaFs(totalFsCents: 6701)),
        startsWith('El total de la factura F2026S12 en FacturaScripts'),
      );
      expect(motivo(facturaFs()), startsWith('Falta el NIF del emisor'));
    });
  });

  group('documentos de cliente', () {
    test('datosProvisional da exactamente el DTO escrito a mano: provisional, '
        'nº local, referencia corta, líneas consolidadas con letras, cajón y '
        'papel del perfil', () {
      final datos = datosProvisional(
        ticketMaqueta(),
        cabecera: cabecera,
        formato: const FormatoTicket(),
        perfil: perfilCocina,
        zona: 'Terraza',
        abrirCajon: true,
      );
      expect(
        datos,
        TicketPrintData(
          empresa: cabecera,
          tituloDocumento: 'DOCUMENTO PROVISIONAL',
          provisional: true,
          numeroLocal: 15,
          numero2: 'TPV-1a2b3c4d',
          fechaHora: cobro,
          mesa: 'Mesa 7',
          zona: 'Terraza',
          camarero: 'Ana',
          lineas: lineasEsperadas,
          desglose: desgloseEsperado,
          totalCents: 6700,
          metodoPago: 'Efectivo',
          entregadoCents: 7000,
          cambioCents: 300,
          ivaIncluido: true,
          paper: PaperWidth.mm58,
          abrirCajon: true,
        ),
      );
      // El generador lo acepta y, aunque el perfil pide 3 líneas, no lleva
      // avance inicial (documento de cliente): lo primero es el cajón.
      final bytes = generarTicket(datos);
      expect(avanceInicialDe(bytes), isNull);
      expect(decodeEscPos(bytes).commands[3].name, 'drawer');
    });

    test('provisional con COPIA, mixto y notas visibles; sin cajón por '
        'defecto', () {
      final mixto = ticketMaqueta(
        metodo: MetodoPago.efectivo,
        pagos: const [
          PagoTicket(metodo: MetodoPago.efectivo, importeCents: 4000),
          PagoTicket(metodo: MetodoPago.tarjeta, importeCents: 2700),
        ],
        entregadoCents: 5000,
      );
      final datos = datosProvisional(
        mixto,
        cabecera: cabecera,
        formato: const FormatoTicket(mostrarNotas: true, ivaIncluido: false),
        perfil: const PerfilImpresora(),
        avisos: const ['COPIA'],
      );
      expect(datos.abrirCajon, isFalse);
      expect(datos.avisos, ['COPIA']);
      expect(datos.metodoPago, 'Mixto');
      expect(datos.pagos, const [
        PagoTicketPrint(formaPago: 'Efectivo', importeCents: 4000),
        PagoTicketPrint(formaPago: 'Tarjeta', importeCents: 2700),
      ]);
      expect(datos.entregadoCents, 5000);
      expect(datos.cambioCents, 1000);
      expect(datos.ivaIncluido, isFalse);
      expect(datos.zona, isNull);
      expect(datos.paper, PaperWidth.mm80);
      expect(datos.lineas[2].nota, '1 poco hecho');
      expect(generarTicket(datos), isNotEmpty);

      final sinEntregado = datosProvisional(
        ticketMaqueta(entregadoCents: null, metodo: MetodoPago.tarjeta),
        cabecera: cabecera,
        formato: const FormatoTicket(),
        perfil: const PerfilImpresora(),
      );
      expect(sinEntregado.metodoPago, 'Tarjeta');
      expect(sinEntregado.pagos, isEmpty);
      expect(sinEntregado.entregadoCents, isNull);
      expect(sinEntregado.cambioCents, isNull);
    });

    test('datosFactura: código, fecha de expedición y total de FS, fecha de '
        'operación, QR, DUPLICADO y sin referencia, zona ni cajón', () {
      final duplicado = DuplicadoPrint(
        numero: 2,
        impresoEn: DateTime(2026, 10, 9, 16, 5),
      );
      final datos = datosFactura(
        ticketMaqueta(factura: facturaFs()),
        cabecera: cabecera,
        formato: const FormatoTicket(),
        perfil: perfilCocina,
        qrUrl:
            'https://prewww2.aeat.es/wlpl/TIKE-CONT/ValidarQR?nif=B12345678'
            '&numserie=F2026S12&fecha=09-10-2026&importe=67.00',
        qrLeyenda: 'VERI*FACTU',
        duplicado: duplicado,
      );
      expect(
        datos,
        TicketPrintData(
          empresa: cabecera,
          tituloDocumento: 'FACTURA SIMPLIFICADA',
          codigoFactura: 'F2026S12',
          numeroLocal: 15,
          fechaHora: cobro,
          fechaExpedicion: expedicion,
          fechaOperacion: cobro,
          mesa: 'Mesa 7',
          camarero: 'Ana',
          lineas: lineasEsperadas,
          desglose: desgloseEsperado,
          totalCents: 6700,
          metodoPago: 'Efectivo',
          entregadoCents: 7000,
          cambioCents: 300,
          qrUrl:
              'https://prewww2.aeat.es/wlpl/TIKE-CONT/ValidarQR?nif=B12345678'
              '&numserie=F2026S12&fecha=09-10-2026&importe=67.00',
          qrLeyenda: 'VERI*FACTU',
          duplicado: duplicado,
          ivaIncluido: true,
          paper: PaperWidth.mm58,
        ),
      );
      expect(datos.numero2, isNull);
      final decoded = decodeEscPos(generarTicket(datos));
      expect(decoded.named('drawer'), isEmpty);
      expect(decoded.texts, contains('Nº F2026S12'));
      expect(avanceInicialDe(generarTicket(datos)), isNull);
    });

    test('datosFactura imprime el total de FS, no el del ticket; sin el '
        'número, la fecha o el total de FS lanza ValidationException con el '
        'motivo y nunca los sustituye por los del ticket (§3.9)', () {
      TicketPrintData factura(FacturaSincronizada? f) => datosFactura(
        ticketMaqueta(factura: f),
        cabecera: cabecera,
        formato: const FormatoTicket(),
        perfil: const PerfilImpresora(),
      );
      expect(factura(facturaFs(totalFsCents: 6701)).totalCents, 6701);
      expect(ticketMaqueta().totalCents, 6700);

      const sinNumero =
          'La factura del ticket nº 15 aún no tiene número de '
          'FacturaScripts';
      final sinDatosFs = startsWith(
        'La factura F2026S12 no tiene la fecha o el total de FacturaScripts',
      );
      for (final (f, motivo) in [
        (null, sinNumero),
        (facturaFs(codigo: '  '), sinNumero),
        (facturaFs(sinFecha: true), sinDatosFs),
        (facturaFs(totalFsCents: null), sinDatosFs),
      ]) {
        expect(
          () => factura(f),
          throwsA(
            isA<ValidationException>().having(
              (e) => e.message,
              'message',
              motivo,
            ),
          ),
          reason: '$f',
        );
      }
    });

    test('mostrarCamarero apagado: sin camarero en el provisional, la factura '
        'y la precuenta; mostrarComensales apagado: sin comensales ni «Por '
        'comensal» en la precuenta; encendidos por defecto', () {
      const apagado = FormatoTicket(
        mostrarCamarero: false,
        mostrarComensales: false,
      );
      const perfil = PerfilImpresora();
      expect(
        datosProvisional(
          ticketMaqueta(),
          cabecera: cabecera,
          formato: apagado,
          perfil: perfil,
        ).camarero,
        isNull,
      );
      expect(
        datosFactura(
          ticketMaqueta(factura: facturaFs()),
          cabecera: cabecera,
          formato: apagado,
          perfil: perfil,
        ).camarero,
        isNull,
      );
      final precuenta = datosPrecuenta(
        precuentaMaqueta(),
        cabecera: cabecera,
        formato: apagado,
        perfil: perfil,
      );
      expect(precuenta.camarero, isNull);
      expect(precuenta.comensales, isNull);
      final texto = decodeEscPos(generarPrecuenta(precuenta)).texts.join('|');
      expect(texto, isNot(contains('Por comensal')));
      expect(texto, isNot(contains('comensales')));

      const porDefecto = FormatoTicket();
      expect(porDefecto.mostrarCamarero, isTrue);
      expect(porDefecto.mostrarComensales, isTrue);
      final encendida = datosPrecuenta(
        precuentaMaqueta(),
        cabecera: cabecera,
        formato: porDefecto,
        perfil: perfil,
      );
      expect(encendida.camarero, 'Ana');
      expect(encendida.comensales, 4);
      expect(
        decodeEscPos(generarPrecuenta(encendida)).texts.join('|'),
        contains('Por comensal (4)'),
      );
      expect(
        datosProvisional(
          ticketMaqueta(),
          cabecera: cabecera,
          formato: porDefecto,
          perfil: perfil,
        ).camarero,
        'Ana',
      );
    });

    test('datosPrecuenta desde el registro: nº, hora y mesa del registro, '
        'líneas consolidadas con letras, notas según el ajuste, zona y papel '
        'del perfil', () {
      final datos = datosPrecuenta(
        precuentaMaqueta(),
        cabecera: cabecera,
        formato: const FormatoTicket(),
        perfil: perfilCocina,
        zona: 'Terraza',
      );
      expect(
        datos,
        PrecuentaPrintData(
          empresa: cabecera,
          fechaHora: DateTime(2026, 10, 9, 14, 10),
          mesa: 'Mesa 7',
          numero: 2,
          zona: 'Terraza',
          camarero: 'Ana',
          comensales: 4,
          lineas: lineasEsperadas,
          desglose: desgloseEsperado,
          totalCents: 6700,
          ivaIncluido: true,
          paper: PaperWidth.mm58,
        ),
      );
      final conNotas = datosPrecuenta(
        precuentaMaqueta(comensales: 0),
        cabecera: cabecera,
        formato: const FormatoTicket(mostrarNotas: true),
        perfil: const PerfilImpresora(),
      );
      expect(conNotas.lineas[2].nota, '1 poco hecho');
      // Un registro con 0 comensales (diario corrupto) no impide imprimir.
      expect(conNotas.comensales, isNull);
      expect(generarPrecuenta(conNotas), isNotEmpty);
      expect(avanceInicialDe(generarPrecuenta(datos)), isNull);
    });
  });

  group('documentos de preparación', () {
    test('datosComanda: puesto, mesa, zona, nº de envío, ordinal por bloques, '
        'camarero del envío, grupos por pase con ESPERAR y «Pase N», avance '
        'y papel del perfil', () {
      final comanda = comandaMaqueta();
      final datos = datosComanda(
        mesa7,
        comanda,
        cocinaDelEnvio12(comanda),
        destino: DestinoPreparacion.cocina,
        pases: const PasesConfig(),
        perfil: perfilCocina,
        ahora: aceptada,
      );
      expect(
        datos,
        KitchenOrderPrintData(
          titulo: 'COCINA',
          mesa: 'Mesa 7',
          zona: 'Terraza',
          comensales: 4,
          camarero: 'Luis',
          numeroComanda: '12',
          fechaHora: aceptada,
          ordinalEnvio: 2,
          abiertaEn: abierta,
          lineas: const [
            LineaComandaPrint(cantidad: 1, descripcion: 'Pan con tomate'),
            LineaComandaPrint(
              cantidad: 2,
              descripcion: 'Croquetas de jamón',
              pase: 1,
              nombrePase: 'Primeros',
            ),
            LineaComandaPrint(
              cantidad: 1,
              descripcion: 'Ensalada de ventresca',
              nota: 'sin cebolla',
              pase: 1,
              nombrePase: 'Primeros',
            ),
            LineaComandaPrint(
              cantidad: 2,
              descripcion: 'Entrecot a la brasa',
              nota: '1 poco hecho, 1 al punto',
              pase: 2,
              nombrePase: 'Segundos',
              esperar: true,
            ),
            LineaComandaPrint(
              cantidad: 1,
              descripcion: 'Lubina a la sal',
              pase: 2,
              nombrePase: 'Segundos',
              esperar: true,
            ),
            LineaComandaPrint(
              cantidad: 1,
              descripcion: 'Tarta de queso',
              pase: 4,
              nombrePase: 'Pase 4',
              esperar: true,
            ),
          ],
          avanceInicial: 3,
          paper: PaperWidth.mm58,
        ),
      );
      final bytes = generarComandaCocina(datos);
      expect(avanceInicialDe(bytes), 3);
      expect(
        decodeEscPos(bytes).texts.join('|'),
        contains('4. PASE 4 · ESPERAR'),
      );
    });

    test('datosComanda: sin pases activos, plana y sin ESPERAR; el ordinal es '
        'el del bloque aunque el número se repita tras un Cierre Z; el '
        'respaldo y las observaciones de la comanda', () {
      final comanda = comandaMaqueta(observaciones: 'Alergia al marisco');
      final plana = datosComanda(
        mesa7,
        comanda,
        cocinaDelEnvio12(comanda),
        destino: DestinoPreparacion.cocina,
        pases: const PasesConfig(activos: false),
        perfil: const PerfilImpresora(),
        ahora: aceptada,
        respaldo: true,
      );
      expect(plana.lineas.map((l) => (l.pase, l.nombrePase, l.esperar)), [
        for (var i = 0; i < 6; i++) (null, null, false),
      ]);
      expect(plana.lineas.map((l) => l.descripcion), [
        'Pan con tomate',
        'Croquetas de jamón',
        'Ensalada de ventresca',
        'Entrecot a la brasa',
        'Lubina a la sal',
        'Tarta de queso',
      ]);
      expect(plana.avanceInicial, 0);
      expect(
        plana.observaciones,
        'Sin impresora de cocina: llevar a cocina · Alergia al marisco',
      );

      final trasZ = Comanda(
        id: 'c2',
        mesaId: 'm7',
        abiertaEn: abierta,
        lineas: [
          lc('x', 'CANA', 'Caña', 1, 200, envio: 3),
          lc('y', 'CANA', 'Caña', 1, 200, envio: 1),
          lc('z', 'CANA', 'Caña', 1, 200, envio: 3),
          lc('w', 'CANA', 'Caña', 1, 200),
        ],
      );
      KitchenOrderPrintData de(String id) => datosComanda(
        mesa7,
        trasZ,
        [trasZ.lineaPorId(id)!],
        destino: DestinoPreparacion.barra,
        pases: const PasesConfig(),
        perfil: const PerfilImpresora(),
        ahora: aceptada,
      );
      expect(de('x').ordinalEnvio, 1);
      expect(de('z').ordinalEnvio, 3);
      expect(de('z').numeroComanda, '3');
      expect(de('w').ordinalEnvio, 4);
      expect(de('w').numeroComanda, isNull);
      expect(de('w').camarero, isNull);
      expect(de('w').comensales, isNull);
      expect(de('w').titulo, 'BARRA');

      // Líneas que aún no están en la comanda: el envío recién aceptado es
      // el último bloque; sin bloques ni líneas, sin ordinal.
      KitchenOrderPrintData fuera(Comanda c, List<LineaComanda> lineas) =>
          datosComanda(
            mesa7,
            c,
            lineas,
            destino: DestinoPreparacion.barra,
            pases: const PasesConfig(),
            perfil: const PerfilImpresora(),
            ahora: aceptada,
          );
      final nueva = lc('n', 'CANA', 'Caña', 1, 200, envio: 7);
      expect(fuera(trasZ, [nueva]).ordinalEnvio, 4);
      final vacia = Comanda(id: 'v', mesaId: 'm7', abiertaEn: abierta);
      expect(fuera(vacia, [nueva]).ordinalEnvio, isNull);
      expect(fuera(vacia, const []).ordinalEnvio, isNull);
      expect(fuera(vacia, const []).numeroComanda, isNull);
    });

    test('datosMarchar: pase y nombre, comandas de origen, hora de la marcha, '
        'REPETIDO con la marcha anterior, respaldo y avance', () {
      final marcha = MarchaPase(
        id: 'mp-2',
        pase: 2,
        cuando: DateTime(2026, 10, 9, 21, 52),
        camarero: 'Ana',
      );
      final comanda = comandaMaqueta(
        observaciones: 'Alergia al marisco',
        marchas: [
          MarchaPase(id: 'mp-1', pase: 1, cuando: aceptada, automatica: true),
          marcha,
        ],
      );
      final lineas = [comanda.lineaPorId('l4')!, comanda.lineaPorId('l5')!];
      final datos = datosMarchar(
        mesa7,
        comanda,
        marcha,
        lineas,
        destino: DestinoPreparacion.cocina,
        pases: const PasesConfig(),
        perfil: perfilCocina,
      );
      expect(
        datos,
        MarcharPrintData(
          titulo: 'COCINA',
          mesa: 'Mesa 7',
          zona: 'Terraza',
          pase: 2,
          nombrePase: 'Segundos',
          numerosComanda: const [12],
          pedidaEn: aceptada,
          fechaHora: DateTime(2026, 10, 9, 21, 52),
          camarero: 'Ana',
          comensales: 4,
          lineas: const [
            LineaComandaPrint(
              cantidad: 2,
              descripcion: 'Entrecot a la brasa',
              nota: '1 poco hecho, 1 al punto',
            ),
            LineaComandaPrint(cantidad: 1, descripcion: 'Lubina a la sal'),
          ],
          avanceInicial: 3,
          paper: PaperWidth.mm58,
        ),
      );
      expect(generarMarchar(datos), isNotEmpty);

      final repetida = MarchaPase(
        id: 'mp-3',
        pase: 2,
        cuando: DateTime(2026, 10, 9, 22, 5),
        repetida: true,
      );
      final otraVez = datosMarchar(
        mesa7,
        comanda.conMarcha(repetida),
        repetida,
        [
          ...lineas,
          lc('l7', 'LUBI', 'Lubina a la sal', 1, 2100, pase: 2, envio: 15),
          lc(
            'l8',
            'LUBI',
            'Lubina a la sal',
            1,
            2100,
            pase: 2,
            envio: 12,
            creadaEn: abierta,
          ),
        ],
        destino: DestinoPreparacion.barra,
        pases: const PasesConfig(nombres: ['Entrantes']),
        perfil: const PerfilImpresora(),
        respaldo: true,
      );
      expect(otraVez.repetida, isTrue);
      expect(otraVez.ultimaMarchaEn, DateTime(2026, 10, 9, 21, 52));
      expect(otraVez.numerosComanda, [12, 15]);
      expect(otraVez.pedidaEn, abierta);
      expect(otraVez.nombrePase, 'Pase 2');
      expect(otraVez.titulo, 'BARRA');
      expect(otraVez.observaciones, 'Sin impresora de barra: llevar a barra');
      expect(otraVez.avanceInicial, 0);
    });

    test('datosAnulacion: título en banda, cantidades a anular con la nota, '
        'el motivo, el envío y la hora de la línea; avance del perfil', () {
      final comanda = comandaMaqueta();
      final anuladas = [
        comanda
            .lineaPorId('l5')!
            .anular(cuando: aceptada, motivo: 'el cliente cambia de plato'),
        comanda.lineaPorId('l3')!.anular(cuando: aceptada, motivo: 'vaciar'),
      ];
      final ahora = DateTime(2026, 10, 9, 21, 30);
      final datos = datosAnulacion(
        mesa7,
        comanda,
        anuladas,
        destino: DestinoPreparacion.cocina,
        perfil: perfilCocina,
        ahora: ahora,
      );
      expect(
        datos,
        KitchenOrderPrintData(
          titulo: 'ANULACIÓN COCINA',
          tituloEnBanda: true,
          mesa: 'Mesa 7',
          zona: 'Terraza',
          camarero: 'Ana',
          numeroComanda: '12',
          fechaHora: ahora,
          lineas: [
            LineaComandaPrint(
              cantidad: 1,
              descripcion: 'Lubina a la sal',
              anulada: true,
              motivo: 'el cliente cambia de plato',
              envio: 12,
              pedidaEn: aceptada,
            ),
            LineaComandaPrint(
              cantidad: 1,
              descripcion: 'Ensalada de ventresca',
              anulada: true,
              nota: 'sin cebolla',
              motivo: 'mesa vaciada',
              envio: 12,
              pedidaEn: aceptada,
            ),
          ],
          avanceInicial: 3,
          paper: PaperWidth.mm58,
        ),
      );
      final texto = decodeEscPos(generarComandaCocina(datos)).texts.join('|');
      expect(texto, contains('-1 x Lubina a la sal'));
      expect(texto, contains('Motivo: mesa vaciada'));

      final sinEnvio = datosAnulacion(
        mesa7,
        comanda,
        [lc('v', 'CANA', 'Caña', 2, 200).anular(cuando: ahora)],
        destino: DestinoPreparacion.barra,
        perfil: const PerfilImpresora(),
        ahora: ahora,
        respaldo: true,
      );
      expect(sinEnvio.numeroComanda, isNull);
      expect(sinEnvio.titulo, 'ANULACIÓN BARRA');
      expect(sinEnvio.observaciones, 'Sin impresora de barra: llevar a barra');
    });

    test('datosMarchar: con varias marchas del mismo pase, la anterior es la '
        'última antes de esta (no la primera, ni una posterior, ni la de otro '
        'pase)', () {
      final primera = MarchaPase(
        id: 'mp-2a',
        pase: 2,
        cuando: DateTime(2026, 10, 9, 21, 52),
      );
      final segunda = MarchaPase(
        id: 'mp-2b',
        pase: 2,
        cuando: DateTime(2026, 10, 9, 22, 5),
        repetida: true,
      );
      final deOtroPase = MarchaPase(
        id: 'mp-4',
        pase: 4,
        cuando: DateTime(2026, 10, 9, 22, 10),
      );
      final tercera = MarchaPase(
        id: 'mp-2c',
        pase: 2,
        cuando: DateTime(2026, 10, 9, 22, 20),
        repetida: true,
      );
      final comanda = comandaMaqueta(
        marchas: [
          MarchaPase(id: 'mp-1', pase: 1, cuando: aceptada, automatica: true),
          primera,
          segunda,
          deOtroPase,
          tercera,
        ],
      );
      DateTime? anteriorA(MarchaPase marcha) => datosMarchar(
        mesa7,
        comanda,
        marcha,
        [comanda.lineaPorId('l5')!],
        destino: DestinoPreparacion.cocina,
        pases: const PasesConfig(),
        perfil: const PerfilImpresora(),
      ).ultimaMarchaEn;
      expect(anteriorA(tercera), DateTime(2026, 10, 9, 22, 5));
      expect(anteriorA(segunda), DateTime(2026, 10, 9, 21, 52));
      expect(anteriorA(primera), isNull);
    });

    test('MARCHAR y anulación: los envíos de las líneas, sin repetir y de '
        'menor a mayor aunque las líneas lleguen desordenadas', () {
      final marcha = MarchaPase(
        id: 'mp-2',
        pase: 2,
        cuando: DateTime(2026, 10, 9, 21, 52),
      );
      final comanda = comandaMaqueta().conMarcha(marcha);
      final lineas = [
        lc('d1', 'LUBI', 'Lubina a la sal', 1, 2100, pase: 2, envio: 15),
        lc('d2', 'ENTR', 'Entrecot a la brasa', 1, 1900, pase: 2, envio: 12),
        lc('d3', 'LUBI', 'Lubina a la sal', 1, 2100, pase: 2, envio: 9),
        lc('d4', 'ENTR', 'Entrecot a la brasa', 1, 1900, pase: 2, envio: 12),
        lc('d5', 'FLAN', 'Flan', 1, 450, pase: 2),
      ];
      final marchar = datosMarchar(
        mesa7,
        comanda,
        marcha,
        lineas,
        destino: DestinoPreparacion.cocina,
        pases: const PasesConfig(),
        perfil: const PerfilImpresora(),
      );
      expect(marchar.numerosComanda, [9, 12, 15]);

      final anulacion = datosAnulacion(
        mesa7,
        comanda,
        [for (final linea in lineas) linea.anular(cuando: aceptada)],
        destino: DestinoPreparacion.cocina,
        perfil: const PerfilImpresora(),
        ahora: aceptada,
      );
      expect(anulacion.numeroComanda, '9, 12, 15');
      expect(
        decodeEscPos(generarComandaCocina(anulacion)).texts.join('|'),
        contains('Comandas nº 9, 12, 15'),
      );
    });

    test('datosReimpresion: la banda con el motivo, «Reimpresa … · '
        'dispositivo», los números de los bloques, ESPERAR según las marchas '
        'actuales y el avance del perfil', () {
      final comanda = comandaMaqueta(
        extra: [
          lc(
            'l9',
            'FLAN',
            'Flan',
            1,
            450,
            pase: 3,
            envio: 15,
            creadaEn: DateTime(2026, 10, 9, 21, 30),
          ),
        ],
        marchas: [
          MarchaPase(id: 'mp-1', pase: 1, cuando: aceptada, automatica: true),
          MarchaPase(
            id: 'mp-2',
            pase: 2,
            cuando: DateTime(2026, 10, 9, 21, 52),
          ),
        ],
      );
      final todo = [
        for (final l in lineasAReimprimir(comanda, AlcanceReimpresion.todo))
          if (l.destino == DestinoPreparacion.cocina) l,
      ];
      final ahora = DateTime(2026, 10, 9, 21, 40);
      final datos = datosReimpresion(
        mesa7,
        comanda,
        todo,
        destino: DestinoPreparacion.cocina,
        pases: const PasesConfig(),
        perfil: perfilCocina,
        motivo: MotivoReimpresion.noSalio,
        dispositivo: 'Caja 1',
        ahora: ahora,
      );
      expect(datos.banner, 'REIMPRESIÓN · PREPARAR');
      expect(datos.bannerDetalle, ['Reimpresa 09/10/2026 21:40 · Caja 1']);
      expect(datos.numeroComanda, '12, 15');
      expect(datos.ordinalEnvio, isNull);
      expect(datos.fechaHora, aceptada);
      expect(datos.titulo, 'COCINA');
      expect(datos.camarero, 'Luis');
      expect(datos.avanceInicial, 3);
      expect(datos.paper, PaperWidth.mm58);
      expect(datos.lineas.map((l) => (l.descripcion, l.esperar)), [
        ('Pan con tomate', false),
        ('Croquetas de jamón', false),
        ('Ensalada de ventresca', false),
        ('Entrecot a la brasa', false),
        ('Lubina a la sal', false),
        ('Flan', true),
        ('Tarta de queso', true),
      ]);
      final texto = decodeEscPos(generarComandaCocina(datos)).texts.join('|');
      expect(texto, contains('ENVÍOS Nº 12, 15'));

      final ultimo = lineasAReimprimir(comanda, AlcanceReimpresion.ultimoEnvio);
      expect(ultimo.map((l) => l.id), ['l9']);
      final copia = datosReimpresion(
        mesa7,
        comanda,
        ultimo,
        destino: DestinoPreparacion.cocina,
        pases: const PasesConfig(activos: false),
        perfil: const PerfilImpresora(),
        motivo: MotivoReimpresion.copia,
        dispositivo: 'Caja 1',
        ahora: ahora,
        respaldo: true,
      );
      expect(copia.banner, 'COPIA · NO PREPARAR');
      expect(copia.numeroComanda, '15');
      expect(copia.ordinalEnvio, 3);
      expect(copia.fechaHora, DateTime(2026, 10, 9, 21, 30));
      expect(copia.lineas.single.esperar, isFalse);
      expect(copia.observaciones, 'Sin impresora de cocina: llevar a cocina');
    });

    test('lineasAReimprimir: todo son las activas; el último envío, el bloque '
        'final sin las anuladas', () {
      final base = comandaMaqueta();
      final comanda = base.conLineaActualizada(
        base.lineaPorId('b2')!.anular(cuando: aceptada),
      );
      expect(
        lineasAReimprimir(comanda, AlcanceReimpresion.todo).map((l) => l.id),
        ['b1', 'l1', 'l2', 'l3', 'l4', 'l5', 'l6'],
      );
      expect(
        lineasAReimprimir(
          comanda,
          AlcanceReimpresion.ultimoEnvio,
        ).map((l) => l.id),
        ['l1', 'l2', 'l3', 'l4', 'l5', 'l6'],
      );
      expect(
        lineasAReimprimir(
          Comanda(id: 'v', mesaId: 'm7', abiertaEn: abierta),
          AlcanceReimpresion.ultimoEnvio,
        ),
        isEmpty,
      );
    });

    test('las reimpresiones sin número de envío (diario anterior) salen sin '
        'número', () {
      final comanda = Comanda(
        id: 'vieja',
        mesaId: 'm7',
        abiertaEn: abierta,
        lineas: [lc('v1', 'CANA', 'Caña', 1, 200)],
      );
      final datos = datosReimpresion(
        mesa7,
        comanda,
        comanda.lineas,
        destino: DestinoPreparacion.barra,
        pases: const PasesConfig(),
        perfil: const PerfilImpresora(),
        motivo: MotivoReimpresion.copia,
        dispositivo: 'Caja 1',
        ahora: aceptada,
      );
      expect(datos.numeroComanda, isNull);
      expect(datos.ordinalEnvio, 1);
      expect(
        decodeEscPos(generarComandaCocina(datos)).texts.join('|'),
        contains('COMANDA · 21:14'),
      );
    });
  });
}
