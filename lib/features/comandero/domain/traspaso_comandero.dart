import 'package:equatable/equatable.dart';

import 'pedido_en_edicion.dart';

/// Lo que un controlador del comandero entrega al cerrarse para que otro lo
/// retome (p. ej. al recrearlo tras cambiar el nombre del dispositivo).
///
/// [pedidos] son los carritos de todas las mesas: las líneas que estaban en
/// envío ya vuelven como editables y "posiblemente transmitidas" (como tras
/// un fallo de red), así que el host las descartará si ya las tenía.
final class TraspasoComandero extends Equatable {
  const TraspasoComandero({
    this.pedidos = const [],
    this.lineasDevueltas = 0,
    this.peticionesPerdidas = 0,
  });

  /// Carritos no vacíos, uno por mesa.
  final List<PedidoEnEdicion> pedidos;

  /// Líneas que estaban enviándose (en cola o sin respuesta del host) y han
  /// vuelto al carrito: hay que revisarlas y volver a enviarlas.
  final int lineasDevueltas;

  /// Peticiones en cola que no son comandas (anulaciones y marchas de pases)
  /// y no se pueden traspasar: el camarero tiene que repetirlas.
  final int peticionesPerdidas;

  /// Total de líneas en los carritos traspasados.
  int get lineas => pedidos.fold(0, (total, p) => total + p.lineas.length);

  bool get estaVacio => pedidos.isEmpty && peticionesPerdidas == 0;

  @override
  List<Object?> get props => [pedidos, lineasDevueltas, peticionesPerdidas];
}
