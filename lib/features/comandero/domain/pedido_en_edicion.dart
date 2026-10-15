import 'package:equatable/equatable.dart';

import '../../../core/errors/app_exception.dart';
import '../../../core/facturascripts/catalog/catalog_models.dart';
import '../../../core/money/money.dart';
import '../../sala/domain/linea_comanda.dart';

/// Línea del carrito de una mesa: un artículo de la carta con su cantidad y
/// nota, todavía sin enviar al host.
///
/// El [id] se fija al crear la línea y será el `id` de la [LineaComanda]
/// resultante: así una misma línea nunca llega dos veces al host aunque el
/// envío se repita. El [articulo] se congela tal como estaba en el catálogo
/// al añadirlo: precio y tipo de IVA no cambian aunque llegue un catálogo
/// nuevo antes de enviar.
///
/// Una línea [posiblementeTransmitida] volvió al carrito tras un fallo de red
/// con el envío ya en marcha: el host pudo haberla registrado con su [id], así
/// que editarla genera una línea con id nuevo (el host descartaría la edición
/// como duplicado) y [reemplazaA] recuerda el id anterior.
final class LineaPedido extends Equatable {
  LineaPedido({
    required this.id,
    required this.articulo,
    required this.cantidad,
    this.nota,
    this.pase,
    this.enviando = false,
    this.posiblementeTransmitida = false,
    this.reemplazaA,
  }) {
    validarCantidad(cantidad);
    validarPase(pase);
  }

  final String id;
  final ArticuloCatalogo articulo;

  /// Unidades (admite fracciones).
  final double cantidad;

  /// Indicación para cocina ("sin cebolla").
  final String? nota;

  /// Pase de la línea: `null` = directa (sale sin esperar a ninguna marcha);
  /// `1..n` = posición, en base 1, en los nombres de `PasesConfig`. Viaja
  /// tal cual en la [LineaComanda]: el host lo conserva con los pases activos
  /// (aunque no esté en su configuración) y lo descarta si están desactivados.
  final int? pase;

  /// Ya forma parte de un envío en curso (esperando el `ack` del host): no se
  /// puede editar ni quitar hasta que el host responda.
  final bool enviando;

  /// El envío falló por la red después de salir hacia el host: puede que el
  /// host ya la tenga. Editarla abre una línea con id nuevo.
  final bool posiblementeTransmitida;

  /// Id de la línea [posiblementeTransmitida] que esta sustituye tras una
  /// edición (para avisar si el host ya tenía la original).
  final String? reemplazaA;

  /// Importe con IVA de la línea, en céntimos.
  int get importeCents => lineTotalCents(articulo.pvpCents, cantidad);

  /// La misma carta (con el mismo precio, impuesto y familia), la misma nota
  /// y el mismo pase: la cantidad se acumula en vez de abrir otra línea. Si
  /// el artículo cambió de precio o de IVA en el catálogo, las unidades
  /// nuevas van en otra línea con el precio vigente. Nunca se acumula en una
  /// línea en envío o [posiblementeTransmitida].
  bool agrupaCon(ArticuloCatalogo otro, String? otraNota, int? otroPase) =>
      !enviando &&
      !posiblementeTransmitida &&
      articulo.referencia == otro.referencia &&
      mismoPrecio(articulo, otro) &&
      (nota ?? '') == (otraNota ?? '') &&
      pase == otroPase;

  /// `true` si [a] y [b] se venden igual: precio, impuesto, descripción y
  /// familia (que decide el destino de preparación).
  static bool mismoPrecio(ArticuloCatalogo a, ArticuloCatalogo b) =>
      a.pvpCents == b.pvpCents &&
      a.precioNeto == b.precioNeto &&
      a.ivaBp == b.ivaBp &&
      a.codimpuesto == b.codimpuesto &&
      a.codfamilia == b.codfamilia &&
      a.descripcion == b.descripcion;

  /// Copia con cambios. [pase] recibe un getter para poder dejarlo a `null`:
  /// `pase: () => null` devuelve la línea a «directa».
  LineaPedido copyWith({
    double? cantidad,
    String? nota,
    int? Function()? pase,
    bool? enviando,
    bool? posiblementeTransmitida,
  }) => LineaPedido(
    id: id,
    articulo: articulo,
    cantidad: cantidad ?? this.cantidad,
    nota: nota ?? this.nota,
    pase: pase == null ? this.pase : pase(),
    enviando: enviando ?? this.enviando,
    posiblementeTransmitida:
        posiblementeTransmitida ?? this.posiblementeTransmitida,
    reemplazaA: reemplazaA,
  );

  /// Construye la línea de comanda con los precios congelados del catálogo
  /// y el [pase] del carrito.
  LineaComanda aLineaComanda({
    required DateTime creadaEn,
    required DestinoPreparacion destino,
    String? camarero,
  }) => LineaComanda(
    id: id,
    referencia: articulo.referencia,
    descripcion: articulo.descripcion,
    cantidad: cantidad,
    pvpUnitarioCents: articulo.pvpCents,
    pvpUnitarioNeto: articulo.precioNeto,
    ivaBp: articulo.ivaBp,
    codimpuesto: articulo.codimpuesto,
    nota: nota,
    destino: destino,
    camarero: camarero,
    creadaEn: creadaEn,
    pase: pase,
  );

  /// Lanza [ValidationException] si [cantidad] no es positiva y finita.
  static void validarCantidad(double cantidad) {
    if (cantidad.isNaN || cantidad.isInfinite || cantidad <= 0) {
      throw ValidationException(
        'La cantidad debe ser mayor que cero (recibido $cantidad)',
      );
    }
  }

  /// Lanza [ValidationException] si [pase] no es `null` ni positivo.
  static void validarPase(int? pase) {
    if (pase != null && pase < 1) {
      throw ValidationException('El pase debe ser 1 o mayor (recibido $pase)');
    }
  }

  @override
  List<Object?> get props => [
    id,
    articulo,
    cantidad,
    nota,
    pase,
    enviando,
    posiblementeTransmitida,
    reemplazaA,
  ];
}

/// Pedido en edición (carrito) de una mesa: lo que el camarero va marcando
/// antes de pulsar "enviar". Vive solo en el comandero hasta que el host lo
/// acepta. Inmutable: cada operación devuelve un pedido nuevo.
final class PedidoEnEdicion extends Equatable {
  PedidoEnEdicion({required this.mesaId, List<LineaPedido> lineas = const []})
    : lineas = List.unmodifiable(lineas);

  factory PedidoEnEdicion.vacio(String mesaId) =>
      PedidoEnEdicion(mesaId: mesaId);

  final String mesaId;

  /// Líneas en orden de incorporación, incluidas las que están en envío.
  final List<LineaPedido> lineas;

  bool get estaVacio => lineas.isEmpty;

  /// Líneas que aún no han salido hacia el host.
  List<LineaPedido> get pendientesDeEnviar => [
    for (final linea in lineas)
      if (!linea.enviando) linea,
  ];

  /// Líneas esperando el `ack` del host.
  List<LineaPedido> get enEnvio => [
    for (final linea in lineas)
      if (linea.enviando) linea,
  ];

  /// Importe orientativo con IVA de todas las líneas, en céntimos.
  int get importeCents =>
      lineas.fold(0, (total, linea) => total + linea.importeCents);

  /// Suma de unidades de todas las líneas.
  double get unidades =>
      lineas.fold(0.0, (total, linea) => total + linea.cantidad);

  LineaPedido? lineaPorId(String lineaId) {
    for (final linea in lineas) {
      if (linea.id == lineaId) return linea;
    }
    return null;
  }

  /// Añade [articulo] con el [pase] indicado (`null` = directo); si ya hay
  /// una línea editable del mismo artículo con la misma nota y el mismo
  /// pase, acumula la cantidad en ella. [nuevoId] solo se invoca si hace
  /// falta abrir línea nueva.
  ///
  /// Lanza [ValidationException] si el artículo no es vendible, la cantidad
  /// no es válida o el pase no es positivo.
  PedidoEnEdicion conArticulo(
    ArticuloCatalogo articulo, {
    required String Function() nuevoId,
    double cantidad = 1,
    String? nota,
    int? pase,
  }) {
    LineaPedido.validarCantidad(cantidad);
    LineaPedido.validarPase(pase);
    if (!articulo.vendible) {
      throw ValidationException(
        "El artículo '${articulo.referencia}' no está a la venta",
      );
    }
    final notaLimpia = _limpiarNota(nota);
    final index = lineas.indexWhere(
      (l) => l.agrupaCon(articulo, notaLimpia, pase),
    );
    if (index >= 0) {
      final actual = lineas[index];
      return _reemplazando(
        index,
        actual.copyWith(cantidad: actual.cantidad + cantidad),
      );
    }
    return PedidoEnEdicion(
      mesaId: mesaId,
      lineas: [
        ...lineas,
        LineaPedido(
          id: nuevoId(),
          articulo: articulo,
          cantidad: cantidad,
          nota: notaLimpia,
          pase: pase,
        ),
      ],
    );
  }

  /// Fija la cantidad de una línea. Lanza [ValidationException] si la línea
  /// no existe, está en envío o la cantidad no es válida.
  ///
  /// Si la línea está [LineaPedido.posiblementeTransmitida], la edición crea
  /// una línea con id nuevo ([nuevoId], o uno derivado del actual si no se
  /// pasa) para que el host no la descarte como duplicada.
  PedidoEnEdicion conCantidad(
    String lineaId,
    double cantidad, {
    String Function()? nuevoId,
  }) {
    LineaPedido.validarCantidad(cantidad);
    final index = _indiceEditable(lineaId);
    final actual = lineas[index];
    return _reemplazando(
      index,
      _editada(
        actual,
        cantidad: cantidad,
        nota: actual.nota,
        pase: actual.pase,
        nuevoId: nuevoId,
      ),
    );
  }

  /// Cambia la nota de una línea (vacía o `null` la quita). Con una línea
  /// [LineaPedido.posiblementeTransmitida] se comporta como [conCantidad].
  PedidoEnEdicion conNota(
    String lineaId,
    String? nota, {
    String Function()? nuevoId,
  }) {
    final index = _indiceEditable(lineaId);
    final actual = lineas[index];
    return _reemplazando(
      index,
      _editada(
        actual,
        cantidad: actual.cantidad,
        nota: _limpiarNota(nota),
        pase: actual.pase,
        nuevoId: nuevoId,
      ),
    );
  }

  /// Fija a la vez la cantidad, la nota y, si se pasa [pase], el pase de una
  /// línea en una sola edición (`pase: () => null` la vuelve directa; sin
  /// [pase] conserva el que tenía).
  ///
  /// Con una línea [LineaPedido.posiblementeTransmitida] se genera un único
  /// id nuevo (encadenar [conCantidad] y [conNota] cambiaría el id en la
  /// primera y la segunda ya no encontraría la línea). Lanza
  /// [ValidationException] como [conCantidad] o si el pase no es positivo.
  PedidoEnEdicion conCantidadYNota(
    String lineaId, {
    required double cantidad,
    required String? nota,
    int? Function()? pase,
    String Function()? nuevoId,
  }) {
    LineaPedido.validarCantidad(cantidad);
    final index = _indiceEditable(lineaId);
    final actual = lineas[index];
    final notaLimpia = _limpiarNota(nota);
    final paseNuevo = pase == null ? actual.pase : pase();
    LineaPedido.validarPase(paseNuevo);
    if (actual.cantidad == cantidad &&
        actual.nota == notaLimpia &&
        actual.pase == paseNuevo) {
      return this;
    }
    return _reemplazando(
      index,
      _editada(
        actual,
        cantidad: cantidad,
        nota: notaLimpia,
        pase: paseNuevo,
        nuevoId: nuevoId,
      ),
    );
  }

  /// Añade al final las líneas de [otro] (de la misma mesa) cuyo id no esté
  /// ya en este pedido. Las que llegan "en envío" vuelven como editables y
  /// [LineaPedido.posiblementeTransmitida]: su envío quedó sin confirmar.
  ///
  /// Sirve para traspasar carritos entre controladores y para deshacer un
  /// vaciado. Lanza [ArgumentError] si [otro] es de otra mesa.
  PedidoEnEdicion fusionando(PedidoEnEdicion otro) {
    if (otro.mesaId != mesaId) {
      throw ArgumentError.value(
        otro.mesaId,
        'otro',
        'El pedido es de otra mesa ($mesaId)',
      );
    }
    final ids = {for (final linea in lineas) linea.id};
    final nuevas = [
      for (final linea in otro.lineas)
        if (!ids.contains(linea.id))
          linea.enviando
              ? linea.copyWith(enviando: false, posiblementeTransmitida: true)
              : linea,
    ];
    if (nuevas.isEmpty) return this;
    return PedidoEnEdicion(mesaId: mesaId, lineas: [...lineas, ...nuevas]);
  }

  /// Línea editada: conserva el id salvo si [actual] es
  /// [LineaPedido.posiblementeTransmitida], en cuyo caso estrena id y
  /// recuerda el anterior en [LineaPedido.reemplazaA].
  LineaPedido _editada(
    LineaPedido actual, {
    required double cantidad,
    required String? nota,
    required int? pase,
    String Function()? nuevoId,
  }) {
    if (!actual.posiblementeTransmitida) {
      return LineaPedido(
        id: actual.id,
        articulo: actual.articulo,
        cantidad: cantidad,
        nota: nota,
        pase: pase,
        reemplazaA: actual.reemplazaA,
      );
    }
    return LineaPedido(
      id: nuevoId != null ? nuevoId() : _idDerivado(actual.id),
      articulo: actual.articulo,
      cantidad: cantidad,
      nota: nota,
      pase: pase,
      reemplazaA: actual.id,
    );
  }

  /// Id nuevo, distinto de todos los del pedido, derivado de [base].
  String _idDerivado(String base) {
    final usados = {for (final linea in lineas) linea.id};
    var n = 1;
    while (usados.contains('$base-e$n')) {
      n++;
    }
    return '$base-e$n';
  }

  /// Quita una línea. Lanza [ValidationException] si no existe o está en
  /// envío.
  PedidoEnEdicion sinLinea(String lineaId) {
    final index = _indiceEditable(lineaId);
    return PedidoEnEdicion(
      mesaId: mesaId,
      lineas: [...lineas.sublist(0, index), ...lineas.sublist(index + 1)],
    );
  }

  /// Marca (o desmarca) como "en envío" las líneas con esos ids.
  PedidoEnEdicion marcandoEnvio(Set<String> ids, {required bool enviando}) =>
      PedidoEnEdicion(
        mesaId: mesaId,
        lineas: [
          for (final linea in lineas)
            if (ids.contains(linea.id))
              linea.copyWith(enviando: enviando)
            else
              linea,
        ],
      );

  /// Devuelve al carrito, como editables y
  /// [LineaPedido.posiblementeTransmitida], las líneas con esos ids cuyo envío
  /// falló por la red cuando ya podía haber llegado al host.
  PedidoEnEdicion devolviendoTrasFalloDeRed(Set<String> ids) => PedidoEnEdicion(
    mesaId: mesaId,
    lineas: [
      for (final linea in lineas)
        if (ids.contains(linea.id))
          linea.copyWith(enviando: false, posiblementeTransmitida: true)
        else
          linea,
    ],
  );

  /// Quita las líneas editables cuyo id ya figura en [idsEnHost] (la comanda
  /// del host): el host las registró aunque su `ack` no llegara. Las que
  /// están en envío se quedan: su respuesta llegará con la retransmisión.
  PedidoEnEdicion sinLineasYaEnHost(Set<String> idsEnHost) => PedidoEnEdicion(
    mesaId: mesaId,
    lineas: [
      for (final linea in lineas)
        if (linea.enviando || !idsEnHost.contains(linea.id)) linea,
    ],
  );

  /// Elimina las líneas con esos ids (tras el `ack` del host).
  PedidoEnEdicion sinLineas(Set<String> ids) => PedidoEnEdicion(
    mesaId: mesaId,
    lineas: [
      for (final linea in lineas)
        if (!ids.contains(linea.id)) linea,
    ],
  );

  int _indiceEditable(String lineaId) {
    final index = lineas.indexWhere((l) => l.id == lineaId);
    if (index < 0) {
      throw ValidationException("No hay línea '$lineaId' en el pedido");
    }
    if (lineas[index].enviando) {
      throw ValidationException(
        'La línea ya se está enviando al host; espera su confirmación',
      );
    }
    return index;
  }

  PedidoEnEdicion _reemplazando(int index, LineaPedido linea) =>
      PedidoEnEdicion(
        mesaId: mesaId,
        lineas: [
          for (var i = 0; i < lineas.length; i++)
            if (i == index) linea else lineas[i],
        ],
      );

  static String? _limpiarNota(String? nota) {
    final limpia = nota?.trim();
    return (limpia == null || limpia.isEmpty) ? null : limpia;
  }

  @override
  List<Object?> get props => [mesaId, lineas];
}
