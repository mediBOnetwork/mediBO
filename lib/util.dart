/// Turns a raw therapeutic-class value ("GASTRO INTESTINAL") into a display
/// label ("Gastro Intestinal"). Leaves "All" untouched and keeps "CNS" upper.
String prettyCategory(String raw) {
  if (raw.isEmpty || raw == 'All') return raw;
  final titled = raw
      .toLowerCase()
      .split(RegExp(r'\s+'))
      .map((w) =>
          w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1)}')
      .join(' ');
  return titled.replaceAll('Cns', 'CNS');
}

/// Formats a value as Indian Rupees, e.g. 1234567.5 -> "₹12,34,567.50".
String rupees(double value) {
  final negative = value < 0;
  final fixed = value.abs().toStringAsFixed(2);
  final parts = fixed.split('.');
  final intPart = parts[0];
  final decPart = parts[1];

  late final String grouped;
  if (intPart.length <= 3) {
    grouped = intPart;
  } else {
    // Indian grouping: rightmost 3 digits, then groups of 2.
    final last3 = intPart.substring(intPart.length - 3);
    var rest = intPart.substring(0, intPart.length - 3);
    final groups = <String>[];
    while (rest.length > 2) {
      groups.insert(0, rest.substring(rest.length - 2));
      rest = rest.substring(0, rest.length - 2);
    }
    if (rest.isNotEmpty) groups.insert(0, rest);
    grouped = '${groups.join(',')},$last3';
  }
  return '${negative ? '-' : ''}₹$grouped.$decPart';
}
