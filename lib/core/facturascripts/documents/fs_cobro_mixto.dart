/// Cobro mixto de una factura de cliente: un recibo por forma de pago.
///
/// FacturaScripts 2026.5 no tiene ningún parámetro para cobrar una factura
/// con varias formas de pago: `crearFacturaCliente` genera un único recibo
/// por el total con el `codpago` de la cabecera, y `pagarFacturaCliente`
/// con `codpago` reescribe la forma de pago de TODOS los recibos. El cobro
/// mixto se registra reconciliando los recibos (`reciboclientes`) con el plan
/// del TPV; cada recibo cobrado genera su `PagoCliente` y su asiento 57x/430
/// con la subcuenta de su propia forma de pago.
///
/// La receta (verificada en el sandbox, `research/fs_pagos_mixtos.md`) es
/// idempotente y reanudable: siempre LEE antes de escribir, y tras cualquier
/// fallo la siguiente ejecución vuelve a leer y completa lo que falte. Nunca
/// repite una escritura a ciegas: un POST de recibo repetido crearía un
/// recibo de más y un PUT `pagado=1` repetido, un segundo pago con asiento.
library;

import '../../errors/app_exception.dart';
import '../../logging/app_logger.dart';
import '../../money/money.dart';
import '../fs_api.dart';
import '../fs_resources.dart';
import '../fs_values.dart';
import 'invoice_models.dart';

/// Resultado de registrar (o comprobar) el cobro mixto de una factura.
final class CobroMixtoRegistrado {
  CobroMixtoRegistrado({
    required this.factura,
    required this.pagada,
    required List<ParteCobro> plan,
    required List<ReciboFactura> recibos,
    required this.escrituras,
  }) : plan = List.unmodifiable(plan),
       recibos = List.unmodifiable(recibos);

  /// Cabecera de la factura tal como quedó (último GET).
  final FsRecord factura;
  final bool pagada;

  /// Plan aplicado, ya ajustado al total de FacturaScripts.
  final List<ParteCobro> plan;
  final List<ReciboFactura> recibos;

  /// Peticiones de escritura hechas en esta pasada (`0` si ya estaba todo).
  final int escrituras;
}

/// Reconciliación de los recibos de una factura con su plan de cobro.
final class FsCobroMixto {
  FsCobroMixto(this._api);

  static const String _facturas = FsResources.facturaClientes;
  static const String _recibos = FsResources.reciboClientes;
  static const String _pagos = FsResources.pagoClientes;
  static const String _pagar = FsResources.pagarFacturaCliente;

  final FsApi _api;
  final Logger _log = appLogger('facturascripts.cobro_mixto');

  /// Deja la factura [idfactura] cobrada según [plan]: recibo `numero` con
  /// su `codpago` y su importe, todos pagados con fecha [fechaPago].
  ///
  /// Pasos: (1) lee la factura y sus recibos; (2) borra los recibos que
  /// sobran o no se pueden corregir (pagados con otro importe o forma) y
  /// ajusta los abiertos, primero los que reducen importe; (3) da de alta ya
  /// cobrados los que faltan; (4) si la factura sigue sin pagar, la cobra con
  /// `pagarFacturaCliente` SIN `codpago`; (5) verifica releyendo recibos y
  /// pagos. Las discrepancias que no corrige van a [avisos].
  ///
  /// Lanza [ValidationException] si el total de FacturaScripts no admite el
  /// plan (ninguna parte puede absorber la diferencia sin quedarse sin
  /// importe; ver [_ajustarAlTotal]) y [ErpApiException]
  /// ante cualquier fallo de la API (reintentable: vuelve a empezar leyendo).
  Future<CobroMixtoRegistrado> registrar({
    required int idfactura,
    required List<ParteCobro> plan,
    required DateTime fechaPago,
    required List<String> avisos,
  }) async {
    if (plan.isEmpty) {
      throw const ValidationException('El plan de cobro está vacío');
    }

    // 1. Estado real en el ERP.
    var factura = await _leerFactura(idfactura);
    final totalCents = centsFromDecimal(factura.fsRequireDouble('total'));
    final planFinal = _ajustarAlTotal(plan, totalCents, avisos);
    final porNumero = {for (final parte in planFinal) parte.numero: parte};
    final recibos = await _leerRecibos(idfactura);

    // 2. Reconciliación de los recibos existentes.
    final conservados = <int, _Recibo>{};
    final borrar = <_Recibo>[];
    final ajustar = <(_Recibo, ParteCobro)>[];
    final porNumeroExistente = <int, List<_Recibo>>{};
    for (final recibo in recibos) {
      porNumeroExistente.putIfAbsent(recibo.numero, () => []).add(recibo);
    }
    for (final MapEntry(key: numero, value: grupo)
        in porNumeroExistente.entries) {
      final parte = porNumero[numero];
      if (parte == null) {
        borrar.addAll(grupo);
        continue;
      }
      // Si hay duplicados del mismo número se conserva el que ya encaja o,
      // si no, el primero abierto (se puede corregir sin borrar cobros).
      final elegido =
          _primero(grupo, (r) => r.encaja(parte)) ??
          _primero(grupo, (r) => !r.pagado) ??
          grupo.first;
      for (final otro in grupo) {
        if (!identical(otro, elegido)) {
          borrar.add(otro);
          avisos.add(
            'Recibo n.º $numero duplicado (idrecibo ${otro.idrecibo}): '
            'se borra',
          );
        }
      }
      if (elegido.encaja(parte)) {
        conservados[numero] = elegido;
      } else if (!elegido.pagado) {
        ajustar.add((elegido, parte));
        conservados[numero] = elegido;
      } else {
        // Un recibo pagado no admite otro importe (FS responde 400) y su
        // forma de pago ya está contabilizada: se borra con su pago y su
        // asiento y se vuelve a crear bien.
        borrar.add(elegido);
      }
    }

    var escrituras = 0;
    for (final recibo in borrar) {
      _log.fine(
        'Factura $idfactura: borrando recibo ${recibo.idrecibo} '
        '(n.º ${recibo.numero}, ${recibo.codpago}, '
        '${formatCents(recibo.importeCents)}, pagado=${recibo.pagado})',
      );
      await _api.delete(_recibos, recibo.idrecibo);
      escrituras++;
    }
    // Primero los que reducen importe: la suma nunca supera el total.
    ajustar.sort(
      (a, b) => (a.$2.importeCents - a.$1.importeCents).compareTo(
        b.$2.importeCents - b.$1.importeCents,
      ),
    );
    for (final (recibo, parte) in ajustar) {
      final campos = <String, Object?>{
        if (recibo.importeCents != parte.importeCents)
          'importe': _importe(parte.importeCents),
        if (recibo.codpago != parte.codpago) 'codpago': parte.codpago,
      };
      _log.fine(
        'Factura $idfactura: ajustando recibo ${recibo.idrecibo} → $campos',
      );
      await _api.update(_recibos, recibo.idrecibo, campos);
      escrituras++;
    }

    // 3. Altas ya cobradas de las partes sin recibo: recibo + PagoCliente +
    // asiento 57x/430 en una sola petición.
    final fechaFactura = factura.fsDate('fecha') ?? fechaPago;
    for (final parte in planFinal) {
      if (conservados.containsKey(parte.numero)) continue;
      _log.fine(
        'Factura $idfactura: alta del recibo n.º ${parte.numero} '
        '(${parte.codpago}, ${formatCents(parte.importeCents)}) cobrado',
      );
      await _api.create(_recibos, {
        'idfactura': idfactura,
        'codcliente': factura.fsRequireString('codcliente'),
        'coddivisa': ?factura.fsNonEmptyString('coddivisa'),
        'idempresa': factura.fsRequireInt('idempresa'),
        'numero': parte.numero,
        'codpago': parte.codpago,
        'importe': _importe(parte.importeCents),
        'fecha': fsFormatDate(fechaFactura),
        'pagado': 1,
        'fechapago': fsFormatDate(fechaPago),
      });
      escrituras++;
    }

    // 4. Cobro de los recibos que sigan abiertos, cada uno con SU forma de
    // pago: nunca se envía codpago (lo reescribiría en todos).
    if (escrituras > 0) factura = await _leerFactura(idfactura);
    if (!factura.fsBool('pagada')) {
      _log.fine('Factura $idfactura: cobrando los recibos abiertos');
      final response = await _api.call(
        _pagar,
        path: [idfactura],
        fields: {'pagada': 1, 'fechapago': fsFormatDate(fechaPago)},
      );
      escrituras++;
      final data = response['data'];
      factura = data is FsRecord
          ? {...factura, ...data}
          : await _leerFactura(idfactura);
    }

    // 5. Verificación releyendo.
    final finales = escrituras > 0 ? await _leerRecibos(idfactura) : recibos;
    final resultado = <ReciboFactura>[];
    for (final recibo in finales) {
      final pagos = await _api.list(
        _pagos,
        filters: {'idrecibo': recibo.idrecibo},
        sort: {'idpago': FsSortOrder.asc},
      );
      final idpagos = [
        for (final pago in pagos.items) pago.fsRequireInt('idpago'),
      ];
      final pagosCents = pagos.items.fold(
        0,
        (sum, pago) => sum + centsFromDecimal(pago.fsDouble('importe') ?? 0),
      );
      resultado.add(
        ReciboFactura(
          idrecibo: recibo.idrecibo,
          numero: recibo.numero,
          codpago: recibo.codpago,
          importeCents: recibo.importeCents,
          pagado: recibo.pagado,
          idpagos: idpagos,
          pagosCents: pagosCents,
        ),
      );
      if (recibo.pagado &&
          (idpagos.length != 1 || pagosCents != recibo.importeCents)) {
        avisos.add(
          'Recibo n.º ${recibo.numero} (idrecibo ${recibo.idrecibo}) con '
          '${idpagos.length} pagos por ${formatCents(pagosCents)} para un '
          'importe de ${formatCents(recibo.importeCents)}: revisar a mano',
        );
      }
    }
    final pagada = factura.fsBool('pagada');
    final cuadra =
        finales.length == planFinal.length &&
        planFinal.every(
          (parte) =>
              finales.any((r) => r.numero == parte.numero && r.encaja(parte)),
        );
    if (!cuadra) {
      avisos.add(
        'Los recibos de la factura no coinciden con el plan de cobro: '
        '${[for (final r in finales) r.describir()]} ≠ '
        '${[for (final p in planFinal) '${p.numero}:${p.codpago}:${formatCents(p.importeCents)}']}',
      );
    }
    final abiertos = finales.where((r) => !r.pagado).toList();
    if (abiertos.isNotEmpty || !pagada) {
      avisos.add(
        'El cobro mixto no quedó completo: factura pagada=$pagada, '
        '${abiertos.length} recibo(s) sin cobrar',
      );
    }
    if (escrituras > 0) {
      _log.info(
        'Factura $idfactura: cobro mixto registrado con $escrituras '
        'escritura(s)',
      );
    }
    return CobroMixtoRegistrado(
      factura: factura,
      pagada: pagada,
      plan: planFinal,
      recibos: resultado,
      escrituras: escrituras,
    );
  }

  /// Si FacturaScripts calculó otro total, la diferencia se carga a una sola
  /// parte del plan: primero a la de efectivo (se cuadra con el arqueo) y,
  /// si no la admite o no hay ninguna marcada, a las demás empezando por la
  /// última. La tarjeta solo se toca como último recurso: su importe es lo
  /// que cobró el datáfono.
  static List<ParteCobro> _ajustarAlTotal(
    List<ParteCobro> plan,
    int totalCents,
    List<String> avisos,
  ) {
    final suma = plan.fold(0, (sum, parte) => sum + parte.importeCents);
    final diferencia = totalCents - suma;
    if (diferencia == 0) return plan;
    final candidatas = [
      for (var i = 0; i < plan.length; i++)
        if (plan[i].efectivo) i,
      for (var i = plan.length - 1; i >= 0; i--)
        if (!plan[i].efectivo) i,
    ];
    for (final i in candidatas) {
      final parte = plan[i];
      final ajustada = parte.importeCents + diferencia;
      if (ajustada <= 0) continue;
      avisos.add(
        'Cobro mixto ajustado al total de FacturaScripts: '
        '${parte.codpago} ${formatCents(parte.importeCents)} → '
        '${formatCents(ajustada)}',
      );
      return [
        for (var j = 0; j < plan.length; j++)
          j == i ? parte.conImporte(ajustada) : plan[j],
      ];
    }
    throw ValidationException(
      'El total de FacturaScripts (${formatCents(totalCents)}) no admite el '
      'cobro mixto del TPV (${formatCents(suma)}): hay que repartirlo a mano',
    );
  }

  Future<FsRecord> _leerFactura(int idfactura) async {
    final factura = await _api.get(_facturas, idfactura);
    if (factura == null) {
      throw ErpApiException(
        'La factura $idfactura no existe en FacturaScripts',
        statusCode: 404,
      );
    }
    return factura;
  }

  Future<List<_Recibo>> _leerRecibos(int idfactura) async {
    final page = await _api.list(
      _recibos,
      filters: {'idfactura': idfactura},
      sort: {'numero': FsSortOrder.asc},
    );
    return [for (final record in page.items) _Recibo.leer(record)]..sort(
      (a, b) => a.numero != b.numero
          ? a.numero.compareTo(b.numero)
          : a.idrecibo.compareTo(b.idrecibo),
    );
  }

  /// Importe con punto y dos decimales (`7.60`), como lo espera la API.
  static String _importe(int cents) {
    final euros = cents ~/ 100;
    final resto = (cents % 100).toString().padLeft(2, '0');
    return '$euros.$resto';
  }

  static _Recibo? _primero(List<_Recibo> grupo, bool Function(_Recibo) test) {
    for (final recibo in grupo) {
      if (test(recibo)) return recibo;
    }
    return null;
  }
}

/// Recibo leído del ERP, con los tipos ya normalizados.
final class _Recibo {
  _Recibo({
    required this.idrecibo,
    required this.numero,
    required this.codpago,
    required this.importeCents,
    required this.pagado,
  });

  factory _Recibo.leer(FsRecord record) => _Recibo(
    idrecibo: record.fsRequireInt('idrecibo'),
    numero: record.fsInt('numero') ?? 1,
    codpago: record.fsString('codpago') ?? '',
    importeCents: centsFromDecimal(record.fsDouble('importe') ?? 0),
    pagado: record.fsBool('pagado'),
  );

  final int idrecibo;
  final int numero;
  final String codpago;
  final int importeCents;
  final bool pagado;

  bool encaja(ParteCobro parte) =>
      numero == parte.numero &&
      codpago == parte.codpago &&
      importeCents == parte.importeCents;

  String describir() =>
      '$numero:$codpago:${formatCents(importeCents)}${pagado ? '' : ' (abierto)'}';
}
