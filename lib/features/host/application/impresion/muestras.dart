/// Documentos de muestra de la página «Tickets y comandas» (§5.18 del
/// diseño de impresión): datos deterministas (los de las maquetas de §2),
/// la cabecera real compuesta con el borrador y la banda «MUESTRA · SIN
/// VALIDEZ» en todos. Dart puro y sin runtime: la vista previa funciona
/// aunque el TPV no haya arrancado.
library;

import 'dart:typed_data';

import '../../../../core/errors/app_exception.dart';
import '../../../../core/fiscal/verifactu_qr.dart';
import '../../../../core/isolates/escpos/escpos_builder.dart' show PaperWidth;
import '../../../../core/isolates/escpos/ticket_documents.dart';
import '../../../../core/isolates/isolate_runner.dart';
import '../../../impresion/domain/formato_impresion.dart';
import '../../../sala/domain/comanda.dart';
import '../../../sala/domain/linea_comanda.dart';
import '../../../sala/domain/marcha_pase.dart';
import '../../../sala/domain/mesa.dart';
import '../../../sala/domain/pases.dart';
import '../../../sala/domain/precuenta_emitida.dart';
import '../../../sala/domain/ticket.dart';
import '../../domain/host_settings.dart';
import 'mapeo_documentos.dart';

/// Documentos que se pueden ver e imprimir como muestra.
enum DocumentoMuestra {
  provisional('Documento provisional', RolImpresora.tickets),
  factura('Factura simplificada', RolImpresora.tickets),
  duplicado('Duplicado de la factura', RolImpresora.tickets),
  precuenta('Precuenta', RolImpresora.tickets),
  comandaCocina('Comanda de cocina', RolImpresora.cocina),
  comandaBarra('Comanda de barra', RolImpresora.barra),
  marchar('MARCHAR un pase', RolImpresora.cocina),
  anulacion('Anulación', RolImpresora.cocina),
  reimpresion('Reimpresión de comanda', RolImpresora.cocina);

  const DocumentoMuestra(this.etiqueta, this.rol);

  /// Nombre del documento en la interfaz.
  final String etiqueta;

  /// Impresora que lo imprime en el día a día.
  final RolImpresora rol;

  /// Documento de preparación: lleva el avance inicial del perfil y, al
  /// imprimirlo, el aviso sonoro (para probarlo).
  bool get preparacion => rol != RolImpresora.tickets;
}

/// Número de serie de la factura de muestra (`numserie` de su QR).
const String serieMuestra = 'MUESTRA-1';

/// Línea de la factura de muestra cuando el NIF del emisor no vale.
const String avisoSinNifMuestra =
    'Sin NIF válido: la factura real no se podrá imprimir';

/// Dispositivo de la reimpresión de muestra.
const String dispositivoMuestra = 'Caja 1';

const Mesa _mesa = Mesa(id: 'muestra-7', nombre: 'Mesa 7', zona: 'Terraza');
const String _camarero = 'Ana';
const int _comensales = 4;
const int _totalCents = 6700;

/// QR de la factura de muestra con la configuración [verifactu]: siempre del
/// entorno de pruebas (`prewww2.aeat.es`, nunca la sede de producción), con
/// la serie [serieMuestra], el día de [ahora], el total de la muestra y el
/// NIF de [cabecera]. `null` con el modo desactivado. Lanza
/// [ValidationException] si el NIF no vale para el QR.
QrTributario? qrMuestra(
  QrVerifactuConfig verifactu, {
  required EmpresaTicket cabecera,
  required DateTime ahora,
}) => QrTributario.segunAjustes(
  modo: verifactu.modo,
  entorno: EntornoVerifactu.pruebas,
  nif: cabecera.cifnif ?? '',
  numSerie: serieMuestra,
  fecha: ahora,
  importeCents: _totalCents,
);

/// Bytes del documento de muestra [tipo] con [ajustes] (el borrador de la
/// página: formato del ticket, QR y pases), la [cabecera] compuesta
/// (`componerCabecera` con la empresa en caché, si la hay), el [papel] del
/// perfil de la impresora y, en los de preparación, [avanceInicial] líneas en
/// blanco (`perfil.lineasIniciales`). Nunca abren el cajón; el aviso sonoro
/// lo añade el canal al imprimirlas. Función pura salvo por [runner], que
/// ejecuta el generador; con el mismo [ahora] da los mismos bytes.
///
/// La factura y el duplicado llevan el QR de [qrMuestra] o, si el NIF no
/// vale (o falta, con el QR desactivado), la línea [avisoSinNifMuestra]; la
/// factura lleva además la regla de 40 mm bajo el QR.
Future<Uint8List> generarMuestra(
  DocumentoMuestra tipo, {
  required ImpresionSettings ajustes,
  required EmpresaTicket cabecera,
  required PaperWidth papel,
  required DateTime ahora,
  required IsolateRunner runner,
  int avanceInicial = 0,
}) {
  final perfil = PerfilImpresora(papel: papel, lineasIniciales: avanceInicial);
  final formato = ajustes.formato.ticket;
  final muestra = _Preparacion(ajustes.pases, perfil, ahora);
  return switch (tipo) {
    DocumentoMuestra.provisional => generarTicketEnIsolate(
      datosProvisional(
        _ticket(ahora),
        cabecera: cabecera,
        formato: formato,
        perfil: perfil,
        zona: _mesa.zona,
        muestra: true,
      ),
      runner: runner,
    ),
    DocumentoMuestra.factura ||
    DocumentoMuestra.duplicado => generarTicketEnIsolate(
      _datosFactura(tipo, ajustes, cabecera, perfil, ahora),
      runner: runner,
    ),
    DocumentoMuestra.precuenta => generarPrecuentaEnIsolate(
      datosPrecuenta(
        _precuenta(ahora),
        cabecera: cabecera,
        formato: formato,
        perfil: perfil,
        zona: _mesa.zona,
        muestra: true,
      ),
      runner: runner,
    ),
    DocumentoMuestra.comandaCocina => generarComandaCocinaEnIsolate(
      muestra.comanda(DestinoPreparacion.cocina),
      runner: runner,
    ),
    DocumentoMuestra.comandaBarra => generarComandaCocinaEnIsolate(
      muestra.comanda(DestinoPreparacion.barra),
      runner: runner,
    ),
    DocumentoMuestra.marchar => generarMarcharEnIsolate(
      muestra.marchar(),
      runner: runner,
    ),
    DocumentoMuestra.anulacion => generarComandaCocinaEnIsolate(
      muestra.anulacion(),
      runner: runner,
    ),
    DocumentoMuestra.reimpresion => generarComandaCocinaEnIsolate(
      muestra.reimpresion(),
      runner: runner,
    ),
  };
}

/// Documentos de preparación de muestra sobre la comanda de la mesa 7, con
/// los pases del borrador y el perfil de la impresora.
final class _Preparacion {
  _Preparacion(this.pases, this.perfil, this.ahora)
    : _comanda = _comandaMuestra(ahora);

  final PasesConfig pases;
  final PerfilImpresora perfil;
  final DateTime ahora;
  final Comanda _comanda;

  /// Líneas del envío nº 12 (el último) que se preparan en [destino].
  List<LineaComanda> _delEnvio12(DestinoPreparacion destino) => [
    for (final linea in _comanda.lineasUltimoEnvio)
      if (linea.destino == destino) linea,
  ];

  /// Comanda del envío nº 12 en [destino], a la hora en que se aceptó.
  KitchenOrderPrintData comanda(DestinoPreparacion destino) {
    final lineas = _delEnvio12(destino);
    return datosComanda(
      _mesa,
      _comanda,
      lineas,
      destino: destino,
      pases: pases,
      perfil: perfil,
      ahora: lineas.first.creadaEn,
      muestra: true,
    );
  }

  /// MARCHAR de los segundos (pase 2) en cocina, marchado ahora.
  MarcharPrintData marchar() {
    final marcha = MarchaPase(
      id: 'muestra-marcha-2',
      pase: 2,
      cuando: ahora,
      camarero: _camarero,
    );
    return datosMarchar(
      _mesa,
      _comanda.conMarcha(marcha),
      marcha,
      [
        for (final linea in _delEnvio12(DestinoPreparacion.cocina))
          if (linea.pase == 2) linea,
      ],
      destino: DestinoPreparacion.cocina,
      pases: pases,
      perfil: perfil,
      muestra: true,
    );
  }

  /// Anulación de la lubina (maqueta (h)).
  KitchenOrderPrintData anulacion() => datosAnulacion(
    _mesa,
    _comanda,
    [
      for (final linea in _delEnvio12(DestinoPreparacion.cocina))
        if (linea.referencia == 'LUBI')
          linea.anular(cuando: ahora, motivo: 'el cliente cambia de plato'),
    ],
    destino: DestinoPreparacion.cocina,
    perfil: perfil,
    ahora: ahora,
    muestra: true,
  );

  /// Reimpresión de toda la cocina porque no salió (maqueta (i)).
  KitchenOrderPrintData reimpresion() => datosReimpresion(
    _mesa,
    _comanda,
    [
      for (final linea in lineasAReimprimir(_comanda, AlcanceReimpresion.todo))
        if (linea.destino == DestinoPreparacion.cocina) linea,
    ],
    destino: DestinoPreparacion.cocina,
    pases: pases,
    perfil: perfil,
    motivo: MotivoReimpresion.noSalio,
    dispositivo: dispositivoMuestra,
    ahora: ahora,
    muestra: true,
  );
}

/// Factura de muestra (con la regla de 40 mm) o su DUPLICADO nº 1.
TicketPrintData _datosFactura(
  DocumentoMuestra tipo,
  ImpresionSettings ajustes,
  EmpresaTicket cabecera,
  PerfilImpresora perfil,
  DateTime ahora,
) {
  final verifactu = ajustes.formato.verifactu;
  QrTributario? qr;
  var nifValido = true;
  try {
    qr = qrMuestra(verifactu, cabecera: cabecera, ahora: ahora);
  } on ValidationException {
    nifValido = false;
  }
  final sinNif = (cabecera.cifnif?.trim() ?? '').isEmpty;
  final factura = FacturaSincronizada(
    estado: EstadoSincronizacion.sincronizado,
    codigo: serieMuestra,
    fecha: ahora,
    totalFsCents: _totalCents,
  );
  return datosFactura(
    _ticket(ahora, factura: factura),
    cabecera: cabecera,
    formato: ajustes.formato.ticket,
    perfil: perfil,
    qrUrl: qr?.url,
    qrLeyenda: qr?.leyenda,
    duplicado: tipo == DocumentoMuestra.duplicado
        ? DuplicadoPrint(numero: 1, impresoEn: ahora)
        : null,
    avisos: [if (!nifValido || sinNif) avisoSinNifMuestra],
    muestra: true,
    reglaQr: tipo == DocumentoMuestra.factura,
  );
}

/// Ticket nº 15 de la mesa 7 cobrado en efectivo (maquetas (a)-(c)): la
/// caña se pidió en dos veces, para que se vea la consolidación.
Ticket _ticket(DateTime ahora, {FacturaSincronizada? factura}) => Ticket(
  id: '1a2b3c4d-0000-4000-8000-000000000015',
  numeroLocal: 15,
  mesaId: _mesa.id,
  nombreMesa: _mesa.nombre,
  comandaId: 'muestra',
  fechaHora: ahora,
  lineas: _lineasTicket(ahora),
  totales: _totales(),
  metodoPago: MetodoPago.efectivo,
  entregadoCents: 7000,
  camarero: _camarero,
  comensales: _comensales,
  factura: factura,
);

/// Precuenta nº 2 de la mesa 7 (maqueta (d)).
PrecuentaEmitida _precuenta(DateTime ahora) => PrecuentaEmitida(
  numero: 2,
  emitidaEn: ahora,
  comandaId: 'muestra',
  nombreMesa: _mesa.nombre,
  lineas: [
    for (final linea in _lineasTicket(ahora)) LineaPrecuenta.desde(linea),
  ],
  totales: _totales(),
  comensales: _comensales,
  emitidaPor: _camarero,
);

List<LineaComanda> _lineasTicket(DateTime ahora) => [
  _linea('t1', 'CANA', 'Caña', 2, 200, ahora),
  _linea('t2', 'CROQ', 'Croquetas de jamón', 1, 900, ahora),
  _linea('t3', 'CANA', 'Caña', 2, 200, ahora),
  _linea(
    't4',
    'ENTR',
    'Entrecot a la brasa',
    2,
    1900,
    ahora,
    nota: '1 poco hecho, 1 al punto',
  ),
  _linea(
    't5',
    'VINO',
    'Vino Rioja crianza (llevar)',
    1,
    1200,
    ahora,
    ivaBp: 2100,
  ),
];

/// Totales del ticket de muestra: 55,00 € al 10 % y 12,00 € al 21 %.
TotalesTicket _totales() => TotalesTicket(
  netoCents: 5992,
  ivaCents: 708,
  totalCents: _totalCents,
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

/// Comanda de la mesa 7 (maquetas (e)-(i)), abierta hace 50 minutos: el
/// envío nº 9 con las aceitunas y, 12 minutos después, el nº 12 con la
/// cocina en dos pases (los primeros, marchados) y la barra de la maqueta
/// (f).
Comanda _comandaMuestra(DateTime ahora) {
  final abierta = ahora.subtract(const Duration(minutes: 50));
  final envio12 = ahora.subtract(const Duration(minutes: 38));
  const barra = DestinoPreparacion.barra;
  return Comanda(
    id: 'muestra',
    mesaId: _mesa.id,
    abiertaEn: abierta,
    camarero: _camarero,
    comensales: _comensales,
    lineas: [
      _linea('c1', 'ACEI', 'Aceitunas', 1, 300, abierta, envio: 9),
      _linea('c2', 'PANT', 'Pan con tomate', 1, 250, envio12, envio: 12),
      _linea(
        'c3',
        'CROQ',
        'Croquetas de jamón',
        2,
        900,
        envio12,
        pase: 1,
        envio: 12,
      ),
      _linea(
        'c4',
        'ENSA',
        'Ensalada de ventresca',
        1,
        1200,
        envio12,
        pase: 1,
        envio: 12,
        nota: 'sin cebolla',
      ),
      _linea('c5', 'SALM', 'Salmorejo', 1, 800, envio12, pase: 1, envio: 12),
      _linea(
        'c6',
        'ENTR',
        'Entrecot a la brasa',
        2,
        1900,
        envio12,
        pase: 2,
        envio: 12,
        nota: '1 poco hecho, 1 al punto',
      ),
      _linea(
        'c7',
        'LUBI',
        'Lubina a la sal',
        1,
        2100,
        envio12,
        pase: 2,
        envio: 12,
        nota: 'sin sal',
      ),
      _linea('c8', 'CANA', 'Caña', 4, 200, envio12, destino: barra, envio: 12),
      _linea(
        'c9',
        'AGUA',
        'Agua con gas',
        1,
        200,
        envio12,
        destino: barra,
        envio: 12,
      ),
      _linea(
        'c10',
        'TINT',
        'Tinto de verano',
        1,
        350,
        envio12,
        destino: barra,
        envio: 12,
        nota: 'con limón',
      ),
    ],
    marchas: [
      MarchaPase(
        id: 'muestra-marcha-1',
        pase: 1,
        cuando: envio12,
        camarero: _camarero,
        automatica: true,
      ),
    ],
  );
}

LineaComanda _linea(
  String id,
  String referencia,
  String descripcion,
  double cantidad,
  int pvpUnitarioCents,
  DateTime creadaEn, {
  int ivaBp = 1000,
  DestinoPreparacion destino = DestinoPreparacion.cocina,
  int? pase,
  int? envio,
  String? nota,
}) => LineaComanda(
  id: 'muestra-$id',
  referencia: referencia,
  descripcion: descripcion,
  cantidad: cantidad,
  pvpUnitarioCents: pvpUnitarioCents,
  // Precio sin IVA en euros, como lo guarda el ERP (no se imprime).
  pvpUnitarioNeto: pvpUnitarioCents / (100 + ivaBp / 100),
  ivaBp: ivaBp,
  codimpuesto: ivaBp == 2100 ? 'IVA21' : 'IVA10',
  nota: nota,
  destino: destino,
  camarero: _camarero,
  creadaEn: creadaEn,
  pase: pase,
  envio: envio,
);
