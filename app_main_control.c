#include "FreeRTOS.h"
#include "task.h"

#include "config.h"
#include "adc_user.h"
#include "debug_arch.h"
#include "motor.h"
#include "motor_register_defs.h"
#include "spi3_user.h"
#include <string.h>
#include "imu_filter.h"
#include "lpf.h"
#include "moving_avg.h"
#include "fuzzy_pid.h"
#include "element.h"
#include "led_indicator.h"
#include "pwm_user.h"
#include "fan_control.h"
#pragma warning disable = 174

extern uint8_t g_current_element_u8;  /* element.c 提供的当前元素枚举值 (uint8_t 镜像) */

/* ================================================================
 * 控制管道类型定义
 * ================================================================ */

/* 内环 PI 参数 */
typedef struct {
    float Kp;
    float Ki;
    float Kd;
    float error_sum_max;
    float min_sep;
    float max_sep;
} PIParams_t;

/* 内环 PI 状态 */
typedef struct {
    float error_sum;
    float last_error;
} PIState_t;

/* ================================================================
 * 控制参数分组 (按状态机劫持点切分)
 *   AdcErrParams:    劫持点0 之前 — ADC 误差权重 (各元素可屏蔽不同电感)
 *   OuterLoopParams: 劫持点1→劫持点3 — 外环全流程
 *   ControlParams:   完整参数集 = outer + adc + inner, 每个元素配一套
 * ================================================================ */

/* 劫持点0: ADC 误差计算参数 */
typedef struct {
    float   err_A_K;
    float   err_B_K;
    float   err_C_K;
    float   err_D_K;
} AdcErrParams_t;

/* 劫持点1→劫持点3: 外环控制参数 (不含 Kd_diff, 它在 RunOuterLoop 内作为局部变量) */
typedef struct {
    float   outer_slew_max;
    float   outer_lpf_fc;
    float   gyro_lpf_fc;
    float   Kd_diff_high;
    float   Kd_diff_low;
    float   Kd_diff_thresh;
    float   diff_deadband;
    uint8_t d_ma_window;
    float   outer_Ki;
    float   outer_i_limit;
    float   outer_i_sep_hi;
    float   outer_i_sep_lo;
    float   lat_g_l_max;     /* 左转最大侧g (绝对值) */
    float   lat_g_l_safe;    /* 左转安全侧g, 超过此值开始减速 */
    float   lat_g_r_max;     /* 右转最大侧g (绝对值) */
    float   lat_g_r_safe;    /* 右转安全侧g, 超过此值开始减速 */
    float   lat_g_brake_k_spd; /* 侧g→线速度削減系数 (0~1) */
    float   lat_g_brake_k_yaw; /* 侧g→角速度削減系数 (0~1) */
    float   err_brake_max;     /* Err绝对值达到此值时减速到最大 */
    float   err_brake_safe;    /* Err绝对值低于此值不减速 */
    float   err_brake_k_spd;   /* Err→线速度削減系数 (0~1) */
    float   err_brake_k_yaw;   /* Err→角速度削減系数 (0~1) */
} OuterLoopParams_t;

/* 速度输出后处理参数 (每个元素独立配置) */
typedef struct {
    float max_output;   /* 单轮最大输出限幅 (绝对值)               */
    float min_output;   /* 单轮最小输出限幅 (死区, 低于此值置零)    */
    float max_diff;     /* 最大差速限幅 (自动 ≤ common_speed 防反转) */
    float min_diff;     /* 最小差速限幅 (死区, |diff| 低于此值置零)  */
    float slew_rate;    /* 输出斜率限制 (每 tick 最大变化量)         */
} SpeedOutputParams_t;

/* 完整控制参数集 (一个元素配一套, 上位机在线调参) */
typedef struct {
    OuterLoopParams_t   outer;
    AdcErrParams_t      adc;
    PIParams_t          inner;
    SpeedOutputParams_t speed_out;  /* 速度输出后处理 */
    FuzzyPID            fuzzy;      /* 模糊PID参数 */
} ControlParams_t;

/* 控制管线运行时状态 (每帧变化) */
typedef struct {
    float   err_slewed;
    float   err_filtered;
    Lpf_t   lpf_outer;
    float   last_err;
    MovingAvg_t d_ma;
    float   filtered_d_term;
    float   i_sum;
    float   i_term;
    Lpf_t   lpf_gyro;
    float   gyro_filtered;
    Lpf_t   lpf_lat_g;       /* v·ω 侧向加速度滤波器 */
    float   lat_g_filtered;   /* v·ω 滤波后侧向加速度 (g) */
    float   err_brake_spd;        /* Err→线速度制动系数 */
    float   err_brake_yaw;        /* Err→角速度制动系数 */
    float   combined_brake_spd;   /* 合并线速度制动系数 = min(侧g, Err) */
    float   combined_brake_yaw;   /* 合并角速度制动系数 = min(侧g, Err) */
    float   tar_yaw_raw;
    float   target_yaw;
    float   pid_output;
    PIState_t inner;
    float   last_spd_l;   /* 左轮上帧输出 (slew 限制用) */
    float   last_spd_r;   /* 右轮上帧输出 (slew 限制用) */
} ControlState_t;

/* ================================================================
 * 控制管道参数 + 状态 (Phase 3: 集中管理, 替代散落变量)
 * ================================================================ */
/* 元素专用控制参数 (cross→g_params_cross, ring→g_params_ring, 其余回落 g_params) */
static ControlParams_t g_params;         /* 默认参数 */
static ControlParams_t g_params_cross;   /* 十字专用 (屏蔽竖直电感) */
static ControlParams_t g_params_ring;    /* 环岛专用 */
static ControlParams_t g_params_wall;    /* 墙面专用 */
static ControlState_t  g_state;          /* 运行时 memset 初始化 */
static const ControlParams_t *g_active_params_prev = NULL; /* 上一帧参数集, 用于检测切换 */
static motor_data_t speed_target_l; /* 左轮速度目标 (被 ApplySpeedOutputParams / CtrlState_Seed 引用) */
static motor_data_t speed_target_r; /* 右轮速度目标 */


static void copy_params(ControlParams_t *dest, const ControlParams_t *src)
{
    memcpy(dest, src, sizeof(ControlParams_t));
}

/* 用指定值 seed 整个管线 — 退出冻结/退出开环时调用, 保证连续性 */
static void CtrlState_Seed(ControlState_t *s, const ControlParams_t *p, float seed_val)
{
    (void)p;
    s->err_slewed      = seed_val;
    s->last_err        = seed_val;
    s->i_sum           = 0.0f;
    s->i_term          = 0.0f;
    s->filtered_d_term = 0.0f;
    lpf_reset(&s->lpf_outer, seed_val);
    lpf_reset(&s->lpf_lat_g, 0.0f);
    ma_reset(&s->d_ma, 0.0f);
    s->lat_g_filtered        = 0.0f;
    s->err_brake_spd     = 1.0f;
    s->err_brake_yaw     = 1.0f;
    s->combined_brake_spd = 1.0f;
    s->combined_brake_yaw = 1.0f;
    s->inner.error_sum  = 0.0f;
    s->inner.last_error = 0.0f;
    s->last_spd_l       = speed_target_l.f;
    s->last_spd_r       = speed_target_r.f;
}


/* ================================================================
 * GetActiveParams — 根据元素返回对应参数集指针
 *   返回值变化时会触发 CtrlState_Seed 平滑过渡
 * ================================================================ */
static const ControlParams_t* GetActiveParams(element_t e)
{
    switch (e) {
    case ELEMENT_CROSS:
        return &g_params_cross;
    case ELEMENT_RING_LEFT_ENTRANCE:
    case ELEMENT_RING_RIGHT_ENTRANCE:
    case ELEMENT_RING_LEFT_PASS:
    case ELEMENT_RING_RIGHT_PASS:
    case ELEMENT_IN_RING:
        return &g_params_ring;
    case ELEMENT_WALL:
    case ELEMENT_WALL_CLIMB:
    case ELEMENT_WALL_HORIZONTAL:
    case ELEMENT_WALL_DESCEND:
        return &g_params_wall;
    default:
        return &g_params;
    }
}


/* ================================================================
 * ApplyParamsIfChanged — 参数集切换时 seed 管线, 防止突变抖动
 * ================================================================ */
static void ApplyParamsIfChanged(const ControlParams_t *p)
{
    if (p != g_active_params_prev) {
        CtrlState_Seed(&g_state, p, g_state.err_filtered);
        g_active_params_prev = p;
    }
}


/* ================================================================
 * 速度目标值宏 (临时占位, 后续调整)
 * ================================================================ */

/* ================================================================
 * TaskNotify 信号位定义
 * ================================================================ */


/* ================================================================
 * 全局变量
 * ================================================================ */

/* ADC DMA 缓冲区 */
static uint8_t xdata adc_dma_buf[ADC2_DMASIZE]; // 运行时 memset 初始化

/* ADC 各通道采样值 */
static float adc_values[ADC2_CH_NUM]; // 运行时 memset 初始化

/* 电机数据 (500Hz stream 推送) */
static float    g_left_speed_actual  = 0.0f;
static float    g_right_speed_actual = 0.0f;
static uint32_t g_mech_state         = 0;

/* 低通滤波器实例 (左右轮速度) */
static Lpf_t g_lpf_left;
static Lpf_t g_lpf_right;

/* 速度目标 & 误差 */
static motor_data_t g_left_speed_target;  // 运行时 memset 初始化
static motor_data_t g_right_speed_target; // 运行时 memset 初始化
static float g_left_speed_error  = 0.0f;
static float g_right_speed_error = 0.0f;

/* PID 参数延迟写入 (回调只置标志, Main_Control 安全点执行 SPI 写入, 避免竞态) */
static volatile uint8_t g_reg_write_pending = 0;
static uint8_t          g_reg_write_addr;
static motor_data_t     g_reg_write_value;

/* 手动模式超时保护 (3s 无指令自动刹车) */
static TickType_t g_last_manual_cmd_tick = 0;
static uint8_t    g_manual_cmd_received  = 0;

/* Stream 模式状态位 (0=已关闭, 1=已开启) */
static volatile uint8_t g_stream_active = 0;

/* 自动模式过渡状态: 0=空闲, 1=风扇已启动等待3s, 2=电机已激活 */
static uint8_t      g_auto_transition = 0;
static TickType_t   g_auto_fan_tick   = 0;



/* 任务句柄 */
TaskHandle_t xMainControlTaskHandle = NULL;

/* ================================================================
 * SPI3 DMA 回调 (预留)
 * ================================================================ */
void SPI3_Callback(void *pvParameters)
{
    (void)pvParameters;
}
/* PID 参数外设描述符 (Motor A / 左电机) */
float xdata g_pid_a_kp = 0.0f;
float xdata g_pid_a_ki = 0.0f;
float xdata g_pid_a_kd = 0.0f;
float xdata g_pid_a_ilim = 3.0f;
float xdata g_pid_b_kp = 0.0f;
float xdata g_pid_b_ki = 0.0f;
float xdata g_pid_b_kd = 0.0f;
float xdata g_pid_b_ilim = 3.0f;
/* ================================================================
 * 电机寄存器 读/写 回调 (供 Debug 系统 PERI_TYPE 使用)
 *   上位机请求 STATIC_REFRESH 时触发读, 写变量时触发写
 * ================================================================ */
static void Motor_Reg_Read_Cb(uint32_t peri_addr, void *pData, uint8_t len)
{
    float tmp;
    switch(peri_addr){
        case REG_A_PID_SPEED_KP:
            tmp = g_pid_a_kp;
            break;
        case REG_A_PID_SPEED_KI:
            tmp = g_pid_a_ki;
            break;
        case REG_A_PID_SPEED_KD:
            tmp = g_pid_a_kd;
            break;
        case REG_A_PID_SPEED_INTEGRAL_LIMIT:
            tmp = g_pid_a_ilim;
            break;
        case REG_B_PID_SPEED_KP:
            tmp = g_pid_b_kp;
            break;
        case REG_B_PID_SPEED_KI:
            tmp = g_pid_b_ki;
            break;
        case REG_B_PID_SPEED_KD:
            tmp = g_pid_b_kd;
            break;
        case REG_B_PID_SPEED_INTEGRAL_LIMIT:
            tmp = g_pid_b_ilim;
            break;
        default:
						break;
             /* 未识别寄存器地址, 返回0 */
    }
   // tmp = 0.0f;
    memcpy(pData,&tmp,sizeof(float));
    return;
}

static void Motor_Reg_Write_Cb(uint32_t peri_addr, void *pData, uint8_t len)
{
    (void)len;
    memcpy(&g_reg_write_value.u32, pData, sizeof(uint32_t));
    g_reg_write_addr = (uint8_t)peri_addr;
    switch(g_reg_write_addr){
        case REG_A_PID_SPEED_KP:
            g_pid_a_kp = g_reg_write_value.f;
            break;
        case REG_A_PID_SPEED_KI:
            g_pid_a_ki = g_reg_write_value.f;
            break;
        case REG_A_PID_SPEED_KD:
            g_pid_a_kd = g_reg_write_value.f;
            break;
        case REG_A_PID_SPEED_INTEGRAL_LIMIT:
            g_pid_a_ilim = g_reg_write_value.f;
            break;
        case REG_B_PID_SPEED_KP:
            g_pid_b_kp = g_reg_write_value.f;
            break;
        case REG_B_PID_SPEED_KI:
            g_pid_b_ki = g_reg_write_value.f;
            break;
        case REG_B_PID_SPEED_KD:
            g_pid_b_kd = g_reg_write_value.f;
            break;
        case REG_B_PID_SPEED_INTEGRAL_LIMIT:
            g_pid_b_ilim = g_reg_write_value.f;
            break;
        default:
            break;
    }
    g_reg_write_pending = 1;
    g_last_manual_cmd_tick = xTaskGetTickCount();
    g_manual_cmd_received = 1;
}

/* ================================================================
 * 内环 PI 控制器 (角速度)
 * ================================================================ */
float PI_Step(const PIParams_t *params, PIState_t *state, float setpoint, float actual)
{
    float error;
    float output;
    float d_term;
    error = setpoint - actual;
    state->error_sum += params->Ki * error;
    if (state->error_sum > params->error_sum_max)  state->error_sum = params->error_sum_max;
    if (state->error_sum < -params->error_sum_max) state->error_sum = -params->error_sum_max;
   // if (error < params->min_sep && error > -params->min_sep) state->error_sum = 0;
    //if (error > params->max_sep || error < -params->max_sep) state->error_sum = 0;
    d_term = params->Kd * (error - state->last_error);
    state->last_error = error;
    output = params->Kp * error + state->error_sum + d_term;
    return output;
}

/*服务于上位机的EC移动平均窗口调整器*/
static void EC_MA_Read_Cb(uint32_t peri_addr, void *pData, uint8_t len)
{
    uint16_t val;
    (void)len;
    val = (uint16_t)(*(char *)(peri_addr));
    memcpy(pData, &val, sizeof(uint16_t));
}

static void EC_MA_Write_Cb(uint32_t peri_addr, void *pData, uint8_t len)
{
    uint16_t new_val;
    unsigned char count;
    (void)len;
    memcpy(&new_val, pData, sizeof(uint16_t));
    count = (unsigned char)new_val;
    if (count < 1) count = 1;
    if (count > 50) count = 50;
    *(char *)(peri_addr) = (char)count;
}
static float normalized_adc_k[4] = {0.7416725158691406f, 0.8736371397972107f, 0.9320777058601379f, 0.9962461590766907f}; // ADC 归一化系数数组
static float user_calib_k[4] = {1.0f, 1.0f, 1.0f, 1.0f};  /* 用户个性化校准系数 [横左,竖左,横右,竖右] 逻辑位置索引 */
static uint8_t normalize_index = 0;
static uint8_t adc_start_normalize = 0;
static uint8_t change_inductor = 0;
static float roll=0.0f, pitch=0.0f, yaw=0.0f;
static float adc_avg_sum = 0.0f;
static float adc_avg = 0.0f;
static uint16_t adc_avg_count = 0;
static uint8_t display_adc_original = 0;
static float adc_normalized[4]; // 运行时 memset 初始化
static void NormalizeADC(uint32_t peri_addr,void *pData,uint8_t len){
    uint8_t* ptr = (uint8_t *)pData;
    (void)peri_addr;
    (void)len;
    if(*ptr<4){
        normalize_index = *ptr;
        adc_avg_sum = 0.0f;
        adc_avg_count = 0;
    }
    adc_start_normalize = 1;
    return;
}

uint8_t ADC_NormalizeCommand(const char* cmd) {
    if (strcmp(cmd, "norm0") == 0) {
        normalize_index = 0;
        NormalizeADC(0, &normalize_index, sizeof(normalize_index));
        Debug_Log("ADC_NORM_0");
        return 1;
    } else if (strcmp(cmd, "norm1") == 0) {
        normalize_index = 1;
        NormalizeADC(0, &normalize_index, sizeof(normalize_index));
        Debug_Log("ADC_NORM_1");
        return 1;
    } else if (strcmp(cmd, "norm2") == 0) {
        normalize_index = 2;
        NormalizeADC(0, &normalize_index, sizeof(normalize_index));
        Debug_Log("ADC_NORM_2");
        return 1;
    } else if (strcmp(cmd, "norm3") == 0) {
        normalize_index = 3;
        NormalizeADC(0, &normalize_index, sizeof(normalize_index));
        Debug_Log("ADC_NORM_3");
        return 1;
    }
    return 0; // 未识别
}

/* ================================================================
 * 控制管道 API
 * ================================================================ */

/* 全量复位 — 刹车/滑行/切手动时调用 */
static void CtrlState_Reset(ControlState_t *s, const ControlParams_t *p)
{
    (void)p;
    s->err_slewed      = 0.0f;
    s->err_filtered    = 0.0f;
    s->last_err        = 0.0f;
    s->filtered_d_term = 0.0f;
    s->i_sum           = 0.0f;
    s->i_term          = 0.0f;
    s->tar_yaw_raw     = 0.0f;
    s->target_yaw      = 0.0f;
    s->gyro_filtered   = 0.0f;
    lpf_reset(&s->lpf_outer, 0.0f);
    lpf_reset(&s->lpf_gyro,  0.0f);
    lpf_reset(&s->lpf_lat_g, 0.0f);
    ma_reset(&s->d_ma, 0.0f);
    s->lat_g_filtered        = 0.0f;
    s->err_brake_spd     = 1.0f;
    s->err_brake_yaw     = 1.0f;
    s->combined_brake_spd = 1.0f;
    s->combined_brake_yaw = 1.0f;
    s->inner.error_sum  = 0.0f;
    s->inner.last_error = 0.0f;
    s->last_spd_l       = 0.0f;
    s->last_spd_r       = 0.0f;
}



/* 冻结/保持模式 — 进入开环或冻结时调用, 清零积分+微分 */
static void CtrlState_Hold(ControlState_t *s)
{
    s->i_sum           = 0.0f;
    s->i_term          = 0.0f;
    s->last_err        = s->err_filtered;
    s->filtered_d_term = 0.0f;
    ma_reset(&s->d_ma, 0.0f);
}
/* 外环 LPF 截止频率读写回调 (上位机在线调参) */
static void OuterLpf_Read_Cb(uint32_t peri_addr, void *pData, uint8_t len)
{
    float val;
    (void)len;
    (void)peri_addr;
    val = g_params.outer.outer_lpf_fc;
    memcpy(pData, &val, sizeof(float));
}

static void OuterLpf_Write_Cb(uint32_t peri_addr, void *pData, uint8_t len)
{
    float new_fc;
    float alpha;
    (void)len;
    (void)peri_addr;
    memcpy(&new_fc, pData, sizeof(float));
    if (new_fc < 1.0f)  new_fc = 1.0f;
    if (new_fc > 400.0f) new_fc = 400.0f;
    g_params.outer.outer_lpf_fc = new_fc;
    alpha = 1.0f - (float)exp(-6.2831853f * new_fc * 0.002f);
    g_state.lpf_outer.alpha = alpha;
    g_state.lpf_outer.freq = new_fc;
    /* 不重置 output, 保持滤波连续性 */
}
/* 微分移动平均窗口读写回调 (上位机在线调参) */
static void D_MA_Win_Read_Cb(uint32_t peri_addr, void *pData, uint8_t len)
{
    uint16_t val;
    (void)len;
    (void)peri_addr;
    val = (uint16_t)g_params.outer.d_ma_window;
    memcpy(pData, &val, sizeof(uint16_t));
}

static void D_MA_Win_Write_Cb(uint32_t peri_addr, void *pData, uint8_t len)
{
    uint16_t new_val;
    (void)len;
    (void)peri_addr;
    memcpy(&new_val, pData, sizeof(uint16_t));
    if (new_val > MA_MAX_WINDOW) new_val = MA_MAX_WINDOW;
    g_params.outer.d_ma_window = (uint8_t)new_val;
    ma_set_window(&g_state.d_ma, g_params.outer.d_ma_window);
}

/* ================================================================
 * 侧向加速度 LPF 截止频率 (PERI_TYPE 读写, 两套方案独立可调)
 * ================================================================ */
static float g_lat_g_vw_fc  = 200.0f;   /* v·ω 方案 LPF 截止频率 */

static void LatG_VW_Lpf_Read_Cb(uint32_t peri_addr, void *pData, uint8_t len)
{
    float val;
    (void)len;
    (void)peri_addr;
    val = g_lat_g_vw_fc;
    memcpy(pData, &val, sizeof(float));
}

static void LatG_VW_Lpf_Write_Cb(uint32_t peri_addr, void *pData, uint8_t len)
{
    float new_fc;
    (void)len;
    (void)peri_addr;
    memcpy(&new_fc, pData, sizeof(float));
    if (new_fc < 1.0f)  new_fc = 1.0f;
    if (new_fc > 400.0f) new_fc = 400.0f;
    g_lat_g_vw_fc = new_fc;
    g_state.lpf_lat_g.alpha = 1.0f - (float)exp(-6.2831853f * new_fc * 0.002f);
    g_state.lpf_lat_g.freq = new_fc;
}

static DebugPeriDesc_t g_lat_g_vw_lpf_desc  = {0, LatG_VW_Lpf_Read_Cb,  LatG_VW_Lpf_Write_Cb};

static DebugPeriDesc_t g_pid_a_kp_desc   = {REG_A_PID_SPEED_KP,             Motor_Reg_Read_Cb, Motor_Reg_Write_Cb};
static DebugPeriDesc_t g_pid_a_ki_desc   = {REG_A_PID_SPEED_KI,             Motor_Reg_Read_Cb, Motor_Reg_Write_Cb};
static DebugPeriDesc_t g_pid_a_kd_desc   = {REG_A_PID_SPEED_KD,             Motor_Reg_Read_Cb, Motor_Reg_Write_Cb};
static DebugPeriDesc_t g_pid_a_ilim_desc = {REG_A_PID_SPEED_INTEGRAL_LIMIT, Motor_Reg_Read_Cb, Motor_Reg_Write_Cb};

/* PID 参数外设描述符 (Motor B / 右电机) */
static DebugPeriDesc_t g_pid_b_kp_desc   = {REG_B_PID_SPEED_KP,             Motor_Reg_Read_Cb, Motor_Reg_Write_Cb};
static DebugPeriDesc_t g_pid_b_ki_desc   = {REG_B_PID_SPEED_KI,             Motor_Reg_Read_Cb, Motor_Reg_Write_Cb};
static DebugPeriDesc_t g_pid_b_kd_desc   = {REG_B_PID_SPEED_KD,             Motor_Reg_Read_Cb, Motor_Reg_Write_Cb};
static DebugPeriDesc_t g_pid_b_ilim_desc = {REG_B_PID_SPEED_INTEGRAL_LIMIT, Motor_Reg_Read_Cb, Motor_Reg_Write_Cb};
static DebugPeriDesc_t g_right_speed_desc = {REG_A_SPEED_TARGET, Motor_Reg_Read_Cb,Motor_Reg_Write_Cb}; // 只写当前右轮速度
static DebugPeriDesc_t g_left_speed_desc  = {REG_B_SPEED_TARGET,Motor_Reg_Read_Cb, Motor_Reg_Write_Cb}; // 只写当前左轮速度
static DebugPeriDesc_t g_ec_ma_count_desc = {0, EC_MA_Read_Cb, EC_MA_Write_Cb}; /* EC移动平均窗口大小 */

static DebugPeriDesc_t g_outer_lpf_fc_desc = {0, OuterLpf_Read_Cb, OuterLpf_Write_Cb}; /* 外环LPF截止频率 */
static DebugPeriDesc_t g_d_ma_win_desc     = {0, D_MA_Win_Read_Cb, D_MA_Win_Write_Cb}; /* 微分MA窗口 */
extern IMU_Filter_t *IMU_Filter_Data;

motor_data_t motor_spi_dat_handle(uint8_t* buffer)
{
    motor_data_t dat;
    int8_t i;
    dat.u32 = 0;
    for (i = 4-1; i >= 0; i--) {
        dat.u32 |= (uint32_t)buffer[4-1-i] << (i * 8);
    }
    return dat;
}
/* ================================================================
 * Main_Control_Task
 *   2ms 固定周期
 *   1. 读取 ADC 并重启
 *   2. 写入左右电机速度目标
 *   3. 计算速度误差供上位机监测
 * ================================================================ */
uint8_t spi_buffer[12];
float left_speed_target = 0.0f;
float right_speed_target = 0.0f;
uint8_t manual_control_flag = 1;


uint16_t adc_dead_zone = 5;
float adc_err_zone = 0.5f;
float Err_Angle=0.0f;

/* 驾驶方向命令 (标志位方式, Main_Control 安全点执行) */
#define DRIVE_STOP     0
#define DRIVE_FORWARD  1
#define DRIVE_BACKWARD 2
#define DRIVE_LEFT     3
#define DRIVE_RIGHT    4
float  drive_speed  = 10.0f;

static volatile uint8_t g_drive_direction = DRIVE_STOP;

uint8_t Motor_HandleCommand(const char* cmd)
{
    if (strcmp(cmd, "forward") == 0) {
        g_drive_direction = DRIVE_FORWARD;
        Debug_Log("MOTOR_FWD");
    } else if (strcmp(cmd, "backward") == 0) {
        g_drive_direction = DRIVE_BACKWARD;
        Debug_Log("MOTOR_BCK");
    } else if (strcmp(cmd, "left") == 0) {
        g_drive_direction = DRIVE_LEFT;
        Debug_Log("MOTOR_LFT");
    } else if (strcmp(cmd, "right") == 0) {
        g_drive_direction = DRIVE_RIGHT;
        Debug_Log("MOTOR_RGT");
    } else if (strcmp(cmd, "stop") == 0) {
        g_drive_direction = DRIVE_STOP;
        Debug_Log("MOTOR_STP");
    } else {
        return 0;
    }
    /* 刷新手动模式超时计时 */
    g_last_manual_cmd_tick = xTaskGetTickCount();
    g_manual_cmd_received = 1;
    return 1;
}

static float common_speed=70.0f;
/* 外环带宽限制: 斜率限制 + 低通滤波 — 参数g_params + 状态g_state */

/* PI 已移入 g_params.inner + g_state.inner */
static float speed_target_r_nagtive=0.0f;
static float err_max = 120.0f;
static element_t current_element = ELEMENT_STRAIGHT;
static element_t prev_element    = ELEMENT_STRAIGHT;  /* 上一次元素, 用于检测切换 */
static ControlStrategy_t prev_ctrl = CTRL_NORMAL;     /* 上一次控制策略, 用于检测切换 */

static ElementCtx_t g_ectx;  /* 元素状态机上下文 */

static float tmp_adc13;
static float tmp_adcsum;

#define spd_limit 150.0f

/* ================================================================
 * 缓启动 (Soft-Start): 限制加速度, 防止启动电流冲击
 *   g_ss_magnitude: 当前缓启动输出速度幅值
 *   g_ss_step:      加速步进/周期 (2ms 周期)
 *   SS_STEP_DOWN:   减速步进 (快速响应刹车)
 * ================================================================ */
static float g_ss_magnitude = 0.0f;
static float g_ss_step      = 2.0f;
#define SS_STEP_DOWN 10.0f



/* ================================================================
 * ApplySpeedOutputParams — 速度输出后处理
 *   输入: common_speed (查表速度), diff_speed (内环PI输出)
 *   处理: 差速死区 → 差速限幅 → 速度合成 → 单轮限幅 → 斜率限制
 *   输出: 写入全局 speed_target_l.f / speed_target_r.f
 * ================================================================ */
static void ApplySpeedOutputParams(const SpeedOutputParams_t *p, ControlState_t *s,
                                    float common_speed, float *diff_speed)
{
    float raw_l, raw_r;
    float tgt_l, tgt_r;
    float diff_l, diff_r;
    float eff_max_diff;

    /* ---- 1. 差速死区 ---- */
  //  if (*diff_speed < p->min_diff && *diff_speed > -p->min_diff) {
  //      *diff_speed = 0.0f;
   // }

    /* ---- 2. 差速限幅 ---- */
    eff_max_diff = p->max_diff;
    // if (eff_max_diff > common_speed) {
    //     eff_max_diff = common_speed;
    // }
    if (*diff_speed >  eff_max_diff) *diff_speed =  eff_max_diff;
    if (*diff_speed < -eff_max_diff) *diff_speed = -eff_max_diff;

    /* ---- 3. 速度合成 ---- */
    raw_l = common_speed - *diff_speed;
    raw_r = -(common_speed + *diff_speed); //后面都是对称的判断，所以这里取负号没有问题

    /* ---- 4. 单轮输出限幅 ---- */
    if (raw_l >  p->max_output) raw_l =  p->max_output;
    if (raw_l < -p->max_output) raw_l = -p->max_output;
    if (raw_r >  p->max_output) raw_r =  p->max_output;
    if (raw_r < -p->max_output) raw_r = -p->max_output;

    /* 单轮死区 */
    if (raw_l < p->min_output && raw_l > -p->min_output) raw_l = 0.0f;
    if (raw_r < p->min_output && raw_r > -p->min_output) raw_r = 0.0f;

    /* ---- 5. 斜率限制 ---- */
    tgt_l = raw_l;
    tgt_r = raw_r;
    diff_l = tgt_l - s->last_spd_l;
    diff_r = tgt_r - s->last_spd_r;

    if (diff_l >  p->slew_rate)      tgt_l = s->last_spd_l + p->slew_rate;
    if (diff_l < -p->slew_rate)      tgt_l = s->last_spd_l - p->slew_rate;
    if (diff_r >  p->slew_rate)      tgt_r = s->last_spd_r + p->slew_rate;
    if (diff_r < -p->slew_rate)      tgt_r = s->last_spd_r - p->slew_rate;

    /* 存储状态 */
    s->last_spd_l = tgt_l;
    s->last_spd_r = tgt_r;

    /* 输出到全局速度目标 */
    speed_target_l.f = tgt_l;
    speed_target_r.f = tgt_r;
}


/* 统一速度写入包装: 传入逻辑速度, 内部用 WR_SIGN 适配下位机方向 */
/* ================================================================
 * 速度方向适配宏 (下位机方向约定变更时只需改这 4 个宏)
 *   WR_SIGN: 写入下位机的最终符号
 *   RD_SIGN: 上位机读取/显示的符号
 * ================================================================ */
#define SPD_WR_SIGN_R  (-1)   /* 右电机 (REG_A) 写入符号 */
#define SPD_WR_SIGN_L  (-1)   /* 左电机 (REG_B) 写入符号 */
#define SPD_RD_SIGN_R  (1)   /* 右电机 读取/显示符号 */
#define SPD_RD_SIGN_L  (-1)    /* 左电机 读取/显示符号 */
static void Motor_Write_Speeds(float spd_r, float spd_l)
{
    motor_data_t dr, dl;
    dr.f = spd_r * SPD_WR_SIGN_R;
    dl.f = spd_l * SPD_WR_SIGN_L;
    motor_write_speed_targets(dr, dl);
}

/* 缓启动步进: 加速缓 (step_up), 减速快 (step_down) */
static float SoftStart_Ramp(float cur, float tgt, float step_up, float step_down)
{
    float diff;
    float step;
    diff = tgt - cur;
    step = (diff > 0.0f) ? step_up : step_down;
    if (diff > step) {
        return cur + step;
    } else if (diff < -step) {
        return cur - step;
    } else {
        return tgt;
    }
}

void System_Reset(void){   
    /* 复位所有状态机/控制管线/滤波器 */
    CtrlState_Reset(&g_state, &g_params);
    Element_ResetOfftrackTimer(NULL);
    Element_ResetTrackIndex(NULL);
    g_ectx.current = ELEMENT_STRAIGHT;
    g_ectx.ring_lockout_cnt   = 0;
    g_ectx.wall_lockout_cnt   = 0;
    g_ectx.barrel_lockout_cnt = 0;
    g_ectx.skip_lockout_cnt   = 0;
    g_ectx.ra_lockout_cnt     = 0;
    g_ectx.cross_lockout_cnt  = 0;
    g_ectx.offtrack_active = 0;
    g_ectx.total_frames = 0;
    manual_control_flag = 1;
    Fan_TurnOff();
    LED_RequestBreathing();              /* 切手动 → 呼吸灯 */
    g_auto_transition = 0;
    g_ss_magnitude = 0.0f;  /* 重置缓启动 */
}


void Change_Maunal(){
    const ElementProp_t *init_prop;
    uint16_t init_fan_d;

	if(manual_control_flag){
        /* 切换到自动模式: 启动风扇(推车模式跳过), 等缓启动完成后激活电机 */
        manual_control_flag = 0;
        if (!g_ectx.push_mode) {
            init_prop = Element_GetProp(ELEMENT_STRAIGHT);
            if (init_prop != NULL && init_prop->fan_d_ptr != NULL) {
                init_fan_d = *(init_prop->fan_d_ptr);
            } else {
                init_fan_d = fan_D;
            }
            Fan_SoftStart_Trigger(init_fan_d);
        }
        LED_RequestSteady(255, 255, 255);   /* 切自动 → 稳态白光 */
        g_auto_transition = 1;
        g_auto_fan_tick = xTaskGetTickCount();
        g_ss_magnitude = 0.0f;  /* 重置缓启动 */
        CtrlState_Reset(&g_state, &g_params);  /* 全量复位控制管线 */
        current_element = ELEMENT_STRAIGHT;
        prev_ctrl = CTRL_NORMAL;                   /* 对齐自动模式初始控制策略 */
        Element_ResetOfftrackTimer(NULL);
        Element_ResetTrackIndex(NULL);
        g_ectx.current = ELEMENT_STRAIGHT;
        g_ectx.ring_lockout_cnt   = 0;
        g_ectx.wall_lockout_cnt   = 0;
        g_ectx.barrel_lockout_cnt = 0;
        g_ectx.skip_lockout_cnt   = 0;
        g_ectx.ra_lockout_cnt     = 0;
        g_ectx.cross_lockout_cnt  = 0;
        g_ectx.offtrack_active = 0;
        /* total_frames 由电机激活时清零, 不在此处提前设置 */
    }else{
        /* 切换到手动模式: 关闭风扇, 刹车 */
        manual_control_flag = 1;
        Fan_TurnOff();
        LED_RequestBreathing();              /* 切手动 → 呼吸灯 */
        g_auto_transition = 0;
        g_ss_magnitude = 0.0f;  /* 重置缓启动 */
    }
}

extern void IMU_Get_Angle(float* roll, float* pitch, float* yaw);
extern float IMU_Get_Yaw_Unwrapped(void);
extern float IMU_Get_Gyro_Z(void);
static float sqrt_negative(float value) {

    if (value < 0.0f) {
        return -sqrt(-value);
    } else {
        return sqrt(value);
    }
}
static float abs_f(float t){
    if(t>0.0f){
        return t;
    }else{
        return -t;
    }
}

/* ================================================================
 * ApplyLatGSpeedLimit — 侧向加速度速度限制
 *   根据当前侧g超限程度, 动态削减基础速度
 *   lat_g > 0 → 左转, 用左转参数; lat_g < 0 → 右转, 用右转参数
 * ================================================================ */
static float CalcLatGBrakeFactor(float lat_g, float max_g, float safe_g, float brake_k)
{
    float lat_g_abs;
    float over_ratio;

    lat_g_abs = (lat_g > 0.0f) ? lat_g : -lat_g;

    /* 未超过安全阈值, 不干预 */
    if (lat_g_abs <= safe_g) {
        return 1.0f;
    }

    /* 参数不合理 (max <= safe), 不干预 */
    if (max_g <= safe_g) {
        return 1.0f;
    }

    /* 超出比例: 0.0 (刚到safe) → 1.0 (达到或超过max) */
    over_ratio = (lat_g_abs - safe_g) / (max_g - safe_g);
    if (over_ratio > 1.0f) over_ratio = 1.0f;

    /* brake_k 控制削减力度: 0=不削减, 1=到max时减到0 */
    return 1.0f - (over_ratio * brake_k);
}
/* ================================================================
 * CalcErrBrakeFactor — Err幅值减速系数 (与侧g逻辑对称)
 *   err_abs = |err_filtered|, 超出 safe 后按比例削减速度
 * ================================================================ */
static float CalcErrBrakeFactor(float err_abs, float max_err, float safe_err, float brake_k)
{
    float over_ratio;

    /* 未超过安全阈值, 不干预 */
    if (err_abs <= safe_err) {
        return 1.0f;
    }

    /* 参数不合理 (max <= safe), 不干预 */
    if (max_err <= safe_err) {
        return 1.0f;
    }

    /* 超出比例: 0.0 (刚到safe) → 1.0 (达到或超过max) */
    over_ratio = (err_abs - safe_err) / (max_err - safe_err);
    if (over_ratio > 1.0f) over_ratio = 1.0f;

    /* brake_k 控制削减力度: 0=不削减, 1=到max时减到0 */
    return 1.0f - (over_ratio * brake_k);
}
/* err_angle_filtered 已移入 g_state.err_filtered */

/* ================================================================
 * OnCtrlTransition — 控制策略切换时的状态清理
 *   集中管理所有 PID/滤波器状态复位, 替代原来散落在
 *   SAFETY_STOP case / Change_Maunal / 自动过渡 中的重复代码
 * ================================================================ */
static void OnCtrlTransition(ControlStrategy_t from, ControlStrategy_t to)
{
    if (from == to) return;

    /* 进入开环: 清零外环积分和微分历史 */
    if (to == CTRL_OL_YAW) {
        CtrlState_Hold(&g_state);
        return;
    }

    /* 开环恢复到正常 PID: 用当前误差 seed 管线 */
    if (from == CTRL_OL_YAW && to == CTRL_NORMAL) {
        CtrlState_Seed(&g_state, &g_params, g_state.err_filtered);
        return;
    }

    /* 进入冻结: 清零 I/D 历史, 冻结在 Err_Angle 层面处理 */
    if (to == CTRL_ERR_FREEZE) {
        CtrlState_Hold(&g_state);
        return;
    }

    /* 退出冻结: seed 管线到当前滤波值 */
    if (from == CTRL_ERR_FREEZE && to == CTRL_NORMAL) {
        CtrlState_Seed(&g_state, &g_params, g_state.err_filtered);
        return;
    }

    /* 进入刹车/滑行: 全量复位 */
    if (to == CTRL_BRAKE ) {
        CtrlState_Reset(&g_state, &g_params);
        return;
    }
}

/* ================================================================
 * ControlDispatch — 统一电机派发
 *   替代原来分散在两处的电机写入逻辑
 * ================================================================ */
static void ControlDispatch(ControlStrategy_t ctrl, float spd_r, float spd_l)
{
    switch (ctrl) {
    case CTRL_NORMAL:
    case CTRL_OL_YAW:
    case CTRL_ERR_FREEZE:
    case CTRL_RA_YAW:
        Motor_Write_Speeds(spd_r, spd_l);
        break;
    case CTRL_BRAKE:
        Motor_Write_Speeds(0.0f, 0.0f);
        Fan_TurnOff();   /* 关负压风扇 */
        break;
    case CTRL_FREEWHEEL:
    default:
        Motor_Write_Speeds(0.0f, 0.0f);
        Fan_TurnOff();
        break;
    }
}

/* ================================================================
 * CalcAdcError — ADC 误差计算 (劫持点0 → 劫持点1 之间)
 *   各元素通过切换 AdcErrParams 屏蔽不同电感通道
 * ================================================================ */
static float CalcAdcError(const AdcErrParams_t *p,
                          float Err_1, float Err_2,
                          float Err_3, float Err_4)
{
    float numerator;
    float denominator;

    numerator   = p->err_A_K * Err_1 + p->err_B_K * Err_2;
    denominator = p->err_C_K * Err_3 + p->err_D_K * Err_4;

    if (denominator < 1.0e-6f && denominator > -1.0e-6f) {
        return 0.0f;
    }
    return numerator / denominator * 100.0f;
}

/* ================================================================
 * RunOuterLoop — 外环全流程 (劫持点1 → 劫持点3)
 *   输入: 劫持后 Err_Angle + 原始陀螺角速度
 *   输出: tar_yaw_raw (待劫持的内环目标角速度)
 *   内含: slew限制+LPF+模糊PID+积分分离+陀螺滤波+不完全微分+自适应Kd
 * ================================================================ */
static float RunOuterLoop(const OuterLoopParams_t *p, ControlState_t *s,
                          FuzzyPID *pid, float err_angle, float gyro_raw)
{
    float Kd_diff;
    float slew_diff;
    float err_diff;
    float raw_d_term;
    /* 1. 斜率限制 → 2. 低通滤波 */
    slew_diff = err_angle - s->err_slewed;
    if (slew_diff > p->outer_slew_max) {
        s->err_slewed += p->outer_slew_max;
    } else if (slew_diff < -p->outer_slew_max) {
        s->err_slewed -= p->outer_slew_max;
    } else {
        s->err_slewed = err_angle;
    }
    s->err_filtered = lpf_update(&s->lpf_outer, s->err_slewed);

    /* 3. 模糊 PID */
    s->pid_output = FuzzyPID_Step(pid, s->err_filtered);

    /* 4. 外环积分 (积分分离) */
    if (abs_f(s->err_filtered) > p->outer_i_sep_hi) {
        s->i_sum = 0.0f;
    } else if (abs_f(s->err_filtered) < p->outer_i_sep_lo) {
        s->i_sum = 0.0f;
    } else {
        s->i_sum += p->outer_Ki * (-s->err_filtered);
        if (s->i_sum > p->outer_i_limit)  s->i_sum = p->outer_i_limit;
        if (s->i_sum < -p->outer_i_limit) s->i_sum = -p->outer_i_limit;
    }
    s->i_term = s->i_sum;

    /* 5. 陀螺仪低通滤波 */
    s->gyro_filtered = lpf_update(&s->lpf_gyro, gyro_raw);

    /* 6. 不完全微分 (MA + 死区) */
    err_diff = s->err_filtered - s->last_err;
    if (err_diff > -p->diff_deadband && err_diff < p->diff_deadband) {
        err_diff = 0.0f;
    }
    raw_d_term = err_diff / 0.002f;
    s->filtered_d_term = ma_update(&s->d_ma, raw_d_term);
    s->last_err = s->err_filtered;

    /* 7. 自适应微分系数选择 (Kd_diff 原为 params 字段, 实为运行时局部变量) */
    if (abs_f(s->err_filtered) > p->Kd_diff_thresh) {
        Kd_diff = p->Kd_diff_high;
    } else {
        Kd_diff = p->Kd_diff_low;
    }

    /* 8. 外环合成: tar_yaw = P输出 + I项 - Kd * 滤波微分 */
    return s->pid_output
         + s->i_term
         - Kd_diff * s->filtered_d_term;
}

/* ================================================================
 * RunInnerLoop — 内环 PI (劫持点3 之后)
 *   输入: 劫持后 target_yaw + 滤波后实际角速度
 *   输出: 左右轮差速
 * ================================================================ */
static float RunInnerLoop(const PIParams_t *p, PIState_t *s,
                          float target_yaw, float actual_yaw)
{
    return PI_Step(p, s, target_yaw, actual_yaw);
}

/* 速度变量已迁移至 element.c, 通过 Element_GetProp 查表获取 */
void Main_Control_Task(void *pvParameters)
{
    uint8_t i;
    uint8_t led_r, led_g, led_b;   /* LED 颜色临时变量 */
    motor_data_t tmp;
    motor_data_t speed_a, speed_b;
    uint32_t ulNotifiedValue;
    uint16_t raw;  /* TODO: 临时, ADC 尖峰过滤用 */
    float Err_1;
    float Err_2;
    float Err_3;
    float Err_4;
    float adc_feed[4];              /* 逻辑电感排列 [横,竖,横,竖], 一次重排后全用此数组 */
    float adc_calib[4];             /* 用户校准后: adc_feed[i] * user_calib_k[i], 供循迹控制用 */
    float differential_speed;
    float actual_yaw_rate_raw;  /* 陀螺仪原始角速度 (滤波前) */
    float gx_body, gy_body, gz_body;  /* 重力向量, 传入 Element_CalcTilt */
    const ElementProp_t *prop;              /* 当前元素属性 (每 tick 查一次) */
    ControlStrategy_t    ctrl;              /* 当前有效控制策略 */
    uint16_t elem_fan_d;                    /* 元素切换时查表的有效风扇占空比 */
    (void)pvParameters;

    Element_Init(&g_ectx);  /* 初始化元素状态机上下文 */

//    xLastWakeTime = xTaskGetTickCount();
    vTaskDelay(pdMS_TO_TICKS(100)); /* 启动后延时 100ms 等待系统稳定 */
      /* 开启电机 stream 模式 */
    MOTOR_CS_RESET();
    motor_stream_start(0x01, 0x02);
    MOTOR_CS_SET();
    while(IMU_Filter_Data->is_calibrated==0){
        vTaskDelay(pdMS_TO_TICKS(10));
        MOTOR_CS_RESET();
        tmp.u32 = 0x01;
        motor_write_reg(0x01, tmp);
        MOTOR_CS_SET();
    }
    


    g_stream_active = 1;
    P2INTE |= PIN_0;
    for (;;) {
        ulNotifiedValue = 0;
        xTaskNotifyWait(0, SIGNAL_MOTOR_DATA_READY, &ulNotifiedValue, pdMS_TO_TICKS(2));

        /* --- 电机数据处理 (仅在有信号时) --- */
        if (ulNotifiedValue & SIGNAL_MOTOR_DATA_READY) {
            if (g_stream_active) {
                
                MOTOR_CS_RESET();
                for (i = 0; i < 12; i++) {
                    spi_buffer[i] = MOTOR_SPI_TxRx(0xFFu);
                }
                MOTOR_CS_SET();
                tmp = motor_spi_dat_handle(spi_buffer);
                g_right_speed_actual = SPD_RD_SIGN_R * lpf_update(&g_lpf_right, tmp.f);
                tmp = motor_spi_dat_handle(spi_buffer + 4);
                g_left_speed_actual = SPD_RD_SIGN_L * lpf_update(&g_lpf_left, tmp.f);
                tmp = motor_spi_dat_handle(spi_buffer + 8);
                g_mech_state = tmp.u32;

                if(adc_start_normalize){
                    adc_avg_sum += adc_values[normalize_index];
                    adc_avg_count++;
                    if(adc_avg_count >= 500){
                        adc_avg = adc_avg_sum / adc_avg_count;
                        adc_avg_sum = 0;
                        adc_avg_count = 0;
                        if(adc_avg > 800){
                            normalized_adc_k[normalize_index] = 1000.0f / (float)adc_avg; // 简单线性归一化
                        }else{
                            normalized_adc_k[normalize_index] = 1.0f; // 不进行归一化
                        }
                        adc_start_normalize = 0;
                    }
                }
                if(display_adc_original){
                    adc_normalized[0] = adc_values[0];
                    adc_normalized[1] = adc_values[1];
                    adc_normalized[2] = adc_values[2];
                    adc_normalized[3] = adc_values[3];
                }else{
                    adc_normalized[0] = (adc_values[0] < adc_dead_zone) ? 0.0f : adc_values[0] * normalized_adc_k[0];
                    adc_normalized[1] = (adc_values[1] < adc_dead_zone) ? 0.0f : adc_values[1] * normalized_adc_k[1];
                    adc_normalized[2] = (adc_values[2] < adc_dead_zone) ? 0.0f : adc_values[2] * normalized_adc_k[2];
                    adc_normalized[3] = (adc_values[3] < adc_dead_zone) ? 0.0f : adc_values[3] * normalized_adc_k[3];
                }
                tmp_adc13 = adc_normalized[1]+adc_normalized[3];
                tmp_adcsum = adc_normalized[0]+adc_normalized[1]+adc_normalized[2]+adc_normalized[3];
                /* 一次重排: 根据电感极性把物理ADC通道映射为逻辑顺序 [横,竖,横,竖] */
                if (change_inductor == 1) {
                    adc_feed[0] = adc_normalized[0];
                    adc_feed[1] = adc_normalized[1];
                    adc_feed[2] = adc_normalized[2];
                    adc_feed[3] = adc_normalized[3];
                } else {
                    adc_feed[0] = adc_normalized[1];
                    adc_feed[1] = adc_normalized[0];
                    adc_feed[2] = adc_normalized[3];
                    adc_feed[3] = adc_normalized[2];
                }
                /* 下面全部基于逻辑排列计算, 不再出现 change_inductor */
                /* 第二级: 用户个性化校准 (循迹控制用), 元素判断用 adc_feed 不受影响 */
                adc_calib[0] = adc_feed[0] * user_calib_k[0];  /* 横向左 */
                adc_calib[1] = adc_feed[1] * user_calib_k[1];  /* 竖直左 */
                adc_calib[2] = adc_feed[2] * user_calib_k[2];  /* 横向右 */
                adc_calib[3] = adc_feed[3] * user_calib_k[3];  /* 竖直右 */
                Err_1 = adc_calib[0] - adc_calib[2];  /* 横向差分 */
                Err_2 = adc_calib[1] - adc_calib[3];  /* 竖直差分 */
                Err_3 = adc_calib[0] + adc_calib[2];  /* 横向和   */
                Err_4 = abs_f(adc_calib[1] - adc_calib[3]); /* 竖直差绝对值 */
                
                if(Err_1 < adc_err_zone && Err_1 > -adc_err_zone) Err_1 = 0.0f;
                if(Err_2 < adc_err_zone && Err_2 > -adc_err_zone) Err_2 = 0.0f;
                if(Err_3 < adc_err_zone && Err_3 > -adc_err_zone) Err_3 = 0.0f;
                if(Err_4 < adc_err_zone && Err_4 > -adc_err_zone) Err_4 = 0.0f;
                /* ===== Block 0: ADC \xce�\xb2�\xbc�\xcb� (\xb0�\xd4�\xcb�\xd1�\xb2�) ===== */
                {
                    const ControlParams_t *p = GetActiveParams(current_element);
                    Err_Angle = CalcAdcError(&p->adc, Err_1, Err_2, Err_3, Err_4);
                }
                /* ===== 传感器灌入 + 倾角计算 + 状态机更新 ===== */
                Element_FeedSensors(&g_ectx, adc_feed,
                    IMU_Filter_Data->sensor.dat.ax,
                    IMU_Filter_Data->sensor.dat.ay,
                    IMU_Filter_Data->sensor.dat.az,
                    yaw, Err_Angle, g_state.err_filtered);

                IMU_Get_Angle(&roll, &pitch, &yaw);
                yaw = IMU_Get_Yaw_Unwrapped();

                IMU_GetGravityVector(&gx_body, &gy_body, &gz_body);
                Element_CalcTilt(&g_ectx, gx_body, gy_body, gz_body);

                /* 侧向加速度方案1: v × ω 运动学法 (rad/s × m × rad/s → g) */
                {
                    float avg_speed_rad_s;
                    float speed_mps;
                    float lat_g_raw;
                    avg_speed_rad_s = (abs_f(g_left_speed_actual) + abs_f(g_right_speed_actual)) * 0.5f * 2.0f;//传感器读出角速度是真实值的1/2，这里再乘2.0
                    speed_mps = avg_speed_rad_s * 0.016f;  /* 轮胎半径 = 3.2cm / 2 = 1.6cm = 0.016m */
                    lat_g_raw = -speed_mps * g_state.gyro_filtered / 9.80665f;
                    g_state.lat_g_filtered = lpf_update(&g_state.lpf_lat_g, lat_g_raw);
                }
                current_element = Element_Update(&g_ectx);
                /* 直角转弯冻结: CTRL_ERR_FREEZE 策略下用冻结值替代真实 Err_Angle */
/************    状态机插入 ****************** */

                Err_Angle = SelectTargetErr(ctrl, prop, &g_ectx);

/************    状态机插入 ****************** */


                /* ===== Block 1: params lookup + ApplyParamsIfChanged ===== */
                {
                    const ControlParams_t *p = GetActiveParams(current_element);
                    ApplyParamsIfChanged(p);
                }
/* 每 tick 一次查表 (替代原多处分散的 Element_GetProp 调用) */
                prop = Element_GetProp(current_element);
                ctrl = Element_GetEffectiveCtrl(current_element, &g_ectx);

                /* 元素切换 → 更新 LED + 风扇 (仅自动模式, 手动模式保持呼吸灯) */
                if (!manual_control_flag && current_element != prev_element) {
                    LED_GetElementColor(current_element, &led_r, &led_g, &led_b);
                    if (current_element == ELEMENT_SAFETY_STOP) {
                        LED_RequestBreathing();
                    } else {
                        LED_RequestSteady(led_r, led_g, led_b);
                        /* 元素切换时应用对应的风扇占空比 */
                        if (prop != NULL && prop->fan_d_ptr != NULL) {
                            elem_fan_d = *(prop->fan_d_ptr);
                        } else {
                            elem_fan_d = fan_D;
                        }
                        Fan_SetDuty(elem_fan_d);
                    }
                    prev_element = current_element;
                }

/************    状态机插入 ****************** */

                /* 控制策略切换 → 清理 PID 状态 (替代原散落的复位代码) */
                if (ctrl != prev_ctrl) {
                    OnCtrlTransition(prev_ctrl, ctrl);
                    prev_ctrl = ctrl;
                }
/************    状态机插入 ****************** */



                /* 速度查表 (基于最新状态机输出) */
                if (current_element == ELEMENT_SAFETY_STOP) {
                    common_speed = 0.0f;
                } else if (prop != NULL && prop->speed_ptr != NULL) {
                    common_speed = *(prop->speed_ptr);
                }

                /* 制动系数 (线速度/角速度独立, 侧g+Err各算各的再取min合并) */
                {
                    const ControlParams_t *p = GetActiveParams(current_element);
                    float max_g, safe_g;
                    float lat_g_brake_spd, lat_g_brake_yaw;
                    float err_abs;

                    if (g_state.lat_g_filtered > 0.0f) {
                        max_g  = p->outer.lat_g_r_max;
                        safe_g = p->outer.lat_g_r_safe;
                    } else {
                        max_g  = p->outer.lat_g_l_max;
                        safe_g = p->outer.lat_g_l_safe;
                    }

                    /* 侧g: 线速度和角速度用各自系数独立计算 */
                    lat_g_brake_spd = CalcLatGBrakeFactor(g_state.lat_g_filtered,
                                              max_g, safe_g,
                                              p->outer.lat_g_brake_k_spd);
                    lat_g_brake_yaw = CalcLatGBrakeFactor(g_state.lat_g_filtered,
                                              max_g, safe_g,
                                              p->outer.lat_g_brake_k_yaw);

                    /* Err: 线速度和角速度用各自系数独立计算 */
                    err_abs = (g_state.err_filtered > 0.0f) ? g_state.err_filtered : -g_state.err_filtered;
                    g_state.err_brake_spd = CalcErrBrakeFactor(err_abs,
                                              p->outer.err_brake_max,
                                              p->outer.err_brake_safe,
                                              p->outer.err_brake_k_spd);
                    g_state.err_brake_yaw = CalcErrBrakeFactor(err_abs,
                                              p->outer.err_brake_max,
                                              p->outer.err_brake_safe,
                                              p->outer.err_brake_k_yaw);

                    /* 合并线速度: min(侧g, Err) */
                    g_state.combined_brake_spd = (lat_g_brake_spd < g_state.err_brake_spd)
                                               ? lat_g_brake_spd : g_state.err_brake_spd;
                    /* 合并角速度: min(侧g, Err) */
                    g_state.combined_brake_yaw = (lat_g_brake_yaw < g_state.err_brake_yaw)
                                               ? lat_g_brake_yaw : g_state.err_brake_yaw;

                    common_speed *= g_state.combined_brake_spd;
                }

                /* ===== Block 2: �⻷ȫ���� �� tar_yaw_raw ===== */
                {
                    const ControlParams_t *p = GetActiveParams(current_element);
                    actual_yaw_rate_raw = IMU_Get_Gyro_Z();
                    g_state.tar_yaw_raw = RunOuterLoop(&p->outer, &g_state, &p->fuzzy,
                                                        Err_Angle, actual_yaw_rate_raw);
                }
//角速度环路劫持
                /* 统一目标角速度选择 (替代原 OL_YAW 劫持) */
/***************    状态机插入 ****************** */

                g_ectx.yawrate = g_state.tar_yaw_raw;
                g_state.target_yaw = SelectTargetYaw(ctrl, prop, &g_ectx);
                g_state.target_yaw *= g_state.combined_brake_yaw;


/***************   状态机插入 ****************** */


                /* 内环 PI + 速度合成 (唯一一次, 基于最新状态机输出) */
                {
                    const ControlParams_t *p = GetActiveParams(current_element);
                    differential_speed = RunInnerLoop(&p->inner, &g_state.inner,
                                                       g_state.target_yaw, g_state.gyro_filtered);
                    ApplySpeedOutputParams(&p->speed_out, &g_state,
                                            common_speed, &differential_speed);
                }
                speed_target_r_nagtive = -speed_target_r.f;

                /* 处理 Debug 系统延迟的 PID 参数写入 / 手动模式超时保护 / 驾驶指令 */
                if(manual_control_flag){
                    /* 3s 无指令自动刹车 */
                    if (g_manual_cmd_received &&
                        (xTaskGetTickCount() - g_last_manual_cmd_tick) >= pdMS_TO_TICKS(3000)) {
                        tmp.f = 0.0f;
                        Motor_Write_Speeds(0.0f, 0.0f);
                        g_reg_write_pending = 0;
                        g_drive_direction = DRIVE_STOP;
                        g_last_manual_cmd_tick = xTaskGetTickCount();
                        g_ss_magnitude = 0.0f;  /* 重置缓启动 */
                    }

                    /* 缓启动: ramp 速度幅值 */
                    if (g_drive_direction != DRIVE_STOP) {
                        g_ss_magnitude = SoftStart_Ramp(g_ss_magnitude, drive_speed, g_ss_step, SS_STEP_DOWN);
                    } else {
                        g_ss_magnitude = SoftStart_Ramp(g_ss_magnitude, 0.0f, g_ss_step, SS_STEP_DOWN);
                    }

                    /* 执行驾驶指令 (标志位 -> 电机写入) */
                    if (g_drive_direction != DRIVE_STOP) {
                        if (g_drive_direction == DRIVE_FORWARD) {
                            speed_a.f = -g_ss_magnitude;
                            speed_b.f = g_ss_magnitude;
                        } else if (g_drive_direction == DRIVE_BACKWARD) {
                            speed_a.f = g_ss_magnitude;
                            speed_b.f = -g_ss_magnitude;
                        } else if (g_drive_direction == DRIVE_LEFT) {
                            speed_a.f = -g_ss_magnitude;
                            speed_b.f = -g_ss_magnitude;
                        } else if (g_drive_direction == DRIVE_RIGHT) {
                            speed_a.f = g_ss_magnitude;
                            speed_b.f = g_ss_magnitude;
                        }
                        Motor_Write_Speeds(speed_a.f, speed_b.f);
                    }else{
                            tmp.f = 0.0f;
                            Motor_Write_Speeds(0.0f, 0.0f);
                    }
                    if (g_reg_write_pending) {
                        if(g_reg_write_addr == REG_A_SPEED_TARGET){
                            g_reg_write_value.f *= SPD_WR_SIGN_R;
                        }
                        MOTOR_CS_RESET();
                        motor_write_reg(g_reg_write_addr, g_reg_write_value);
                        MOTOR_CS_SET();
                        g_reg_write_pending = 0;
                    }
                    
                }else{
                    /* --- 自动模式: 处理延迟 PID 参数写入 --- */
                    if (g_reg_write_pending) {
                        MOTOR_CS_RESET();
                        motor_write_reg(g_reg_write_addr, g_reg_write_value);
                        MOTOR_CS_SET();
                        g_reg_write_pending = 0;
                    }

                    /* 风扇缓启动完成后激活电机 (推车模式跳过风扇, 立即激活) */
                    if (g_auto_transition == 1) {
                        if (g_ectx.push_mode
                            || ((xTaskGetTickCount() - g_auto_fan_tick) >= pdMS_TO_TICKS(2000)
                                && Fan_IsSoftStartComplete())) {
                            g_auto_transition = 2;
                            lpf_reset(&g_state.lpf_gyro, 0.0f);
                            g_state.inner.error_sum = 0.0f;
                            g_state.inner.last_error = 0.0f;
                            g_state.i_sum = 0.0f;
                            g_ectx.total_frames = 0;
                        }
                    }

                    /* 统一电机派发 (状态机 + PID 已在上面统一计算) */
                    if (g_auto_transition == 2) {
                        ControlDispatch(ctrl, speed_target_r.f, speed_target_l.f);
                    }

                }
                Fan_SoftStart_Step();
                //taskEXIT_CRITICAL();
            }

            if (ADC2_DMA_IsDone()) {
                    
                ADC2_DMA_ClearFlag();
                
                for (i = 0; i < ADC2_CH_NUM; i++) {
                    raw = ADC2_GetAvgValue(i);
                    adc_values[i] = (float)raw; //最右横向为1，最左横向为3，左中为2，右中为0
                }
                
                ADC2_DMA_Start();
               
            }
        }
    }
}

/* ================================================================
 * P2.0 中断处理 (500Hz 电机数据就绪)
 *   通知 Main_Control_Task
 * ================================================================ */
void Motor_Data_Ready_INT2_Handle(BaseType_t *xHigherPriorityTaskWoken)
{
    xTaskNotifyFromISR(xMainControlTaskHandle, SIGNAL_MOTOR_DATA_READY, eSetBits, xHigherPriorityTaskWoken);
}

/* ================================================================
 * 初始化: 注册调试变量 + 创建两个任务
 * ================================================================ */
void Main_Control_Task_Init(void)
{
    motor_data_t tmp;

    /* 运行时初始化大数组/结构体，避免 Flash 镜像占用 */
    memset(adc_dma_buf,          0, sizeof(adc_dma_buf));
    memset(adc_values,           0, sizeof(adc_values));
    memset(&g_left_speed_target,  0, sizeof(g_left_speed_target));
    memset(&g_right_speed_target, 0, sizeof(g_right_speed_target));
    memset(adc_normalized,       0, sizeof(adc_normalized));
    memset(&g_params,            0, sizeof(g_params));
    memset(&g_params_cross,      0, sizeof(g_params_cross));
    memset(&g_params_ring,       0, sizeof(g_params_ring));
    memset(&g_params_wall,       0, sizeof(g_params_wall));


    memcpy(&g_params_cross, &g_params, sizeof(ControlParams_t));
    memcpy(&g_params_ring,  &g_params, sizeof(ControlParams_t));
    memcpy(&g_params_wall,  &g_params, sizeof(ControlParams_t));

    memset(&g_state,             0, sizeof(g_state));
    memset(&speed_target_l,      0, sizeof(speed_target_l));
    memset(&speed_target_r,      0, sizeof(speed_target_r));

    // g_ec_ma_count_desc.peri_addr = (uint32_t)&(pid_struct.ec_count); /* EC移动平均已移除 */
    /* ================================================================
     * 1. 实时观测 (HIGH_FREQ) — 只看不改
     * ================================================================ */
    /* ADC */
    Debug_Register("adc0",   DBG_FLOAT | HIGH_FREQ_TYPE, &adc_normalized[0]);
    Debug_Register("adc1",   DBG_FLOAT | HIGH_FREQ_TYPE, &adc_normalized[1]);
    Debug_Register("adc2",   DBG_FLOAT | HIGH_FREQ_TYPE, &adc_normalized[2]);
    Debug_Register("adc3",   DBG_FLOAT | HIGH_FREQ_TYPE, &adc_normalized[3]);
    //Debug_Register("adc1+3", DBG_FLOAT | HIGH_FREQ_TYPE, &tmp_adc13);
    //Debug_Register("adcsum", DBG_FLOAT | HIGH_FREQ_TYPE, &tmp_adcsum);
    /* 姿态 */
    Debug_Register("yaw",    DBG_FLOAT | HIGH_FREQ_TYPE, &yaw);
    Debug_Register("ErrFil", DBG_FLOAT | HIGH_FREQ_TYPE, &g_state.err_filtered);
    Debug_Register("TiltFB", DBG_FLOAT | HIGH_FREQ_TYPE, &g_ectx.tilt_fb);
    Debug_Register("TiltLR", DBG_FLOAT | HIGH_FREQ_TYPE, &g_ectx.tilt_lr);
   // Debug_Register("LatG_VW",  DBG_FLOAT | HIGH_FREQ_TYPE, &g_state.lat_g_filtered);
   // Debug_Register("ErrB_Fac_Spd", DBG_FLOAT | HIGH_FREQ_TYPE, &g_state.err_brake_spd);
   // Debug_Register("ErrB_Fac_Yaw", DBG_FLOAT | HIGH_FREQ_TYPE, &g_state.err_brake_yaw);
    /* 电机 */
    Debug_Register("L_Tar", DBG_FLOAT | HIGH_FREQ_TYPE, &(speed_target_l.f));
    Debug_Register("R_Tar", DBG_FLOAT | HIGH_FREQ_TYPE, &(speed_target_r_nagtive));
    Debug_Register("L_Act", DBG_FLOAT | HIGH_FREQ_TYPE, &g_left_speed_actual);
    Debug_Register("R_Act", DBG_FLOAT | HIGH_FREQ_TYPE, &g_right_speed_actual);

    /* ================================================================
     * 2. ADC 误差权重 & 归一化 — 默认值 & Debug 注册
     * ================================================================ */
    /* 默认参数 (g_params.adc) */
    g_params.adc.err_A_K = 3.0f;
    g_params.adc.err_B_K = 7.5f;
    g_params.adc.err_C_K = 5.0f;
    g_params.adc.err_D_K = 8.75f;
    Debug_Register("Err_K_A", DBG_FLOAT | STATIC_TYPE, &g_params.adc.err_A_K);
    Debug_Register("Err_K_B", DBG_FLOAT | STATIC_TYPE, &g_params.adc.err_B_K);
    Debug_Register("Err_K_C", DBG_FLOAT | STATIC_TYPE, &g_params.adc.err_C_K);
    Debug_Register("Err_K_D", DBG_FLOAT | STATIC_TYPE, &g_params.adc.err_D_K);

    /* 十字专用 (g_params_cross.adc, Init 末尾 copy 后个别清零) */
    Debug_Register("Cr_ErrKA", DBG_FLOAT | STATIC_TYPE, &g_params_cross.adc.err_A_K);
    Debug_Register("Cr_ErrKB", DBG_FLOAT | STATIC_TYPE, &g_params_cross.adc.err_B_K);
    Debug_Register("Cr_ErrKC", DBG_FLOAT | STATIC_TYPE, &g_params_cross.adc.err_C_K);
    Debug_Register("Cr_ErrKD", DBG_FLOAT | STATIC_TYPE, &g_params_cross.adc.err_D_K);

    /* 墙面专用 (g_params_wall.adc) */
    Debug_Register("Wl_ErrKA", DBG_FLOAT | STATIC_TYPE, &g_params_wall.adc.err_A_K);
    Debug_Register("Wl_ErrKB", DBG_FLOAT | STATIC_TYPE, &g_params_wall.adc.err_B_K);
    Debug_Register("Wl_ErrKC", DBG_FLOAT | STATIC_TYPE, &g_params_wall.adc.err_C_K);
    Debug_Register("Wl_ErrKD", DBG_FLOAT | STATIC_TYPE, &g_params_wall.adc.err_D_K);

    /* 死区 & 通道选择 */
    Debug_Register("CH_Induct",   DBG_UINT8  | STATIC_TYPE, &change_inductor);
    Debug_Register("ADC_DeadZone",DBG_UINT16 | STATIC_TYPE, &adc_dead_zone);
    Debug_Register("ADC_ErrZone", DBG_FLOAT  | STATIC_TYPE, &adc_err_zone);

    /* 归一化系数 (自动校准, 上位机代为保存) */
    Debug_Register("NormK", DBG_FLOAT | STATIC_TYPE, &normalized_adc_k[0]);
    Debug_Register("NormK", DBG_FLOAT | STATIC_TYPE, &normalized_adc_k[1]);
    Debug_Register("NormK", DBG_FLOAT | STATIC_TYPE, &normalized_adc_k[2]);
    Debug_Register("NormK", DBG_FLOAT | STATIC_TYPE, &normalized_adc_k[3]);

    /* 用户个性化校准系数 (逻辑位置索引: [横左,竖左,横右,竖右]) */
    Debug_Register("CalibK", DBG_FLOAT | STATIC_TYPE, &user_calib_k[0]);
    Debug_Register("CalibK", DBG_FLOAT | STATIC_TYPE, &user_calib_k[1]);
    Debug_Register("CalibK", DBG_FLOAT | STATIC_TYPE, &user_calib_k[2]);
    Debug_Register("CalibK", DBG_FLOAT | STATIC_TYPE, &user_calib_k[3]);

    /* ================================================================
     * 3. 外环控制参数 (OuterLoop) — 默认值 & Debug 注册
     * ================================================================ */
    g_params.outer.outer_slew_max  = 100.0f;
    g_params.outer.outer_lpf_fc    = 100.0f;
    g_params.outer.gyro_lpf_fc     = 100.0f;
    g_params.outer.Kd_diff_thresh  = 100.0f;
    g_params.outer.Kd_diff_high  = 0.0f;
    g_params.outer.Kd_diff_low   = 0.0f;
    g_params.outer.diff_deadband   = 0.5f;
    g_params.outer.d_ma_window     = 80;
    g_params.outer.outer_Ki        = 0.0f;
    g_params.outer.outer_i_limit   = 0.0f;
    g_params.outer.outer_i_sep_hi  = 10000.0f;
    g_params.outer.outer_i_sep_lo  = 30.0f;
    g_params.outer.lat_g_l_max  = 2.7f;
    g_params.outer.lat_g_l_safe = 1.6f;
    g_params.outer.lat_g_r_max  = 2.6f;
    g_params.outer.lat_g_r_safe = 1.5f;
    g_params.outer.lat_g_brake_k_spd = 0.5f;
    g_params.outer.lat_g_brake_k_yaw = 0.5f;
    g_params.outer.err_brake_max  = 75.0f;
    g_params.outer.err_brake_safe = 55.0f;
    g_params.outer.err_brake_k_spd = 0.0f;
    g_params.outer.err_brake_k_yaw = 0.0f;
    Debug_Register("OutSlew",   DBG_FLOAT  | STATIC_TYPE, &g_params.outer.outer_slew_max);
   // Debug_Register("OutLPFFc",  DBG_FLOAT  | STATIC_TYPE | PERI_TYPE, &g_outer_lpf_fc_desc);
   // Debug_Register("KdDifHi",   DBG_FLOAT  | STATIC_TYPE, &g_params.outer.Kd_diff_high);
    //Debug_Register("KdDifLo",   DBG_FLOAT  | STATIC_TYPE, &g_params.outer.Kd_diff_low);
    //Debug_Register("KdDifTh",   DBG_FLOAT  | STATIC_TYPE, &g_params.outer.Kd_diff_thresh);
    //Debug_Register("DiffDead",  DBG_FLOAT  | STATIC_TYPE, &g_params.outer.diff_deadband);
   // Debug_Register("D_MA_Win",  DBG_UINT16 | STATIC_TYPE | PERI_TYPE, &g_d_ma_win_desc);
    //Debug_Register("Out_Ki",    DBG_FLOAT  | STATIC_TYPE, &g_params.outer.outer_Ki);
    //Debug_Register("OutILim",   DBG_FLOAT  | STATIC_TYPE, &g_params.outer.outer_i_limit);
    //Debug_Register("OutIHi",    DBG_FLOAT  | STATIC_TYPE, &g_params.outer.outer_i_sep_hi);
   // Debug_Register("OutILo",    DBG_FLOAT  | STATIC_TYPE, &g_params.outer.outer_i_sep_lo);
    Debug_Register("GyroLPFFc", DBG_FLOAT  | STATIC_TYPE, &g_params.outer.gyro_lpf_fc);
    Debug_Register("LatG_L_Max", DBG_FLOAT | STATIC_TYPE, &g_params.outer.lat_g_l_max);
    Debug_Register("LatG_L_Saf", DBG_FLOAT | STATIC_TYPE, &g_params.outer.lat_g_l_safe);
    Debug_Register("LatG_R_Max", DBG_FLOAT | STATIC_TYPE, &g_params.outer.lat_g_r_max);
    Debug_Register("LatG_R_Saf", DBG_FLOAT | STATIC_TYPE, &g_params.outer.lat_g_r_safe);
    Debug_Register("LatG_BrkSpd", DBG_FLOAT | STATIC_TYPE, &g_params.outer.lat_g_brake_k_spd);
    Debug_Register("LatG_BrkYaw", DBG_FLOAT | STATIC_TYPE, &g_params.outer.lat_g_brake_k_yaw);
    Debug_Register("ErrB_Max",  DBG_FLOAT | STATIC_TYPE, &g_params.outer.err_brake_max);
    Debug_Register("ErrB_Safe", DBG_FLOAT | STATIC_TYPE, &g_params.outer.err_brake_safe);
    Debug_Register("ErrB_BrkSpd", DBG_FLOAT | STATIC_TYPE, &g_params.outer.err_brake_k_spd);
    Debug_Register("ErrB_BrkYaw", DBG_FLOAT | STATIC_TYPE, &g_params.outer.err_brake_k_yaw);

    /* 十字专用外环参数 (g_params_cross.outer, 上位机独立调参) */
    Debug_Register("Cr_Slew",   DBG_FLOAT | STATIC_TYPE, &g_params_cross.outer.outer_slew_max);
    Debug_Register("Cr_GLPFc",  DBG_FLOAT | STATIC_TYPE, &g_params_cross.outer.gyro_lpf_fc);
    Debug_Register("Cr_LG_LMx", DBG_FLOAT | STATIC_TYPE, &g_params_cross.outer.lat_g_l_max);
    Debug_Register("Cr_LG_LSf", DBG_FLOAT | STATIC_TYPE, &g_params_cross.outer.lat_g_l_safe);
    Debug_Register("Cr_LG_RMx", DBG_FLOAT | STATIC_TYPE, &g_params_cross.outer.lat_g_r_max);
    Debug_Register("Cr_LG_RSf", DBG_FLOAT | STATIC_TYPE, &g_params_cross.outer.lat_g_r_safe);
    Debug_Register("Cr_LGBrkS", DBG_FLOAT | STATIC_TYPE, &g_params_cross.outer.lat_g_brake_k_spd);
    Debug_Register("Cr_LGBrkY", DBG_FLOAT | STATIC_TYPE, &g_params_cross.outer.lat_g_brake_k_yaw);
    Debug_Register("Cr_EB_Mx",  DBG_FLOAT | STATIC_TYPE, &g_params_cross.outer.err_brake_max);
    Debug_Register("Cr_EB_Sf",  DBG_FLOAT | STATIC_TYPE, &g_params_cross.outer.err_brake_safe);
    Debug_Register("Cr_EBrkSp", DBG_FLOAT | STATIC_TYPE, &g_params_cross.outer.err_brake_k_spd);
    Debug_Register("Cr_EBrkYa", DBG_FLOAT | STATIC_TYPE, &g_params_cross.outer.err_brake_k_yaw);

    /* 环岛专用外环参数 (g_params_ring.outer, 上位机独立调参) */
    Debug_Register("Rn_Slew",   DBG_FLOAT | STATIC_TYPE, &g_params_ring.outer.outer_slew_max);
    Debug_Register("Rn_GLPFc",  DBG_FLOAT | STATIC_TYPE, &g_params_ring.outer.gyro_lpf_fc);
    Debug_Register("Rn_LG_LMx", DBG_FLOAT | STATIC_TYPE, &g_params_ring.outer.lat_g_l_max);
    Debug_Register("Rn_LG_LSf", DBG_FLOAT | STATIC_TYPE, &g_params_ring.outer.lat_g_l_safe);
    Debug_Register("Rn_LG_RMx", DBG_FLOAT | STATIC_TYPE, &g_params_ring.outer.lat_g_r_max);
    Debug_Register("Rn_LG_RSf", DBG_FLOAT | STATIC_TYPE, &g_params_ring.outer.lat_g_r_safe);
    Debug_Register("Rn_LGBrkS", DBG_FLOAT | STATIC_TYPE, &g_params_ring.outer.lat_g_brake_k_spd);
    Debug_Register("Rn_LGBrkY", DBG_FLOAT | STATIC_TYPE, &g_params_ring.outer.lat_g_brake_k_yaw);
    Debug_Register("Rn_EB_Mx",  DBG_FLOAT | STATIC_TYPE, &g_params_ring.outer.err_brake_max);
    Debug_Register("Rn_EB_Sf",  DBG_FLOAT | STATIC_TYPE, &g_params_ring.outer.err_brake_safe);
    Debug_Register("Rn_EBrkSp", DBG_FLOAT | STATIC_TYPE, &g_params_ring.outer.err_brake_k_spd);
    Debug_Register("Rn_EBrkYa", DBG_FLOAT | STATIC_TYPE, &g_params_ring.outer.err_brake_k_yaw);

    /* 墙面专用外环参数 (g_params_wall.outer, 上位机独立调参) */
    Debug_Register("Wl_Slew",   DBG_FLOAT | STATIC_TYPE, &g_params_wall.outer.outer_slew_max);
    Debug_Register("Wl_GLPFc",  DBG_FLOAT | STATIC_TYPE, &g_params_wall.outer.gyro_lpf_fc);
    Debug_Register("Wl_LG_LMx", DBG_FLOAT | STATIC_TYPE, &g_params_wall.outer.lat_g_l_max);
    Debug_Register("Wl_LG_LSf", DBG_FLOAT | STATIC_TYPE, &g_params_wall.outer.lat_g_l_safe);
    Debug_Register("Wl_LG_RMx", DBG_FLOAT | STATIC_TYPE, &g_params_wall.outer.lat_g_r_max);
    Debug_Register("Wl_LG_RSf", DBG_FLOAT | STATIC_TYPE, &g_params_wall.outer.lat_g_r_safe);
    Debug_Register("Wl_LGBrkS", DBG_FLOAT | STATIC_TYPE, &g_params_wall.outer.lat_g_brake_k_spd);
    Debug_Register("Wl_LGBrkY", DBG_FLOAT | STATIC_TYPE, &g_params_wall.outer.lat_g_brake_k_yaw);
    Debug_Register("Wl_EB_Mx",  DBG_FLOAT | STATIC_TYPE, &g_params_wall.outer.err_brake_max);
    Debug_Register("Wl_EB_Sf",  DBG_FLOAT | STATIC_TYPE, &g_params_wall.outer.err_brake_safe);
    Debug_Register("Wl_EBrkSp", DBG_FLOAT | STATIC_TYPE, &g_params_wall.outer.err_brake_k_spd);
    Debug_Register("Wl_EBrkYa", DBG_FLOAT | STATIC_TYPE, &g_params_wall.outer.err_brake_k_yaw);

    /* ================================================================
     * 4. 外环观测 (HIGH_FREQ) — 只看不改
     * ================================================================ */
    Debug_Register("TgtYaw",  DBG_FLOAT | HIGH_FREQ_TYPE, &g_state.pid_output);
   // Debug_Register("TarYawR", DBG_FLOAT | HIGH_FREQ_TYPE, &g_state.tar_yaw_raw);
    Debug_Register("ActYaw",  DBG_FLOAT | HIGH_FREQ_TYPE, &g_state.gyro_filtered);
    Debug_Register("YawITrm", DBG_FLOAT | HIGH_FREQ_TYPE, &g_state.inner.error_sum);

    /* ================================================================
     * 5. 内环 PI — 默认值 & Debug 注册
     * ================================================================ */
    g_params.inner.Kp = 7.300000190734863f;
    g_params.inner.Ki = 0.12999999523162842f;
    g_params.inner.Kd = 0.10000000149011612f;
    g_params.inner.error_sum_max = 24.0f;    /* 内环积分上限 */
    g_params.inner.max_sep = 100000.0f;
    g_params.inner.min_sep = 0.0f;
    g_state.inner.error_sum  = 0.0f;
    g_state.inner.last_error = 0.0f;
    Debug_Register("Yaw_Kp",   DBG_FLOAT | STATIC_TYPE, &g_params.inner.Kp);
    Debug_Register("Yaw_Ki",   DBG_FLOAT | STATIC_TYPE, &g_params.inner.Ki);
    Debug_Register("Yaw_Kd",   DBG_FLOAT | STATIC_TYPE, &g_params.inner.Kd);
    Debug_Register("YawLimit", DBG_FLOAT | STATIC_TYPE, &g_params.inner.error_sum_max);
    Debug_Register("YawHiLi",  DBG_FLOAT | STATIC_TYPE, &g_params.inner.max_sep);
    Debug_Register("YawLoLi",  DBG_FLOAT | STATIC_TYPE, &g_params.inner.min_sep);

    /* 十字专用内环 PI 参数 (g_params_cross.inner) */
    Debug_Register("Cr_YKp",   DBG_FLOAT | STATIC_TYPE, &g_params_cross.inner.Kp);
    Debug_Register("Cr_YKi",   DBG_FLOAT | STATIC_TYPE, &g_params_cross.inner.Ki);
    Debug_Register("Cr_YKd",   DBG_FLOAT | STATIC_TYPE, &g_params_cross.inner.Kd);
    Debug_Register("Cr_YLim",  DBG_FLOAT | STATIC_TYPE, &g_params_cross.inner.error_sum_max);

    /* 环岛专用内环 PI 参数 (g_params_ring.inner) */
    Debug_Register("Rn_YKp",   DBG_FLOAT | STATIC_TYPE, &g_params_ring.inner.Kp);
    Debug_Register("Rn_YKi",   DBG_FLOAT | STATIC_TYPE, &g_params_ring.inner.Ki);
    Debug_Register("Rn_YKd",   DBG_FLOAT | STATIC_TYPE, &g_params_ring.inner.Kd);
    Debug_Register("Rn_YLim",  DBG_FLOAT | STATIC_TYPE, &g_params_ring.inner.error_sum_max);

    /* 墙面专用内环 PI 参数 (g_params_wall.inner) */
    Debug_Register("Wl_YKp",   DBG_FLOAT | STATIC_TYPE, &g_params_wall.inner.Kp);
    Debug_Register("Wl_YKi",   DBG_FLOAT | STATIC_TYPE, &g_params_wall.inner.Ki);
    Debug_Register("Wl_YKd",   DBG_FLOAT | STATIC_TYPE, &g_params_wall.inner.Kd);
    Debug_Register("Wl_YLim",  DBG_FLOAT | STATIC_TYPE, &g_params_wall.inner.error_sum_max);

    /* ================================================================
     * 5b. 速度输出后处理 — 默认值 & Debug 注册
     * ================================================================ */
    g_params.speed_out.max_output = 250.0f;
    g_params.speed_out.min_output = 2.0f;
    g_params.speed_out.max_diff   = 200.0f;
    g_params.speed_out.min_diff   = 1.0f;
    g_params.speed_out.slew_rate  = 40.0f;
    g_state.last_spd_l = 0.0f;
    g_state.last_spd_r = 0.0f;
    Debug_Register("SpdMax",  DBG_FLOAT | STATIC_TYPE, &g_params.speed_out.max_output);
    Debug_Register("SpdMin",  DBG_FLOAT | STATIC_TYPE, &g_params.speed_out.min_output);
    Debug_Register("DiffMax", DBG_FLOAT | STATIC_TYPE, &g_params.speed_out.max_diff);
    Debug_Register("DiffMin", DBG_FLOAT | STATIC_TYPE, &g_params.speed_out.min_diff);
    Debug_Register("SpdSlew", DBG_FLOAT | STATIC_TYPE, &g_params.speed_out.slew_rate);

    /* 墙面专用速度输出后处理 (g_params_wall.speed_out) */
    Debug_Register("Wl_SpdMx", DBG_FLOAT | STATIC_TYPE, &g_params_wall.speed_out.max_output);
    Debug_Register("Wl_SpdMn", DBG_FLOAT | STATIC_TYPE, &g_params_wall.speed_out.min_output);
    Debug_Register("Wl_DfMx",  DBG_FLOAT | STATIC_TYPE, &g_params_wall.speed_out.max_diff);
    Debug_Register("Wl_DfMn",  DBG_FLOAT | STATIC_TYPE, &g_params_wall.speed_out.min_diff);
    Debug_Register("Wl_SpdSl", DBG_FLOAT | STATIC_TYPE, &g_params_wall.speed_out.slew_rate);

    /* 十字专用速度输出后处理 (g_params_cross.speed_out) */
    Debug_Register("Cr_SpMx",  DBG_FLOAT | STATIC_TYPE, &g_params_cross.speed_out.max_output);
    Debug_Register("Cr_SpMn",  DBG_FLOAT | STATIC_TYPE, &g_params_cross.speed_out.min_output);
    Debug_Register("Cr_DfMx",  DBG_FLOAT | STATIC_TYPE, &g_params_cross.speed_out.max_diff);
    Debug_Register("Cr_DfMn",  DBG_FLOAT | STATIC_TYPE, &g_params_cross.speed_out.min_diff);
    Debug_Register("Cr_SpSl",  DBG_FLOAT | STATIC_TYPE, &g_params_cross.speed_out.slew_rate);

    /* 环岛专用速度输出后处理 (g_params_ring.speed_out) */
    Debug_Register("Rn_SpMx",  DBG_FLOAT | STATIC_TYPE, &g_params_ring.speed_out.max_output);
    Debug_Register("Rn_SpMn",  DBG_FLOAT | STATIC_TYPE, &g_params_ring.speed_out.min_output);
    Debug_Register("Rn_DfMx",  DBG_FLOAT | STATIC_TYPE, &g_params_ring.speed_out.max_diff);
    Debug_Register("Rn_DfMn",  DBG_FLOAT | STATIC_TYPE, &g_params_ring.speed_out.min_diff);
    Debug_Register("Rn_SpSl",  DBG_FLOAT | STATIC_TYPE, &g_params_ring.speed_out.slew_rate);

    /* ================================================================
     * 6. 模糊 PID — 默认值 & Debug 注册 (三套独立: 默认 / 十字 / 环岛)
     * ================================================================ */
    g_params.fuzzy.e_max    = 70.0f;
    g_params.fuzzy.Kp0      = 0.1550000011920929f;
    g_params.fuzzy.setpoint = 0.0f;
    FuzzyPID_Init(&g_params.fuzzy, g_params.fuzzy.Kp0, g_params.fuzzy.e_max);
    /* 覆盖模糊 Kp 单点值 (FKp NB~PB, 9 档) */
    g_params.fuzzy.kp_singletons[FUZZY_NB] = 2.200000047683716f;
    g_params.fuzzy.kp_singletons[FUZZY_NM] = 2.0f;
    g_params.fuzzy.kp_singletons[FUZZY_NS] = 1.7999999523162842f;
    g_params.fuzzy.kp_singletons[FUZZY_NZ] = 1.2000000476837158f;
    g_params.fuzzy.kp_singletons[FUZZY_ZO] = 0.8999999761581421f;
    g_params.fuzzy.kp_singletons[FUZZY_PZ] = 1.2999999523162842f;
    g_params.fuzzy.kp_singletons[FUZZY_PS] = 1.7999999523162842f;
    g_params.fuzzy.kp_singletons[FUZZY_PM] = 2.0f;
    g_params.fuzzy.kp_singletons[FUZZY_PB] = 2.200000047683716f;

    /* 默认 */
    Debug_Register("FKp0",   DBG_FLOAT | STATIC_TYPE, &g_params.fuzzy.Kp0);
    Debug_Register("Fe_max", DBG_FLOAT | STATIC_TYPE, &g_params.fuzzy.e_max);
    Debug_Register("FKeX",   DBG_FLOAT | STATIC_TYPE, &g_params.fuzzy.Kp_excess);
    Debug_Register("FKp", DBG_FLOAT | STATIC_TYPE, &g_params.fuzzy.kp_singletons[FUZZY_NB]);
    Debug_Register("FKp", DBG_FLOAT | STATIC_TYPE, &g_params.fuzzy.kp_singletons[FUZZY_NM]);
    Debug_Register("FKp", DBG_FLOAT | STATIC_TYPE, &g_params.fuzzy.kp_singletons[FUZZY_NS]);
    Debug_Register("FKp", DBG_FLOAT | STATIC_TYPE, &g_params.fuzzy.kp_singletons[FUZZY_NZ]);
    Debug_Register("FKp", DBG_FLOAT | STATIC_TYPE, &g_params.fuzzy.kp_singletons[FUZZY_ZO]);
    Debug_Register("FKp", DBG_FLOAT | STATIC_TYPE, &g_params.fuzzy.kp_singletons[FUZZY_PZ]);
    Debug_Register("FKp", DBG_FLOAT | STATIC_TYPE, &g_params.fuzzy.kp_singletons[FUZZY_PS]);
    Debug_Register("FKp", DBG_FLOAT | STATIC_TYPE, &g_params.fuzzy.kp_singletons[FUZZY_PM]);
    Debug_Register("FKp", DBG_FLOAT | STATIC_TYPE, &g_params.fuzzy.kp_singletons[FUZZY_PB]);

    /* 十字专用 */
    Debug_Register("Cr_FKp0",   DBG_FLOAT | STATIC_TYPE, &g_params_cross.fuzzy.Kp0);
    Debug_Register("Cr_Fe_max", DBG_FLOAT | STATIC_TYPE, &g_params_cross.fuzzy.e_max);
    Debug_Register("Cr_FKeX",   DBG_FLOAT | STATIC_TYPE, &g_params_cross.fuzzy.Kp_excess);
    Debug_Register("Cr_FKp", DBG_FLOAT | STATIC_TYPE, &g_params_cross.fuzzy.kp_singletons[FUZZY_NB]);
    Debug_Register("Cr_FKp", DBG_FLOAT | STATIC_TYPE, &g_params_cross.fuzzy.kp_singletons[FUZZY_NM]);
    Debug_Register("Cr_FKp", DBG_FLOAT | STATIC_TYPE, &g_params_cross.fuzzy.kp_singletons[FUZZY_NS]);
    Debug_Register("Cr_FKp", DBG_FLOAT | STATIC_TYPE, &g_params_cross.fuzzy.kp_singletons[FUZZY_NZ]);
    Debug_Register("Cr_FKp", DBG_FLOAT | STATIC_TYPE, &g_params_cross.fuzzy.kp_singletons[FUZZY_ZO]);
    Debug_Register("Cr_FKp", DBG_FLOAT | STATIC_TYPE, &g_params_cross.fuzzy.kp_singletons[FUZZY_PZ]);
    Debug_Register("Cr_FKp", DBG_FLOAT | STATIC_TYPE, &g_params_cross.fuzzy.kp_singletons[FUZZY_PS]);
    Debug_Register("Cr_FKp", DBG_FLOAT | STATIC_TYPE, &g_params_cross.fuzzy.kp_singletons[FUZZY_PM]);
    Debug_Register("Cr_FKp", DBG_FLOAT | STATIC_TYPE, &g_params_cross.fuzzy.kp_singletons[FUZZY_PB]);

    /* 环岛专用 */
    Debug_Register("Rn_FKp0",   DBG_FLOAT | STATIC_TYPE, &g_params_ring.fuzzy.Kp0);
    Debug_Register("Rn_Fe_max", DBG_FLOAT | STATIC_TYPE, &g_params_ring.fuzzy.e_max);
    Debug_Register("Rn_FKeX",   DBG_FLOAT | STATIC_TYPE, &g_params_ring.fuzzy.Kp_excess);
    Debug_Register("Rn_FKp", DBG_FLOAT | STATIC_TYPE, &g_params_ring.fuzzy.kp_singletons[FUZZY_NB]);
    Debug_Register("Rn_FKp", DBG_FLOAT | STATIC_TYPE, &g_params_ring.fuzzy.kp_singletons[FUZZY_NM]);
    Debug_Register("Rn_FKp", DBG_FLOAT | STATIC_TYPE, &g_params_ring.fuzzy.kp_singletons[FUZZY_NS]);
    Debug_Register("Rn_FKp", DBG_FLOAT | STATIC_TYPE, &g_params_ring.fuzzy.kp_singletons[FUZZY_NZ]);
    Debug_Register("Rn_FKp", DBG_FLOAT | STATIC_TYPE, &g_params_ring.fuzzy.kp_singletons[FUZZY_ZO]);
    Debug_Register("Rn_FKp", DBG_FLOAT | STATIC_TYPE, &g_params_ring.fuzzy.kp_singletons[FUZZY_PZ]);
    Debug_Register("Rn_FKp", DBG_FLOAT | STATIC_TYPE, &g_params_ring.fuzzy.kp_singletons[FUZZY_PS]);
    Debug_Register("Rn_FKp", DBG_FLOAT | STATIC_TYPE, &g_params_ring.fuzzy.kp_singletons[FUZZY_PM]);
    Debug_Register("Rn_FKp", DBG_FLOAT | STATIC_TYPE, &g_params_ring.fuzzy.kp_singletons[FUZZY_PB]);

    /* 墙面专用模糊 PID (g_params_wall.fuzzy) */
    Debug_Register("Wl_FKp0",  DBG_FLOAT | STATIC_TYPE, &g_params_wall.fuzzy.Kp0);
    Debug_Register("Wl_Femax", DBG_FLOAT | STATIC_TYPE, &g_params_wall.fuzzy.e_max);
    Debug_Register("Wl_FKeX",  DBG_FLOAT | STATIC_TYPE, &g_params_wall.fuzzy.Kp_excess);
    Debug_Register("Wl_FKp", DBG_FLOAT | STATIC_TYPE, &g_params_wall.fuzzy.kp_singletons[FUZZY_NB]);
    Debug_Register("Wl_FKp", DBG_FLOAT | STATIC_TYPE, &g_params_wall.fuzzy.kp_singletons[FUZZY_NM]);
    Debug_Register("Wl_FKp", DBG_FLOAT | STATIC_TYPE, &g_params_wall.fuzzy.kp_singletons[FUZZY_NS]);
    Debug_Register("Wl_FKp", DBG_FLOAT | STATIC_TYPE, &g_params_wall.fuzzy.kp_singletons[FUZZY_NZ]);
    Debug_Register("Wl_FKp", DBG_FLOAT | STATIC_TYPE, &g_params_wall.fuzzy.kp_singletons[FUZZY_ZO]);
    Debug_Register("Wl_FKp", DBG_FLOAT | STATIC_TYPE, &g_params_wall.fuzzy.kp_singletons[FUZZY_PZ]);
    Debug_Register("Wl_FKp", DBG_FLOAT | STATIC_TYPE, &g_params_wall.fuzzy.kp_singletons[FUZZY_PS]);
    Debug_Register("Wl_FKp", DBG_FLOAT | STATIC_TYPE, &g_params_wall.fuzzy.kp_singletons[FUZZY_PM]);
    Debug_Register("Wl_FKp", DBG_FLOAT | STATIC_TYPE, &g_params_wall.fuzzy.kp_singletons[FUZZY_PB]);

    /* ================================================================
     * 7. 电机外设 (PERI_TYPE) — 通过 SPI 读写电机寄存器
     * ================================================================ */
    Debug_Register("A_ILim", DBG_FLOAT | STATIC_TYPE | PERI_TYPE, &g_pid_a_ilim_desc);
    Debug_Register("B_ILim", DBG_FLOAT | STATIC_TYPE | PERI_TYPE, &g_pid_b_ilim_desc);

    /* ================================================================
     * 8. 系统 / 杂项 — Debug 注册
     * ================================================================ */
    Debug_Register("ComSpd",    DBG_FLOAT  | STATIC_TYPE, &common_speed);
    Debug_Register("Drive_Spd", DBG_FLOAT  | STATIC_TYPE, &drive_speed);
    Debug_Register("Fan_D",     DBG_UINT16 | STATIC_TYPE | PERI_TYPE, &g_fan_d);
    Debug_Register("SS_Step",   DBG_FLOAT  | STATIC_TYPE, &g_ss_step);
    Debug_Register("Manual",    DBG_UINT8  | STATIC_TYPE, &manual_control_flag);
    Debug_Register("stat",      DBG_UINT8 | HIGH_FREQ_TYPE, &g_current_element_u8);

    /* 侧向加速度 LPF 截止频率 (PERI_TYPE → 上位机可读写) */
  //  Debug_Register("LatG_VW_Fc",  DBG_FLOAT | STATIC_TYPE | PERI_TYPE, &g_lat_g_vw_lpf_desc);

    /* ================================================================
     * 9. 滤波器 & 移动平均初始化 (依赖外环默认参数)
     * ================================================================ */
    lpf_init_fc(&g_lpf_left,              400.0f, 0.002f);
    lpf_init_fc(&g_lpf_right,             400.0f, 0.002f);
    lpf_init_fc(&g_state.lpf_outer, g_params.outer.outer_lpf_fc, 0.002f);
    lpf_init_fc(&g_state.lpf_gyro,  g_params.outer.gyro_lpf_fc,  0.002f);
    lpf_init_fc(&g_state.lpf_lat_g, 200.0f, 0.002f);      /* v·ω 侧向加速度滤波 */
    ma_init(&g_state.d_ma, g_params.outer.d_ma_window);

    /* ================================================================
     * 10. 十字参数集 & 收尾
     * ================================================================ */
    g_stream_active = 0;
    copy_params(&g_params_cross, &g_params);
    copy_params(&g_params_ring, &g_params);
    copy_params(&g_params_wall, &g_params);
    g_params_wall.adc.err_B_K = 4.0f;
    g_params_cross.adc.err_B_K = 0.0f;
    g_params_cross.adc.err_D_K = 0.0f;

    /* 非直道元素旁路所有制动 (只调直道, 后续逐元素放开) */
    g_params_cross.outer.lat_g_brake_k_spd = 0.0f;
    g_params_cross.outer.lat_g_brake_k_yaw = 0.0f;
    g_params_cross.outer.err_brake_k_spd   = 0.0f;
    g_params_cross.outer.err_brake_k_yaw   = 0.0f;
    g_params_ring.outer.lat_g_brake_k_spd  = 0.0f;
    g_params_ring.outer.lat_g_brake_k_yaw  = 0.0f;
    g_params_ring.outer.err_brake_k_spd    = 0.0f;
    g_params_ring.outer.err_brake_k_yaw    = 0.0f;
    g_params_wall.outer.lat_g_brake_k_spd  = 0.0f;
    g_params_wall.outer.lat_g_brake_k_yaw  = 0.0f;
    g_params_wall.outer.err_brake_k_spd    = 0.0f;
    g_params_wall.outer.err_brake_k_yaw    = 0.0f;

    /* 十字/环岛/上墙 继承固化前的环路参数, 不做改动 */
    g_params_cross.inner.Kp = 5.800000190734863f;
    g_params_cross.inner.Ki = 0.0f;
    g_params_cross.inner.error_sum_max = 50.0f;
    g_params_ring.inner.Kp = 5.800000190734863f;
    g_params_ring.inner.Ki = 0.0f;
    g_params_ring.inner.error_sum_max = 50.0f;
    g_params_wall.inner.Kp = 5.800000190734863f;
    g_params_wall.inner.Ki = 0.0f;
    g_params_wall.inner.error_sum_max = 50.0f;

    /* 环岛专用模糊 PID 固化 (来自 改一下环岛.json 调参结果, 9档插值) */
    g_params_ring.fuzzy.Kp0 = 0.15000000596046448f;
    g_params_ring.fuzzy.kp_singletons[FUZZY_NB] = 1.5f;
    g_params_ring.fuzzy.kp_singletons[FUZZY_NM] = 1.399999976158142f;
    g_params_ring.fuzzy.kp_singletons[FUZZY_NS] = 1.100000023841858f;
    g_params_ring.fuzzy.kp_singletons[FUZZY_NZ] = 1.0f;
    g_params_ring.fuzzy.kp_singletons[FUZZY_ZO] = 0.8999999761581421f;
    g_params_ring.fuzzy.kp_singletons[FUZZY_PZ] = 1.0f;
    g_params_ring.fuzzy.kp_singletons[FUZZY_PS] = 1.100000023841858f;
    g_params_ring.fuzzy.kp_singletons[FUZZY_PM] = 1.399999976158142f;
    g_params_ring.fuzzy.kp_singletons[FUZZY_PB] = 1.5f;
    g_params_ring.fuzzy.e_max = 70.0f;

    /* 十字专用模糊 PID 固化 (来自 完赛参数.json, 与直线默认值不同, 需显式覆盖) */
    g_params_cross.fuzzy.Kp0 = 0.17000000178813934f;
    g_params_cross.fuzzy.e_max = 50.0f;
    g_params_cross.fuzzy.kp_singletons[FUZZY_NB] = 2.200000047683716f;
    g_params_cross.fuzzy.kp_singletons[FUZZY_NM] = 1.600000023841858f;
    g_params_cross.fuzzy.kp_singletons[FUZZY_NS] = 1.399999976158142f;
    g_params_cross.fuzzy.kp_singletons[FUZZY_NZ] = 1.149999976158142f;
    g_params_cross.fuzzy.kp_singletons[FUZZY_ZO] = 0.8999999761581421f;
    g_params_cross.fuzzy.kp_singletons[FUZZY_PZ] = 1.149999976158142f;
    g_params_cross.fuzzy.kp_singletons[FUZZY_PS] = 1.399999976158142f;
    g_params_cross.fuzzy.kp_singletons[FUZZY_PM] = 1.600000023841858f;
    g_params_cross.fuzzy.kp_singletons[FUZZY_PB] = 2.200000047683716f;

    /* 上墙专用模糊 PID 固化 (来自 完赛参数.json, 与直线默认值不同, 需显式覆盖) */
    g_params_wall.fuzzy.Kp0 = 0.17000000178813934f;
    g_params_wall.fuzzy.e_max = 50.0f;
    g_params_wall.fuzzy.kp_singletons[FUZZY_NB] = 2.200000047683716f;
    g_params_wall.fuzzy.kp_singletons[FUZZY_NM] = 1.600000023841858f;
    g_params_wall.fuzzy.kp_singletons[FUZZY_NS] = 1.399999976158142f;
    g_params_wall.fuzzy.kp_singletons[FUZZY_NZ] = 1.149999976158142f;
    g_params_wall.fuzzy.kp_singletons[FUZZY_ZO] = 0.8999999761581421f;
    g_params_wall.fuzzy.kp_singletons[FUZZY_PZ] = 1.149999976158142f;
    g_params_wall.fuzzy.kp_singletons[FUZZY_PS] = 1.399999976158142f;
    g_params_wall.fuzzy.kp_singletons[FUZZY_PM] = 1.600000023841858f;
    g_params_wall.fuzzy.kp_singletons[FUZZY_PB] = 2.200000047683716f;

    /* 初始化 SPI3, ADC */
    SPI3_Init(SPI3_Callback);
    ADC2_DMA_Init(adc_dma_buf);
    ADC2_DMA_Start();
    //vTaskDelay(pdMS_TO_TICKS(10));
    
    /* 创建 Main_Control_Task (低优先级, 2ms 周期) */
     xTaskCreate(Main_Control_Task, "main_control", 1224, NULL, tskIDLE_PRIORITY + 3, &xMainControlTaskHandle);
}
