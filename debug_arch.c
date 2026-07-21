#include "debug_arch.h"
#include "FreeRTOS.h"
#include "task.h"
#include "semphr.h"
#include "event_groups.h" // 务必在 FreeRTOSConfig.h 中启用 Event Groups
#include <string.h>
#include <stdio.h>
#include <stdarg.h>


#pragma warning disable = 188
#pragma warning disable = 138

/* ================= 配置与定义 ================= */
#define MAX_DEBUG_VARS  400
#define TX_BUF_SIZE     255  // 统一发送缓冲区
#define RX_BUF_SIZE     512  // 接收缓冲区
debug_port_t* debug_init_struct = NULL;
// 协议常量
#define CMD_HANDSHAKE       0x00
#define CMD_WRITE           0x55
#define CMD_REGISTER        0x56
#define CMD_TEXT            0x57
#define CMD_STATIC_REFRESH  0x58
#define CMD_BULK_HFREQ      0xFC


// RTOS 事件位
#define EVT_CONNECTED   (1 << 0) // Bit 0: 上位机已连接

/* ================= 类型定义 ================= */

typedef struct {
    char name[11];      // 10 chars + \0
    uint8_t type;       // VarType_t
    void* addr;         // 4字节指针
} DebugObj_t;

/* ================= 静态变量 ================= */
static DebugObj_t xdata debugTable[MAX_DEBUG_VARS];
static uint16_t debugVarCount = 0;
static uint8_t xdata txPkt[TX_BUF_SIZE]; // 统一发送缓冲，运行时 memset 初始化
static char xdata print_buf[512];        // 运行时 memset 初始化

/*================== 互斥锁   ================= */

SemaphoreHandle_t xLogMutex = NULL;

/*================== 信号量 =====================*/

SemaphoreHandle_t xDebugReadySignal = NULL;

// RTOS 句柄
static EventGroupHandle_t xDebugEventGroup = NULL;

/* ================= 外部回调 ================= */
extern void Debug_OnTextReceived(char* str, uint8_t len);

/* ================= 核心工具函数 ================= */
static uint16_t Debug_Arch_CRC16(uint8_t *pData, uint16_t len) {
    uint16_t crc_res;
    taskENTER_CRITICAL();
    CRC_CR = 0x83; 
    CRC_SetInitial16(0xFFFF);
    while(len--) {
        CRC_DIN = *pData++;
    }
    crc_res = ((uint16_t)CRC_DOH << 8) | CRC_DOL;
    taskEXIT_CRITICAL();
    return crc_res;
}

// 串口写入封装
static void Debug_Arch_Write(uint8_t *pData, uint16_t len) {
   debug_init_struct->debug_write(pData,len);
}

// 串口读取封装
static uint16_t Debug_Arch_Read(uint8_t *pData, uint16_t len) {
   return debug_init_struct->debug_read(pData,len);
   // return UART5_Read((char *)pData, len);
}
// 获取类型长度
static uint8_t GetTypeSize(uint8_t type) {
    switch(type) {
        case DBG_UINT8: case DBG_INT8: return 1;
        case DBG_UINT16: case DBG_INT16: return 2;
        case DBG_UINT32: case DBG_INT32: case DBG_FLOAT: return 4;
        default: return 0;
    }
}

/**
 * @brief [核心精简] 通用发送函数
 * @param id   Packet ID (0x00-0x0F:变量, 0xFE:元数据, 0xFF:日志, 0xFD:握手)
 * @param type Packet Type (用于变量/日志类型，握手时填0)
 * @param payload 指向数据负载
 * @param len  负载长度
 */
static void Debug_TxCore(uint8_t id, uint8_t type, uint8_t *payload, uint8_t len) {
    uint16_t crc;
    uint8_t pktLen = 4 + len; // Head(1)+ID(1)+Type(1)+Len(1) + Payload(n)

    // 1. 组包头
    txPkt[0] = 0xAA;
    txPkt[1] = id;
    txPkt[2] = type;
    txPkt[3] = len;

    // 2. 拷贝负载
    if(len > 0 && payload != NULL) {
        memcpy(&txPkt[4], payload, len);
    }

    if(len > (TX_BUF_SIZE - 6)){
        len = TX_BUF_SIZE - 6;
    }
		
    // 3. 计算 CRC (范围: ID ~ Payload结束)
    crc = Debug_Arch_CRC16(&txPkt[1], pktLen - 1);

    // 4. 填充 CRC
    txPkt[pktLen]     = (uint8_t)(crc >> 8);
    txPkt[pktLen + 1] = (uint8_t)(crc & 0xFF);

    // 5. 发送
    Debug_Arch_Write(txPkt, pktLen + 2);
}

/* ================= 业务发送函数 ================= */

// 发送元数据 (ID=0xFE)
static void Debug_SendMetaPacket(uint8_t id) {
    uint8_t buf[16]; // 临时组装 [ID][Type][Addr4][Name10]
    if(id >= debugVarCount) return;

    buf[0] = id;
    buf[1] = debugTable[id].type;
    memcpy(&buf[2], &debugTable[id].addr, 4); // C251 4字节指针拷贝
    memset(&buf[6], 0, 10);
    strncpy((char*)&buf[6], debugTable[id].name, 10);
    if(xSemaphoreTake(xLogMutex,pdMS_TO_TICKS(10)) == pdTRUE){
        Debug_TxCore(0xFE, 0xFF, buf, 16);
        xSemaphoreGive(xLogMutex);
    }
    
}

// 发送变量值 (ID=0..N)
static void Debug_SendValuePacket(uint8_t id) {
    uint8_t len;
    uint8_t temp_buf[4];
    uint8_t* pData;
    DebugPeriDesc_t* desc;

    len = GetTypeSize(debugTable[id].type & DataType_Msk);
    if(len > 0) {
        pData = (uint8_t*)debugTable[id].addr;

        if((debugTable[id].type & PeriType_Msk) != 0) {
            desc = (DebugPeriDesc_t*)debugTable[id].addr;
            if(desc && desc->read_cb) {
                desc->read_cb(desc->peri_addr, temp_buf, len);
                pData = temp_buf;
            } else {
                return;
            }
        }

        if(xSemaphoreTake(xLogMutex,pdMS_TO_TICKS(10)) == pdTRUE){
            Debug_TxCore(id, debugTable[id].type, pData, len);
            xSemaphoreGive(xLogMutex);
        }
    }
}

// 1. 底层核心函数：直接接收 va_list
void vDebug_Log(const char* fmt, va_list args) {
    if (xLogMutex != NULL) {
        if (xSemaphoreTake(xLogMutex, pdMS_TO_TICKS(100)) == pdTRUE) {
            // 注意：没有 vsnprintf 时，确保 print_buf 足够大以防溢出
            memset(print_buf, 0x00, sizeof(print_buf));

            // 使用 vsprintf 解析 va_list
            vsprintf(print_buf, fmt, args); 
            
            Debug_TxCore(0xFF, DBG_STRING, (uint8_t*)print_buf, strlen(print_buf));

            xSemaphoreGive(xLogMutex);
        } else {
            // 信号量获取失败处理
            while(1); 
        }
    }
}

// 2. 对外的通用日志接口
void Debug_Log(const char* fmt, ...) {
    va_list args;
    va_start(args, fmt);
    vDebug_Log(fmt, args); // 转发给底层函数
    va_end(args);
}

static uint8_t FindFrameHeader(void) {
    uint8_t byte;
    uint16_t max_search = 64; // 最多查找 64 字节，防止无限循环

    while(max_search--) {
        // 尝试读取 1 字节
        if(Debug_Arch_Read(&byte, 1) != 1) {
            return 0; // 没有数据可读
        }
        if(byte == 0x55) {
            return 1; // 找到帧头
        }
        // 不是帧头，继续查找（已经消费掉这个字节）
    }
    return 0; // 查找超时
}

// 辅助函数：分片发送长字符串
// buffer: 待发送的长字符串（例如 CPU 统计信息）
void Debug_LogLongString(char *buffer) {
    char *pStart = buffer;
    char *pNext;
    
    while (*pStart != '\0') {
        // 寻找下一行
        pNext = strchr(pStart, '\n');
        
        if (pNext != NULL) {
            *pNext = '\0'; // 临时截断
            Debug_Log("%s\n", pStart); // 发送一行
            *pNext = '\n'; // 恢复
            pStart = pNext + 1; // 移动指针
        } else {
            Debug_Log("%s", pStart); // 发送最后一行
            break;
        }
        
        // 关键：给 DMA 和 RTOS 一点喘息时间
        // 如果不加延时，连续的 Debug_Log 可能会填满串口 RingBuffer 导致丢包
        vTaskDelay(pdMS_TO_TICKS(10)); 
    }
}

/* ================= 注册与接收逻辑 ================= */

// 注册变量
void Debug_Register(char* name, uint8_t type, void* addr) {
    if(debugVarCount < MAX_DEBUG_VARS) {
        memset(debugTable[debugVarCount].name, 0, 11);
        strncpy(debugTable[debugVarCount].name, name, 10);
        debugTable[debugVarCount].type = type;
        debugTable[debugVarCount].addr = addr;
        debugVarCount++;
    }
}

static void Debug_SendBulkHighFreqPacket(void) {
    uint8_t i;
    uint8_t payload_len = 0;
    uint8_t xdata temp_buf[MAX_DEBUG_VARS * 5];
    uint8_t peri_buf[4];
    DebugPeriDesc_t* desc;
    uint8_t* pSrc;

    for(i = 0; i < debugVarCount; i++) {
        // 判断是否为高频变量
        if((debugTable[i].type & FreqType_Msk) != 0) {
            uint8_t var_len = GetTypeSize(debugTable[i].type & DataType_Msk);

            // 防止越界保护
            if(var_len > 0 && (payload_len + 1 + var_len) <= sizeof(temp_buf)) {
                // 1. 写入变量 ID
                temp_buf[payload_len++] = i;

                // 2. 获取数据源指针（外设变量通过回调读取到 peri_buf）
                if((debugTable[i].type & PeriType_Msk) != 0) {
                    desc = (DebugPeriDesc_t*)debugTable[i].addr;
                    if(desc && desc->read_cb) {
                        desc->read_cb(desc->peri_addr, peri_buf, var_len);
                        pSrc = peri_buf;
                    } else {
                        continue;
                    }
                } else {
                    pSrc = (uint8_t*)debugTable[i].addr;
                }

                memcpy(&temp_buf[payload_len], pSrc, var_len);

                payload_len += var_len;
            }
        }
    }

    // 如果有数据被打包，则统一发送
    if(payload_len > 0) {
        if(xSemaphoreTake(xLogMutex, pdMS_TO_TICKS(10)) == pdTRUE) {
            // 参数说明：ID填0xFC, Type填0(用不到), 传入聚合后的负载和总长度
            Debug_TxCore(CMD_BULK_HFREQ, 0x00, temp_buf, payload_len);
            xSemaphoreGive(xLogMutex);
        }
    }
}

// [核心精简] 统一接收处理
static uint8_t xdata rxBuf[RX_BUF_SIZE]; // 接收缓冲，每次使用前完整写入，无需 Flash 镜像
static void Debug_ProcessIncoming(void) {
    
    uint16_t crc_calc, crc_recv;
    uint8_t cmd;
		uint16_t len;
		uint8_t i;
		uint8_t id;
		uint8_t vLen;
        volatile uint8_t *ptr;
        DebugPeriDesc_t* desc;
        /* char logbuf[32]; */
    // 1. 预读头部 [0x55] [CMD] [LEN]
    if(!FindFrameHeader()) return;
    if(Debug_Arch_Read(&rxBuf[1], 2) != 2) return;

    rxBuf[0] = 0x55; // 帧头
    
    cmd = rxBuf[1];
    len = rxBuf[2];
    if(len > RX_BUF_SIZE - 5) return; // 保护

    // 2. 读取 [Payload...] + [CRC(2)]
    if(Debug_Arch_Read(&rxBuf[3], len + 2) == (len + 2)) {
        
        // 3. 校验 CRC (范围: CMD, LEN, Payload)
        crc_calc = Debug_Arch_CRC16(&rxBuf[1], len + 2);
        crc_recv = ((uint16_t)rxBuf[3+len] << 8) | rxBuf[4+len];

        if(crc_calc != crc_recv) return;

        // 4. 命令分发
        switch(cmd) {
            // ---> 握手请求 (Payload: 4 Bytes Magic)
            case CMD_HANDSHAKE:
                if(len == 4) {
                    if(xSemaphoreTake(xLogMutex, pdMS_TO_TICKS(10)) == pdTRUE) {
                        Debug_TxCore(0xFD, 0x00, &rxBuf[3], 4);
                        xSemaphoreGive(xLogMutex);
                    }
                    
                    // RTOS 事件组：标记连接 (确保 vDebugTask 可以开始发送 value 报文)
                    xEventGroupSetBits(xDebugEventGroup, EVT_CONNECTED);
                    
                    // 【修改点】：移除原有的 if 判断，每次握手都强制遍历并发送所有元数据
                    vTaskDelay(pdMS_TO_TICKS(10)); // 防止突发
                    for(i=0; i<debugVarCount; i++) {
                        Debug_SendMetaPacket(i);
                        vTaskDelay(pdMS_TO_TICKS(5)); // 防止突发，避免填满串口缓冲区
                    }
                }
                break;

            // ---> 写变量 (Payload: ID, Len, Data...)
            case CMD_WRITE:
                {
                    id = rxBuf[3];
                    vLen = rxBuf[4];
                    if(id < debugVarCount) {
                        if((debugTable[id].type & PeriType_Msk) != 0) {
                            desc = (DebugPeriDesc_t*)debugTable[id].addr;
                            if(desc && desc->write_cb) {
                                desc->write_cb(desc->peri_addr, &rxBuf[5], vLen);
                            }
                        } else {
                            taskENTER_CRITICAL();
                            ptr = (uint8_t *)(debugTable[id].addr);
                            ptr[0] = rxBuf[5];
                            if(vLen > 1) ptr[1] = rxBuf[6];
                            if(vLen > 2) ptr[2] = rxBuf[7];
                            if(vLen > 3) ptr[3] = rxBuf[8];
                            taskEXIT_CRITICAL();
                        }
                    }
                }
                break;

            // ---> 动态注册 (Payload: Type, Addr4, Name10)
            case CMD_REGISTER:
                if(len == 15 && debugVarCount < MAX_DEBUG_VARS) {
                    debugTable[debugVarCount].type = rxBuf[3];
                    memcpy(&debugTable[debugVarCount].addr, &rxBuf[4], 4);
                    memset(debugTable[debugVarCount].name, 0, 11);
                    strncpy(debugTable[debugVarCount].name, (char*)&rxBuf[8], 10);
                    
                    // 注册成功，补发 Meta
                    //delay_ms(2);
                    debugVarCount++;//先增加计数器
                    Debug_SendMetaPacket(debugVarCount-1);
                    //delay_ms(2);
                    
                }
                break;

            // ---> 文本传输
            case CMD_TEXT:
                rxBuf[3+len] = '\0'; // 安全截断
                Debug_OnTextReceived((char*)&rxBuf[3], len);
                break;

            // ---> 请求刷新静态变量 (Payload: ID)
            case CMD_STATIC_REFRESH:
                {
                    id = rxBuf[3];
                    if(id < debugVarCount) {
                        // 检查是否为静态变量
                        if((debugTable[id].type & StaticType_Msk) != 0) {
                            Debug_SendValuePacket(id);
                    }
                }
            }
            break;

        }
    }
}


/*================== 初始化 =================== */

void Debug_Init(debug_port_t* debug_port_initstruct){
    memset(txPkt,     0, sizeof(txPkt));
    memset(print_buf, 0, sizeof(print_buf));
    /* debugTable 不在此清零 — Debug_Register() 在调度器启动前已填充各 entry */
    if(debug_port_initstruct!=NULL)
        debug_init_struct = debug_port_initstruct;
    xLogMutex = xSemaphoreCreateMutex();
    xDebugReadySignal = xSemaphoreCreateBinary();
   // UART5_Init();
}


/* ================= 任务主体 ================= */
#define RECEIVE_FREQ 2
#define HIGH_FREQ 1
#define LOW_FREQ 10
void vDebugTask(void *pvParameters) {
    uint8_t i;
    //TickType_t xLastWakeTime;
    //TickType_t xLastWakeTimeHighFreq;
    //const TickType_t xFrequency = pdMS_TO_TICKS(100); // 10Hz 发送频率
    TickType_t t=0;
    (void)pvParameters;

    // 1. 初始化事件组
    xDebugEventGroup = xEventGroupCreate();
    xEventGroupClearBits(xDebugEventGroup, EVT_CONNECTED);

    // 初始化时间戳
    //xLastWakeTime = xTaskGetTickCount();
    //xLastWakeTimeHighFreq = xTaskGetTickCount();
    xSemaphoreGive(xDebugReadySignal);
    for(;;) {
        vTaskDelay(pdMS_TO_TICKS(10));
        t++;
        // A. 快速处理接收指令 (Poll)
        if(t%RECEIVE_FREQ==0){
            Debug_ProcessIncoming();
            //Receive=0;
        }
        if (xEventGroupGetBits(xDebugEventGroup) & EVT_CONNECTED){
            if(t%HIGH_FREQ==0){
                //HighFreqTx=0;
                Debug_SendBulkHighFreqPacket();
            }
            if(t%LOW_FREQ==0){
               // LowFreqTx=0;
				//Debug_Log("log_test\r\n");
                for(i = 0; i < debugVarCount; i++) {
                    // 只发送低频且非静态的变量
                    if(((debugTable[i].type & FreqType_Msk) == 0) &&
                       ((debugTable[i].type & StaticType_Msk) == 0)) {
                        Debug_SendValuePacket(i);
                    }
                }
            }
        }
    }
}