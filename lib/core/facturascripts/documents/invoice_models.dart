/// Modelos de la factura simplificada de un ticket (`FsInvoiceService`).
library;

import 'package:equatable/equatable.dart';

import '../../errors/app_exception.dart';
import 'fs_idempotency_key.dart';

/// Cómo queda cobrada la factura en FacturaScripts.
enum ModoPago {
  /// La forma de pago (`formapagos.pagado = true`) hace que el recibo nazca
  /// cobrado con la fecha del ticket: no hay que enviar nada más.
  nacePagada,

  /// La forma de pago no nace pagada: tras crear se llama a
  /// `pagarFacturaCliente/{id}` con `fechapago` y `codpago` del ticket.
  pagarTrasCrear,
}

/// Una parte del cobro de un ticket con una forma de pago de FacturaScripts
/// (cobro mixto: p. ej. 12,35 € con `TPVEFE` y 7,60 € con `TPVTAR`).
final class PagoFactura extends Equatable {
  PagoFactura({
    required this.codpago,
    required this.importeCents,
    this.modoPago = ModoPago.pagarTrasCrear,
    this.efectivo = false,
  }) {
    if (codpago.trim().isEmpty) {
      throw const ValidationException('Un pago del ticket no tiene codpago');
    }
    if (importeCents < 0) {
      throw ValidationException(
        "Importe negativo en el pago con '$codpago': $importeCents céntimos",
      );
    }
  }

  final String codpago;
  final int importeCents;

  /// Cómo queda cobrada la factura si este pago acaba siendo el único (tras
  /// normalizar el plan). En el cobro mixto es informativo: la receta decide
  /// por el estado real de los recibos, no por `formapagos.pagado`.
  final ModoPago modoPago;

  /// Pago en efectivo: si el total de FacturaScripts difiere del del TPV, la
  /// diferencia se carga preferentemente a esta parte (se cuadra con el
  /// arqueo), nunca a la de tarjeta, que debe casar con el datáfono.
  final bool efectivo;

  @override
  List<Object?> get props => [codpago, importeCents, modoPago, efectivo];
}

/// Parte del plan de cobro ya normalizado: el recibo número [numero] de la
/// factura, con su forma de pago y su importe.
///
/// La clave de cada parte en FacturaScripts es `(idfactura, numero)`; como
/// el ERP no la protege con un UNIQUE, el TPV fija siempre el número y lee
/// los recibos antes de escribir.
final class ParteCobro extends Equatable {
  const ParteCobro({
    required this.numero,
    required this.codpago,
    required this.importeCents,
    this.modoPago = ModoPago.pagarTrasCrear,
    this.efectivo = false,
  });

  final int numero;
  final String codpago;
  final int importeCents;
  final ModoPago modoPago;

  /// Parte cobrada en efectivo (ver [PagoFactura.efectivo]).
  final bool efectivo;

  ParteCobro conImporte(int cents) => ParteCobro(
    numero: numero,
    codpago: codpago,
    importeCents: cents,
    modoPago: modoPago,
    efectivo: efectivo,
  );

  @override
  List<Object?> get props => [
    numero,
    codpago,
    importeCents,
    modoPago,
    efectivo,
  ];
}

/// Línea de la factura tal como la admite `crearFacturaCliente`.
final class LineaFactura extends Equatable {
  LineaFactura({
    this.referencia,
    required this.descripcion,
    required this.cantidad,
    required this.pvpunitarioNeto,
    required this.codimpuesto,
  }) {
    if (descripcion.trim().isEmpty) {
      throw const ValidationException(
        'La descripción de una línea de factura no puede estar vacía',
      );
    }
    if (!cantidad.isFinite || cantidad == 0) {
      throw ValidationException(
        "Cantidad no válida en la línea '$descripcion': $cantidad",
      );
    }
    if (!pvpunitarioNeto.isFinite) {
      throw ValidationException(
        "Precio no válido en la línea '$descripcion': $pvpunitarioNeto",
      );
    }
    if (codimpuesto.trim().isEmpty) {
      throw ValidationException(
        "La línea '$descripcion' no tiene código de impuesto",
      );
    }
  }

  /// `variantes.referencia` (o código de barras). `null` = línea libre: FS no
  /// toca stock y toma el impuesto de [codimpuesto].
  final String? referencia;
  final String descripcion;
  final double cantidad;

  /// Precio unitario SIN IVA. FacturaScripts trabaja con 5 decimales
  /// (`Producto::ROUND_DECIMALS`); se redondea a 5 al serializar.
  final double pvpunitarioNeto;

  /// El IVA se identifica siempre por código (`IVA10`), nunca por porcentaje:
  /// la API no admite `iva` en la línea.
  final String codimpuesto;

  /// Objeto JSON de la línea para el campo `lineas`. Solo claves que
  /// `applyLineFields` reconoce; las demás se ignoran en silencio.
  Map<String, Object?> toFsJson() => {
    if (referencia != null) 'referencia': referencia,
    'descripcion': descripcion,
    'cantidad': cantidad,
    'pvpunitario': double.parse(pvpunitarioNeto.toStringAsFixed(5)),
    'codimpuesto': codimpuesto,
  };

  @override
  List<Object?> get props => [
    referencia,
    descripcion,
    cantidad,
    pvpunitarioNeto,
    codimpuesto,
  ];
}

/// Ticket listo para convertirse en factura simplificada.
final class TicketFactura extends Equatable {
  /// [pagos] reparte el cobro entre varias formas de pago (cobro mixto). Sin
  /// él, el ticket se cobra entero con [codpago] y [modoPago], como siempre.
  /// Si se da, debe sumar [totalEsperadoCents].
  TicketFactura({
    required String claveIdempotente,
    required this.codcliente,
    required this.codserie,
    required this.codpago,
    required this.codalmacen,
    required this.fechaHora,
    this.observaciones,
    required this.lineas,
    required this.totalEsperadoCents,
    required this.modoPago,
    List<PagoFactura> pagos = const [],
    this.emitir = false,
    this.idEstadoEmitida,
  }) : claveIdempotente = validarClaveIdempotente(
         claveIdempotente,
         campo: 'numero2',
       ),
       pagos = List<PagoFactura>.unmodifiable(pagos),
       planCobro = List<ParteCobro>.unmodifiable(
         _normalizarPlan(codpago, modoPago, totalEsperadoCents, pagos),
       ) {
    if (pagos.isNotEmpty) {
      final suma = pagos.fold(0, (sum, pago) => sum + pago.importeCents);
      if (suma != totalEsperadoCents) {
        throw ValidationException(
          'Los pagos del ticket suman $suma céntimos y el total es '
          '$totalEsperadoCents',
        );
      }
    }
    if (lineas.isEmpty) {
      throw const ValidationException('El ticket no tiene líneas');
    }
    for (final (campo, valor) in [
      ('codcliente', codcliente),
      ('codserie', codserie),
      ('codpago', codpago),
      ('codalmacen', codalmacen),
    ]) {
      if (valor.trim().isEmpty) {
        throw ValidationException('El ticket no tiene $campo');
      }
    }
    if (emitir && idEstadoEmitida == null) {
      throw const ValidationException(
        'Para emitir la factura hace falta idEstadoEmitida (estado no '
        'editable "Emitida" leído de estadodocumentos)',
      );
    }
  }

  /// Clave guardada en `numero2` (≤ 50 caracteres, no parece una fecha).
  final String claveIdempotente;
  final String codcliente;

  /// Serie de tipo simplificada (p. ej. `S`).
  final String codserie;

  /// Forma de pago del ticket (efectivo o tarjeta). En un cobro mixto es la
  /// forma de pago de la cabecera (y del recibo número 1) si está entre los
  /// [pagos]; si no, manda la parte de mayor importe.
  final String codpago;
  final String codalmacen;

  /// Fecha y hora de negocio del ticket (hora local).
  final DateTime fechaHora;
  final String? observaciones;
  final List<LineaFactura> lineas;

  /// Total calculado por el TPV (réplica del `Calculator`). Si FacturaScripts
  /// devuelve otro total la factura NO se repite: se avisa.
  final int totalEsperadoCents;
  final ModoPago modoPago;

  /// Reparto del cobro tal como llegó (vacío: pago único con [codpago]).
  final List<PagoFactura> pagos;

  /// Plan de cobro normalizado: sin partes de 0 céntimos, con las de igual
  /// `codpago` fusionadas y numeradas desde 1 (el 1 es la forma de pago de
  /// la cabecera). Siempre tiene al menos una parte.
  final List<ParteCobro> planCobro;

  /// Pasar la factura al estado no editable "Emitida" tras cobrarla.
  final bool emitir;

  /// `idestado` del estado "Emitida" de esta instalación (nunca a fuego).
  final int? idEstadoEmitida;

  /// Tras normalizar quedan dos o más formas de pago: un recibo por cada una.
  bool get esCobroMixto => planCobro.length > 1;

  /// `codpago` que se envía en la cabecera de `crearFacturaCliente`.
  String get codpagoCabecera => planCobro.first.codpago;

  /// Modo de cobro del flujo de pago único (el de la parte que queda).
  ModoPago get modoPagoCabecera => planCobro.first.modoPago;

  static List<ParteCobro> _normalizarPlan(
    String codpago,
    ModoPago modoPago,
    int totalCents,
    List<PagoFactura> pagos,
  ) {
    // Fusiona por codpago conservando el orden de aparición.
    final importes = <String, int>{};
    final modos = <String, ModoPago>{};
    final efectivos = <String>{};
    for (final pago in pagos) {
      if (pago.importeCents == 0) continue;
      importes[pago.codpago] =
          (importes[pago.codpago] ?? 0) + pago.importeCents;
      modos.putIfAbsent(pago.codpago, () => pago.modoPago);
      if (pago.efectivo) efectivos.add(pago.codpago);
    }
    if (importes.isEmpty) {
      return [
        ParteCobro(
          numero: 1,
          codpago: codpago,
          importeCents: totalCents,
          modoPago: modoPago,
        ),
      ];
    }
    final orden = importes.keys.toList();
    var cabecera = orden.contains(codpago) ? codpago : null;
    if (cabecera == null) {
      cabecera = orden.first;
      for (final cod in orden.skip(1)) {
        if (importes[cod]! > importes[cabecera]!) cabecera = cod;
      }
    }
    orden
      ..remove(cabecera)
      ..insert(0, cabecera!);
    return [
      for (var i = 0; i < orden.length; i++)
        ParteCobro(
          numero: i + 1,
          codpago: orden[i],
          importeCents: importes[orden[i]]!,
          modoPago: modos[orden[i]]!,
          efectivo: efectivos.contains(orden[i]),
        ),
    ];
  }

  @override
  List<Object?> get props => [
    claveIdempotente,
    codcliente,
    codserie,
    codpago,
    codalmacen,
    fechaHora,
    observaciones,
    lineas,
    totalEsperadoCents,
    modoPago,
    pagos,
    emitir,
    idEstadoEmitida,
  ];
}

/// Recibo de la factura en FacturaScripts tras registrar el cobro.
final class ReciboFactura extends Equatable {
  ReciboFactura({
    required this.idrecibo,
    required this.numero,
    required this.codpago,
    required this.importeCents,
    required this.pagado,
    List<int> idpagos = const [],
    this.pagosCents = 0,
  }) : idpagos = List.unmodifiable(idpagos);

  final int idrecibo;
  final int numero;
  final String codpago;
  final int importeCents;
  final bool pagado;

  /// `pagoclientes` del recibo: uno solo si todo fue bien.
  final List<int> idpagos;

  /// Suma de los importes de esos pagos (debe igualar [importeCents]).
  final int pagosCents;

  @override
  List<Object?> get props => [
    idrecibo,
    numero,
    codpago,
    importeCents,
    pagado,
    idpagos,
    pagosCents,
  ];
}

/// Resultado de crear (o reanudar) la factura de un ticket.
///
/// La factura impresa y su QR usan [fecha] y [totalFsCents], que son siempre
/// los de FacturaScripts (o `null` si no los devolvió): nunca se sustituyen
/// por la fecha o el total del ticket.
final class ResultadoFactura extends Equatable {
  const ResultadoFactura({
    required this.idfactura,
    required this.codigo,
    required this.numero,
    required this.totalCents,
    required this.pagada,
    required this.idasiento,
    required this.emitida,
    required this.yaExistia,
    required this.avisos,
    this.recibos = const [],
    this.fecha,
    this.totalFsCents,
  });

  final int idfactura;

  /// Código legal (`F2026S7`); lo decide FacturaScripts.
  final String codigo;

  /// Número dentro de la serie. Llega como texto en los GET.
  final String numero;

  /// Fecha y hora de la factura en FacturaScripts (hora local). El ERP puede
  /// cambiarlas respecto a las del ticket al rellenar un hueco de numeración,
  /// por eso la factura impresa y su QR usan esta y no [TicketFactura.fechaHora].
  /// Sin `hora` en el ERP, las 00:00:00. `null` si FacturaScripts no devolvió
  /// la fecha ni al releer la factura.
  final DateTime? fecha;

  /// Total calculado por FacturaScripts, en céntimos; si el ERP no lo
  /// devolvió, el total del ticket. Para imprimir o para el QR usa
  /// [totalFsCents].
  final int totalCents;

  /// Total de la factura en FacturaScripts, en céntimos: el importe impreso y
  /// el del QR. `null` si el ERP no lo devolvió ni al releer la factura; a
  /// diferencia de [totalCents], nunca se rellena con el total del ticket.
  final int? totalFsCents;
  final bool pagada;

  /// Asiento de venta generado automáticamente; `null` si el ejercicio no
  /// tiene plan contable (la factura existe igualmente).
  final int? idasiento;

  /// `idestado` coincide con el estado "Emitida" pedido (o no se pidió emitir
  /// y vale `false`).
  final bool emitida;

  /// La factura ya existía en FacturaScripts (reanudación).
  final bool yaExistia;

  /// Discrepancias que no impiden dar la operación por hecha.
  final List<String> avisos;

  /// Recibos (con sus pagos) tras registrar un cobro mixto, por número.
  /// Vacío en el pago único: ese flujo no lee los recibos.
  final List<ReciboFactura> recibos;

  bool get conAvisos => avisos.isNotEmpty;

  /// La factura se cobró con varias formas de pago (un recibo por cada una).
  bool get cobroMixto => recibos.length > 1;

  @override
  List<Object?> get props => [
    idfactura,
    codigo,
    numero,
    fecha,
    totalCents,
    totalFsCents,
    pagada,
    idasiento,
    emitida,
    yaExistia,
    avisos,
    recibos,
  ];
}
