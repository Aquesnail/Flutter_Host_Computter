class RegisteredVar {
  final int id;
  final String name;
  final int type; // 纯类型 (0-6)
  final int addr;
  final bool isHighFreq; // 是否高频
  final bool isStatic; // 是否静态变量（不主动刷新）
  final bool isPeri; // 是否外设变量（I2C/SPI 等）
  final int category; // 语义分类 (0x00~0xFF, 0xFF=未分类)
  final int element;  // 元素类型 (0x00=全局, 0x01=直线, 0x02=十字, 0x03=环岛, 0x04=墙面)
  dynamic value;

  RegisteredVar(this.id, this.name, this.type, this.addr,
      {this.value = 0,
      this.isHighFreq = false,
      this.isStatic = false,
      this.isPeri = false,
      this.category = 0xFF,
      this.element = 0x00});
}
