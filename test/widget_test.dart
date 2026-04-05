import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myapp/audio_handler.dart';
import 'package:myapp/main.dart';

void main() {
  // Inicializa el AudioHandler antes de que se ejecuten los tests,
  // ya que la app depende de que esta variable global esté inicializada.
  setUpAll(() async {
    await initAudioService();
  });

  testWidgets('Muestra las pestañas Buscar y Descargas', (WidgetTester tester) async {
    // Construye la app y renderiza un frame.
    await tester.pumpWidget(const MyApp());

    // Espera a que la UI se estabilice.
    await tester.pumpAndSettle();

    // Verifica que la barra de pestañas está presente.
    expect(find.byType(CupertinoTabScaffold), findsOneWidget);
    expect(find.byType(CupertinoTabBar), findsOneWidget);

    // Verifica que las pestañas "Buscar" y "Descargas" existen.
    expect(find.text('Buscar'), findsOneWidget);
    expect(find.text('Descargas'), findsOneWidget);

    // Verifica que los iconos de búsqueda y descarga están presentes.
    expect(find.byIcon(CupertinoIcons.search), findsOneWidget);
    expect(find.byIcon(CupertinoIcons.down_arrow), findsOneWidget);
  });
}
