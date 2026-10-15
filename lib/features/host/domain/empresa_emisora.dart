import 'package:equatable/equatable.dart';

import '../../../core/facturascripts/master_data/fs_master_models.dart'
    show FsEmpresa;

/// Identidad fiscal del emisor de los tickets: la última empresa buena leída
/// de FacturaScripts, guardada en el diario del host para poder imprimir la
/// cabecera de los tickets aunque el ERP no responda.
final class EmpresaEmisora extends Equatable {
  const EmpresaEmisora({
    this.idempresa,
    required this.nombre,
    this.nombrecorto,
    this.cifnif,
    this.direccion,
    this.codpostal,
    this.ciudad,
    this.provincia,
    this.telefono,
    this.email,
    this.web,
    required this.obtenidaEn,
  });

  /// Copia la empresa leída del ERP, obtenida en [ahora].
  factory EmpresaEmisora.desdeFs(FsEmpresa e, DateTime ahora) => EmpresaEmisora(
    idempresa: e.idempresa,
    nombre: e.nombre,
    nombrecorto: e.nombrecorto,
    cifnif: e.cifnif,
    direccion: e.direccion,
    codpostal: e.codpostal,
    ciudad: e.ciudad,
    provincia: e.provincia,
    telefono: e.telefono1,
    email: e.email,
    web: e.web,
    obtenidaEn: ahora,
  );

  /// Lee el `empresa` del diario: `null` si falta, no es un objeto o no trae
  /// un `nombre` y una `obtenidaEn` válidos. Cualquier otro campo con un tipo
  /// inesperado se trata como ausente. Nunca lanza: un valor raro en este
  /// campo no invalida el diario entero.
  static EmpresaEmisora? tolerante(Object? raw) {
    if (raw is! Map<String, Object?>) return null;
    final nombre = raw['nombre'];
    if (nombre is! String) return null;
    final obtenidaEn = _fecha(raw['obtenidaEn']);
    if (obtenidaEn == null) return null;
    return EmpresaEmisora(
      idempresa: _entero(raw['idempresa']),
      nombre: nombre,
      nombrecorto: _texto(raw['nombrecorto']),
      cifnif: _texto(raw['cifnif']),
      direccion: _texto(raw['direccion']),
      codpostal: _texto(raw['codpostal']),
      ciudad: _texto(raw['ciudad']),
      provincia: _texto(raw['provincia']),
      telefono: _texto(raw['telefono']),
      email: _texto(raw['email']),
      web: _texto(raw['web']),
      obtenidaEn: obtenidaEn,
    );
  }

  final int? idempresa;
  final String nombre;
  final String? nombrecorto;
  final String? cifnif;
  final String? direccion;
  final String? codpostal;
  final String? ciudad;
  final String? provincia;

  /// `telefono1` de la empresa en FacturaScripts.
  final String? telefono;
  final String? email;
  final String? web;

  /// Cuándo se leyó del ERP (reloj del host).
  final DateTime obtenidaEn;

  bool get tieneNif => cifnif?.trim().isNotEmpty ?? false;

  /// Solo los campos no nulos.
  Map<String, Object?> toJson() => {
    if (idempresa != null) 'idempresa': idempresa,
    'nombre': nombre,
    if (nombrecorto != null) 'nombrecorto': nombrecorto,
    if (cifnif != null) 'cifnif': cifnif,
    if (direccion != null) 'direccion': direccion,
    if (codpostal != null) 'codpostal': codpostal,
    if (ciudad != null) 'ciudad': ciudad,
    if (provincia != null) 'provincia': provincia,
    if (telefono != null) 'telefono': telefono,
    if (email != null) 'email': email,
    if (web != null) 'web': web,
    'obtenidaEn': obtenidaEn.toIso8601String(),
  };

  static int? _entero(Object? valor) => valor is int ? valor : null;

  static String? _texto(Object? valor) => valor is String ? valor : null;

  static DateTime? _fecha(Object? valor) =>
      valor is String ? DateTime.tryParse(valor) : null;

  @override
  List<Object?> get props => [
    idempresa,
    nombre,
    nombrecorto,
    cifnif,
    direccion,
    codpostal,
    ciudad,
    provincia,
    telefono,
    email,
    web,
    obtenidaEn,
  ];
}
