class RegisteredVar {
  final int id;
  final String name;
  final int type; // 纯类型 (0-6)
  final int addr;
  final bool isHighFreq; // 是否高频
  final bool isStatic; // 是否静态变量（不主动刷新）
  dynamic value;

  RegisteredVar(this.id, this.name, this.type, this.addr,
      {this.value = 0, this.isHighFreq = false, this.isStatic = false});
}
