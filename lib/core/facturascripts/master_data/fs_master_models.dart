/// Modelos de datos maestros de FacturaScripts que usa el TPV.
///
/// Cada modelo se construye desde un `FsRecord` con `FsRecordReader`, porque
/// los tipos de la API no son fiables (un GET devuelve números y booleanos
/// nativos; la respuesta de un POST devuelve lo mismo como texto).
library;

import 'dart:convert';

import 'package:equatable/equatable.dart';

import '../fs_api.dart';
import '../fs_values.dart';

/// Ajustes del grupo `default` (registro `settings/default`).
///
/// En la API el campo `properties` es un **texto JSON** con todas las claves
/// del grupo; cualquiera puede faltar (el asistente no las inicializa todas),
/// por eso todos los campos son opcionales salvo los que tienen defecto en el
/// propio código de FacturaScripts (`decimals` = 2, método de cálculo
/// `classic`).
final class FsDefaultSettings extends Equatable {
  const FsDefaultSettings({
    this.codalmacen,
    this.codpago,
    this.codserie,
    this.coddivisa,
    this.codimpuesto,
    this.idempresa,
    this.decimals = 2,
    this.taxCalculationMethod = 'classic',
    this.ventasinstock,
    this.properties = const {},
  });

  /// Lanza [FormatException] si `properties` no es JSON o no es un objeto.
  factory FsDefaultSettings.fromRecord(FsRecord record) {
    final raw = record['properties'];
    final Map<String, Object?> props;
    switch (raw) {
      case null:
        props = const {};
      case final Map<String, Object?> map:
        props = map;
      case final String text:
        if (text.trim().isEmpty) {
          props = const {};
        } else {
          final decoded = jsonDecode(text);
          if (decoded is! Map<String, Object?>) {
            throw const FormatException(
              "Campo 'properties' de settings: el JSON no es un objeto",
            );
          }
          props = decoded;
        }
      default:
        throw FormatException(
          "Campo 'properties' de settings: tipo inesperado "
          '${raw.runtimeType}',
        );
    }
    final method = props.fsNonEmptyString('taxcalculationmethod');
    return FsDefaultSettings(
      codalmacen: props.fsNonEmptyString('codalmacen'),
      codpago: props.fsNonEmptyString('codpago'),
      codserie: props.fsNonEmptyString('codserie'),
      coddivisa: props.fsNonEmptyString('coddivisa'),
      codimpuesto: props.fsNonEmptyString('codimpuesto'),
      idempresa: props.fsInt('idempresa'),
      decimals: props.fsInt('decimals') ?? 2,
      taxCalculationMethod: method ?? 'classic',
      ventasinstock: props.containsKey('ventasinstock')
          ? props.fsBool('ventasinstock')
          : null,
      properties: Map.unmodifiable(props),
    );
  }

  final String? codalmacen;
  final String? codpago;
  final String? codserie;
  final String? coddivisa;

  /// Impuesto por defecto de los productos nuevos (de fábrica `IVA21`).
  final String? codimpuesto;
  final int? idempresa;

  /// Decimales de los importes (FacturaScripts asume 2 si no está definido).
  final int decimals;

  /// `classic` o `price-adjusted` (clave `taxcalculationmethod`).
  final String taxCalculationMethod;

  /// Defecto de `productos.ventasinstock` para productos nuevos.
  final bool? ventasinstock;

  /// Todas las claves del grupo, por si la capa superior necesita alguna más.
  final Map<String, Object?> properties;

  @override
  List<Object?> get props => [
    codalmacen,
    codpago,
    codserie,
    coddivisa,
    codimpuesto,
    idempresa,
    decimals,
    taxCalculationMethod,
    ventasinstock,
  ];
}

/// Empresa emisora (cabecera del ticket).
final class FsEmpresa extends Equatable {
  const FsEmpresa({
    required this.idempresa,
    required this.nombre,
    this.nombrecorto,
    this.cifnif,
    this.direccion,
    this.codpostal,
    this.ciudad,
    this.provincia,
    this.telefono1,
    this.email,
    this.web,
  });

  factory FsEmpresa.fromRecord(FsRecord r) => FsEmpresa(
    idempresa: r.fsRequireInt('idempresa'),
    nombre: r.fsRequireString('nombre'),
    nombrecorto: r.fsNonEmptyString('nombrecorto'),
    cifnif: r.fsNonEmptyString('cifnif'),
    direccion: r.fsNonEmptyString('direccion'),
    codpostal: r.fsNonEmptyString('codpostal'),
    ciudad: r.fsNonEmptyString('ciudad'),
    provincia: r.fsNonEmptyString('provincia'),
    telefono1: r.fsNonEmptyString('telefono1'),
    email: r.fsNonEmptyString('email'),
    web: r.fsNonEmptyString('web'),
  );

  final int idempresa;
  final String nombre;
  final String? nombrecorto;
  final String? cifnif;
  final String? direccion;
  final String? codpostal;
  final String? ciudad;
  final String? provincia;
  final String? telefono1;
  final String? email;
  final String? web;

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
    telefono1,
    email,
    web,
  ];
}

/// Serie de facturación. [tipo] `S` = simplificada (tickets), `R` =
/// rectificativa, vacío = general.
final class FsSerie extends Equatable {
  const FsSerie({
    required this.codserie,
    required this.descripcion,
    this.tipo,
    this.siniva = false,
  });

  factory FsSerie.fromRecord(FsRecord r) => FsSerie(
    codserie: r.fsRequireString('codserie'),
    descripcion: r.fsString('descripcion') ?? '',
    tipo: r.fsNonEmptyString('tipo'),
    siniva: r.fsBool('siniva'),
  );

  final String codserie;
  final String descripcion;
  final String? tipo;
  final bool siniva;

  bool get esSimplificada => tipo == 'S';

  @override
  List<Object?> get props => [codserie, descripcion, tipo, siniva];
}

/// Forma de pago.
///
/// [pagado] decide si una factura creada con esta forma de pago nace cobrada
/// (recibo pagado automáticamente). [codcuentabanco] determina la subcuenta
/// del cobro (sin cuenta bancaria FacturaScripts cae a la cuenta especial
/// BANCO/CAJA en vez de a la caja del TPV).
final class FsFormaPago extends Equatable {
  const FsFormaPago({
    required this.codpago,
    required this.descripcion,
    this.pagado = false,
    this.activa = true,
    this.codcuentabanco,
    this.idempresa,
  });

  factory FsFormaPago.fromRecord(FsRecord r) => FsFormaPago(
    codpago: r.fsRequireString('codpago'),
    descripcion: r.fsString('descripcion') ?? '',
    pagado: r.fsBool('pagado'),
    activa: r.fsBool('activa', orElse: true),
    codcuentabanco: r.fsNonEmptyString('codcuentabanco'),
    idempresa: r.fsInt('idempresa'),
  );

  final String codpago;
  final String descripcion;
  final bool pagado;
  final bool activa;
  final String? codcuentabanco;
  final int? idempresa;

  @override
  List<Object?> get props => [
    codpago,
    descripcion,
    pagado,
    activa,
    codcuentabanco,
    idempresa,
  ];
}

/// Almacén.
final class FsAlmacen extends Equatable {
  const FsAlmacen({
    required this.codalmacen,
    required this.nombre,
    this.activo = true,
    this.idempresa,
  });

  factory FsAlmacen.fromRecord(FsRecord r) => FsAlmacen(
    codalmacen: r.fsRequireString('codalmacen'),
    nombre: r.fsString('nombre') ?? '',
    activo: r.fsBool('activo', orElse: true),
    idempresa: r.fsInt('idempresa'),
  );

  final String codalmacen;
  final String nombre;
  final bool activo;
  final int? idempresa;

  @override
  List<Object?> get props => [codalmacen, nombre, activo, idempresa];
}

/// Estado de documento (`estadodocumentos`). Los ids NUNCA se fijan a fuego:
/// 10 Boceto / 11 Emitida son solo los de fábrica.
final class FsEstadoDocumento extends Equatable {
  const FsEstadoDocumento({
    required this.idestado,
    required this.nombre,
    required this.tipodoc,
    this.predeterminado = false,
    this.editable = true,
    this.actualizastock = 0,
    this.activo = true,
  });

  factory FsEstadoDocumento.fromRecord(FsRecord r) => FsEstadoDocumento(
    idestado: r.fsRequireInt('idestado'),
    nombre: r.fsString('nombre') ?? '',
    tipodoc: r.fsString('tipodoc') ?? '',
    predeterminado: r.fsBool('predeterminado'),
    editable: r.fsBool('editable', orElse: true),
    actualizastock: r.fsInt('actualizastock') ?? 0,
    activo: r.fsBool('activo', orElse: true),
  );

  final int idestado;
  final String nombre;
  final String tipodoc;
  final bool predeterminado;
  final bool editable;

  /// `-1` resta stock, `1` lo suma, `0` no lo toca (`2`/`-2` reservas).
  final int actualizastock;
  final bool activo;

  @override
  List<Object?> get props => [
    idestado,
    nombre,
    tipodoc,
    predeterminado,
    editable,
    actualizastock,
    activo,
  ];
}

/// Cliente (solo los campos que usa el TPV).
final class FsCliente extends Equatable {
  const FsCliente({
    required this.codcliente,
    required this.nombre,
    this.razonsocial,
    this.cifnif,
    this.codpago,
    this.codserie,
    this.riesgomax,
    this.debaja = false,
  });

  factory FsCliente.fromRecord(FsRecord r) => FsCliente(
    codcliente: r.fsRequireString('codcliente'),
    nombre: r.fsString('nombre') ?? '',
    razonsocial: r.fsNonEmptyString('razonsocial'),
    cifnif: r.fsString('cifnif'),
    codpago: r.fsNonEmptyString('codpago'),
    codserie: r.fsNonEmptyString('codserie'),
    riesgomax: r.fsDouble('riesgomax'),
    debaja: r.fsBool('debaja'),
  );

  final String codcliente;
  final String nombre;
  final String? razonsocial;
  final String? cifnif;
  final String? codpago;
  final String? codserie;

  /// Riesgo máximo: si se supera, FacturaScripts rechaza la factura (422).
  /// El cliente genérico del TPV debe tenerlo vacío.
  final double? riesgomax;
  final bool debaja;

  @override
  List<Object?> get props => [
    codcliente,
    nombre,
    razonsocial,
    cifnif,
    codpago,
    codserie,
    riesgomax,
    debaja,
  ];
}

/// Gravedad de un resultado del diagnóstico.
enum DiagnosticoNivel { ok, aviso, error }

/// Resultado de una comprobación de [FsMasterDataService.diagnosticar].
final class DiagnosticoItem extends Equatable {
  const DiagnosticoItem({
    required this.codigo,
    required this.nivel,
    required this.titulo,
    required this.detalle,
  });

  /// Identificador estable (`api`, `serie`, `pago_efectivo_cuenta`...).
  final String codigo;
  final DiagnosticoNivel nivel;
  final String titulo;
  final String detalle;

  Map<String, Object?> toJson() => {
    'codigo': codigo,
    'nivel': nivel.name,
    'titulo': titulo,
    'detalle': detalle,
  };

  @override
  List<Object?> get props => [codigo, nivel, titulo, detalle];
}

/// Lo que el TPV tiene configurado y quiere validar contra el ERP.
final class DiagnosticoConfig extends Equatable {
  const DiagnosticoConfig({
    required this.codserie,
    required this.codpagoEfectivo,
    required this.codpagoTarjeta,
    required this.codalmacen,
    required this.codcliente,
  });

  final String codserie;
  final String codpagoEfectivo;
  final String codpagoTarjeta;
  final String codalmacen;
  final String codcliente;

  @override
  List<Object?> get props => [
    codserie,
    codpagoEfectivo,
    codpagoTarjeta,
    codalmacen,
    codcliente,
  ];
}
