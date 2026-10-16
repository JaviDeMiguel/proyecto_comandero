/// `FsHttpApi.close` termina aunque un oyente tenga en pausa su suscripción
/// a [FsHttpApi.guardStates].
library;

import 'package:proyecto_comandero/core/facturascripts/fs_api_config.dart';
import 'package:proyecto_comandero/core/facturascripts/fs_http_api.dart';
import 'package:test/test.dart';

void main() {
  test('close no espera a un oyente de guardStates en pausa', () async {
    final api = FsHttpApi(
      FsApiConfig(baseUrl: 'http://erp.local/fs', token: 'secreto'),
    );
    final suscripcion = api.guardStates.listen((_) {})..pause();
    addTearDown(suscripcion.cancel);

    await expectLater(
      api.close().timeout(const Duration(seconds: 2)),
      completes,
    );
  });
}
