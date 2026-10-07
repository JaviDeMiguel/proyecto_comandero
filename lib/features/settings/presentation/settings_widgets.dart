import 'package:flutter/material.dart';

import '../../../core/errors/app_exception.dart';
import 'settings_diagnostics.dart';

/// Texto de un error para el usuario.
String textoDeError(Object error) => switch (error) {
  AppException(:final message) => message,
  StateError(:final message) => message,
  _ => 'Error inesperado: $error',
};

/// Tarjeta de una sección del formulario de ajustes.
class SeccionAjustes extends StatelessWidget {
  const SeccionAjustes({
    super.key,
    required this.titulo,
    required this.icono,
    required this.children,
    this.descripcion,
  });

  final String titulo;
  final IconData icono;
  final String? descripcion;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(icono, color: theme.colorScheme.primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(titulo, style: theme.textTheme.titleLarge),
                ),
              ],
            ),
            if (descripcion != null) ...[
              const SizedBox(height: 4),
              Text(
                descripcion!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(height: 16),
            for (final (i, child) in children.indexed) ...[
              if (i > 0) const SizedBox(height: 12),
              child,
            ],
          ],
        ),
      ),
    );
  }
}

/// Botón de acción que muestra un indicador mientras [ocupado].
class BotonDiagnostico extends StatelessWidget {
  const BotonDiagnostico({
    super.key,
    required this.texto,
    required this.icono,
    required this.ocupado,
    required this.onPressed,
  });

  final String texto;
  final IconData icono;
  final bool ocupado;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: ocupado ? null : onPressed,
      icon: ocupado
          ? const SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(icono),
      label: Text(texto),
    );
  }
}

/// Color e icono de un nivel de diagnóstico.
(IconData, Color) estiloNivel(BuildContext context, DiagnosticoNivel nivel) {
  final scheme = Theme.of(context).colorScheme;
  return switch (nivel) {
    DiagnosticoNivel.ok => (Icons.check_circle, Colors.green.shade700),
    DiagnosticoNivel.aviso => (Icons.warning_amber, Colors.orange.shade800),
    DiagnosticoNivel.error => (Icons.error, scheme.error),
  };
}

/// Una línea de resultado (ok / aviso / error).
class ResultadoLinea extends StatelessWidget {
  const ResultadoLinea({
    super.key,
    required this.nivel,
    required this.titulo,
    this.detalle,
  });

  final DiagnosticoNivel nivel;
  final String titulo;
  final String? detalle;

  @override
  Widget build(BuildContext context) {
    final (icono, color) = estiloNivel(context, nivel);
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icono, color: color, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(titulo, style: theme.textTheme.bodyMedium),
                if (detalle != null && detalle!.isNotEmpty)
                  Text(
                    detalle!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Lista de resultados de `diagnosticar`.
class ListaDiagnostico extends StatelessWidget {
  const ListaDiagnostico({super.key, required this.items});

  final List<DiagnosticoItem> items;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final item in items)
          ResultadoLinea(
            key: ValueKey('diagnostico-${item.codigo}'),
            nivel: item.nivel,
            titulo: item.titulo,
            detalle: item.detalle,
          ),
      ],
    );
  }
}

/// Informe de las tablas `tpv_*` ([SchemaInspection]).
class InformeEsquema extends StatelessWidget {
  const InformeEsquema({super.key, required this.informe});

  final SchemaInspection informe;

  @override
  Widget build(BuildContext context) {
    final referencia = informe.referencia;
    final faltan = informe.missingTables.toList()..sort();
    final existen = informe.existingTables.toList()..sort();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ResultadoLinea(
          nivel: informe.variantesExists
              ? DiagnosticoNivel.ok
              : DiagnosticoNivel.error,
          titulo: informe.variantesExists
              ? 'Tabla variantes encontrada'
              : 'No existe la tabla variantes',
          detalle: informe.variantesExists
              ? null
              : 'La base de datos no es una instalación de FacturaScripts '
                    'soportada.',
        ),
        if (referencia != null)
          ResultadoLinea(
            nivel: referencia.hasUniqueIndex
                ? DiagnosticoNivel.ok
                : DiagnosticoNivel.error,
            titulo: 'variantes.referencia: ${referencia.columnType}',
            detalle: [
              if (referencia.collation != null) referencia.collation!,
              referencia.hasUniqueIndex
                  ? 'con índice único'
                  : 'SIN índice único (la clave ajena no puede crearse)',
            ].join(' · '),
          ),
        ResultadoLinea(
          nivel: faltan.isEmpty ? DiagnosticoNivel.ok : DiagnosticoNivel.aviso,
          titulo: faltan.isEmpty
              ? 'Tablas del TPV completas'
              : 'Faltan tablas: ${faltan.join(', ')}',
          detalle: existen.isEmpty ? null : 'Existen: ${existen.join(', ')}',
        ),
        for (final aviso in informe.warnings)
          ResultadoLinea(nivel: DiagnosticoNivel.aviso, titulo: aviso),
      ],
    );
  }
}

/// Recuadro de aviso destacado (riesgos de configuración).
class AvisoDestacado extends StatelessWidget {
  const AvisoDestacado({super.key, required this.texto, this.peligro = false});

  final String texto;
  final bool peligro;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fondo = peligro
        ? scheme.errorContainer
        : scheme.surfaceContainerHighest;
    final texto0 = peligro ? scheme.onErrorContainer : scheme.onSurfaceVariant;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: fondo,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              peligro ? Icons.warning_amber : Icons.info_outline,
              color: texto0,
              size: 20,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(texto, style: TextStyle(color: texto0)),
            ),
          ],
        ),
      ),
    );
  }
}
