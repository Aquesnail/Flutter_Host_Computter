enum LogType { rx, tx, info, error }

class LogEntry {
  final DateTime timestamp;
  final LogType type;
  final String content;

  LogEntry(this.type, this.content) : timestamp = DateTime.now();

  String get timeStr {
    final h = timestamp.hour.toString().padLeft(2, '0');
    final m = timestamp.minute.toString().padLeft(2, '0');
    final s = timestamp.second.toString().padLeft(2, '0');
    final ms = timestamp.millisecond.toString().padLeft(3, '0');
    return "$h:$m:$s.$ms";
  }
}
