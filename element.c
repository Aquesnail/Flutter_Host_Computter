#include "element.h"
#include "debug_arch.h"
#include "FreeRTOS.h"
#include "task.h"
#include "led_indicator.h"
#include <math.h>
#include "lpf.h"
#include <string.h>
extern unsigned char manual_control_flag;

#define FABS(x) ((x) > 0.0f ? (x) : -(x))

/* ================================================================
 * SECTION 0 — 共享参数 & 基础设施
 * ================================================================ */

/* ---- 车身水平倾角阈值 (多元素共用) ---- */
static float angle_level = 15.0f;   /* 车身水平倾角阈值(度), 四元数前后倾角 */

/* ---- 推车调试 ---- */

/* ================================================================
 * 速度变量 (供元素属性表 speed_ptr 指向 + Debug_Register 在线调参)
 *   必须在 g_element_props 之前声明
 * ================================================================ */
static float g_speed_cruising     = 70.0f;
static float g_speed_ring         = 60.0f;
static float g_speed_wall         = 45.0f;
static float g_speed_wall_climb   = 45.0f;
static float g_speed_wall_horiz   = 40.0f;
static float g_speed_wall_descend = 50.0f;
static float g_speed_barrel       = 95.0f;
static float g_speed_cross        = 70.0f;
static float g_speed_skip         = 30.0f;

/* ---- 风扇占空比变量 (供元素属性表 fan_d_ptr 指向 + Debug_Register 在线调参) ---- */
static uint16_t g_fan_d_straight = 400;
static uint16_t g_fan_d_ring     = 400;
static uint16_t g_fan_d_wall     = 425;
static uint16_t g_fan_d_cross    = 400;
static uint16_t g_fan_d_barrel   = 425;
static uint16_t g_fan_d_skip     = 400;

/* ---- 环岛开环参数 (被 g_element_props 引用, 必须前置) ---- */
float    g_ol_ring_angle   = 0.0f;    /* 环岛开环目标角度(绝对值, 度) */
float    g_ol_ring_yawrate = 15.0f;    /* 环岛开环目标角速度(绝对值, °/s) */

/* ================================================================
 * 元素属性表 (Flash 常驻, 按 ELEMENT_ACTIVE_COUNT 索引)
 * ================================================================ */
static const ElementProp_t g_element_props[ELEMENT_ACTIVE_COUNT] = {
    /* [0] ELEMENT_STRAIGHT            R    G    B   颜色 */
    { ELEMENT_STRAIGHT, "STRAIGHT", &g_speed_cruising,   &g_fan_d_straight,   0,   0,   0, CTRL_NORMAL, NULL, 0 }, /* 灭 (黑) */
    /* [1] ELEMENT_RING_LEFT_ENTRANCE */
    { ELEMENT_RING_LEFT_ENTRANCE, "RING_L_ENT", &g_speed_ring, &g_fan_d_ring, 0, 0, 255, CTRL_NORMAL, NULL, 0 }, /* 蓝 */
    /* [2] ELEMENT_RING_RIGHT_ENTRANCE */
    { ELEMENT_RING_RIGHT_ENTRANCE,"RING_R_ENT",&g_speed_ring, &g_fan_d_ring, 0, 0, 255, CTRL_NORMAL, NULL, 0 }, /* 蓝 */
    /* [3] ELEMENT_WALL */
    { ELEMENT_WALL, "WALL", &g_speed_wall, &g_fan_d_wall, 255, 128, 0, CTRL_NORMAL, NULL, 0 }, /* 橙 */
    /* [4] ELEMENT_CROSS */
    { ELEMENT_CROSS, "CROSS", &g_speed_cross, &g_fan_d_cross, 0, 255, 0, CTRL_NORMAL, NULL, 0 }, /* 绿 */
    /* [5] ELEMENT_BARREL */
    { ELEMENT_BARREL, "BARREL", &g_speed_barrel, &g_fan_d_barrel, 255, 0, 255, CTRL_NORMAL, NULL, 0 }, /* 品红 */
    /* [6] ELEMENT_SKIP */
    { ELEMENT_SKIP, "SKIP", &g_speed_skip, &g_fan_d_skip, 255, 255, 255, CTRL_NORMAL, NULL, 0 }, /* 白 */
    /* [7] ELEMENT_RING_LEFT_PASS */
    { ELEMENT_RING_LEFT_PASS, "RING_L_PASS", &g_speed_ring, &g_fan_d_ring, 0, 255, 255, CTRL_OL_YAW, &g_ol_ring_yawrate,  1 }, /* 青 */
    /* [8] ELEMENT_RING_RIGHT_PASS */
    { ELEMENT_RING_RIGHT_PASS,"RING_R_PASS",&g_speed_ring, &g_fan_d_ring, 0, 255, 255, CTRL_OL_YAW, &g_ol_ring_yawrate, -1 }, /* 青 */
    /* [9] ELEMENT_IN_RING */
    { ELEMENT_IN_RING, "IN_RING", &g_speed_ring, &g_fan_d_ring, 255, 255, 0, CTRL_NORMAL, NULL, 0 }, /* 黄 */
    /* [10] ELEMENT_WALL_CLIMB */
    { ELEMENT_WALL_CLIMB, "WALL_CLIMB", &g_speed_wall_climb, &g_fan_d_wall, 255, 128, 0, CTRL_NORMAL, NULL, 0 }, /* 橙 */
    /* [11] ELEMENT_WALL_HORIZONTAL */
    { ELEMENT_WALL_HORIZONTAL, "WALL_HORIZ", &g_speed_wall_horiz, &g_fan_d_wall, 255, 255, 0, CTRL_NORMAL, NULL, 0 }, /* 黄 */
    /* [12] ELEMENT_WALL_DESCEND */
    { ELEMENT_WALL_DESCEND, "WALL_DESC", &g_speed_wall_descend, &g_fan_d_wall, 0, 255, 255, CTRL_NORMAL, NULL, 0 }, /* 青 */
    /* [13] ELEMENT_RIGHT_ANGLE_LEFT */
    { ELEMENT_RIGHT_ANGLE_LEFT,  "RT_ANG_L", &g_speed_cruising, &g_fan_d_straight, 128, 0, 255, CTRL_RA_YAW, NULL, 0 }, /* 紫 */
    /* [14] ELEMENT_RIGHT_ANGLE_RIGHT */
    { ELEMENT_RIGHT_ANGLE_RIGHT, "RT_ANG_R", &g_speed_cruising, &g_fan_d_straight, 255, 128, 0, CTRL_RA_YAW, NULL, 0 }, /* 橙 */
    /* [15] ELEMENT_BARREL_CLIMB */
    { ELEMENT_BARREL_CLIMB, "BAR_CLIMB", &g_speed_barrel, &g_fan_d_barrel, 255, 0, 255, CTRL_NORMAL, NULL, 0 }, /* 品红 */
    /* [16] ELEMENT_BARREL_VERTICAL_PEAK */
    { ELEMENT_BARREL_VERTICAL_PEAK, "BAR_PEAK", &g_speed_barrel, &g_fan_d_barrel, 255, 0, 255, CTRL_NORMAL, NULL, 0 }, /* 品红 */
    /* [17] ELEMENT_BARREL_DESCEND */
    { ELEMENT_BARREL_DESCEND, "BAR_DESC", &g_speed_barrel, &g_fan_d_barrel, 255, 0, 255, CTRL_NORMAL, NULL, 0 }, /* 品红 */
    /* [18] ELEMENT_SKIP_AIRBORNE */
    { ELEMENT_SKIP_AIRBORNE, "SKIP_AIR", &g_speed_skip, &g_fan_d_skip, 128, 128, 128, CTRL_NORMAL, NULL, 0 }, /* 灰 */
    /* [19] ELEMENT_SAFETY_STOP */
    { ELEMENT_SAFETY_STOP, "SAFETY_STOP", NULL, 0, 255, 0, 0, CTRL_BRAKE, NULL, 0 }, /* 红 */
};

/* ================================================================
 * 安全停车 / 离赛道 / 上赛道超时
 * ================================================================ */
static float   g_offtrack_timeout_ms   = 300.0f;  /* 离赛道超时 (ms) */
static float   g_offtrack_adc_thresh   = 20.0f;   /* ADC 低于此值视为离赛道 */
static uint32_t g_ontrack_timeout_frames = 10000; /* 上赛道超时 (帧), 上位机下发帧数 (500帧/s, 10000帧=20s) */
uint8_t  g_current_element_u8;            /* 当前元素枚举值 (uint8_t 镜像, 供上位机 HIGH_FREQ 上传) */

/* ================================================================
 * 赛道元素顺序表 (写死在 flash 中, 按赛道实际顺序排列)
 *   启用后, STRAIGHT 下只对表指定的方向投票, 杜绝方向误判
 * ================================================================ */
#define TRACK_TABLE_LEN  8

static const unsigned char g_track_table[TRACK_TABLE_LEN] = {
    ELEMENT_BARREL,
    ELEMENT_RING_LEFT_ENTRANCE,
    ELEMENT_SKIP,
    ELEMENT_WALL,
    
    ELEMENT_BARREL,
    ELEMENT_RING_LEFT_ENTRANCE,
    ELEMENT_SKIP,
    ELEMENT_WALL,
    
    
   /* ELEMENT_CROSS, */
   /* ELEMENT_CROSS, */
   /* ELEMENT_WALL,  */
   /* ELEMENT_BARREL */
};

static element_t g_single_element_debug = ELEMENT_RING_LEFT_ENTRANCE; /* 单元素调试: track_table_enabled=0时反复触发 */

/* ---- 投票窗缓冲区容量 ---- */
#define WALL_WIN_MAX         20
#define WALL_CLIMB_WIN_MAX   20
#define WALL_HORIZ_WIN_MAX   20
#define WALL_DESCEND_WIN_MAX 20
#define BARREL_WIN_MAX       20
#define CROSS_WIN_MAX        20
#define RA_WIN_MAX           20
#define SKIP_WIN_MAX         20


/* ================================================================
 * SECTION 1 — 通用投票窗 API
 * ================================================================ */

void VoteWin_Init(VoteWindow_t *w, unsigned char xdata *buf, unsigned char max_len)
{
    unsigned char i;

    w->buf     = buf;
    w->max_len = max_len;
    w->idx     = 0;
    w->cnt     = 0;
    w->len     = 10;          /* 默认窗长 10 帧 */
    w->entry_thresh = 5;      /* 默认 70% 多数 */
    w->exit_thresh  = 5;

    for (i = 0; i < max_len; i++) {
        buf[i] = 0;
    }
}

void VoteWin_Push(VoteWindow_t *w, unsigned char vote)
{
    unsigned char old_vote;

    if (w->len == 0) return;
    if (w->idx >= w->len) {
        w->idx = 0;
    }

    old_vote = w->buf[w->idx];
    if (old_vote == 1) {
        w->cnt--;
    }
    w->buf[w->idx] = vote;
    if (vote == 1) {
        w->cnt++;
    }
    if (w->cnt > w->len) {
        w->cnt = w->len;
    }
    w->idx++;
}

unsigned char VoteWin_Reached(VoteWindow_t *w, unsigned char thresh)
{
    return (w->cnt >= thresh) ? 1 : 0;
}

void VoteWin_Reset(VoteWindow_t *w)
{
    unsigned char i;

    for (i = 0; i < w->len; i++) {
        w->buf[i] = 0;
    }
    w->cnt = 0;
    w->idx = 0;
}

void VoteWin_SetLen(VoteWindow_t *w, unsigned char len)
{
    if (len > w->max_len) {
        len = w->max_len;
    }
    w->len = len;
    VoteWin_Reset(w);
}


/* ================================================================
 * SECTION 2 — 赛道表辅助 & 公共动作
 * ================================================================ */

static void Track_Advance(ElementCtx_t *ctx)
{
    if (ctx->track_table_enabled && ctx->track_idx < TRACK_TABLE_LEN) {
        ctx->track_idx++;
    }
}

static element_t Track_GetExpected(ElementCtx_t *ctx)
{
    if (ctx->track_table_enabled) {
        if (ctx->track_idx < TRACK_TABLE_LEN) {
            return (element_t)g_track_table[ctx->track_idx];
        }
        return ELEMENT_STRAIGHT;
    } else {
        return g_single_element_debug;
    }
}

static unsigned char Track_CheckExpected(ElementCtx_t *ctx, element_t expected)
{
    element_t exp;
    exp = Track_GetExpected(ctx);
    return (exp == expected) ? 1 : 0;
}

static const char* Element_Name(element_t e)
{
    if (e < ELEMENT_ACTIVE_COUNT) {
        return g_element_props[e].name;
    }
    switch (e) {
    case ELEMENT_RING_LEFT_EXIT:     return "RING_L_EXIT";
    case ELEMENT_RING_RIGHT_EXIT:    return "RING_R_EXIT";
    case ELEMENT_SKIP:               return "SKIP";
    case ELEMENT_SKIP_AIRBORNE:      return "SKIP_AIR";
    default:                         return "UNKNOWN";
    }
}

const ElementProp_t* Element_GetProp(element_t e)
{
    if (e >= ELEMENT_ACTIVE_COUNT) return NULL;
    return &g_element_props[e];
}

ControlStrategy_t Element_GetEffectiveCtrl(element_t e, ElementCtx_t *ctx)
{
    const ElementProp_t *prop;
    ControlStrategy_t ctrl;

    prop = Element_GetProp(e);
    if (prop == NULL) return CTRL_NORMAL;
    ctrl = prop->ctrl;

    if (ctx != NULL && ctx->push_mode && ctrl != CTRL_BRAKE) {
        return CTRL_FREEWHEEL;
    }
    return ctrl;
}

/* ---- 统一退出到 STRAIGHT: 推进赛道元素表 (所有元素正常退出共用) ---- */
static void Enter_ExitToStraight(ElementCtx_t *ctx)
{
    Track_Advance(ctx);
}


/* ================================================================
 * SECTION 3 — 环岛 RING
 * ================================================================ */

/* ---- 环岛参数 ---- */
static float RingEntrance[4];
static float RingExit[4];
static unsigned char xdata ring_vote_buf[100];
static VoteWindow_t vote_win_ring;

static unsigned short g_pass_timeout_frames = 150;  /* 默认150帧=300ms */
static float    g_ring_exit_yaw_thresh  = 300.0f;  /* 退环所需 yaw 累计角度(绝对值, 度) */
static unsigned short g_ring_exit_lockout_frames = 300;  /* 锁存时长(帧), 默认300帧=600ms */
static unsigned short g_ring_timeout_frames   = 400;  /* 环岛总超时 (帧, ≈0.8s) */
static float    g_ring_veto_vertical_sum = 600.0f;  /* 竖向电感和否决阈值: adc[1]+adc[3] > 此值 → 十字特征, 否决进环 */

/* ---- 环岛 Check ---- */
static unsigned char Check_RingEntry_Physical(ElementCtx_t *ctx)
{
    float ring_vert_sum;

    if (ctx->ring_lockout_cnt > 0) {
        return 0;
    }
    /* 竖向电感和过高 → 十字横线特征, 瞬时否决, 防止十字误入环岛 */
    ring_vert_sum = ctx->adc[1] + ctx->adc[3];
    if (ring_vert_sum > g_ring_veto_vertical_sum) {
        return 0;
    }
    if (ctx->vote_ring.len == 0) {
        return ((ctx->adc[0] > RingEntrance[0] || ctx->adc[2] > RingEntrance[2])
                && (FABS(ctx->tilt_fb) < angle_level)) ? 1 : 0;
    }
    return VoteWin_Reached(&ctx->vote_ring, ctx->vote_ring.entry_thresh);
}

static unsigned char Check_RingLeftEntry(ElementCtx_t *ctx)
{
    if (!Track_CheckExpected(ctx, ELEMENT_RING_LEFT_ENTRANCE)) return 0;
    return Check_RingEntry_Physical(ctx);
}

static unsigned char Check_RingRightEntry(ElementCtx_t *ctx)
{
    if (!Track_CheckExpected(ctx, ELEMENT_RING_RIGHT_ENTRANCE)) return 0;
    return Check_RingEntry_Physical(ctx);
}

static unsigned char Check_PassTimeout(ElementCtx_t *ctx)
{
    return (ctx->elem_frame_cnt >= g_pass_timeout_frames) ? 1 : 0;
}

static unsigned char Check_RingExit(ElementCtx_t *ctx)
{
    float yaw_delta;

    yaw_delta = ctx->yaw - ctx->ring_entry_yaw;
    if (ctx->ring_side == 0) {
        if (yaw_delta < g_ring_exit_yaw_thresh) return 0;
    } else {
        if (yaw_delta > -g_ring_exit_yaw_thresh) return 0;
    }

    if (ctx->vote_ring.len == 0) {
        return (ctx->adc[2] > RingExit[2] || ctx->adc[0] > RingExit[0]) ? 1 : 0;
    }
    return VoteWin_Reached(&ctx->vote_ring, ctx->vote_ring.exit_thresh);
}

static unsigned char Check_RingTimeout(ElementCtx_t *ctx)
{
    return (ctx->ring_frame_cnt >= g_ring_timeout_frames) ? 1 : 0;
}

/* ---- 环岛 Enter ---- */
static void Enter_RingPass(ElementCtx_t *ctx)
{
    ctx->elem_frame_cnt = 0;
    ctx->ring_frame_cnt = 0;
}

static void Enter_RingEntry(ElementCtx_t *ctx)
{
    if (ctx->current == ELEMENT_RING_LEFT_ENTRANCE ||
        ctx->current == ELEMENT_RING_LEFT_PASS) {
        ctx->ring_side = 0;
    } else {
        ctx->ring_side = 1;
    }
}

static void Enter_InRing(ElementCtx_t *ctx)
{
    ctx->ring_entry_yaw = ctx->yaw;
    VoteWin_Reset(&ctx->vote_ring);
}

static void Enter_RingExit(ElementCtx_t *ctx)
{
    ctx->ring_lockout_cnt = g_ring_exit_lockout_frames;
    VoteWin_Reset(&ctx->vote_ring);
    Enter_ExitToStraight(ctx);
}

static void Enter_RingTimeout(ElementCtx_t *ctx)
{
    ctx->ring_frame_cnt = 0;
    VoteWin_Reset(&ctx->vote_ring);
    Enter_ExitToStraight(ctx);
}


/* ================================================================
 * SECTION 4 — 上墙 WALL
 *   线性子状态链: WALL → CLIMB → HORIZONTAL → DESCEND → STRAIGHT
 *   TiltB (tilt_fb): 前后倾角, 四元数版, 有符号
 *   TiltR (tilt_lr): 左右倾角, 四元数版, 有符号
 * ================================================================ */

/* ---- 上墙参数 ---- */
static unsigned char xdata wall_vote_buf[WALL_WIN_MAX];
static VoteWindow_t vote_win_wall;
static float   wall_entry_tiltb;              /* STRAIGHT→WALL 进入 TiltB 阈值 (默认 -60) */

static unsigned char xdata wall_climb_vote_buf[WALL_CLIMB_WIN_MAX];
static VoteWindow_t vote_win_wall_climb;
static float   wall_climb_exit_tiltr;         /* CLIMB→HORIZONTAL |TiltR| 阈值 (默认 70) */

static unsigned char xdata wall_horiz_vote_buf[WALL_HORIZ_WIN_MAX];
static VoteWindow_t vote_win_wall_horiz;
static float   wall_horiz_exit_tiltr;         /* HORIZONTAL→DESCEND |TiltR| 阈值 (默认 70) */

static unsigned char xdata wall_descend_vote_buf[WALL_DESCEND_WIN_MAX];
static VoteWindow_t vote_win_wall_descend;
static float   wall_descend_exit_tiltb;       /* DESCEND→STRAIGHT 退出 TiltB 阈值 (默认 60) */
static uint16_t wall_descent_blanking_frames = 200; /* HORIZONTAL→DESCEND 消隐帧数 (默认200帧=400ms) */

static unsigned short g_wall_timeout_frames   = 2000; /* 上墙总超时 (帧, =4s) */
static unsigned short g_wall_exit_lockout_frames = 300; /* 上墙超时退出后锁存帧数 (默认1000帧=2s) */
/* ---- 上墙 Check ---- */
static unsigned char Check_WallEntry(ElementCtx_t *ctx)
{
    if (ctx->wall_lockout_cnt > 0) return 0;
    if (!Track_CheckExpected(ctx, ELEMENT_WALL)) return 0;

    if (ctx->vote_wall.len == 0) {
        return (ctx->tilt_fb < wall_entry_tiltb) ? 1 : 0;
    }
    return VoteWin_Reached(&ctx->vote_wall, ctx->vote_wall.entry_thresh);
}

static unsigned char Check_WallClimbToHoriz(ElementCtx_t *ctx)
{
    float tilt_lr_abs;
    tilt_lr_abs = FABS(ctx->tilt_lr);

    if (ctx->vote_wall_climb.len == 0) {
        return (tilt_lr_abs > wall_climb_exit_tiltr) ? 1 : 0;
    }
    return VoteWin_Reached(&ctx->vote_wall_climb, ctx->vote_wall_climb.entry_thresh);
}

static unsigned char Check_WallHorizToDescend(ElementCtx_t *ctx)
{
    float tilt_lr_abs;
    tilt_lr_abs = FABS(ctx->tilt_lr);

    if (ctx->vote_wall_horiz.len == 0) {
        return (tilt_lr_abs < wall_horiz_exit_tiltr) ? 1 : 0;
    }
    return VoteWin_Reached(&ctx->vote_wall_horiz, ctx->vote_wall_horiz.entry_thresh);
}

static unsigned char Check_WallDescendExit(ElementCtx_t *ctx)
{
    if (ctx->elem_blanking_cnt < wall_descent_blanking_frames) {
        return 0;
    }
    if (ctx->vote_wall_descend.len == 0) {
        return (ctx->tilt_fb <wall_descend_exit_tiltb) ? 1 : 0;
    }
    return VoteWin_Reached(&ctx->vote_wall_descend, ctx->vote_wall_descend.entry_thresh);
}

static unsigned char Check_WallTimeout(ElementCtx_t *ctx)
{
    return (ctx->elem_frame_cnt >= g_wall_timeout_frames) ? 1 : 0;
}

/* ---- 上墙 Enter ---- */
static void Enter_Wall(ElementCtx_t *ctx)
{
    ctx->elem_frame_cnt  = 0;
    VoteWin_Reset(&ctx->vote_wall);
    VoteWin_Reset(&ctx->vote_wall_climb);
    VoteWin_Reset(&ctx->vote_wall_horiz);
    VoteWin_Reset(&ctx->vote_wall_descend);
}

static void Enter_WallClimb(ElementCtx_t *ctx)
{
    VoteWin_Reset(&ctx->vote_wall_climb);
}

static void Enter_WallHoriz(ElementCtx_t *ctx)
{
    VoteWin_Reset(&ctx->vote_wall_horiz);
}

static void Enter_WallDescend(ElementCtx_t *ctx)
{
    VoteWin_Reset(&ctx->vote_wall_descend);
    ctx->elem_blanking_cnt = 0;
}

static void Enter_WallTimeout(ElementCtx_t *ctx)
{
    VoteWin_Reset(&ctx->vote_wall);
    VoteWin_Reset(&ctx->vote_wall_climb);
    VoteWin_Reset(&ctx->vote_wall_horiz);
    VoteWin_Reset(&ctx->vote_wall_descend);
    ctx->wall_lockout_cnt = g_wall_exit_lockout_frames;
    Enter_ExitToStraight(ctx);
}


/* ================================================================
 * SECTION 5 — 滚筒 BARREL
 *   子状态链: BARREL → BARREL_CLIMB → BARREL_DESCEND → STRAIGHT
 *   进入: 低头 tilt_fb < -25°
 *   峰值: 抬头 tilt_fb > 75°
 *   退出: 抬头近水平 0° < tilt_fb < 15°
 * ================================================================ */

/* ---- 滚筒参数 ---- */
static unsigned char xdata barrel_vote_buf[BARREL_WIN_MAX];
static unsigned char xdata barrel_peak_vote_buf[BARREL_WIN_MAX];
static VoteWindow_t vote_win_barrel_peak;
static VoteWindow_t vote_win_barrel;
static float   barrel_entry_tilt;
static float   barrel_exit_tilt;
static float   barrel_peak_tilt = 70.0f;
static unsigned short g_barrel_timeout_frames = 60000; /* 滚筒总超时 (帧, =120s) */
static unsigned short g_barrel_exit_lockout_frames = 200; /* 出桶后锁存帧数 (默认200帧=400ms) */

/* ---- 滚筒 Check ---- */
static unsigned char Check_BarrelEntry(ElementCtx_t *ctx)
{
    if (ctx->barrel_lockout_cnt > 0) return 0;
    if (!Track_CheckExpected(ctx, ELEMENT_BARREL)) return 0;

    if (ctx->vote_barrel.len == 0) {
        return (ctx->tilt_fb < barrel_entry_tilt) ? 1 : 0;
    }
    return VoteWin_Reached(&ctx->vote_barrel, ctx->vote_barrel.entry_thresh);
}

static unsigned char Check_BarrelVerticalPeak(ElementCtx_t *ctx)
{
    if (ctx->vote_barrel_peak.len == 0) {
        return (ctx->tilt_fb > barrel_peak_tilt) ? 1 : 0;
    }
    return VoteWin_Reached(&ctx->vote_barrel_peak, ctx->vote_barrel_peak.entry_thresh);
}

static unsigned char Check_BarrelExit(ElementCtx_t *ctx)
{
    if (ctx->vote_barrel.len == 0) {
        return (ctx->tilt_fb < barrel_exit_tilt && ctx->tilt_fb > 0) ? 1 : 0;
    }
    return VoteWin_Reached(&ctx->vote_barrel, ctx->vote_barrel.exit_thresh);
}

static unsigned char Check_BarrelTimeout(ElementCtx_t *ctx)
{
    return (ctx->elem_frame_cnt >= g_barrel_timeout_frames) ? 1 : 0;
}

/* ---- 滚筒 Enter ---- */
static void Enter_Barrel(ElementCtx_t *ctx)
{
    ctx->elem_frame_cnt = 0;
    VoteWin_Reset(&ctx->vote_barrel);
}

static void Enter_BarrelClimb(ElementCtx_t *ctx)
{
    VoteWin_Reset(&ctx->vote_barrel);
    VoteWin_Reset(&ctx->vote_barrel_peak);
}

static void Enter_BarrelDescend(ElementCtx_t *ctx)
{
    VoteWin_Reset(&ctx->vote_barrel);
}

static void Enter_BarrelExit(ElementCtx_t *ctx)
{
    VoteWin_Reset(&ctx->vote_barrel);
    ctx->barrel_lockout_cnt = g_barrel_exit_lockout_frames;
    Enter_ExitToStraight(ctx);
}

static void Enter_BarrelTimeout(ElementCtx_t *ctx)
{
    VoteWin_Reset(&ctx->vote_barrel);
    Enter_ExitToStraight(ctx);
}


/* ================================================================
 * SECTION 6 — 十字 CROSS
 * ================================================================ */

/* ---- 十字参数 ---- */
static unsigned char xdata cross_vote_buf[CROSS_WIN_MAX];
static VoteWindow_t vote_win_cross;
static unsigned char xdata cross_tilt_vote_buf[CROSS_WIN_MAX];
static VoteWindow_t vote_win_cross_tilt;
static float   cross_entry_sum;
static float   cross_exit_sum;
static float   cross_all_sum;              /* adc[0]+adc[1]+adc[2]+adc[3] 总和阈值 */
static float   cross_all_exit_sum;         /* 退出: 四通道总和 < 此值 (需低于 cross_all_sum 保持滞回) */
static unsigned short g_cross_timeout_frames  = 2500;  /* 十字总超时 (帧, =5s) */
static unsigned short g_cross_exit_lockout_frames = 5; /* 十字退出后禁止再进入锁存 (帧, =10ms) */
static unsigned short g_cross_exit_blanking_frames = 30; /* 进入十字后退出消隐 (帧, =60ms), 期间屏蔽 ADC/倾角退出, 防止单帧闪退 */

/* ---- 十字 Check ---- */
static unsigned char Check_CrossEntry(ElementCtx_t *ctx)
{
    if (ctx->cross_lockout_cnt > 0) return 0;
    if (ctx->vote_cross.len == 0) {
        return (ctx->cross_sum_cache > cross_entry_sum
                && ctx->cross_all_cache > cross_all_sum
                && FABS(ctx->tilt_fb) < angle_level
                && FABS(ctx->tilt_lr) < angle_level) ? 1 : 0;
    }
    return VoteWin_Reached(&ctx->vote_cross, ctx->vote_cross.entry_thresh);
}

static unsigned char Check_CrossExit(ElementCtx_t *ctx)
{
    /* 消隐期: 刚进十字时 sum 还在进入阈值附近, 未消隐会单帧闪退并触发锁存 */
    if (ctx->elem_frame_cnt < g_cross_exit_blanking_frames) {
        return 0;
    }
    if (ctx->vote_cross.len == 0) {
        return (ctx->cross_sum_cache < cross_exit_sum
                || ctx->cross_all_cache < cross_all_exit_sum) ? 1 : 0;
    }
    return VoteWin_Reached(&ctx->vote_cross, ctx->vote_cross.exit_thresh);
}

static unsigned char Check_CrossTilt(ElementCtx_t *ctx)
{
    float tilt_fb_abs;
    float tilt_lr_abs;

    /* 消隐期: 与 ADC 退出共用, 防止进入瞬间倾角毛刺导致闪退 */
    if (ctx->elem_frame_cnt < g_cross_exit_blanking_frames) {
        return 0;
    }
    tilt_fb_abs = FABS(ctx->tilt_fb);
    tilt_lr_abs = FABS(ctx->tilt_lr);
    if (ctx->vote_cross_tilt.len == 0) {
        return (tilt_fb_abs >= angle_level || tilt_lr_abs >= angle_level) ? 1 : 0;
    }
    return VoteWin_Reached(&ctx->vote_cross_tilt, ctx->vote_cross_tilt.exit_thresh);
}

static unsigned char Check_CrossTimeout(ElementCtx_t *ctx)
{
    return (ctx->elem_frame_cnt >= g_cross_timeout_frames) ? 1 : 0;
}

/* ---- 十字 Enter ---- */
static void Enter_Cross(ElementCtx_t *ctx)
{
    ctx->elem_frame_cnt = 0;
    VoteWin_Reset(&ctx->vote_cross);
    VoteWin_Reset(&ctx->vote_cross_tilt);
}

static void Enter_CrossExit(ElementCtx_t *ctx)
{
    ctx->cross_lockout_cnt = g_cross_exit_lockout_frames;
    VoteWin_Reset(&ctx->vote_cross);
    VoteWin_Reset(&ctx->vote_cross_tilt);
    //Enter_ExitToStraight(ctx);
}

static void Enter_CrossTimeout(ElementCtx_t *ctx)
{
    ctx->cross_lockout_cnt = g_cross_exit_lockout_frames;
    VoteWin_Reset(&ctx->vote_cross);
    VoteWin_Reset(&ctx->vote_cross_tilt);
    Enter_ExitToStraight(ctx);
}


/* ================================================================
 * SECTION 7 — 跷跷板 SKIP
 *   子状态链: STRAIGHT → SKIP → SKIP_AIRBORNE → STRAIGHT
 *   进入: tilt_fb < skip_entry_tilt (负值, 上坡低头)
 *   腾空: adc[0]+adc[1]+adc[2]+adc[3] < skip_exit_sum (四轮离地)
 *   落地: |tilt_fb| < skip_airborne_exit_tilt (车身回平)
 * ================================================================ */

/* ---- 跷跷板参数 ---- */
static unsigned char xdata skip_vote_buf[SKIP_WIN_MAX];
static VoteWindow_t vote_win_skip;
static float   skip_entry_tilt;                  /* 进入阈值: tilt_fb < 此值(负值) → 进入跷跷板 */
static float   skip_entry_tilt_lr;              /* 进入防误判: |tilt_lr| > 此值 → 否决进入 (真跷跷板只前后倾) */
static float   skip_exit_sum;                    /* 腾空阈值: 四通道ADC之和 < 此值 → 判定腾空 */
static float   skip_airborne_exit_tilt;          /* 落地阈值: |tilt_fb| < 此值 → 判定落地回平 */
static float   skip_landing_adc_min;            /* 落地阈值: 四通道ADC之和 > 此值 */
static float   skip_landing_adc_max;            /* 落地阈值: 四通道ADC之和 < 此值 */
static unsigned short g_skip_timeout_frames = 500;          /* 跷跷板总超时 (帧, =1s) */
static unsigned short g_skip_exit_lockout_frames = 200;    /* 退出后锁存帧数 (默认200帧=400ms) */

/* ---- 跷跷板 Check ---- */
static unsigned char Check_SkipEntry(ElementCtx_t *ctx)
{
    float tilt_lr_abs;
    if (ctx->skip_lockout_cnt > 0) return 0;
    if (!Track_CheckExpected(ctx, ELEMENT_SKIP)) return 0;

    /* 防误判: 真跷跷板只有前后倾, 左右倾必须小 */
    tilt_lr_abs = FABS(ctx->tilt_lr);
    if (tilt_lr_abs > skip_entry_tilt_lr) return 0;

    if (ctx->vote_skip.len == 0) {
        return (ctx->tilt_fb < skip_entry_tilt) ? 1 : 0;
    }
    return VoteWin_Reached(&ctx->vote_skip, ctx->vote_skip.entry_thresh);
}

static unsigned char Check_SkipToAirborne(ElementCtx_t *ctx)
{
    float skip_adc_sum;
    skip_adc_sum = ctx->adc[0] + ctx->adc[1] + ctx->adc[2] + ctx->adc[3];

    if (ctx->vote_skip.len == 0) {
        return (skip_adc_sum < skip_exit_sum) ? 1 : 0;
    }
    return VoteWin_Reached(&ctx->vote_skip, ctx->vote_skip.exit_thresh);
}

static unsigned char Check_SkipAirborneExit(ElementCtx_t *ctx)
{
    float tilt_fb_abs;
    float skip_adc_sum;
    tilt_fb_abs = FABS(ctx->tilt_fb);
    skip_adc_sum = ctx->adc[0] + ctx->adc[1] + ctx->adc[2] + ctx->adc[3];

    if (ctx->vote_skip.len == 0) {
        return (tilt_fb_abs < skip_airborne_exit_tilt
                && skip_adc_sum > skip_landing_adc_min
                && skip_adc_sum < skip_landing_adc_max) ? 1 : 0;
    }
    return VoteWin_Reached(&ctx->vote_skip, ctx->vote_skip.entry_thresh);
}

static unsigned char Check_SkipTimeout(ElementCtx_t *ctx)
{
    return (ctx->elem_frame_cnt >= g_skip_timeout_frames) ? 1 : 0;
}

/* ---- 跷跷板 Enter ---- */
static void Enter_Skip(ElementCtx_t *ctx)
{
    ctx->elem_frame_cnt = 0;
    VoteWin_Reset(&ctx->vote_skip);
}

static void Enter_SkipAirborne(ElementCtx_t *ctx)
{
    VoteWin_Reset(&ctx->vote_skip);
}

static void Enter_SkipAirborneExit(ElementCtx_t *ctx)
{
    VoteWin_Reset(&ctx->vote_skip);
    ctx->skip_lockout_cnt = g_skip_exit_lockout_frames;
    Element_ResetOfftrackTimer(ctx);
    Enter_ExitToStraight(ctx);
}

static void Enter_SkipTimeout(ElementCtx_t *ctx)
{
    VoteWin_Reset(&ctx->vote_skip);
    /* 只有经过腾空阶段(AIRBORNE)的超时才推进元素表;
     * 直接从 SKIP 超时 → 行驶震动误触发, 不推进表索引,
     * 全局退出锁存会防止立即重入, 等锁存过后下一帧可重新检测进入 */
    if (ctx->prev == ELEMENT_SKIP_AIRBORNE) {
        Enter_ExitToStraight(ctx);
    }
}

/* ---- 十字 → 跷跷板 纠错 (误触 CROSS 后跳回 SKIP, 放此处因 C89 需 skip_entry_tilt 先声明) ---- */
static unsigned char Check_CrossToSkip(ElementCtx_t *ctx)
{
    float tilt_lr_abs;
    if (!Track_CheckExpected(ctx, ELEMENT_SKIP)) return 0;

    /* 防误判: 真跷跷板只有前后倾, 左右倾必须小 */
    tilt_lr_abs = FABS(ctx->tilt_lr);
    if (tilt_lr_abs > skip_entry_tilt_lr) return 0;

    return (ctx->tilt_fb < skip_entry_tilt) ? 1 : 0;
}

static void Enter_CrossToSkip(ElementCtx_t *ctx)
{
    ctx->cross_lockout_cnt = g_cross_exit_lockout_frames;
    VoteWin_Reset(&ctx->vote_cross);
    VoteWin_Reset(&ctx->vote_cross_tilt);
    VoteWin_Reset(&ctx->vote_skip);
    ctx->elem_frame_cnt = 0;
}


/* ================================================================
 * SECTION 8 — 直角转弯 RIGHT_ANGLE
 *   子元素: STRAIGHT → RIGHT_ANGLE_LEFT/RIGHT → STRAIGHT
 *   进入: |err_filtered| > entry_thresh (传感器即将串道)
 *   退出: 单边 err 接近零 (车身回到线上)
 *   左右共用同一投票窗
 * ================================================================ */

/* ---- 直角转弯参数 ---- */
static unsigned char xdata ra_vote_buf[RA_WIN_MAX];
static VoteWindow_t vote_win_ra;
static float   g_ra_entry_thresh    = 100.0f;   /* |err_filtered| > 此值 → 进入直角 */
static float   g_ra_exit_thresh     = 30.0f;    /* |err_raw| < 此值 → 退出直角 (滞回) */
static unsigned short g_ra_timeout_frames = 1000;  /* 直角超时帧数 (默认1000帧=2s) */
static unsigned short g_ra_exit_lockout_frames = 0;  /* 直角转弯退出后锁存帧数 (默认0帧=无锁存) */
static float   g_ra_yawrate_feedforward_k = 0.6000000238418579f; /* 直角转弯前馈角速度系数 */

#define WHEELBASE_MM  16.0f   /* 轮半径 (mm)*/
#define TURN_RADIUS_MM  55.0f   /* 转弯半径(mm) */
/* ---- 直角转弯前馈角速度计算 ----  */
static float Calc_RAPreYawrate(ElementCtx_t *ctx, float speed)
{
    float yawrate;
    float sign;
    if (ctx->right_angle_side == 0) {
        sign =  1.0f;   /* 左直角 → 正前馈 */
    } else {
        sign = -1.0f;   /* 右直角 → 负前馈 */
    }
    yawrate = sign * g_ra_yawrate_feedforward_k * speed * (WHEELBASE_MM / TURN_RADIUS_MM);
    return yawrate;
}
/* ---- 直角转弯 Check ---- */
/* 直角转弯进入前置检查: 锁存 & 环岛内屏蔽 (左右共用) */
static unsigned char Check_RightAngleEntry_Pre(ElementCtx_t *ctx)
{
    if (ctx->ra_lockout_cnt > 0) return 0;
    if (ctx->current == ELEMENT_RING_LEFT_ENTRANCE
        || ctx->current == ELEMENT_RING_LEFT_PASS
        || ctx->current == ELEMENT_IN_RING
        || ctx->current == ELEMENT_RING_RIGHT_ENTRANCE
        || ctx->current == ELEMENT_RING_RIGHT_PASS) {
        return 0;
    }
    return 1;
}

static unsigned char Check_RightAngleLeftEntry(ElementCtx_t *ctx)
{
    if (!Check_RightAngleEntry_Pre(ctx)) return 0;
    if (ctx->vote_right_angle.len == 0) {
        return (ctx->err_raw < -g_ra_entry_thresh) ? 1 : 0;
    }
    if (!VoteWin_Reached(&ctx->vote_right_angle, ctx->vote_right_angle.entry_thresh))
        return 0;
    return (ctx->err_raw < -g_ra_entry_thresh) ? 1 : 0;
}

static unsigned char Check_RightAngleRightEntry(ElementCtx_t *ctx)
{
    if (!Check_RightAngleEntry_Pre(ctx)) return 0;
    if (ctx->vote_right_angle.len == 0) {
        return (ctx->err_raw > g_ra_entry_thresh) ? 1 : 0;
    }
    if (!VoteWin_Reached(&ctx->vote_right_angle, ctx->vote_right_angle.entry_thresh))
        return 0;
    return (ctx->err_raw > g_ra_entry_thresh) ? 1 : 0;
}

static unsigned char Check_RightAngleExit(ElementCtx_t *ctx)
{
    if (ctx->vote_right_angle.len == 0) {
        if (ctx->right_angle_side == 0) {
            return (ctx->err_raw > -g_ra_exit_thresh && ctx->err_raw < 0) ? 1 : 0;
        } else {
            return (ctx->err_raw < g_ra_exit_thresh && ctx->err_raw > 0) ? 1 : 0;
        }
    }
    return VoteWin_Reached(&ctx->vote_right_angle, ctx->vote_right_angle.exit_thresh);
}

static unsigned char Check_RATimeout(ElementCtx_t *ctx)
{
    return (ctx->elem_frame_cnt >= g_ra_timeout_frames) ? 1 : 0;
}

/* ---- 直角转弯 Enter ---- */
static void Enter_RightAngle(ElementCtx_t *ctx)
{
    ctx->frozen_err       = ctx->err_raw;
    ctx->right_angle_side = (ctx->current == ELEMENT_RIGHT_ANGLE_LEFT) ? 0 : 1;
    ctx->elem_frame_cnt   = 0;
    VoteWin_Reset(&ctx->vote_right_angle);
}

static void Enter_RightAngleExit(ElementCtx_t *ctx)
{
    ctx->ra_lockout_cnt = g_ra_exit_lockout_frames;
    VoteWin_Reset(&ctx->vote_right_angle);
}


/* ================================================================
 * SECTION 8.5 — 全局退出锁存 (Global Exit Lockout)
 *   退出赛道元素 (Ring/Wall/Barrel/Skip) 后, 按元素类型设置锁存,
 *   防止退出瞬态的传感器毛刺误入下一个赛道元素.
 *   Cross 和 RightAngle 不参与全局锁.
 * ================================================================ */

static unsigned short g_ring_global_lock  = 300;  /* 环岛退出后全局锁存帧数 */
static unsigned short g_wall_global_lock  = 200;  /* 上墙退出后全局锁存帧数 */
static unsigned short g_barrel_global_lock = 300; /* 滚筒退出后全局锁存帧数 */
static unsigned short g_skip_global_lock  = 30;  /* 跷跷板退出后全局锁存帧数 */

static unsigned short GetGlobalExitLockFrames(element_t e)
{
    switch (e) {
    case ELEMENT_IN_RING:
        return g_ring_global_lock;
    case ELEMENT_WALL_CLIMB:
    case ELEMENT_WALL_HORIZONTAL:
    case ELEMENT_WALL_DESCEND:
        return g_wall_global_lock;
    case ELEMENT_BARREL_CLIMB:
    case ELEMENT_BARREL_DESCEND:
        return g_barrel_global_lock;
    case ELEMENT_SKIP:
    case ELEMENT_SKIP_AIRBORNE:
        return g_skip_global_lock;
    default:
        return 0;  /* Cross / RightAngle / 其他: 不触发全局锁 */
    }
}

/* 全局锁拦截的进入目标: 只有赛道表元素, Cross/RightAngle 放行 */
static unsigned char IsBlockedByGlobalLock(element_t to)
{
    switch (to) {
    case ELEMENT_RING_LEFT_ENTRANCE:
    case ELEMENT_RING_RIGHT_ENTRANCE:
    case ELEMENT_WALL:
    case ELEMENT_BARREL:
    case ELEMENT_SKIP:
        return 1;
    default:
        return 0;  /* CROSS / RIGHT_ANGLE_*: 放行 */
    }
}

/* ================================================================
 * SECTION 9 — 转移表 & 状态机引擎
 * ================================================================ */

typedef unsigned char (*TransitionCheck)(ElementCtx_t *ctx);
typedef void (*TransitionAction)(ElementCtx_t *ctx);

typedef struct {
    element_t        from;
    element_t        to;
    unsigned char    priority;
    TransitionCheck  check;
    TransitionAction on_enter;
} Transition_t;

static const Transition_t g_transitions[] = {

    /* 无条件即时转移 */
    { ELEMENT_RING_LEFT_ENTRANCE,  ELEMENT_RING_LEFT_PASS,  0, NULL, Enter_RingPass },
    { ELEMENT_RING_RIGHT_ENTRANCE, ELEMENT_RING_RIGHT_PASS, 0, NULL, Enter_RingPass },

    /* STRAIGHT → 各元素 (优先级: 环岛=1 > 上墙=2 > 滚筒=3 > 跷跷板=4 > 十字=5 > 直角=6) */
    { ELEMENT_STRAIGHT, ELEMENT_RING_LEFT_ENTRANCE,  1, Check_RingLeftEntry,  Enter_RingEntry },
    { ELEMENT_STRAIGHT, ELEMENT_RING_RIGHT_ENTRANCE, 1, Check_RingRightEntry, Enter_RingEntry },
    { ELEMENT_STRAIGHT, ELEMENT_WALL,    2, Check_WallEntry,    Enter_Wall },
    { ELEMENT_STRAIGHT, ELEMENT_BARREL,  3, Check_BarrelEntry,  Enter_Barrel },
    { ELEMENT_STRAIGHT, ELEMENT_SKIP,    4, Check_SkipEntry,    Enter_Skip },
    { ELEMENT_STRAIGHT, ELEMENT_CROSS,   5, Check_CrossEntry,   Enter_Cross },
    { ELEMENT_STRAIGHT, ELEMENT_RIGHT_ANGLE_LEFT,  6, Check_RightAngleLeftEntry,  Enter_RightAngle },
    { ELEMENT_STRAIGHT, ELEMENT_RIGHT_ANGLE_RIGHT, 6, Check_RightAngleRightEntry, Enter_RightAngle },

    /* 环岛 */
    { ELEMENT_RING_LEFT_PASS,  ELEMENT_IN_RING, 0, Check_PassTimeout, Enter_InRing },
    { ELEMENT_RING_RIGHT_PASS, ELEMENT_IN_RING, 0, Check_PassTimeout, Enter_InRing },
    { ELEMENT_IN_RING, ELEMENT_STRAIGHT, 0, Check_RingExit, Enter_RingExit },
    { ELEMENT_IN_RING, ELEMENT_STRAIGHT, 1, Check_RingTimeout, Enter_RingTimeout },

    /* 上墙线性子状态链: WALL → CLIMB → HORIZONTAL → DESCEND → STRAIGHT */
    { ELEMENT_WALL,       ELEMENT_WALL_CLIMB,      0, NULL,                     Enter_WallClimb },
    { ELEMENT_WALL_CLIMB, ELEMENT_WALL_HORIZONTAL, 0, Check_WallClimbToHoriz,   Enter_WallHoriz },
    { ELEMENT_WALL_HORIZONTAL, ELEMENT_WALL_DESCEND, 0, Check_WallHorizToDescend, Enter_WallDescend },
    { ELEMENT_WALL_DESCEND,    ELEMENT_STRAIGHT,      0, Check_WallDescendExit,    Enter_ExitToStraight },

    /* 上墙超时兜底 (prio=1: 正常子状态转移优先) */
    { ELEMENT_WALL_CLIMB,    ELEMENT_STRAIGHT, 1, Check_WallTimeout,    Enter_WallTimeout },
    { ELEMENT_WALL_HORIZONTAL, ELEMENT_STRAIGHT, 1, Check_WallTimeout,    Enter_WallTimeout },
    { ELEMENT_WALL_DESCEND,  ELEMENT_STRAIGHT, 1, Check_WallTimeout,    Enter_WallTimeout },

    /* 滚筒子状态链: BARREL → CLIMB → DESCEND → STRAIGHT */
    { ELEMENT_BARREL,   ELEMENT_BARREL_CLIMB, 0, NULL, Enter_BarrelClimb },
    { ELEMENT_BARREL_CLIMB, ELEMENT_BARREL_DESCEND, 0, Check_BarrelVerticalPeak, Enter_BarrelDescend },
    { ELEMENT_BARREL_DESCEND, ELEMENT_STRAIGHT, 0, Check_BarrelExit, Enter_BarrelExit },

    /* 滚筒超时兜底 */
    { ELEMENT_BARREL_CLIMB,   ELEMENT_STRAIGHT, 1, Check_BarrelTimeout, Enter_BarrelTimeout },
    { ELEMENT_BARREL_DESCEND, ELEMENT_STRAIGHT, 1, Check_BarrelTimeout, Enter_BarrelTimeout },

    /* 跷跷板子状态链: SKIP → SKIP_AIRBORNE → STRAIGHT */
    { ELEMENT_SKIP,           ELEMENT_SKIP_AIRBORNE, 0, Check_SkipToAirborne,    Enter_SkipAirborne },
    { ELEMENT_SKIP,           ELEMENT_STRAIGHT,       1, Check_SkipTimeout,       Enter_SkipTimeout },
    { ELEMENT_SKIP_AIRBORNE,  ELEMENT_STRAIGHT,       0, Check_SkipAirborneExit,  Enter_SkipAirborneExit },
    { ELEMENT_SKIP_AIRBORNE,  ELEMENT_STRAIGHT,       1, Check_SkipTimeout,       Enter_SkipTimeout },

    /* 十字 → STRAIGHT (prio 0=倾角超限, 1=超时, 2=正常退出) */
    /* 十字 → 跷跷板 纠错 (prio 0: 最高, 误触 CROSS 后跳回 SKIP) */
    { ELEMENT_CROSS, ELEMENT_SKIP,     0, Check_CrossToSkip,  Enter_CrossToSkip },
    /* 十字 → STRAIGHT (prio 1=ADC退出, 2=超时, 3=倾角超限) */
    { ELEMENT_CROSS, ELEMENT_STRAIGHT, 1, Check_CrossExit,    Enter_CrossExit },
    { ELEMENT_CROSS, ELEMENT_STRAIGHT, 2, Check_CrossTimeout, Enter_CrossTimeout },
    { ELEMENT_CROSS, ELEMENT_STRAIGHT, 3, Check_CrossTilt,    Enter_CrossExit },

    /* 直角转弯退出 */
    { ELEMENT_RIGHT_ANGLE_LEFT,  ELEMENT_STRAIGHT, 0, Check_RightAngleExit, Enter_RightAngleExit },
    { ELEMENT_RIGHT_ANGLE_LEFT,  ELEMENT_STRAIGHT, 1, Check_RATimeout,      Enter_RightAngleExit },
    { ELEMENT_RIGHT_ANGLE_RIGHT, ELEMENT_STRAIGHT, 0, Check_RightAngleExit, Enter_RightAngleExit },
    { ELEMENT_RIGHT_ANGLE_RIGHT, ELEMENT_STRAIGHT, 1, Check_RATimeout,      Enter_RightAngleExit },
};

#define TRANSITION_COUNT  (sizeof(g_transitions) / sizeof(g_transitions[0]))

static void Element_EvaluateTransitions(ElementCtx_t *ctx)
{
    unsigned char i;
    const Transition_t *t;

    for (i = 0; i < TRANSITION_COUNT; i++) {
        t = &g_transitions[i];
        if (t->from != ctx->current) continue;

        /* 全局退出锁存: STRAIGHT 下禁止进入赛道表元素 (Cross/RA 放行) */
        if (t->from == ELEMENT_STRAIGHT
            && ctx->global_exit_lockout_cnt > 0
            && IsBlockedByGlobalLock(t->to)) {
            continue;
        }

        if (t->check == NULL || t->check(ctx)) {
            ctx->prev = ctx->current;
            ctx->current = t->to;

            if (t->on_enter != NULL) {
                t->on_enter(ctx);
            }

            /* 退出赛道元素到 STRAIGHT: 按元素类型设置全局锁存 */
            if (t->to == ELEMENT_STRAIGHT && ctx->prev != ELEMENT_STRAIGHT) {
                unsigned short lock_frames;
                lock_frames = GetGlobalExitLockFrames(ctx->prev);
                if (lock_frames > 0) {
                    ctx->global_exit_lockout_cnt = lock_frames;
                }
            }

            Debug_Log(Element_GetProp(t->to)->name);
            break;
        }
    }
}


/* ---- Tilt LPF 截止频率读写回调 (上位机在线调参, 不重置output) ---- */
static float g_tilt_lpf_fc = 10.0f;
static Lpf_t g_lpf_tilt_fb;
static Lpf_t g_lpf_tilt_lr;
static unsigned char tilt_lpf_ready = 0;

static void TiltLpf_Read_Cb(uint32_t peri_addr, void *pData, uint8_t len)
{
    float val;
    (void)len;
    (void)peri_addr;
    val = g_tilt_lpf_fc;
    memcpy(pData, &val, sizeof(float));
}

static void TiltLpf_Write_Cb(uint32_t peri_addr, void *pData, uint8_t len)
{
    float new_fc;
    float alpha;
    (void)len;
    (void)peri_addr;
    memcpy(&new_fc, pData, sizeof(float));
    if (new_fc < 1.0f)  new_fc = 1.0f;
    if (new_fc > 400.0f) new_fc = 400.0f;
    g_tilt_lpf_fc = new_fc;
    alpha = 1.0f - (float)exp(-6.2831853f * new_fc * 0.002f);
    g_lpf_tilt_fb.alpha = alpha;
    g_lpf_tilt_fb.freq = new_fc;
    g_lpf_tilt_lr.alpha = alpha;
    g_lpf_tilt_lr.freq = new_fc;
}

static DebugPeriDesc_t g_tilt_lpf_fc_desc = {0, TiltLpf_Read_Cb, TiltLpf_Write_Cb};

/* ================================================================
 * SECTION 10 — Element_Init
 * ================================================================ */
extern void System_Reset(void);

void Element_Init(ElementCtx_t *ctx)
{
    unsigned char i;

    if (ctx != NULL) {
        ctx->ring_side        = 0;
        ctx->ring_frame_cnt   = 0;
        ctx->elem_frame_cnt   = 0;
        ctx->ring_entry_yaw   = 0.0f;
        ctx->ring_lockout_cnt   = 0;
        ctx->wall_lockout_cnt   = 0;
        ctx->barrel_lockout_cnt = 0;
        ctx->skip_lockout_cnt   = 0;
        ctx->ra_lockout_cnt     = 0;
        ctx->cross_lockout_cnt  = 0;
        ctx->global_exit_lockout_cnt = 0;
        ctx->track_idx        = 0;
        ctx->track_table_enabled = 0;
        ctx->offtrack_active     = 0;
        ctx->offtrack_start_tick = 0;
        ctx->push_mode           = 0;
        ctx->current = ELEMENT_STRAIGHT;
        ctx->prev    = ELEMENT_STRAIGHT;
        ctx->tilt_fb      = 0.0f;
        ctx->tilt_lr      = 0.0f;
        ctx->cross_sum_cache = 0.0f;
        ctx->cross_all_cache = 0.0f;
        tilt_lpf_ready = 0;      /* 下次 CalcTilt 重新初始化滤波器 */
        lpf_init_fc(&g_lpf_tilt_fb, g_tilt_lpf_fc, 0.002f);
        lpf_init_fc(&g_lpf_tilt_lr, g_tilt_lpf_fc, 0.002f);
        ctx->frozen_err       = 0.0f;
        ctx->right_angle_side = 0;
        ctx->err_raw          = 0.0f;
        ctx->err_filtered     = 0.0f;
        ctx->total_frames = 0;

    }
    /* ================================================================
     * 1. 共享 / 赛道表 / 安全停车 — Debug 注册
     * ================================================================ */
    Debug_Register("TTimeOut", DBG_UINT32 | STATIC_TYPE, &g_ontrack_timeout_frames);
    Debug_Register("OffTkMs",  DBG_FLOAT  | STATIC_TYPE, &g_offtrack_timeout_ms);
    Debug_Register("OffTkAdc", DBG_FLOAT  | STATIC_TYPE, &g_offtrack_adc_thresh);
    Debug_Register("TblEnable",DBG_UINT8  | STATIC_TYPE, &ctx->track_table_enabled);
    Debug_Register("DbgElem",  DBG_UINT16 | STATIC_TYPE, &g_single_element_debug);
    Debug_Register("PushMode", DBG_UINT8  | STATIC_TYPE, &ctx->push_mode);
    Debug_Register("Index",    DBG_UINT8 , &ctx->track_idx);
    /* ================================================================
     * 2. 速度变量 — Debug 注册
     * ================================================================ */
    Debug_Register("Cruising",  DBG_FLOAT | STATIC_TYPE, &g_speed_cruising);
    Debug_Register("RingSpd",   DBG_FLOAT | STATIC_TYPE, &g_speed_ring);
    Debug_Register("WallSpd",   DBG_FLOAT | STATIC_TYPE, &g_speed_wall);
    Debug_Register("WClimbSpd", DBG_FLOAT | STATIC_TYPE, &g_speed_wall_climb);
    Debug_Register("WHorizSpd", DBG_FLOAT | STATIC_TYPE, &g_speed_wall_horiz);
    Debug_Register("WDescSpd",  DBG_FLOAT | STATIC_TYPE, &g_speed_wall_descend);
    Debug_Register("BarrelSpd", DBG_FLOAT | STATIC_TYPE, &g_speed_barrel);
    Debug_Register("CrossSpd",  DBG_FLOAT | STATIC_TYPE, &g_speed_cross);
    Debug_Register("SkipSpd",   DBG_FLOAT | STATIC_TYPE, &g_speed_skip);

    /* ---- 风扇占空比变量 — Debug 注册 ---- */
    Debug_Register("FanD_Str",  DBG_UINT16 | STATIC_TYPE, &g_fan_d_straight);
    Debug_Register("FanD_Ring", DBG_UINT16 | STATIC_TYPE, &g_fan_d_ring);
    Debug_Register("FanD_Wall", DBG_UINT16 | STATIC_TYPE, &g_fan_d_wall);
    Debug_Register("FanD_Cross",DBG_UINT16 | STATIC_TYPE, &g_fan_d_cross);
    Debug_Register("FanD_Bar",  DBG_UINT16 | STATIC_TYPE, &g_fan_d_barrel);
    Debug_Register("FanD_Skip", DBG_UINT16 | STATIC_TYPE, &g_fan_d_skip);

    /* ================================================================
     * 3. 环岛 RING — 默认值 & Debug 注册
     * ================================================================ */
    /* 进入 ADC 阈值 */
    RingEntrance[0] = 1000.0f;
    RingEntrance[1] = 0.0f;
    RingEntrance[2] = 1000.0f;
    RingEntrance[3] = 0.0f;
    Debug_Register("RingEn0", DBG_FLOAT | STATIC_TYPE, &RingEntrance[0]);
    Debug_Register("RingEn1", DBG_FLOAT | STATIC_TYPE, &RingEntrance[1]);
    Debug_Register("RingEn2", DBG_FLOAT | STATIC_TYPE, &RingEntrance[2]);
    Debug_Register("RingEn3", DBG_FLOAT | STATIC_TYPE, &RingEntrance[3]);

    /* 退出 ADC 阈值 */
    RingExit[0] = 1000.0f;
    RingExit[1] = 1000.0f;
    RingExit[2] = 1000.0f;
    RingExit[3] = 1000.0f;
    Debug_Register("RingEx0", DBG_FLOAT | STATIC_TYPE, &RingExit[0]);
    Debug_Register("RingEx1", DBG_FLOAT | STATIC_TYPE, &RingExit[1]);
    Debug_Register("RingEx2", DBG_FLOAT | STATIC_TYPE, &RingExit[2]);
    Debug_Register("RingEx3", DBG_FLOAT | STATIC_TYPE, &RingExit[3]);

    /* 角度阈值 */
    Debug_Register("Ring_AngThr", DBG_FLOAT | STATIC_TYPE, &angle_level);

    /* 开环 / 时序参数 */
    Debug_Register("OL_Yaw",      DBG_FLOAT  | STATIC_TYPE, &g_ol_ring_yawrate);
    Debug_Register("PassTmOut",   DBG_UINT16 | STATIC_TYPE, &g_pass_timeout_frames);
    Debug_Register("RingExYaw",   DBG_FLOAT  | STATIC_TYPE, &g_ring_exit_yaw_thresh);
    Debug_Register("RingExLock",  DBG_UINT16 | STATIC_TYPE, &g_ring_exit_lockout_frames);
    Debug_Register("Ring_Timeout",DBG_UINT16 | STATIC_TYPE, &g_ring_timeout_frames);
    Debug_Register("Ring_OLAng", DBG_FLOAT  | STATIC_TYPE, &g_ol_ring_angle);
    Debug_Register("RingVetoVt", DBG_FLOAT  | STATIC_TYPE, &g_ring_veto_vertical_sum);

    /* ================================================================
     * 4. 上墙 WALL — 默认值 & Debug 注册
     * ================================================================ */
    /* 入口: TiltB < -60 → WALL */
    wall_entry_tiltb = -60.0f;
    vote_win_wall.len          = 10;
    vote_win_wall.entry_thresh = 7;
    vote_win_wall.exit_thresh  = 7;
    Debug_Register("Wall_EntTiltB", DBG_FLOAT | STATIC_TYPE, &wall_entry_tiltb);

    /* CLIMB→HORIZONTAL: |TiltR| > 70 */
    wall_climb_exit_tiltr = 70.0f;
    vote_win_wall_climb.len          = 10;
    vote_win_wall_climb.entry_thresh = 7;
    vote_win_wall_climb.exit_thresh  = 7;
    Debug_Register("Wall_ClimbTR", DBG_FLOAT | STATIC_TYPE, &wall_climb_exit_tiltr);

    /* HORIZONTAL→DESCEND: |TiltR| < 70 */
    wall_horiz_exit_tiltr = 70.0f;
    vote_win_wall_horiz.len          = 10;
    vote_win_wall_horiz.entry_thresh = 7;
    vote_win_wall_horiz.exit_thresh  = 7;
    Debug_Register("Wall_HorizTR", DBG_FLOAT | STATIC_TYPE, &wall_horiz_exit_tiltr);

    /* DESCEND→STRAIGHT: TiltB > 60, 消隐期内强制投 0 */
    wall_descend_exit_tiltb = 60.0f;
    vote_win_wall_descend.len          = 10;
    vote_win_wall_descend.entry_thresh = 7;
    vote_win_wall_descend.exit_thresh  = 7;
    Debug_Register("Wall_DescTiltB", DBG_FLOAT  | STATIC_TYPE, &wall_descend_exit_tiltb);
    Debug_Register("Wall_DesBlk",    DBG_UINT16 | STATIC_TYPE, &wall_descent_blanking_frames);

    /* 超时 */
    Debug_Register("Wall_Timeout", DBG_UINT16 | STATIC_TYPE, &g_wall_timeout_frames);
    Debug_Register("Wall_ExLock",  DBG_UINT16 | STATIC_TYPE, &g_wall_exit_lockout_frames);

    /* ================================================================
     * 5. 滚筒 BARREL — 默认值 & Debug 注册
     * ================================================================ */
    /* 进入 < -25°(低头), 退出 0~15°(抬头近水平) */
    barrel_entry_tilt = -25.0f;
    barrel_exit_tilt  = 25.0f;
    vote_win_barrel.len          = 10;
    vote_win_barrel.entry_thresh = 7;
    vote_win_barrel.exit_thresh  = 7;
    Debug_Register("Bar_EnTilt", DBG_FLOAT | STATIC_TYPE, &barrel_entry_tilt);
    Debug_Register("Bar_ExTilt", DBG_FLOAT | STATIC_TYPE, &barrel_exit_tilt);

    /* 峰值 > 75° (投票窗滤波) */
    barrel_peak_tilt = 70.0f;
    vote_win_barrel_peak.len          = 10;
    vote_win_barrel_peak.entry_thresh = 7;
    vote_win_barrel_peak.exit_thresh  = 7;
    Debug_Register("Bar_PeakTilt", DBG_FLOAT | STATIC_TYPE, &barrel_peak_tilt);

    /* 超时 */
    Debug_Register("Bar_Timeout", DBG_UINT16 | STATIC_TYPE, &g_barrel_timeout_frames);
    Debug_Register("Bar_ExLock",  DBG_UINT16 | STATIC_TYPE, &g_barrel_exit_lockout_frames);

    /* ================================================================
     * 6. 十字 CROSS — 默认值 & Debug 注册
     * ================================================================ */
    /* 进入: [1]+[3]>300 且全和>2000; 退出: [1]+[3]<150 或全和<1500 (滞回: 退出阈值必须低于进入阈值) */

    //经观察陀螺仪解算出的倾角数据波形良好，可以不加时间滤波
    cross_entry_sum = 800.0f;
    cross_exit_sum  = 600.0f;
    cross_all_sum   = 2100.0f;
    cross_all_exit_sum = 1700.0f;
    Debug_Register("Cross_EnSum",   DBG_FLOAT  | STATIC_TYPE, &cross_entry_sum);
    Debug_Register("Cross_ExSum",   DBG_FLOAT  | STATIC_TYPE, &cross_exit_sum);
    Debug_Register("Cross_AllSum",  DBG_FLOAT  | STATIC_TYPE, &cross_all_sum);
    Debug_Register("Cross_ExAll",   DBG_FLOAT  | STATIC_TYPE, &cross_all_exit_sum);
    Debug_Register("Cross_Timeout", DBG_UINT16 | STATIC_TYPE, &g_cross_timeout_frames);
    Debug_Register("Cross_ExLock", DBG_UINT16 | STATIC_TYPE, &g_cross_exit_lockout_frames);
    Debug_Register("Cross_ExBlk",  DBG_UINT16 | STATIC_TYPE, &g_cross_exit_blanking_frames);

    /* ================================================================
     * 7. 跷跷板 SKIP — 默认值 & Debug 注册
     * ================================================================ */
    /* 进入: tilt_fb < -15° 且 |tilt_lr| <= 20°, 腾空: ADC和 < 500, 落地: |tilt| < 10° + ADC和在600~1000 */
    skip_entry_tilt          = -16.0f;
    skip_entry_tilt_lr       = 10.0f;   /* 左右倾角上限: 超过此值否决进入, 防颠簸/十字误判 */
    skip_exit_sum            = 500.0f;
    skip_airborne_exit_tilt  = 10.0f;
    skip_landing_adc_min     = 600.0f;
    skip_landing_adc_max     = 1000.0f;
    vote_win_skip.len          = 20;    /* 投票窗滤波, 20帧窗口抑制噪声 */
    vote_win_skip.entry_thresh = 19;
    vote_win_skip.exit_thresh  = 3;
    Debug_Register("SkpEnTilt",  DBG_FLOAT  | STATIC_TYPE, &skip_entry_tilt);
    Debug_Register("SkpEnTltLR", DBG_FLOAT  | STATIC_TYPE, &skip_entry_tilt_lr);
    Debug_Register("SkpExSum",   DBG_FLOAT  | STATIC_TYPE, &skip_exit_sum);
    Debug_Register("SkpAirTlt",  DBG_FLOAT  | STATIC_TYPE, &skip_airborne_exit_tilt);
    Debug_Register("SkpLdMin",   DBG_FLOAT  | STATIC_TYPE, &skip_landing_adc_min);
    Debug_Register("SkpLdMax",   DBG_FLOAT  | STATIC_TYPE, &skip_landing_adc_max);
    Debug_Register("SkpTmOut",   DBG_UINT16 | STATIC_TYPE, &g_skip_timeout_frames);
    Debug_Register("SkpExLck",   DBG_UINT16 | STATIC_TYPE, &g_skip_exit_lockout_frames);
    Debug_Register("Skp_WnLen",  DBG_UINT8  | STATIC_TYPE, &vote_win_skip.len);
    Debug_Register("Skp_WnEnTh", DBG_UINT8  | STATIC_TYPE, &vote_win_skip.entry_thresh);
    Debug_Register("Skp_WnExTh", DBG_UINT8  | STATIC_TYPE, &vote_win_skip.exit_thresh);
    Debug_Register("TiltLpfFc",  DBG_FLOAT  | STATIC_TYPE | PERI_TYPE, &g_tilt_lpf_fc_desc);

    /* ================================================================
     * 8. 直角转弯 RIGHT_ANGLE — 默认值 & Debug 注册
     * ================================================================ */
    /* len=10: 投票窗滤波模式 */
    vote_win_ra.len          = 10;
    vote_win_ra.entry_thresh = 7;
    vote_win_ra.exit_thresh  = 7;
    g_ra_yawrate_feedforward_k = 0.6000000238418579f;
    Debug_Register("RA_YawFwdK", DBG_FLOAT  | STATIC_TYPE, &g_ra_yawrate_feedforward_k);
    Debug_Register("RA_EnThr",   DBG_FLOAT  | STATIC_TYPE, &g_ra_entry_thresh);
    Debug_Register("RA_ExThr",   DBG_FLOAT  | STATIC_TYPE, &g_ra_exit_thresh);
    Debug_Register("RA_Timeout", DBG_UINT16 | STATIC_TYPE, &g_ra_timeout_frames);
    Debug_Register("RA_ExLkFrames", DBG_UINT16 | STATIC_TYPE, &g_ra_exit_lockout_frames);
    Debug_Register("RingGlbLk", DBG_UINT16 | STATIC_TYPE, &g_ring_global_lock);
    Debug_Register("WallGlbLk", DBG_UINT16 | STATIC_TYPE, &g_wall_global_lock);
    Debug_Register("BarGlbLk",  DBG_UINT16 | STATIC_TYPE, &g_barrel_global_lock);
    Debug_Register("SkpGlbLk",  DBG_UINT16 | STATIC_TYPE, &g_skip_global_lock);

    /* ================================================================
     * 9. 时间滤波(投票窗)参数 — 集中管理, 暂时注释以减少上位机参数列表
     *    需要恢复时取消注释即可
     * ================================================================ */
    /* 环岛 */
    // Debug_Register("Ring_WinLen", DBG_UINT8 | STATIC_TYPE, &vote_win_ring.len);
    // Debug_Register("Ring_EntThr", DBG_UINT8 | STATIC_TYPE, &vote_win_ring.entry_thresh);
    // Debug_Register("Ring_ExtThr", DBG_UINT8 | STATIC_TYPE, &vote_win_ring.exit_thresh);
    /* 上墙 */
    // Debug_Register("Wall_WinLen",  DBG_UINT8 | STATIC_TYPE, &vote_win_wall.len);
    // Debug_Register("Wall_EntThr",  DBG_UINT8 | STATIC_TYPE, &vote_win_wall.entry_thresh);
    // Debug_Register("Wall_ExtThr",  DBG_UINT8 | STATIC_TYPE, &vote_win_wall.exit_thresh);
    // Debug_Register("WCl_WinLen",   DBG_UINT8 | STATIC_TYPE, &vote_win_wall_climb.len);
    // Debug_Register("WCl_EntThr",   DBG_UINT8 | STATIC_TYPE, &vote_win_wall_climb.entry_thresh);
    // Debug_Register("WHr_WinLen",   DBG_UINT8 | STATIC_TYPE, &vote_win_wall_horiz.len);
    // Debug_Register("WHr_EntThr",   DBG_UINT8 | STATIC_TYPE, &vote_win_wall_horiz.entry_thresh);
    // Debug_Register("WDs_WinLen",   DBG_UINT8 | STATIC_TYPE, &vote_win_wall_descend.len);
    // Debug_Register("WDs_EntThr",   DBG_UINT8 | STATIC_TYPE, &vote_win_wall_descend.entry_thresh);
    /* 滚筒 */
    // Debug_Register("Bar_WinLen",   DBG_UINT8 | STATIC_TYPE, &vote_win_barrel.len);
    // Debug_Register("Bar_EntThr",   DBG_UINT8 | STATIC_TYPE, &vote_win_barrel.entry_thresh);
    // Debug_Register("Bar_ExtThr",   DBG_UINT8 | STATIC_TYPE, &vote_win_barrel.exit_thresh);
     Debug_Register("Bar_PkWnLen",  DBG_UINT8 | STATIC_TYPE, &vote_win_barrel_peak.len);
     Debug_Register("Bar_PkWnEnTh", DBG_UINT8 | STATIC_TYPE, &vote_win_barrel_peak.entry_thresh);
     Debug_Register("Bar_PkWnExTh", DBG_UINT8 | STATIC_TYPE, &vote_win_barrel_peak.exit_thresh);
    /* 十字 */
    // Debug_Register("Cross_EntThr",  DBG_UINT8 | STATIC_TYPE, &vote_win_cross.entry_thresh);
    // Debug_Register("Cross_ExtThr",  DBG_UINT8 | STATIC_TYPE, &vote_win_cross.exit_thresh);
    // Debug_Register("Cross_WinLen",  DBG_UINT8 | STATIC_TYPE, &vote_win_cross.len);
    // Debug_Register("Cross_TltWnLen", DBG_UINT8 | STATIC_TYPE, &vote_win_cross_tilt.len);
    // Debug_Register("Cross_TltExtTh", DBG_UINT8 | STATIC_TYPE, &vote_win_cross_tilt.exit_thresh);
    /* 直角转弯 */
    // Debug_Register("RA_WinLen",   DBG_UINT8 | STATIC_TYPE, &vote_win_ra.len);
    // Debug_Register("RA_WinEnTh",  DBG_UINT8 | STATIC_TYPE, &vote_win_ra.entry_thresh);
    // Debug_Register("RA_WinExTh",  DBG_UINT8 | STATIC_TYPE, &vote_win_ra.exit_thresh);

    /* ================================================================
     * 10. 投票窗缓冲区绑定 & 上下文赋值
     * ================================================================ */
    VoteWin_Init(&vote_win_ring,         ring_vote_buf,          100);
    VoteWin_Init(&vote_win_wall,         wall_vote_buf,          WALL_WIN_MAX);
    VoteWin_Init(&vote_win_wall_climb,   wall_climb_vote_buf,    WALL_CLIMB_WIN_MAX);
    VoteWin_Init(&vote_win_wall_horiz,   wall_horiz_vote_buf,    WALL_HORIZ_WIN_MAX);
    VoteWin_Init(&vote_win_wall_descend, wall_descend_vote_buf,  WALL_DESCEND_WIN_MAX);
    VoteWin_Init(&vote_win_barrel,       barrel_vote_buf,        BARREL_WIN_MAX);
    VoteWin_Init(&vote_win_barrel_peak,  barrel_peak_vote_buf,   BARREL_WIN_MAX);
    VoteWin_Init(&vote_win_cross,        cross_vote_buf,         CROSS_WIN_MAX);
    VoteWin_Init(&vote_win_cross_tilt,   cross_tilt_vote_buf,    CROSS_WIN_MAX);
    VoteWin_Init(&vote_win_ra,           ra_vote_buf,            RA_WIN_MAX);
    VoteWin_Init(&vote_win_skip,        skip_vote_buf,          SKIP_WIN_MAX);

    /* 覆盖 VoteWin_Init 默认值, 匹配 JSON 调参后的值 */
    vote_win_ring.entry_thresh = 3;
    vote_win_ring.exit_thresh  = 5;
    vote_win_cross.len         = 0;
    vote_win_cross_tilt.len    = 0;
    vote_win_skip.len          = 20;
    vote_win_skip.entry_thresh = 19;
    vote_win_skip.exit_thresh  = 3;

    if (ctx != NULL) {
        ctx->vote_ring         = vote_win_ring;
        ctx->vote_wall         = vote_win_wall;
        ctx->vote_wall_climb   = vote_win_wall_climb;
        ctx->vote_wall_horiz   = vote_win_wall_horiz;
        ctx->vote_wall_descend = vote_win_wall_descend;
        ctx->vote_barrel       = vote_win_barrel;
        ctx->vote_barrel_peak  = vote_win_barrel_peak;
        ctx->vote_cross        = vote_win_cross;
        ctx->vote_cross_tilt   = vote_win_cross_tilt;
        ctx->vote_right_angle  = vote_win_ra;
        ctx->vote_skip         = vote_win_skip;
    }

    Element_ResetTrackIndex(ctx);
}

/* ---- 重置离赛道超时计时器 ---- */
void Element_ResetOfftrackTimer(ElementCtx_t *ctx)
{
    ctx->offtrack_active = 0;
}

/* ---- 重置赛道元素表索引 ---- */
void Element_ResetTrackIndex(ElementCtx_t *ctx)
{
    ctx->track_idx = 0;
}


/* ================================================================
 * SECTION 10.5 — 传感器灌入 & 倾角计算 (每帧由主循环调用)
 *   集中管理 ctx 传感器字段的写入, 避免散落在控制代码中
 * ================================================================ */

void Element_FeedSensors(ElementCtx_t *ctx,
    const float adc[4], float ax, float ay, float az,
    float yaw, float err_raw, float err_filtered)
{
    unsigned char j;

    if (ctx == NULL) return;

    for (j = 0; j < 4; j++) {
        ctx->adc[j] = adc[j];
    }
    ctx->ax           = ax;
    ctx->ay           = ay;
    ctx->az           = az;
    ctx->yaw          = yaw;
    ctx->err_raw      = err_raw;
    ctx->err_filtered = err_filtered;
}

void Element_CalcTilt(ElementCtx_t *ctx, float gx_body, float gy_body, float gz_body)
{
    float g_horiz;
    float gz_abs;
    float tilt_total;
    float inv_horiz;
    float raw_fb;
    float raw_lr;

    if (ctx == NULL) return;

    /* 水平分量幅值: g_horiz²+gz²=1 (四元数归一化保证) */
    g_horiz = (float)sqrt(gx_body * gx_body + gy_body * gy_body);
    gz_abs  = FABS(gz_body);

    /* 总倾角 = atan2(水平, 垂直) — 大倾角时 g_horiz→1, 无小分母 */
    tilt_total = (float)atan2(g_horiz, gz_abs) * 57.29578f;

    /* 按比例分解为前后/左右分量, 保留符号区分方向 */
    if (g_horiz > 0.001f) {
        inv_horiz = 1.0f / g_horiz;
        raw_fb = tilt_total * gx_body * inv_horiz;
        raw_lr = tilt_total * gy_body * inv_horiz;
    } else {
        raw_fb = 0.0f;
        raw_lr = 0.0f;
    }

    /* 共用 LPF 模块滤波 — 抑制高速行驶高频振动噪声 */
    if (!tilt_lpf_ready) {
        lpf_reset(&g_lpf_tilt_fb, raw_fb);
        lpf_reset(&g_lpf_tilt_lr, raw_lr);
        tilt_lpf_ready = 1;
    }
    ctx->tilt_fb = lpf_update(&g_lpf_tilt_fb, raw_fb);
    ctx->tilt_lr = lpf_update(&g_lpf_tilt_lr, raw_lr);
}

/* ================================================================
 * SECTION 11 — Element_Update
 *   每帧调用一次 (2ms 周期)
 *   1. 安全检测层
 *   2. 帧计数
 *   3. 投票生成 + 推入窗口
 *   4. 状态转移评估
 * ================================================================ */
element_t Element_Update(ElementCtx_t *ctx)
{
    unsigned char all_adc_low;
    unsigned long elapsed_ms;
    unsigned long now_tick;
    float tilt_fb_abs;
    unsigned char ring_vote;
    unsigned char wall_vote;
    unsigned char wall_climb_vote;
    unsigned char wall_horiz_vote;
    unsigned char wall_descend_vote;
    unsigned char barrel_vote;
    unsigned char barrel_peak_vote;
    unsigned char cross_vote;
    unsigned char cross_tilt_vote;
    unsigned char ra_vote;
    unsigned char skip_vote;
    float err_abs;
    float tilt_lr_abs;
    float skip_adc_sum;


    /* ---- 0. 安全检测层 (最高优先级) ---- */
    all_adc_low = (ctx->adc[0] < g_offtrack_adc_thresh && ctx->adc[1] < g_offtrack_adc_thresh
                && ctx->adc[2] < g_offtrack_adc_thresh && ctx->adc[3] < g_offtrack_adc_thresh) ? 1 : 0;
    /* ---- 1. 倾角绝对值 (供投票和停车使用) ---- */
    tilt_fb_abs = FABS(ctx->tilt_fb);
    tilt_lr_abs = FABS(ctx->tilt_lr);
    if (ctx->current != ELEMENT_SAFETY_STOP) {
        ctx->total_frames++;
    }
    now_tick = xTaskGetTickCount();
    if (all_adc_low && ctx->current != ELEMENT_SAFETY_STOP) {
        if (ctx->offtrack_active== 0) {
            ctx->offtrack_active= 1;
            ctx->offtrack_start_tick = xTaskGetTickCount();
        } else {

            elapsed_ms = (now_tick - ctx->offtrack_start_tick) * portTICK_PERIOD_MS;
            if (elapsed_ms >= (unsigned long)g_offtrack_timeout_ms) {
                ctx->current = ELEMENT_SAFETY_STOP;
                Debug_Log(Element_GetProp(ELEMENT_SAFETY_STOP)->name);
                ctx->offtrack_active= 0;
                g_current_element_u8 = (uint8_t)ctx->current;
                return ctx->current;
            }
        }
    } else {
        ctx->offtrack_active= 0;
    }
    if (ctx->current != ELEMENT_SAFETY_STOP && ctx->push_mode != 1 && manual_control_flag == 0) {
        if (g_ontrack_timeout_frames > 0
            && ctx->total_frames >= g_ontrack_timeout_frames
            && tilt_fb_abs < angle_level && tilt_lr_abs < angle_level) {
            System_Reset();
            g_current_element_u8 = (uint8_t)ctx->current;
            return ctx->current;
        }
    }

    /* SAFETY_STOP 退出: 任一 ADC 恢复 → 切手动模式 */
    if (ctx->current == ELEMENT_SAFETY_STOP) {
        g_current_element_u8 = (uint8_t)ctx->current;
        if (ctx->adc[0] > g_offtrack_adc_thresh || ctx->adc[1] > g_offtrack_adc_thresh
            || ctx->adc[2] > g_offtrack_adc_thresh || ctx->adc[3] > g_offtrack_adc_thresh) {
            System_Reset();
            ctx->offtrack_active= 0;
            Element_ResetTrackIndex(ctx);
            Debug_Log(Element_GetProp(ELEMENT_STRAIGHT)->name);
            return ctx->current;
        }
        return ctx->current;
    }

    /* ---- 0.5 元素表 ---- */
    if (!ctx->track_table_enabled) {
        ctx->track_idx = 0;
    }

    /* ---- 0.6 通用帧计数 (各元素超时检测共用) ---- */
    ctx->elem_frame_cnt++;
    ctx->elem_blanking_cnt++;
    if (ctx->ring_lockout_cnt > 0)   ctx->ring_lockout_cnt--;
    if (ctx->wall_lockout_cnt > 0)   ctx->wall_lockout_cnt--;
    if (ctx->barrel_lockout_cnt > 0) ctx->barrel_lockout_cnt--;
    if (ctx->skip_lockout_cnt > 0)   ctx->skip_lockout_cnt--;
    if (ctx->ra_lockout_cnt > 0)     ctx->ra_lockout_cnt--;
    if (ctx->cross_lockout_cnt > 0)  ctx->cross_lockout_cnt--;
    if (ctx->global_exit_lockout_cnt > 0) ctx->global_exit_lockout_cnt--;
    /* 环岛链帧计数 (ENTRANCE/PASS/IN_RING 超时兜底) */
    if (ctx->current == ELEMENT_RING_LEFT_ENTRANCE
        || ctx->current == ELEMENT_RING_RIGHT_ENTRANCE
        || ctx->current == ELEMENT_RING_LEFT_PASS
        || ctx->current == ELEMENT_RING_RIGHT_PASS
        || ctx->current == ELEMENT_IN_RING) {
        ctx->ring_frame_cnt++;
    }



    /* ---- 2. 投票生成 (所有元素类型的投票在此统一计算) ---- */

    /* 环岛投票 */
    if (ctx->current == ELEMENT_STRAIGHT) {
        ring_vote = (((ctx->adc[0] > RingEntrance[0]) ||
                      (ctx->adc[2] > RingEntrance[2])) &&
                     (tilt_fb_abs < angle_level)) ? 1 : 0;
    } else if (ctx->current == ELEMENT_IN_RING) {
        ring_vote = (ctx->adc[2] > RingExit[2] || ctx->adc[0] > RingExit[0]) ? 1 : 0;
    } else {
        ring_vote = 0;
    }
    VoteWin_Push(&ctx->vote_ring, ring_vote);

    /* 上墙入口投票: STRAIGHT → WALL, TiltB < 阈值 */
    if (ctx->current == ELEMENT_STRAIGHT) {
        wall_vote = (ctx->tilt_fb < wall_entry_tiltb) ? 1 : 0;
    } else {
        wall_vote = 0;
    }
    VoteWin_Push(&ctx->vote_wall, wall_vote);

    /* 上爬→水平投票: WALL_CLIMB → HORIZONTAL, |TiltR| > 阈值 */
    if (ctx->current == ELEMENT_WALL_CLIMB) {
        wall_climb_vote = (tilt_lr_abs > wall_climb_exit_tiltr) ? 1 : 0;
    } else {
        wall_climb_vote = 0;
    }
    VoteWin_Push(&ctx->vote_wall_climb, wall_climb_vote);

    /* 水平→下行投票: WALL_HORIZONTAL → DESCEND, |TiltR| < 阈值 */
    if (ctx->current == ELEMENT_WALL_HORIZONTAL) {
        wall_horiz_vote = (tilt_lr_abs < wall_horiz_exit_tiltr) ? 1 : 0;
    } else {
        wall_horiz_vote = 0;
    }
    VoteWin_Push(&ctx->vote_wall_horiz, wall_horiz_vote);

    /* 下行→STRAIGHT投票: WALL_DESCEND → STRAIGHT, TiltB > 阈值, 消隐期内强制投0 */
    if (ctx->current == ELEMENT_WALL_DESCEND) {
        if (ctx->elem_blanking_cnt < wall_descent_blanking_frames) {
            wall_descend_vote = 0;
        } else {
            wall_descend_vote = (ctx->tilt_fb < wall_descend_exit_tiltb) ? 1 : 0;
        }
    } else {
        wall_descend_vote = 0;
    }
    VoteWin_Push(&ctx->vote_wall_descend, wall_descend_vote);

    /* 滚筒投票 */
    if (ctx->current == ELEMENT_STRAIGHT) {
        barrel_vote = (ctx->tilt_fb < barrel_entry_tilt) ? 1 : 0;
    } else if (ctx->current == ELEMENT_BARREL_DESCEND) {
        barrel_vote = (ctx->tilt_fb < barrel_exit_tilt && ctx->tilt_fb > 0) ? 1 : 0;
    } else {
        barrel_vote = 0;
    }
    VoteWin_Push(&ctx->vote_barrel, barrel_vote);

    if (ctx->current == ELEMENT_BARREL_CLIMB) {
        barrel_peak_vote = (ctx->tilt_fb > barrel_peak_tilt) ? 1 : 0;
    } else {
        barrel_peak_vote = 0;
    }
    VoteWin_Push(&ctx->vote_barrel_peak, barrel_peak_vote);

    /* 十字 ADC 和缓存 (一帧算一次, 投票 & Check 共用) */
    ctx->cross_sum_cache = ctx->adc[1] + ctx->adc[3];
    ctx->cross_all_cache = ctx->adc[0] + ctx->adc[1] + ctx->adc[2] + ctx->adc[3];

    /* 十字投票 */
    if (ctx->current == ELEMENT_STRAIGHT) {
        cross_vote = (ctx->cross_sum_cache > cross_entry_sum && ctx->cross_all_cache > cross_all_sum
                      && tilt_fb_abs < angle_level && tilt_lr_abs < angle_level) ? 1 : 0;
    } else if (ctx->current == ELEMENT_CROSS) {
        cross_vote = (ctx->cross_sum_cache < cross_exit_sum
                   || ctx->cross_all_cache < cross_all_exit_sum) ? 1 : 0;
    } else {
        cross_vote = 0;
    }
    VoteWin_Push(&ctx->vote_cross, cross_vote);

    /* 十字倾角退出投票: CROSS 下倾角超限则投票退出 */
    if (ctx->current == ELEMENT_CROSS) {
        cross_tilt_vote = (tilt_fb_abs >= angle_level || tilt_lr_abs >= angle_level) ? 1 : 0;
    } else {
        cross_tilt_vote = 0;
    }
    VoteWin_Push(&ctx->vote_cross_tilt, cross_tilt_vote);

    /* 直角转弯投票: STRAIGHT 下 |err_raw| > entry_thresh 则投票进入 */
    if (ctx->current == ELEMENT_STRAIGHT) {
        err_abs = FABS(ctx->err_raw);
        ra_vote = (err_abs > g_ra_entry_thresh) ? 1 : 0;
    } else if (ctx->current == ELEMENT_RIGHT_ANGLE_LEFT) {
        ra_vote = (ctx->err_raw > -g_ra_exit_thresh && ctx->err_raw < 0) ? 1 : 0;
    } else if (ctx->current == ELEMENT_RIGHT_ANGLE_RIGHT) {
        ra_vote = (ctx->err_raw < g_ra_exit_thresh && ctx->err_raw > 0) ? 1 : 0;
    } else {
        ra_vote = 0;
    }
    VoteWin_Push(&ctx->vote_right_angle, ra_vote);

    /* 跷跷板投票: STRAIGHT→SKIP (tilt + 防左右倾误判); SKIP→AIRBORNE (ADC和); AIRBORNE→STRAIGHT (|tilt|) */
    if (ctx->current == ELEMENT_STRAIGHT) {
        skip_vote = (ctx->tilt_fb < skip_entry_tilt && tilt_lr_abs <= skip_entry_tilt_lr) ? 1 : 0;
    } else if (ctx->current == ELEMENT_SKIP) {
        skip_adc_sum = ctx->adc[0] + ctx->adc[1] + ctx->adc[2] + ctx->adc[3];
        skip_vote = (skip_adc_sum < skip_exit_sum) ? 1 : 0;
    } else if (ctx->current == ELEMENT_SKIP_AIRBORNE) {
        skip_adc_sum = ctx->adc[0] + ctx->adc[1] + ctx->adc[2] + ctx->adc[3];
        skip_vote = (tilt_fb_abs < skip_airborne_exit_tilt
                  && skip_adc_sum > skip_landing_adc_min
                  && skip_adc_sum < skip_landing_adc_max) ? 1 : 0;
    } else {
        skip_vote = 0;
    }
    VoteWin_Push(&ctx->vote_skip, skip_vote);

    /* ---- 4. 状态转移评估 (遍历转移表) ---- */
    Element_EvaluateTransitions(ctx);

    g_current_element_u8 = (uint8_t)ctx->current;
    return ctx->current;
}


/* ================================================================
 * SECTION 12 — 控制策略选择器
 * ================================================================ */

float SelectTargetYaw(ControlStrategy_t ctrl, const ElementProp_t *prop, ElementCtx_t *ctx)
{
    if (ctrl == CTRL_OL_YAW && prop != NULL && prop->ol_yawrate_ptr != NULL) {
        return (float)(prop->ol_yaw_sign) * (*prop->ol_yawrate_ptr) + ctx->yawrate;
    }
    if (ctrl == CTRL_RA_YAW && prop != NULL && prop->speed_ptr != NULL) {
        return Calc_RAPreYawrate(ctx, *prop->speed_ptr) + ctx->yawrate;
    }
    if (ctrl == CTRL_BRAKE) {
        return 0.0f;
    }
    return ctx->yawrate;
}

float SelectTargetErr(ControlStrategy_t ctrl, const ElementProp_t *prop, ElementCtx_t *ctx)
{
    if (ctrl == CTRL_ERR_FREEZE && prop != NULL && ctx != NULL) {
        return (ctx->frozen_err);
    }
    return ctx->err_raw;
}
