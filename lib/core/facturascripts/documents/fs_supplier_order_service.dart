/// Pedidos a proveedor idempotentes sobre `crearPedidoProveedor`.
library;

import '../../errors/app_exception.dart';
import '../../logging/app_logger.dart';
import '../../money/money.dart';
import '../fs_api.dart';
import '../fs_values.dart';
import 'supplier_order_models.dart';

/// Crea un pedido a proveedor (uno por proveedor y lote de reposición) en una
/// transacción del ERP. El pedido queda "Abierto" y suma `stocks.pterecibir`,
/// que es lo que el motor de reaprovisionamiento resta para no repetir.
final class FsSupplierOrderService {
  FsSupplierOrderService(this._api);

  static const String _resource = 'pedidoproveedores';
  static const String _lineas = 'lineapedidoproveedores';
  static const String _crear = 'crearPedidoProveedor';

  final FsApi _api;
  final Logger _log = appLogger('facturascripts.supplier_order');

  /// Crea el pedido o devuelve el existente con la misma clave
  /// (`numproveedor`). Lanza [ValidationException] si hay más de uno con esa
  /// clave y [ErpApiException] ante fallos de la API.
  Future<ResultadoPedido> crearOReanudar(PedidoProveedorDraft draft) async {
    try {
      return await _crearOReanudar(draft);
    } on FormatException catch (error) {
      throw ErpApiException(
        'Respuesta de FacturaScripts no interpretable al crear el pedido '
        "'${draft.clave}': ${error.message}",
        statusCode: 200,
        cause: error,
      );
    }
  }

  Future<ResultadoPedido> _crearOReanudar(PedidoProveedorDraft draft) async {
    final existente = await _buscarPorClave(draft.clave);
    final FsRecord doc;
    final List<FsRecord> lines;
    if (existente != null) {
      _log.info('Pedido ${draft.clave} ya existía en FS: reanudando');
      doc = existente;
      lines = await _api.listAll(
        _lineas,
        filters: {'idpedido': doc.fsRequireInt('idpedido')},
        sortBy: 'idlinea',
      );
    } else {
      _log.fine('Creando pedido ${draft.clave} a ${draft.codproveedor}');
      final response = await _api.call(_crear, fields: _camposCreacion(draft));
      doc = _mapa(response, 'doc');
      lines = _listaDeMapas(response, 'lines');
    }

    final sinProducto = <String>[
      for (final line in lines)
        if (line.fsInt('idproducto') == null)
          line.fsString('referencia') ?? '(sin referencia)',
    ];
    if (sinProducto.isNotEmpty) {
      _log.warning(
        'Pedido ${draft.clave}: referencias sin producto en FS $sinProducto',
      );
    }

    final total = doc.fsDouble('total');
    return ResultadoPedido(
      idpedido: doc.fsRequireInt('idpedido'),
      codigo: doc.fsRequireString('codigo'),
      totalCents: total == null ? 0 : centsFromDecimal(total),
      referenciasSinProducto: List.unmodifiable(sinProducto),
      yaExistia: existente != null,
    );
  }

  /// Campos de `crearPedidoProveedor`. `codserie` y `codpago` se toman del
  /// proveedor; nunca se envían `codigo`, `numero`, `idestado` ni totales.
  Map<String, Object?> _camposCreacion(PedidoProveedorDraft draft) => {
    'codproveedor': draft.codproveedor,
    'codalmacen': draft.codalmacen,
    'fecha': fsFormatDate(draft.fechaHora),
    'hora': fsFormatTime(draft.fechaHora),
    'numproveedor': draft.clave,
    if (draft.observaciones case final texto? when texto.trim().isNotEmpty)
      'observaciones': texto,
    'lineas': [for (final linea in draft.lineas) linea.toFsJson()],
  };

  Future<FsRecord?> _buscarPorClave(String clave) async {
    final page = await _api.list(
      _resource,
      filters: {'numproveedor': clave},
      limit: 2,
    );
    if (page.items.length > 1) {
      final ids = [for (final item in page.items) item.fsString('idpedido')];
      throw ValidationException(
        "Clave '$clave' duplicada en FacturaScripts: pedidos $ids",
      );
    }
    return page.items.isEmpty ? null : page.items.first;
  }

  static FsRecord _mapa(FsRecord response, String key) {
    final value = response[key];
    if (value is FsRecord) return value;
    throw FormatException("Campo '$key' ausente en la respuesta de $_crear");
  }

  static List<FsRecord> _listaDeMapas(FsRecord response, String key) {
    final value = response[key];
    if (value is! List<Object?>) {
      throw FormatException("Campo '$key' ausente en la respuesta de $_crear");
    }
    return [
      for (final item in value)
        if (item is FsRecord)
          item
        else
          throw FormatException("Campo '$key': elemento no es un objeto"),
    ];
  }
}
