/// Modelos comunes de los documentos ESC/POS: la empresa de la cabecera, las
/// líneas de venta, el desglose de IVA, las partes de un cobro mixto y la marca
/// de DUPLICADO de una factura.
library;

import 'dart:typed_data';

import 'package:equatable/equatable.dart';

/// Datos de la empresa para la cabecera de tickets e informes.
final class EmpresaTicket extends Equatable {
  const EmpresaTicket({
    required this.nombre,
    this.nombreComercial,
    this.cifnif,
    this.direccion,
    this.codpostal,
    this.ciudad,
    this.provincia,
    this.telefono,
    this.web,
    this.pie,
    this.logoPng,
  });

  /// Razón social (`nombre` de FacturaScripts), obligatoria en la factura.
  final String nombre;

  /// Nombre comercial («BAR MANOLO»). Si lo hay, encabeza la cabecera en
  /// negrita y doble alto y la razón social va debajo; si coincide con
  /// [nombre] (sin distinguir mayúsculas) se imprime una sola vez.
  final String? nombreComercial;

  /// NIF del emisor, obligatorio en la factura simplificada.
  final String? cifnif;
  final String? direccion;
  final String? codpostal;
  final String? ciudad;

  /// Provincia, entre paréntesis tras la ciudad: «28001 Madrid (Madrid)».
  final String? provincia;
  final String? telefono;

  /// Sitio web, en su propia línea tras el teléfono.
  final String? web;

  /// Texto legal o de cortesía al pie del ticket ("IVA incluido", "Gracias
  /// por su visita"...).
  final String? pie;

  /// Logo codificado (PNG, JPEG...) que se rasteriza dentro del isolate.
  final Uint8List? logoPng;

  @override
  List<Object?> get props => [
    nombre,
    nombreComercial,
    cifnif,
    direccion,
    codpostal,
    ciudad,
    provincia,
    telefono,
    web,
    pie,
    logoPng,
  ];
}

/// Línea de un ticket. [pvpUnitarioCents] e [importeCents] llevan el IVA
/// incluido (es lo que paga el cliente); el desglose va aparte.
final class LineaTicket extends Equatable {
  const LineaTicket({
    required this.descripcion,
    required this.cantidad,
    required this.pvpUnitarioCents,
    required this.importeCents,
    this.nota,
    this.letraIva,
  });

  final String descripcion;
  final double cantidad;
  final int pvpUnitarioCents;
  final int importeCents;
  final String? nota;

  /// Letra del tipo de IVA de la línea («A», «B»…), impresa tras el importe
  /// cuando el ticket tiene dos o más tipos (ver [letrasIva]).
  final String? letraIva;

  @override
  List<Object?> get props => [
    descripcion,
    cantidad,
    pvpUnitarioCents,
    importeCents,
    nota,
    letraIva,
  ];
}

/// Fila del desglose de IVA (base y cuota en céntimos, tipo en porcentaje).
final class DesgloseIvaTicketPrint extends Equatable {
  const DesgloseIvaTicketPrint({
    required this.ivaPct,
    required this.baseCents,
    required this.cuotaCents,
    this.letra,
  });

  final double ivaPct;
  final int baseCents;
  final int cuotaCents;

  /// Letra del tipo («A 10 %»), la misma que llevan sus líneas.
  final String? letra;

  @override
  List<Object?> get props => [ivaPct, baseCents, cuotaCents, letra];
}

/// Una parte del cobro de un ticket mixto ("Efectivo" 12,35 €).
final class PagoTicketPrint extends Equatable {
  const PagoTicketPrint({required this.formaPago, required this.importeCents});

  /// Texto de la forma de pago tal como se imprime.
  final String formaPago;
  final int importeCents;

  @override
  List<Object?> get props => [formaPago, importeCents];
}

/// Marca de DUPLICADO de una factura simplificada (art. 14.4 del
/// RD 1619/2012): el número de duplicado y cuándo se reimprime.
final class DuplicadoPrint extends Equatable {
  const DuplicadoPrint({required this.numero, required this.impresoEn});

  /// 1 para el primer duplicado, 2 para el segundo…
  final int numero;

  /// Fecha y hora de la reimpresión.
  final DateTime impresoEn;

  @override
  List<Object?> get props => [numero, impresoEn];
}

/// Letras de IVA («A», «B», «C»…) por tipo, asignadas en orden ascendente de
/// tipo y solo cuando hay dos o más tipos distintos: con uno solo la letra no
/// aporta nada y el resultado es vacío. Las claves son los tipos tal como los
/// maneja quien llama (puntos básicos, por ejemplo): solo importa su orden.
Map<int, String> letrasIva(Iterable<int> tipos) {
  final distintos = tipos.toSet().toList()..sort();
  if (distintos.length < 2) return const {};
  return {
    for (var i = 0; i < distintos.length; i++)
      distintos[i]: String.fromCharCode('A'.codeUnitAt(0) + i),
  };
}
