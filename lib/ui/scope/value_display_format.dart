enum ValueDisplayFormat { normal, scientific }

String formatValue(double value, ValueDisplayFormat format) {
  switch (format) {
    case ValueDisplayFormat.normal:
      return value.toStringAsFixed(2);
    case ValueDisplayFormat.scientific:
      return value.toStringAsExponential(3);
  }
}

enum IntDisplayFormat { decimal, hex, binary }

String formatIntValue(double value, IntDisplayFormat format) {
  final intVal = value.round();
  switch (format) {
    case IntDisplayFormat.decimal:
      return intVal.toString();
    case IntDisplayFormat.hex:
      return '0x${intVal.toRadixString(16).toUpperCase()}';
    case IntDisplayFormat.binary:
      return '0b${intVal.toRadixString(2)}';
  }
}
