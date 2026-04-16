String cleanArtistName(String? input) {
  var value = (input ?? '').trim();
  if (value.isEmpty) return '';

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

