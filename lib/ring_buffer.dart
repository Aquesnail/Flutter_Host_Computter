import 'dart:typed_data';

class RingBuffer {
  // 1. 去掉 final，因为我们要替换它们
  int _capacity; 
  Float64List _data; 
  
  int _writeIndex = 0;
  int _count = 0;
  // int _totalWritten = 0; // 这个仅用于调试或统计，逻辑上非必须，如果没用到可以不管

  RingBuffer(int capacity) 
      : _capacity = capacity, 
        _data = Float64List(capacity);

  int get capacity => _capacity;
  int get length => _count;

  void add(double value) {
    _data[_writeIndex] = value;
    _writeIndex = (_writeIndex + 1) % _capacity;
    if (_count < _capacity) {
      _count++;
    }
  }

  void clear() {
    _writeIndex = 0;
    _count = 0;
    // _data 不需要清零，重置指针即可，性能更高
  }

  double operator [](int index) {
    if (index < 0 || index >= _count) return 0.0;
    // 逻辑转物理索引
    int physicalIndex;
    if (_count < _capacity) {
      physicalIndex = index;
    } else {
      physicalIndex = (_writeIndex + index) % _capacity;
    }
    return _data[physicalIndex];
  }

  // --- 【新增】 核心扩容/缩容逻辑 ---
  void resize(int newCapacity) {
    if (newCapacity <= 0 || newCapacity == _capacity) return;

    final newBuffer = Float64List(newCapacity);
    
    // 1. 计算需要搬运的数据量
    // 如果扩容：搬运所有数据 (_count)
    // 如果缩容：只搬运最新的 newCapacity 个数据
    int itemsToCopy = _count > newCapacity ? newCapacity : _count;

    // 2. 搬运数据 (利用现有的 operator[] 自动处理回环逻辑)
    // 我们把旧数据中最旧的，搬到新数组的 0，依次类推
    // 如果是缩容，我们要跳过旧数据头部那部分被截断的
    int skipOffset = _count - itemsToCopy; // 如果缩容，跳过前面 skipOffset 个

    for (int i = 0; i < itemsToCopy; i++) {
      // 从旧 buffer 读 (逻辑索引 + 偏移)
      // 写入新 buffer (从 0 开始顺序写)
      newBuffer[i] = this[skipOffset + i];
    }

    // 3. 替换内部状态
    _data = newBuffer;
    _capacity = newCapacity;
    _count = itemsToCopy;     // 更新计数
    _writeIndex = itemsToCopy % newCapacity; // 指针指向下一个空位
    
    // 如果刚好填满，writeIndex 应该是 0
  }
}