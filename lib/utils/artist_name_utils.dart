String cleanArtistName(String? input) {
  var value = (input ?? '').trim();
  if (value.isEmpty) return '';

  // Corrige conectores pegados entre artistas en formato CamelCase:
  // "CamiloyEvaluna Montaner" -> "Camilo y Evaluna Montaner"
  // "ArtistxGuest" -> "Artist x Guest"
  value = _normalizeGluedArtistConnectors(value);

  value = value.replaceAll(
    RegExp(r'\s*[-–—]\s*topic\s*$', caseSensitive: false),
    '',
  );
  value = value.replaceAll(
    RegExp(r'\s*[\(\[]\s*topic\s*[\)\]]\s*$', caseSensitive: false),
    '',
  );
  value = value.replaceAll(RegExp(r'\s+'), ' ').trim();

  return value;
}

String _normalizeGluedArtistConnectors(String input) {
  var value = input;
  const lower = 'a-záéíóúüñ';
  const upper = 'A-ZÁÉÍÓÚÜÑ';

  final connectorPatterns = <String>[
    'y',
    'x',
    '&',
  ];

  for (final connector in connectorPatterns) {
    value = value.replaceAllMapped(
      RegExp('([$lower])${RegExp.escape(connector)}([$upper])'),
      (m) => '${m[1]} $connector ${m[2]}',
    );
    value = value.replaceAllMapped(
      RegExp('([$upper])${RegExp.escape(connector)}([$upper])'),
      (m) => '${m[1]} $connector ${m[2]}',
    );
  }

  return value;
}
