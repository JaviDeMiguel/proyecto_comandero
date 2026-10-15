import 'package:equatable/equatable.dart';

import '../../../core/utils/json_map.dart';

/// Configuración de los pases de una comanda (primeros, segundos, postres…).
///
/// La comparten los ajustes del host, el snapshot de sala que reciben los
/// comanderos y la impresión de comandas, como `EnrutamientoComandas`. Solo
/// contiene la configuración: cada línea guarda su pase como posición (base
/// 1) en [nombres], o `null` si es directa.
///
/// El constructor `const` no copia [nombres]: quien lo construya no debe
/// modificar la lista después. [fromJson] y [copyWith] devuelven siempre
/// listas inmodificables.
final class PasesConfig extends Equatable {
  const PasesConfig({
    this.activos = true,
    this.nombres = porDefecto,
    this.marcharAlEnviar = true,
  });

  /// Lee la configuración guardada en los ajustes: estricta.
  ///
  /// Lo que falta toma su valor por defecto. Lanza [FormatException] si un
  /// campo tiene un tipo inválido, si no hay entre 1 y [maxPases] nombres o
  /// si alguno está vacío o pasa de [maxLongitudNombre] caracteres.
  factory PasesConfig.fromJson(Map<String, Object?> json) => PasesConfig(
    activos: json.optionalBool('activos') ?? true,
    nombres: switch (json.optionalList('nombres')) {
      final List<Object?> lista => _leerNombres(lista),
      null => porDefecto,
    },
    marcharAlEnviar: json.optionalBool('marcharAlEnviar') ?? true,
  );

  /// Lee el `pases` de un snapshot de sala: `null` si falta o no se entiende
  /// (no es un objeto, o [fromJson] lo rechaza). Nunca lanza: un host de otra
  /// versión no debe invalidar el snapshot entero.
  static PasesConfig? tolerante(Object? raw) {
    if (raw is! Map<String, Object?>) return null;
    try {
      return PasesConfig.fromJson(raw);
    } on FormatException {
      return null;
    }
  }

  static const List<String> porDefecto = ['Primeros', 'Segundos', 'Postres'];
  static const int maxPases = 5;
  static const int maxLongitudNombre = 16;

  /// Los pases están activos: el comandero muestra el selector de pase y los
  /// botones «Marchar», y las comandas se imprimen agrupadas por pase.
  final bool activos;

  /// Nombres de los pases en orden: el pase `n` de una línea es
  /// `nombres[n - 1]`.
  final List<String> nombres;

  /// Al enviar líneas del primer pase se marcha ese pase automáticamente.
  final bool marcharAlEnviar;

  int get numPases => nombres.length;

  /// El pase está en la configuración (1..[numPases]). Un pase fuera de ella
  /// no es inválido: se conserva y se rotula «Pase N».
  bool existe(int pase) => pase >= 1 && pase <= numPases;

  /// Nombre del pase; fuera de la configuración, «Pase N».
  String nombreDe(int pase) => existe(pase) ? nombres[pase - 1] : 'Pase $pase';

  /// Rótulo del pase de una línea: «Directo» si es `null`; si no, «N. Nombre»
  /// (p. ej. «2. Segundos» o «7. Pase 7»).
  String etiqueta(int? pase) =>
      pase == null ? 'Directo' : '$pase. ${nombreDe(pase)}';

  /// Siempre completo (también con los valores por defecto).
  Map<String, Object?> toJson() => {
    'activos': activos,
    'nombres': [...nombres],
    'marcharAlEnviar': marcharAlEnviar,
  };

  PasesConfig copyWith({
    bool? activos,
    List<String>? nombres,
    bool? marcharAlEnviar,
  }) => PasesConfig(
    activos: activos ?? this.activos,
    nombres: nombres == null ? this.nombres : List.unmodifiable(nombres),
    marcharAlEnviar: marcharAlEnviar ?? this.marcharAlEnviar,
  );

  static List<String> _leerNombres(List<Object?> lista) {
    if (lista.isEmpty || lista.length > maxPases) {
      throw FormatException(
        "Campo 'nombres': se esperaban entre 1 y $maxPases pases y hay "
        '${lista.length}',
      );
    }
    final nombres = <String>[];
    for (var i = 0; i < lista.length; i++) {
      final nombre = lista[i];
      if (nombre is! String) {
        throw FormatException("Campo 'nombres[$i]': se esperaba String");
      }
      if (nombre.trim().isEmpty) {
        throw FormatException("Campo 'nombres[$i]': el nombre está vacío");
      }
      if (nombre.length > maxLongitudNombre) {
        throw FormatException(
          "Campo 'nombres[$i]': el nombre pasa de $maxLongitudNombre "
          'caracteres',
        );
      }
      nombres.add(nombre);
    }
    return List.unmodifiable(nombres);
  }

  @override
  List<Object?> get props => [activos, nombres, marcharAlEnviar];
}
