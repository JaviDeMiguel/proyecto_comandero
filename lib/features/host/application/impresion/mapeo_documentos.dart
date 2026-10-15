/// Mapeo del dominio a los DTOs de impresión (§5.2-§5.10 y §5.13 del diseño
/// de impresión): funciones puras, sin estado ni reloj propio, que usan los
/// colaboradores de impresión del host, las muestras y la interfaz (por
/// ejemplo, para explicar por qué no se puede imprimir una factura).
///
/// - Documentos de cliente: [datosProvisional], [datosFactura] y
///   [datosPrecuenta], con las líneas consolidadas ([consolidarLineas]) y las
///   letras de IVA ([lineasYDesglose]); la cabecera del emisor sale de
///   [componerCabecera] y [motivoNoImprimible] dice si la factura se puede
///   imprimir.
/// - Documentos de preparación: [datosComanda], [datosMarchar],
///   [datosAnulacion] y [datosReimpresion], con el avance inicial del perfil
///   de la impresora (`perfil.lineasIniciales`).
library;

import '../../../../core/errors/app_exception.dart';
import '../../../../core/isolates/escpos/ticket_documents.dart';
import '../../../../core/money/money.dart';
import '../../../impresion/domain/formato_impresion.dart';
import '../../../sala/domain/comanda.dart';
import '../../../sala/domain/linea_comanda.dart';
import '../../../sala/domain/marcha_pase.dart';
import '../../../sala/domain/mesa.dart';
import '../../../sala/domain/pases.dart';
import '../../../sala/domain/precuenta_emitida.dart';
import '../../../sala/domain/ticket.dart';
import '../../domain/empresa_emisora.dart';

/// Título del documento provisional del cobro (en banda).
const String tituloProvisional = 'DOCUMENTO PROVISIONAL';

/// Título de la factura simplificada.
const String tituloFactura = 'FACTURA SIMPLIFICADA';

/// Caracteres del id del ticket en la referencia corta («TPV-1a2b3c4d»).
const int _caracteresReferencia = 8;

/// Qué líneas se reimprimen (§5.10).
enum AlcanceReimpresion {
  /// Todas las líneas activas de la comanda.
  todo,

  /// El último bloque de envío, sin las anuladas.
  ultimoEnvio,
}

/// Por qué se reimprime una comanda: lo elige quien reimprime, sin valor por
/// defecto, y viaja en la banda (decisión D.3).
enum MotivoReimpresion {
  /// La comanda no llegó al puesto o se perdió sin prepararse.
  noSalio(banda: 'REIMPRESIÓN · PREPARAR', etiqueta: 'No salió / se perdió'),

  /// Copia de control de algo que ya está en marcha.
  copia(banda: 'COPIA · NO PREPARAR', etiqueta: 'Copia para el puesto');

  const MotivoReimpresion({required this.banda, required this.etiqueta});

  /// Texto de la banda de la reimpresión.
  final String banda;

  /// Texto de la opción en el diálogo de reimprimir.
  final String etiqueta;
}

/// Línea de venta lista para consolidar: la de un ticket ([lineaVentaDe]) o
/// la de una precuenta ([lineaVentaDePrecuenta]).
typedef LineaVenta = ({
  String? referencia,
  String descripcion,
  double cantidad,
  int pvpUnitarioCents,
  int importeCents,
  int ivaBp,
  String? codimpuesto,
  String? nota,
});

// ---------------------------------------------------------------------------
// Textos sueltos

/// Título del puesto en las comandas: `COCINA` o `BARRA`.
String tituloPuesto(DestinoPreparacion destino) => switch (destino) {
  DestinoPreparacion.cocina => 'COCINA',
  DestinoPreparacion.barra => 'BARRA',
};

/// Nombre de la mesa tal como se imprime: tal cual («Mesa 7», «Terraza 3») y,
/// si son solo dígitos, con el prefijo «Mesa» («Mesa 7»). Es la misma regla
/// que aplican los generadores, para las descripciones de los trabajos.
String etiquetaMesa(String nombre) {
  final texto = nombre.trim();
  return RegExp(r'^\d+$').hasMatch(texto) ? 'Mesa $texto' : texto;
}

/// Texto impreso de cada forma de cobro.
String formaDePago(MetodoPago metodo) => switch (metodo) {
  MetodoPago.efectivo => 'Efectivo',
  MetodoPago.tarjeta => 'Tarjeta',
};

/// Referencia corta del ticket («TPV-1a2b3c4d»): el principio de
/// `Ticket.claveFactura` (el `numero2` de la factura), así que en
/// FacturaScripts se encuentra filtrando `numero2` por «contiene».
String referenciaCorta(Ticket ticket) {
  final clave = ticket.claveFactura;
  final longitud = clave.length - ticket.id.length + _caracteresReferencia;
  return clave.length <= longitud ? clave : clave.substring(0, longitud);
}

/// Motivo de anulación impreso: `'vaciar'` es «mesa vaciada»; sin motivo,
/// `null`.
String? motivoTexto(LineaComanda linea) =>
    switch (linea.motivoAnulacion?.trim()) {
      null || '' => null,
      'vaciar' => 'mesa vaciada',
      final String texto => texto,
    };

/// Observaciones al pie de un documento de preparación: el aviso de
/// impresora de respaldo («Sin impresora de barra: llevar a barra») y, si se
/// pasan, las observaciones de la comanda; `null` si no hay ninguna.
String? observacionesPuesto(
  DestinoPreparacion destino, {
  required bool respaldo,
  String? deLaComanda,
}) {
  final puesto = tituloPuesto(destino).toLowerCase();
  final comanda = _texto(deLaComanda);
  final partes = [
    if (respaldo) 'Sin impresora de $puesto: llevar a $puesto',
    ?comanda,
  ];
  return partes.isEmpty ? null : partes.join(' · ');
}

// ---------------------------------------------------------------------------
// Líneas de venta

/// Línea de un ticket como línea de venta.
LineaVenta lineaVentaDe(LineaComanda linea) => (
  referencia: linea.referencia,
  descripcion: linea.descripcion,
  cantidad: linea.cantidad,
  pvpUnitarioCents: linea.pvpUnitarioCents,
  importeCents: linea.importeCents,
  ivaBp: linea.ivaBp,
  codimpuesto: linea.codimpuesto,
  nota: linea.nota,
);

/// Línea de una precuenta registrada como línea de venta.
LineaVenta lineaVentaDePrecuenta(LineaPrecuenta linea) => (
  referencia: linea.referencia,
  descripcion: linea.descripcion,
  cantidad: linea.cantidad,
  pvpUnitarioCents: linea.pvpUnitarioCents,
  importeCents: linea.importeCents,
  ivaBp: linea.ivaBp,
  codimpuesto: linea.codimpuesto,
  nota: linea.nota,
);

/// Junta las líneas iguales sumando cantidad e importe, en el orden en que
/// aparece cada una por primera vez. Son iguales si coinciden `referencia`,
/// `descripcion`, `pvpUnitarioCents`, `ivaBp` y `codimpuesto` y, con
/// [conNotas], también la nota (sin espacios alrededor). El IVA va en la
/// clave porque el host lo fija al aceptar cada línea: el mismo artículo
/// antes y después de un cambio de IVA no se junta. Sin [conNotas] las notas
/// no salen.
List<LineaVenta> consolidarLineas(
  Iterable<LineaVenta> lineas, {
  required bool conNotas,
}) {
  final indices = <Object, int>{};
  final resultado = <LineaVenta>[];
  for (final linea in lineas) {
    final nota = conNotas ? _texto(linea.nota) : null;
    final clave = (
      linea.referencia,
      linea.descripcion,
      linea.pvpUnitarioCents,
      linea.ivaBp,
      linea.codimpuesto,
      nota,
    );
    final indice = indices[clave];
    if (indice == null) {
      indices[clave] = resultado.length;
      resultado.add(
        _conCantidad(linea, linea.cantidad, linea.importeCents, nota),
      );
    } else {
      final previa = resultado[indice];
      resultado[indice] = _conCantidad(
        previa,
        previa.cantidad + linea.cantidad,
        previa.importeCents + linea.importeCents,
        nota,
      );
    }
  }
  return List.unmodifiable(resultado);
}

LineaVenta _conCantidad(
  LineaVenta linea,
  double cantidad,
  int importeCents,
  String? nota,
) => (
  referencia: linea.referencia,
  descripcion: linea.descripcion,
  cantidad: cantidad,
  pvpUnitarioCents: linea.pvpUnitarioCents,
  importeCents: importeCents,
  ivaBp: linea.ivaBp,
  codimpuesto: linea.codimpuesto,
  nota: nota,
);

/// Líneas consolidadas ([consolidarLineas]) y desglose de IVA de un
/// documento de cliente, con la letra de cada tipo en ambos (`letrasIva`:
/// solo con dos o más tipos, «A» el menor).
({List<LineaTicket> lineas, List<DesgloseIvaTicketPrint> desglose})
lineasYDesglose(
  Iterable<LineaVenta> lineas,
  List<DesgloseIva> desglose, {
  required bool conNotas,
}) {
  final consolidadas = consolidarLineas(lineas, conNotas: conNotas);
  final letras = letrasIva([
    for (final linea in consolidadas) linea.ivaBp,
    for (final iva in desglose) iva.ivaBp,
  ]);
  return (
    lineas: List.unmodifiable([
      for (final linea in consolidadas)
        LineaTicket(
          descripcion: linea.descripcion,
          cantidad: linea.cantidad,
          pvpUnitarioCents: linea.pvpUnitarioCents,
          importeCents: linea.importeCents,
          nota: linea.nota,
          letraIva: letras[linea.ivaBp],
        ),
    ]),
    desglose: List.unmodifiable([
      for (final iva in desglose)
        DesgloseIvaTicketPrint(
          ivaPct: basisPointsToPercent(iva.ivaBp),
          baseCents: iva.baseCents,
          cuotaCents: iva.cuotaCents,
          letra: letras[iva.ivaBp],
        ),
    ]),
  );
}

// ---------------------------------------------------------------------------
// Emisor y factura

/// Cabecera del emisor de los documentos de cliente (§5.13):
///
/// - [empresaAjustes] (`HostSettings.empresa`, solo en tests) manda tal cual;
/// - si no, la empresa del ERP en caché ([empresaErp]): razón social, NIF,
///   dirección, localidad, teléfono y web; como nombre comercial, el del
///   [formato] o, si no hay, el `nombrecorto` cuando es distinto de la razón
///   social; y el pie del [formato];
/// - sin ninguna de las dos, el nombre comercial del [formato] o, si no hay,
///   [nombreTpv], con el pie del [formato].
///
/// Los textos vacíos o de solo espacios se tratan como ausentes.
EmpresaTicket componerCabecera({
  EmpresaTicket? empresaAjustes,
  EmpresaEmisora? empresaErp,
  required FormatoTicket formato,
  required String nombreTpv,
}) {
  if (empresaAjustes != null) return empresaAjustes;
  final comercial = _texto(formato.nombreComercial);
  final pie = _texto(formato.pie);
  final erp = empresaErp;
  if (erp == null) {
    return EmpresaTicket(nombre: comercial ?? nombreTpv, pie: pie);
  }
  final nombre = erp.nombre.trim();
  final corto = _texto(erp.nombrecorto);
  final cortoDistinto =
      corto != null && corto.toUpperCase() != nombre.toUpperCase()
      ? corto
      : null;
  return EmpresaTicket(
    nombre: nombre,
    nombreComercial: comercial ?? cortoDistinto,
    cifnif: _texto(erp.cifnif),
    direccion: _texto(erp.direccion),
    codpostal: _texto(erp.codpostal),
    ciudad: _texto(erp.ciudad),
    provincia: _texto(erp.provincia),
    telefono: _texto(erp.telefono),
    web: _texto(erp.web),
    pie: pie,
  );
}

/// Por qué no se puede imprimir la factura simplificada del [ticket] con la
/// [cabecera] dada, o `null` si se puede (§5.5, paso 2). En este orden: sin
/// número de FacturaScripts, sin la fecha o el total de FS, con un total de
/// FS distinto del del ticket y sin NIF del emisor. Nunca se sustituyen la
/// fecha ni el total de FS por los del ticket.
String? motivoNoImprimible(Ticket ticket, EmpresaTicket cabecera) {
  final factura = ticket.factura;
  final codigo = _texto(factura?.codigo);
  if (factura == null ||
      factura.estado != EstadoSincronizacion.sincronizado ||
      codigo == null) {
    return 'La factura del ticket nº ${ticket.numeroLocal} aún no tiene '
        'número de FacturaScripts';
  }
  final totalFs = factura.totalFsCents;
  if (factura.fecha == null || totalFs == null) {
    return 'La factura $codigo no tiene la fecha o el total de FacturaScripts '
        '(se sincronizó con una versión anterior): imprímela desde '
        'FacturaScripts';
  }
  if (totalFs != ticket.totalCents) {
    return 'El total de la factura $codigo en FacturaScripts '
        '(${formatCents(totalFs)}) no coincide con el del ticket '
        '(${formatCents(ticket.totalCents)}): revísala en el ERP';
  }
  if (_texto(cabecera.cifnif) == null) {
    return 'Falta el NIF del emisor: actualiza los datos de la empresa en '
        '«Tickets y comandas»';
  }
  return null;
}

// ---------------------------------------------------------------------------
// Documentos de cliente

/// Documento provisional del cobro (§5.3, maqueta (a)): nº local, referencia
/// corta, mesa con su [zona], camarero según el ajuste, líneas consolidadas
/// con letras de IVA (notas según el ajuste), cobro y papel del [perfil].
/// Con [abrirCajon], el pulso del cajón va justo tras el `init`; [avisos]
/// lleva, por ejemplo, «COPIA» en una reimpresión. Nunca lleva avance
/// inicial ni QR.
TicketPrintData datosProvisional(
  Ticket ticket, {
  required EmpresaTicket cabecera,
  required FormatoTicket formato,
  required PerfilImpresora perfil,
  String? zona,
  bool abrirCajon = false,
  List<String> avisos = const [],
  bool muestra = false,
}) {
  final venta = _ventaDelTicket(ticket, formato);
  final cobro = _cobro(ticket);
  return TicketPrintData(
    empresa: cabecera,
    tituloDocumento: tituloProvisional,
    provisional: true,
    numeroLocal: _positivo(ticket.numeroLocal),
    numero2: referenciaCorta(ticket),
    fechaHora: ticket.fechaHora,
    mesa: ticket.nombreMesa,
    zona: zona,
    camarero: formato.mostrarCamarero ? ticket.camarero : null,
    lineas: venta.lineas,
    desglose: venta.desglose,
    totalCents: ticket.totalCents,
    metodoPago: cobro.metodoPago,
    pagos: cobro.pagos,
    entregadoCents: cobro.entregadoCents,
    cambioCents: cobro.cambioCents,
    avisos: avisos,
    ivaIncluido: formato.ivaIncluido,
    muestra: muestra,
    paper: perfil.papel,
    abrirCajon: abrirCajon,
  );
}

/// Factura simplificada (§5.5, maquetas (b) y (c)): el código, la fecha de
/// expedición y el total de FacturaScripts, la fecha de la operación (el
/// generador solo la imprime si es de otro día), el nº local y la mesa, el
/// camarero según el ajuste, las líneas y el cobro como en el provisional, el
/// QR ([qrUrl] y [qrLeyenda], los guardados con el ORIGINAL) y, en un
/// DUPLICADO, su [duplicado]. Sin referencia (`numero2`), sin zona y sin
/// cajón. Solo se llama si [motivoNoImprimible] es nulo; [reglaQr] es para la
/// factura de muestra. Sin el número, la fecha o el total de FS lanza
/// [ValidationException] con el motivo: nunca toma los del ticket (§3.9).
TicketPrintData datosFactura(
  Ticket ticket, {
  required EmpresaTicket cabecera,
  required FormatoTicket formato,
  required PerfilImpresora perfil,
  String? qrUrl,
  String? qrLeyenda,
  DuplicadoPrint? duplicado,
  List<String> avisos = const [],
  bool muestra = false,
  bool reglaQr = false,
}) {
  final factura = ticket.factura;
  final fecha = factura?.fecha;
  final totalFs = factura?.totalFsCents;
  if (fecha == null || totalFs == null || _texto(factura?.codigo) == null) {
    // Es una de las dos primeras causas de motivoNoImprimible: su texto.
    throw ValidationException(motivoNoImprimible(ticket, cabecera)!);
  }
  final venta = _ventaDelTicket(ticket, formato);
  final cobro = _cobro(ticket);
  return TicketPrintData(
    empresa: cabecera,
    tituloDocumento: tituloFactura,
    codigoFactura: factura?.codigo,
    numeroLocal: _positivo(ticket.numeroLocal),
    fechaHora: ticket.fechaHora,
    fechaExpedicion: fecha,
    fechaOperacion: ticket.fechaHora,
    mesa: ticket.nombreMesa,
    camarero: formato.mostrarCamarero ? ticket.camarero : null,
    lineas: venta.lineas,
    desglose: venta.desglose,
    totalCents: totalFs,
    metodoPago: cobro.metodoPago,
    pagos: cobro.pagos,
    entregadoCents: cobro.entregadoCents,
    cambioCents: cobro.cambioCents,
    avisos: avisos,
    qrUrl: qrUrl,
    qrLeyenda: qrLeyenda,
    duplicado: duplicado,
    ivaIncluido: formato.ivaIncluido,
    muestra: muestra,
    reglaQr: reglaQr,
    paper: perfil.papel,
  );
}

/// Precuenta desde su registro (§5.8, maqueta (d)): nº, hora y mesa del
/// registro, la [zona], quien la pidió como camarero y los comensales según
/// los ajustes, las líneas consolidadas con letras de IVA (notas según el
/// ajuste) y los totales de aquel momento. Sin QR, cajón ni avance.
PrecuentaPrintData datosPrecuenta(
  PrecuentaEmitida precuenta, {
  required EmpresaTicket cabecera,
  required FormatoTicket formato,
  required PerfilImpresora perfil,
  String? zona,
  bool muestra = false,
}) {
  final venta = lineasYDesglose(
    [for (final linea in precuenta.lineas) lineaVentaDePrecuenta(linea)],
    precuenta.totales.desglose,
    conNotas: formato.mostrarNotas,
  );
  return PrecuentaPrintData(
    empresa: cabecera,
    fechaHora: precuenta.emitidaEn,
    mesa: precuenta.nombreMesa,
    numero: _positivo(precuenta.numero),
    zona: zona,
    camarero: formato.mostrarCamarero ? precuenta.emitidaPor : null,
    comensales: formato.mostrarComensales
        ? _positivo(precuenta.comensales)
        : null,
    lineas: venta.lineas,
    desglose: venta.desglose,
    totalCents: precuenta.totalCents,
    ivaIncluido: formato.ivaIncluido,
    muestra: muestra,
    paper: perfil.papel,
  );
}

// ---------------------------------------------------------------------------
// Documentos de preparación

/// Comanda de un envío en un puesto (§5.2, maquetas (e) y (f)): el título
/// del puesto, la mesa y su zona, los comensales, el camarero del envío (o
/// el de la comanda), el nº de envío, el ordinal del bloque de envío de
/// [lineas] en la comanda, la apertura de la mesa, las líneas agrupadas por
/// pase con ESPERAR en los no marchados (solo con los pases activos) y las
/// observaciones de respaldo y de la comanda. [ahora] es la hora de
/// aceptación.
KitchenOrderPrintData datosComanda(
  Mesa mesa,
  Comanda comanda,
  List<LineaComanda> lineas, {
  required DestinoPreparacion destino,
  required PasesConfig pases,
  required PerfilImpresora perfil,
  required DateTime ahora,
  bool respaldo = false,
  bool muestra = false,
}) => KitchenOrderPrintData(
  titulo: tituloPuesto(destino),
  mesa: mesa.nombre,
  zona: mesa.zona,
  comensales: _positivo(comanda.comensales),
  camarero: lineas.firstOrNull?.camarero ?? comanda.camarero,
  numeroComanda: lineas.firstOrNull?.envio?.toString(),
  fechaHora: ahora,
  ordinalEnvio: _ordinalEnvio(comanda, lineas.firstOrNull),
  abiertaEn: comanda.abiertaEn,
  lineas: _lineasConPases(comanda, lineas, pases),
  observaciones: observacionesPuesto(
    destino,
    respaldo: respaldo,
    deLaComanda: comanda.observaciones,
  ),
  avanceInicial: perfil.lineasIniciales,
  muestra: muestra,
  paper: perfil.papel,
);

/// MARCHAR de un pase en un puesto (§5.7, maquetas (g) y (g2)): el pase y su
/// nombre («Pase N» fuera de la configuración), REPETIDO con la hora de la
/// marcha anterior de ese pase, los envíos distintos de [lineas] y la hora
/// en que se pidieron, la hora y el camarero de la [marcha], los comensales,
/// las líneas con sus notas y el aviso de respaldo.
MarcharPrintData datosMarchar(
  Mesa mesa,
  Comanda comanda,
  MarchaPase marcha,
  List<LineaComanda> lineas, {
  required DestinoPreparacion destino,
  required PasesConfig pases,
  required PerfilImpresora perfil,
  bool respaldo = false,
  bool muestra = false,
}) => MarcharPrintData(
  titulo: tituloPuesto(destino),
  mesa: mesa.nombre,
  zona: mesa.zona,
  pase: marcha.pase,
  nombrePase: pases.nombreDe(marcha.pase),
  repetida: marcha.repetida,
  ultimaMarchaEn: _marchaAnterior(comanda, marcha)?.cuando,
  numerosComanda: List.unmodifiable(
    {for (final linea in lineas) ?linea.envio}.toList()..sort(),
  ),
  pedidaEn: _pedidaEn(lineas),
  fechaHora: marcha.cuando,
  camarero: marcha.camarero,
  comensales: _positivo(comanda.comensales),
  lineas: List.unmodifiable([
    for (final linea in lineas)
      LineaComandaPrint(
        cantidad: linea.cantidad,
        descripcion: linea.descripcion,
        nota: linea.nota,
      ),
  ]),
  observaciones: observacionesPuesto(destino, respaldo: respaldo),
  avanceInicial: perfil.lineasIniciales,
  muestra: muestra,
  paper: perfil.papel,
);

/// Anulación en un puesto (§5.9, maqueta (h)): el título en banda, la mesa,
/// los envíos de las líneas, el camarero de la comanda, la hora de la
/// anulación ([ahora]) y, por línea, la cantidad (el generador la imprime en
/// negativo), la nota original, el motivo, el envío y la hora en que se pidió.
KitchenOrderPrintData datosAnulacion(
  Mesa mesa,
  Comanda comanda,
  List<LineaComanda> anuladas, {
  required DestinoPreparacion destino,
  required PerfilImpresora perfil,
  required DateTime ahora,
  bool respaldo = false,
  bool muestra = false,
}) => KitchenOrderPrintData(
  titulo: 'ANULACIÓN ${tituloPuesto(destino)}',
  tituloEnBanda: true,
  mesa: mesa.nombre,
  zona: mesa.zona,
  camarero: comanda.camarero,
  numeroComanda: _unidos(
    {for (final linea in anuladas) ?linea.envio}.toList()..sort(),
  ),
  fechaHora: ahora,
  lineas: List.unmodifiable([
    for (final linea in anuladas)
      LineaComandaPrint(
        cantidad: linea.cantidad,
        descripcion: linea.descripcion,
        anulada: true,
        nota: linea.nota,
        motivo: motivoTexto(linea),
        envio: linea.envio,
        pedidaEn: linea.creadaEn,
      ),
  ]),
  observaciones: observacionesPuesto(destino, respaldo: respaldo),
  avanceInicial: perfil.lineasIniciales,
  muestra: muestra,
  paper: perfil.papel,
);

/// Reimpresión de [lineas] en un puesto (§5.10, maqueta (i)): como la
/// comanda, con la banda del [motivo], la fecha y hora de [ahora] y el
/// [dispositivo] («Reimpresa 09/10/2026 21:40 · Caja 1»), los números de los
/// bloques de envío de esas líneas en orden («12, 15»; sin número las de un
/// diario anterior), el ordinal solo si son de un único bloque, la hora del
/// primer pedido y ESPERAR según las marchas actuales.
KitchenOrderPrintData datosReimpresion(
  Mesa mesa,
  Comanda comanda,
  List<LineaComanda> lineas, {
  required DestinoPreparacion destino,
  required PasesConfig pases,
  required PerfilImpresora perfil,
  required MotivoReimpresion motivo,
  required String dispositivo,
  required DateTime ahora,
  bool respaldo = false,
  bool muestra = false,
}) {
  final bloques = comanda.bloquesDeEnvio;
  final indices = _indicesDeBloques(bloques, lineas);
  return KitchenOrderPrintData(
    titulo: tituloPuesto(destino),
    mesa: mesa.nombre,
    zona: mesa.zona,
    comensales: _positivo(comanda.comensales),
    camarero: lineas.firstOrNull?.camarero ?? comanda.camarero,
    // Un conjunto conserva el orden de inserción: los números van en el
    // orden de los bloques y sin repetirse.
    numeroComanda: _unidos(
      {for (final i in indices) ?bloques[i].envio}.toList(),
    ),
    fechaHora: _pedidaEn(lineas) ?? ahora,
    ordinalEnvio: indices.length == 1 ? indices.single + 1 : null,
    abiertaEn: comanda.abiertaEn,
    banner: motivo.banda,
    bannerDetalle: ['Reimpresa ${_fechaHora(ahora)} · $dispositivo'],
    lineas: _lineasConPases(comanda, lineas, pases),
    observaciones: observacionesPuesto(
      destino,
      respaldo: respaldo,
      deLaComanda: comanda.observaciones,
    ),
    avanceInicial: perfil.lineasIniciales,
    muestra: muestra,
    paper: perfil.papel,
  );
}

/// Líneas que se reimprimen con cada [alcance]: con `todo`, las activas; con
/// `ultimoEnvio`, el último bloque de envío sin las anuladas (así no lo
/// confunde el reinicio del número en el Cierre Z).
List<LineaComanda> lineasAReimprimir(
  Comanda comanda,
  AlcanceReimpresion alcance,
) => List.unmodifiable(switch (alcance) {
  AlcanceReimpresion.todo => comanda.lineasActivas,
  AlcanceReimpresion.ultimoEnvio => comanda.lineasUltimoEnvio.where(
    (linea) => !linea.anulada,
  ),
});

// ---------------------------------------------------------------------------
// Internos

/// Líneas y desglose de un ticket con las notas según el ajuste.
({List<LineaTicket> lineas, List<DesgloseIvaTicketPrint> desglose})
_ventaDelTicket(Ticket ticket, FormatoTicket formato) => lineasYDesglose(
  [for (final linea in ticket.lineas) lineaVentaDe(linea)],
  ticket.totales.desglose,
  conNotas: formato.mostrarNotas,
);

/// Bloque de cobro del ticket: «Mixto» con un pago por forma si el cobro es
/// mixto; el entregado y el cambio solo si se anotó lo entregado.
({
  String metodoPago,
  List<PagoTicketPrint> pagos,
  int? entregadoCents,
  int? cambioCents,
})
_cobro(Ticket ticket) => (
  metodoPago: ticket.esMixto ? 'Mixto' : formaDePago(ticket.metodoPago),
  pagos: List.unmodifiable([
    if (ticket.esMixto)
      for (final pago in ticket.pagos)
        PagoTicketPrint(
          formaPago: formaDePago(pago.metodo),
          importeCents: pago.importeCents,
        ),
  ]),
  entregadoCents: ticket.entregadoCents,
  cambioCents: ticket.entregadoCents == null ? null : ticket.cambioCents,
);

/// Líneas de preparación: con los pases activos, en el orden de
/// `agruparPorPase`, con el nombre de cada pase y ESPERAR en los no
/// marchados; sin pases, planas.
List<LineaComandaPrint> _lineasConPases(
  Comanda comanda,
  List<LineaComanda> lineas,
  PasesConfig pases,
) {
  if (!pases.activos) {
    return List.unmodifiable([
      for (final linea in lineas)
        LineaComandaPrint(
          cantidad: linea.cantidad,
          descripcion: linea.descripcion,
          nota: linea.nota,
        ),
    ]);
  }
  final marchados = comanda.pasesMarchados;
  return List.unmodifiable([
    for (final grupo in agruparPorPase(lineas))
      for (final linea in grupo.lineas)
        LineaComandaPrint(
          cantidad: linea.cantidad,
          descripcion: linea.descripcion,
          nota: linea.nota,
          pase: grupo.pase,
          nombrePase: switch (grupo.pase) {
            final int pase => pases.nombreDe(pase),
            null => null,
          },
          esperar: grupo.pase != null && !marchados.contains(grupo.pase),
        ),
  ]);
}

/// Ordinal (base 1) del bloque de envío que contiene [linea]; si no está en
/// la comanda, el número de bloques (el envío recién aceptado es el último).
int? _ordinalEnvio(Comanda comanda, LineaComanda? linea) {
  if (linea == null) return null;
  final bloques = comanda.bloquesDeEnvio;
  for (var i = 0; i < bloques.length; i++) {
    if (bloques[i].lineas.any((l) => l.id == linea.id)) return i + 1;
  }
  return bloques.isEmpty ? null : bloques.length;
}

/// Índices, en orden, de los [bloques] de envío con alguna de [lineas].
List<int> _indicesDeBloques(
  List<BloqueEnvio> bloques,
  List<LineaComanda> lineas,
) {
  final ids = {for (final linea in lineas) linea.id};
  return [
    for (var i = 0; i < bloques.length; i++)
      if (bloques[i].lineas.any((l) => ids.contains(l.id))) i,
  ];
}

/// La marcha anterior a [marcha] del mismo pase.
MarchaPase? _marchaAnterior(Comanda comanda, MarchaPase marcha) {
  MarchaPase? anterior;
  for (final otra in comanda.marchas) {
    if (otra.id == marcha.id) break;
    if (otra.pase == marcha.pase) anterior = otra;
  }
  return anterior;
}

/// La hora más temprana en que se pidieron [lineas].
DateTime? _pedidaEn(List<LineaComanda> lineas) {
  DateTime? primera;
  for (final linea in lineas) {
    final creada = linea.creadaEn;
    if (primera == null || creada.isBefore(primera)) primera = creada;
  }
  return primera;
}

/// Números unidos con coma («12, 15»), o `null` si no hay ninguno.
String? _unidos(List<int> numeros) =>
    numeros.isEmpty ? null : numeros.join(', ');

/// El valor si es positivo; un valor no positivo (diario corrupto) no debe
/// impedir que el documento se imprima.
int? _positivo(int? valor) => valor != null && valor > 0 ? valor : null;

/// Texto sin espacios alrededor, o `null` si queda vacío.
String? _texto(String? valor) {
  final texto = valor?.trim();
  return texto == null || texto.isEmpty ? null : texto;
}

String _dos(int valor) => valor.toString().padLeft(2, '0');

/// «09/10/2026 21:40».
String _fechaHora(DateTime d) =>
    '${_dos(d.day)}/${_dos(d.month)}/${d.year} ${_dos(d.hour)}:'
    '${_dos(d.minute)}';
