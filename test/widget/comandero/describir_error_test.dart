import 'package:flutter_test/flutter_test.dart';
import 'package:proyecto_comandero/core/errors/app_exception.dart';
import 'package:proyecto_comandero/core/network/protocol/transport_messages.dart';
import 'package:proyecto_comandero/features/comandero/domain/comandero_exceptions.dart';
import 'package:proyecto_comandero/features/comandero/presentation/comandero_widgets.dart';
import 'package:proyecto_comandero/features/sala/protocol/sala_messages.dart';

void main() {
  group('describirError', () {
    test('unknown_type de un host antiguo se traduce a un texto amable', () {
      const error = RemoteRequestException(
        "Tipo 'comanda.pase.marchar' desconocido",
        code: ErrorCodes.unknownType,
      );
      expect(describirError(error), kMensajeHostAntiguo);
      expect(
        describirError(error),
        'El TPV no admite esta función: actualiza la aplicación del TPV',
      );
      // El controlador lo deja pasar sin tipar: el texto es el mismo.
      final sinTipar = ComanderoSalaException.desde(error, mesaId: 'm1');
      expect(sinTipar, same(error));
      expect(describirError(sinTipar), kMensajeHostAntiguo);
    });

    test('los códigos de pase muestran el mensaje del host', () {
      const sinLineas = ComanderoSalaException(
        'La mesa Mesa 7 no tiene líneas de Segundos',
        code: SalaErrorCodes.paseSinLineas,
        mesaId: 'm7',
      );
      expect(
        describirError(sinLineas),
        'La mesa Mesa 7 no tiene líneas de Segundos',
      );
      const noValido = ComanderoSalaException(
        'El pase 4 no existe',
        code: SalaErrorCodes.paseNoValido,
        mesaId: 'm7',
      );
      expect(describirError(noValido), 'El pase 4 no existe');

      // Del host llegan como RemoteRequestException y el controlador los
      // tipa con la mesa; el texto sigue siendo el del host.
      final tipada = ComanderoSalaException.desde(
        const RemoteRequestException(
          'La mesa Mesa 7 no tiene líneas de Segundos',
          code: SalaErrorCodes.paseSinLineas,
        ),
        mesaId: 'm7',
      );
      expect(
        tipada,
        isA<ComanderoSalaException>()
            .having((e) => e.paseSinLineas, 'paseSinLineas', isTrue)
            .having((e) => e.paseNoValido, 'paseNoValido', isFalse)
            .having((e) => e.mesaId, 'mesaId', 'm7')
            .having((e) => e.retryable, 'retryable', isFalse),
      );
      expect(
        describirError(tipada),
        'La mesa Mesa 7 no tiene líneas de Segundos',
      );
      expect(
        ComanderoSalaException.desde(
          const RemoteRequestException(
            'El pase 4 no existe',
            code: SalaErrorCodes.paseNoValido,
          ),
        ),
        isA<ComanderoSalaException>().having(
          (e) => e.paseNoValido,
          'paseNoValido',
          isTrue,
        ),
      );
    });

    test('los demás errores conservan su mensaje', () {
      expect(
        describirError(
          const RemoteRequestException(
            'Error interno del host',
            code: ErrorCodes.internal,
            retryable: true,
          ),
        ),
        'Error interno del host',
      );
      expect(
        describirError(const SinConexionException()),
        'No hay conexión con el host',
      );
      expect(
        describirError(const ValidationException('Cantidad no válida')),
        'Cantidad no válida',
      );
    });
  });
}
