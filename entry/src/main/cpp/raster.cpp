// spine38 C++ 光栅化内核 — NAPI 模块
// 与 ArkTS 版 rasterize_triangle/polygon_mask/composite_over 语义一致（真机验证过的算法直译）。
#include <napi/native_api.h>
#include <cstdint>
#include <cstring>
#include <cmath>
#include <vector>
#include <chrono>
#include <hilog/log.h>
#include <ace/xcomponent/native_interface_xcomponent.h>
#include <native_window/external_window.h>
#include <native_buffer/native_buffer.h>
#include <sys/mman.h>
#include <qos/qos.h>
#include <EGL/egl.h>
#include <GLES3/gl3.h>
#include <GLES3/gl32.h>
#ifdef __aarch64__
#include <arm_neon.h>
#endif

struct ClipMask {
    uint8_t* mask;
    int x0, y0, x1, y1;
};

// 多边形填充掩码（偶数奇数规则），bbox 裁剪
static void polygon_mask(const double* pts, int nPts, int w, int h, ClipMask& cm, uint8_t* maskBuf) {
    cm.mask = maskBuf;
    cm.x0 = 0; cm.y0 = 0; cm.x1 = 0; cm.y1 = 0;
    if (nPts < 3) {
        return;
    }
    double minX = pts[0], maxX = pts[0], minY = pts[1], maxY = pts[1];
    for (int i = 2; i < nPts * 2; i += 2) {
        if (pts[i] < minX) minX = pts[i];
        if (pts[i] > maxX) maxX = pts[i];
        if (pts[i + 1] < minY) minY = pts[i + 1];
        if (pts[i + 1] > maxY) maxY = pts[i + 1];
    }
    int x0 = (int)std::floor(minX);
    if (x0 < 0) x0 = 0;
    int x1 = (int)std::ceil(maxX);
    if (x1 > w) x1 = w;
    int y0 = (int)std::floor(minY);
    if (y0 < 0) y0 = 0;
    int y1 = (int)std::ceil(maxY);
    if (y1 > h) y1 = h;
    if (x1 <= x0 || y1 <= y0) {
        return;
    }
    cm.x0 = x0; cm.y0 = y0; cm.x1 = x1; cm.y1 = y1;
    // 只清零包围盒区域（全画布清零在 1000vp 级画布上每帧浪费数 MB 内存带宽）
    for (int y = y0; y < y1; y++) {
        std::memset(cm.mask + (size_t)y * w + x0, 0, (size_t)(x1 - x0));
    }
    for (int y = y0; y < y1; y++) {
        double py = y + 0.5;
        for (int x = x0; x < x1; x++) {
            double px = x + 0.5;
            bool inside = false;
            for (int i = 0; i < nPts; i++) {
                double x1v = pts[i * 2], y1v = pts[i * 2 + 1];
                int j = (i + 1) % nPts;
                double x2v = pts[j * 2], y2v = pts[j * 2 + 1];
                bool cond = (y1v > py) != (y2v > py);
                if (cond) {
                    double denom = y2v - y1v;
                    if (denom == 0.0) denom = 1e-9;
                    double xint = (x2v - x1v) * (py - y1v) / denom + x1v;
                    if (px < xint) inside = !inside;
                }
            }
            if (inside) cm.mask[y * w + x] = 255;
        }
    }
}

// 只清零掩码包围盒区域
static void clear_bbox(uint8_t* buf, int w, const ClipMask& cm) {
    for (int y = cm.y0; y < cm.y1; y++) {
        std::memset(buf + ((size_t)y * w + cm.x0) * 4, 0, (size_t)(cm.x1 - cm.x0) * 4);
    }
}

// src 按 mask 门控叠加到 dst（直通 alpha source-over），只循环掩码包围盒
static void composite_over(uint8_t* dst, const uint8_t* src, const ClipMask& cm, int w) {
    for (int y = cm.y0; y < cm.y1; y++) {
        for (int x = cm.x0; x < cm.x1; x++) {
            int mi = y * w + x;
            if (cm.mask[mi] == 0) {
                continue;
            }
            int o = mi * 4;
            double sa = src[o + 3] / 255.0;
            double da = dst[o + 3] / 255.0;
            double oa = sa + da * (1.0 - sa);
            if (oa > 0.0) {
                dst[o] = (uint8_t)((src[o] * sa + dst[o] * da * (1.0 - sa)) / oa);
                dst[o + 1] = (uint8_t)((src[o + 1] * sa + dst[o + 1] * da * (1.0 - sa)) / oa);
                dst[o + 2] = (uint8_t)((src[o + 2] * sa + dst[o + 2] * da * (1.0 - sa)) / oa);
                dst[o + 3] = (uint8_t)(oa * 255.0);
            }
        }
    }
}

// ── 定点数内核：x/255 精确近似（x ≤ 65025 时与 floor(x/255) 一致）+ 倒数表 ──
// 每像素的 double 除法（旧版 5~6 次/像素）是光栅化成本核心，全部替换为整数运算。
static uint32_t UNPM[256];   // unpm[a] = round(255*65536/a)：0-255 尺度预乘 → 直通色
static uint32_t INV_A[256];  // inv[a] = 65536/a：r*a 尺度预乘（双线性插值产物）→ 直通色

static inline void init_unpm() {
    static bool s_done = false;
    if (s_done) {
        return;
    }
    s_done = true;
    UNPM[0] = 0;
    INV_A[0] = 0;
    for (int a = 1; a < 256; a++) {
        UNPM[a] = (255u * 65536u + (uint32_t)a / 2) / (uint32_t)a;
        INV_A[a] = (65536u + (uint32_t)a / 2) / (uint32_t)a;
    }
}

static inline uint32_t div255(uint32_t x) {
    return (x + 1u + (x >> 8)) >> 8;
}

static inline uint32_t unpremul(uint32_t premul, uint32_t a) {
    if (a == 0) {
        return 0;
    }
    uint32_t v = (uint32_t)(((uint64_t)premul * UNPM[a]) >> 16);
    return v > 255 ? 255 : v;
}

// 按混合模式的像素访问统计（诊断贵片段构成；每 60 帧由 Phase 日志汇总清零）
static uint64_t g_blendPx[4] = { 0, 0, 0, 0 };

// 单三角形扫描线光栅化（最近邻/双线性采样；blend: 0=normal 1=additive 2=multiply 3=screen）
// 语义与 ArkTS/Python 参考实现一致（±1/255 舍入差）。
// PREMUL=true：out 缓冲存预乘 RGBA（窗口直写路径）——正常混合零反预乘、加法混合纯加法，
//   写入侧也免预乘；PREMUL=false：直通 alpha（TestPage 参考路径，原语义不变）。
// u/v 走 16.16 定点；双线性采样在 PREMUL 路径用 NEON（通道作车道，vld4 读相邻纹素对）。
template<bool PREMUL>
static void rasterize_triangle_t(uint8_t* out, int w, int h, const uint8_t* tex, int tw, int th,
    size_t texBytes,
    double t0x, double t0y, double t1x, double t1y, double t2x, double t2y,
    double u0, double v0, double u1, double v1, double u2, double v2,
    double cr, double cg, double cb, double ca, int blend, int bilinear) {
    init_unpm();
    // 槽位颜色是 0-1 浮点（spine 格式，utils.ets Color），×255 转 0-255 整数
    uint32_t cr8 = (uint32_t)(cr * 255.0 + 0.5);
    uint32_t cg8 = (uint32_t)(cg * 255.0 + 0.5);
    uint32_t cb8 = (uint32_t)(cb * 255.0 + 0.5);
    uint32_t ca8 = (uint32_t)(ca * 255.0 + 0.5);
    // 预乘路径的每通道合成系数：psrc = div255(pr8 × kR)，pr8 = div255(pr)（pr 为 r*a 尺度）
    uint32_t kR = div255(cr8 * ca8);
    uint32_t kG = div255(cg8 * ca8);
    uint32_t kB = div255(cb8 * ca8);
    // 按 y 排序（顶/中/底）
    double xa = t0x, ya = t0y, ua = u0, va = v0;
    double xb = t1x, yb = t1y, ub = u1, vb = v1;
    double xc = t2x, yc = t2y, uc = u2, vc = v2;
    double tmp;
    if (ya > yb) {
        tmp = ya; ya = yb; yb = tmp; tmp = xa; xa = xb; xb = tmp;
        tmp = ua; ua = ub; ub = tmp; tmp = va; va = vb; vb = tmp;
    }
    if (yb > yc) {
        tmp = yb; yb = yc; yc = tmp; tmp = xb; xb = xc; xc = tmp;
        tmp = ub; ub = uc; uc = tmp; tmp = vb; vb = vc; vc = tmp;
    }
    if (ya > yb) {
        tmp = ya; ya = yb; yb = tmp; tmp = xa; xa = xb; xb = tmp;
        tmp = ua; ua = ub; ub = tmp; tmp = va; va = vb; vb = tmp;
    }
    double dLong = yc - ya;
    if (dLong < 1e-6) {
        return; // 水平退化三角形
    }
    int yStart = (int)std::ceil(ya - 0.5);
    if (yStart < 0) yStart = 0;
    int yEnd = (int)std::floor(yc - 0.5);
    if (yEnd > h - 1) yEnd = h - 1;
    if (yEnd < yStart) {
        return;
    }
    double dUpper = yb - ya;
    double dLower = yc - yb;
    // 增量边步进：每边只除一次
    double dxLong = (xc - xa) / dLong;
    double duLong = (uc - ua) / dLong;
    double dvLong = (vc - va) / dLong;
    double dxUp = 0.0, duUp = 0.0, dvUp = 0.0;
    if (dUpper > 1e-6) {
        dxUp = (xb - xa) / dUpper;
        duUp = (ub - ua) / dUpper;
        dvUp = (vb - va) / dUpper;
    }
    double dxLo = 0.0, duLo = 0.0, dvLo = 0.0;
    if (dLower > 1e-6) {
        dxLo = (xc - xb) / dLower;
        duLo = (uc - ub) / dLower;
        dvLo = (vc - vb) / dLower;
    }
    uint64_t spans = 0;
    double y0f = yStart + 0.5;
    double ex0 = xa + dxLong * (y0f - ya);
    double eu0 = ua + duLong * (y0f - ya);
    double ev0 = va + dvLong * (y0f - ya);
    bool useUpper = y0f <= yb && dUpper > 1e-6;
    double ex1, eu1, ev1;
    if (useUpper) {
        ex1 = xa + dxUp * (y0f - ya);
        eu1 = ua + duUp * (y0f - ya);
        ev1 = va + dvUp * (y0f - ya);
    } else {
        ex1 = xb + dxLo * (y0f - yb);
        eu1 = ub + duLo * (y0f - yb);
        ev1 = vb + dvLo * (y0f - yb);
    }
    for (int y = yStart; y <= yEnd; y++) {
        double left, right, ul, vl, ur, vr;
        if (ex0 < ex1) {
            left = ex0; right = ex1; ul = eu0; vl = ev0; ur = eu1; vr = ev1;
        } else {
            left = ex1; right = ex0; ul = eu1; vl = ev1; ur = eu0; vr = ev0;
        }
        int xStart = (int)std::ceil(left - 0.5);
        if (xStart < 0) xStart = 0;
        int xEnd = (int)std::floor(right - 0.5);
        if (xEnd > w - 1) xEnd = w - 1;
        if (xEnd >= xStart) {
            double dRow = right - left;
            if (dRow >= 1e-6) {
                double du = (ur - ul) / dRow;
                double dv = (vr - vl) / dRow;
                double u = ul + du * (xStart + 0.5 - left);
                double v = vl + dv * (xStart + 0.5 - left);
                int rowBase = y * w * 4;
                spans += (uint64_t)(xEnd - xStart + 1);
                // 16.16 定点步进（每像素整数加法替代 double 加法）
                int32_t uFp = (int32_t)(u * 65536.0);
                int32_t vFp = (int32_t)(v * 65536.0);
                int32_t duFp = (int32_t)(du * 65536.0);
                int32_t dvFp = (int32_t)(dv * 65536.0);
                for (int x = xStart; x <= xEnd; x++) {
                    uint32_t pr = 0, pg = 0, pb = 0, ta8 = 0;
                    uint32_t sr8 = 0, sg8 = 0, sb8 = 0, sa8 = 0;
                    uint32_t psrcR = 0, psrcG = 0, psrcB = 0;
                    if (bilinear) {
                        // 双线性采样，预乘修正插值（避免透明边缘黑边——Python 同款）。
                        // u×tw×65536 全精度定点：ui = floor(u×tw-0.5)，权重 = 小数×256
                        int64_t ufFp = (int64_t)uFp * tw - 32768;
                        int64_t vfFp = (int64_t)vFp * th - 32768;
                        int ui = (int)(ufFp >> 16);
                        int vi = (int)(vfFp >> 16);
                        if (ui < 0) ui = 0;
                        if (vi < 0) vi = 0;
                        int ui1 = ui + 1;
                        int vi1 = vi + 1;
                        if (ui1 >= tw) ui1 = tw - 1;
                        if (vi1 >= th) vi1 = th - 1;
                        if (ui >= tw) ui = tw - 1;
                        if (vi >= th) vi = th - 1;
                        // 8bit 权重（和 65536），预乘插值 uint32 恰好不溢出
                        int32_t wFx32 = (int32_t)((ufFp - ((int64_t)ui << 16)) >> 8);
                        int32_t wFy32 = (int32_t)((vfFp - ((int64_t)vi << 16)) >> 8);
                        uint32_t wFx = wFx32 < 0 ? 0u : (wFx32 > 255 ? 255u : (uint32_t)wFx32);
                        uint32_t wFy = wFy32 < 0 ? 0u : (wFy32 > 255 ? 255u : (uint32_t)wFy32);
                        uint32_t w00 = (256 - wFx) * (256 - wFy);
                        uint32_t w10 = wFx * (256 - wFy);
                        uint32_t w01 = (256 - wFx) * wFy;
                        uint32_t w11 = wFx * wFy;
                        const uint8_t* t00 = tex + (vi * tw + ui) * 4;
                        const uint8_t* t10 = tex + (vi * tw + ui1) * 4;
                        const uint8_t* t01 = tex + (vi1 * tw + ui) * 4;
                        const uint8_t* t11 = tex + (vi1 * tw + ui1) * 4;
                        pr = (t00[0] * t00[3] * w00 + t10[0] * t10[3] * w10 +
                              t01[0] * t01[3] * w01 + t11[0] * t11[3] * w11 + 32768u) >> 16;
                        pg = (t00[1] * t00[3] * w00 + t10[1] * t10[3] * w10 +
                              t01[1] * t01[3] * w01 + t11[1] * t11[3] * w11 + 32768u) >> 16;
                        pb = (t00[2] * t00[3] * w00 + t10[2] * t10[3] * w10 +
                              t01[2] * t01[3] * w01 + t11[2] * t11[3] * w11 + 32768u) >> 16;
                        ta8 = (t00[3] * w00 + t10[3] * w10 +
                               t01[3] * w01 + t11[3] * w11 + 32768u) >> 16;
                        if (PREMUL) {
                            sa8 = div255(ta8 * ca8);
                            psrcR = div255(div255(pr) * kR);
                            psrcG = div255(div255(pg) * kG);
                            psrcB = div255(div255(pb) * kB);
                            if (blend == 2 || blend == 3) {
                                sr8 = ta8 > 0 ? div255((uint32_t)(((uint64_t)pr * INV_A[ta8]) >> 16) * cr8) : 0u;
                                sg8 = ta8 > 0 ? div255((uint32_t)(((uint64_t)pg * INV_A[ta8]) >> 16) * cg8) : 0u;
                                sb8 = ta8 > 0 ? div255((uint32_t)(((uint64_t)pb * INV_A[ta8]) >> 16) * cb8) : 0u;
                            }
                        } else {
                            // pr 是 r*a 尺度（0-65025），用 INV_A 反预乘
                            uint32_t tr8 = ta8 > 0 ? (uint32_t)(((uint64_t)pr * INV_A[ta8]) >> 16) : 0u;
                            uint32_t tg8 = ta8 > 0 ? (uint32_t)(((uint64_t)pg * INV_A[ta8]) >> 16) : 0u;
                            uint32_t tb8 = ta8 > 0 ? (uint32_t)(((uint64_t)pb * INV_A[ta8]) >> 16) : 0u;
                            sr8 = div255(tr8 * cr8);
                            sg8 = div255(tg8 * cg8);
                            sb8 = div255(tb8 * cb8);
                            sa8 = div255(ta8 * ca8);
                        }
                    } else {
                        // 最近邻：UV 恒非负，钳制防定点负零
                        int ti = (int32_t)(((int64_t)vFp * th) >> 16);
                        if (ti < 0) ti = 0;
                        if (ti >= th) ti = th - 1;
                        int tj = (int32_t)(((int64_t)uFp * tw) >> 16);
                        if (tj < 0) tj = 0;
                        if (tj >= tw) tj = tw - 1;
                        const uint8_t* texel = tex + (ti * tw + tj) * 4;
                        ta8 = texel[3];
                        sa8 = div255(ta8 * ca8);
                        sr8 = div255(texel[0] * cr8);
                        sg8 = div255(texel[1] * cg8);
                        sb8 = div255(texel[2] * cb8);
                        if (PREMUL) {
                            psrcR = div255(sr8 * sa8);
                            psrcG = div255(sg8 * sa8);
                            psrcB = div255(sb8 * sa8);
                        }
                    }
                    int o = rowBase + x * 4;
                    uint32_t da8 = out[o + 3];
                    if (PREMUL) {
                        // 预乘缓冲混合：正常混合零反预乘，加法混合纯加法
                        if (blend == 0) {
                            uint32_t oa8 = sa8 + div255(da8 * (255 - sa8));
                            if (oa8 > 0) {
                                uint32_t pR = psrcR + div255(out[o] * (255 - sa8));
                                uint32_t pG = psrcG + div255(out[o + 1] * (255 - sa8));
                                uint32_t pB = psrcB + div255(out[o + 2] * (255 - sa8));
                                if (pR > 255) pR = 255;
                                if (pG > 255) pG = 255;
                                if (pB > 255) pB = 255;
                                out[o] = (uint8_t)pR;
                                out[o + 1] = (uint8_t)pG;
                                out[o + 2] = (uint8_t)pB;
                                out[o + 3] = (uint8_t)oa8;
                            }
                        } else if (blend == 1) {
                            uint32_t na8 = sa8 + da8;
                            if (na8 > 255) na8 = 255;
                            if (na8 > 0) {
                                uint32_t pR = psrcR + out[o];
                                uint32_t pG = psrcG + out[o + 1];
                                uint32_t pB = psrcB + out[o + 2];
                                if (pR > 255) pR = 255;
                                if (pG > 255) pG = 255;
                                if (pB > 255) pB = 255;
                                out[o] = (uint8_t)pR;
                                out[o + 1] = (uint8_t)pG;
                                out[o + 2] = (uint8_t)pB;
                                out[o + 3] = (uint8_t)na8;
                            }
                        } else if (blend == 2) {
                            // multiply 作用于预乘色：out_p' = out_p×f/255（f 与直通语义同式）
                            uint32_t fR = 255 - sa8 + div255(sa8 * sr8);
                            out[o] = (uint8_t)div255(out[o] * fR);
                            uint32_t fG = 255 - sa8 + div255(sa8 * sg8);
                            out[o + 1] = (uint8_t)div255(out[o + 1] * fG);
                            uint32_t fB = 255 - sa8 + div255(sa8 * sb8);
                            out[o + 2] = (uint8_t)div255(out[o + 2] * fB);
                        } else {
                            // screen 预乘推导：out_p' = da8 - f×(da8 - out_p)/255
                            uint32_t fR = 255 - div255(sa8 * sr8);
                            out[o] = (uint8_t)(da8 - div255((da8 - out[o]) * fR));
                            uint32_t fG = 255 - div255(sa8 * sg8);
                            out[o + 1] = (uint8_t)(da8 - div255((da8 - out[o + 1]) * fG));
                            uint32_t fB = 255 - div255(sa8 * sb8);
                            out[o + 2] = (uint8_t)(da8 - div255((da8 - out[o + 2]) * fB));
                        }
                    } else {
                        // 直通 alpha 混合（参考语义，原样保留）
                        if (blend == 0) {
                            uint32_t oa8 = sa8 + div255(da8 * (255 - sa8));
                            if (oa8 > 0) {
                                uint32_t pR = div255(sr8 * sa8) + div255(div255(out[o] * da8) * (255 - sa8));
                                uint32_t pG = div255(sg8 * sa8) + div255(div255(out[o + 1] * da8) * (255 - sa8));
                                uint32_t pB = div255(sb8 * sa8) + div255(div255(out[o + 2] * da8) * (255 - sa8));
                                out[o] = (uint8_t)unpremul(pR, oa8);
                                out[o + 1] = (uint8_t)unpremul(pG, oa8);
                                out[o + 2] = (uint8_t)unpremul(pB, oa8);
                                out[o + 3] = (uint8_t)oa8;
                            }
                        } else if (blend == 1) {
                            // additive：预乘语义叠加
                            uint32_t na8 = sa8 + da8;
                            if (na8 > 255) na8 = 255;
                            if (na8 > 0) {
                                uint32_t pR = div255(sr8 * sa8) + div255(out[o] * da8);
                                uint32_t pG = div255(sg8 * sa8) + div255(out[o + 1] * da8);
                                uint32_t pB = div255(sb8 * sa8) + div255(out[o + 2] * da8);
                                out[o] = (uint8_t)unpremul(pR, na8);
                                out[o + 1] = (uint8_t)unpremul(pG, na8);
                                out[o + 2] = (uint8_t)unpremul(pB, na8);
                                out[o + 3] = (uint8_t)na8;
                            }
                        } else if (blend == 2) {
                            uint32_t fR = 255 - sa8 + div255(sa8 * sr8);
                            out[o] = (uint8_t)div255(out[o] * fR);
                            uint32_t fG = 255 - sa8 + div255(sa8 * sg8);
                            out[o + 1] = (uint8_t)div255(out[o + 1] * fG);
                            uint32_t fB = 255 - sa8 + div255(sa8 * sb8);
                            out[o + 2] = (uint8_t)div255(out[o + 2] * fB);
                        } else {
                            uint32_t fR = 255 - div255(sa8 * sr8);
                            out[o] = (uint8_t)(255 - div255((255 - out[o]) * fR));
                            uint32_t fG = 255 - div255(sa8 * sg8);
                            out[o + 1] = (uint8_t)(255 - div255((255 - out[o + 1]) * fG));
                            uint32_t fB = 255 - div255(sa8 * sb8);
                            out[o + 2] = (uint8_t)(255 - div255((255 - out[o + 2]) * fB));
                        }
                    }
                    uFp += duFp;
                    vFp += dvFp;
                }
            }
        }
        // 行步进 + 短边换段（换段时用下段参数重算下一行起点）
        ex0 += dxLong;
        eu0 += duLong;
        ev0 += dvLong;
        if (useUpper) {
            if (y + 1 + 0.5 > yb) {
                useUpper = false;
                double ynf = y + 1 + 0.5;
                ex1 = xb + dxLo * (ynf - yb);
                eu1 = ub + duLo * (ynf - yb);
                ev1 = vb + dvLo * (ynf - yb);
            } else {
                ex1 += dxUp;
                eu1 += duUp;
                ev1 += dvUp;
            }
        } else {
            ex1 += dxLo;
            eu1 += duLo;
            ev1 += dvLo;
        }
    }
    g_blendPx[blend & 3] += spans;
}

// 预乘缓冲版裁剪段合成：out_p = src_p + dst_p×(255-sa)/255（预乘线性，合成即加法）
static void composite_over_pm(uint8_t* dst, const uint8_t* src, const ClipMask& cm, int w) {
    for (int y = cm.y0; y < cm.y1; y++) {
        for (int x = cm.x0; x < cm.x1; x++) {
            int mi = y * w + x;
            if (cm.mask[mi] == 0) {
                continue;
            }
            int o = mi * 4;
            uint32_t sa = src[o + 3];
            uint32_t da = dst[o + 3];
            uint32_t oa = sa + div255(da * (255 - sa));
            if (oa > 0) {
                uint32_t pR = src[o] + div255(dst[o] * (255 - sa));
                uint32_t pG = src[o + 1] + div255(dst[o + 1] * (255 - sa));
                uint32_t pB = src[o + 2] + div255(dst[o + 2] * (255 - sa));
                if (pR > 255) pR = 255;
                if (pG > 255) pG = 255;
                if (pB > 255) pB = 255;
                dst[o] = (uint8_t)pR;
                dst[o + 1] = (uint8_t)pG;
                dst[o + 2] = (uint8_t)pB;
                dst[o + 3] = (uint8_t)oa;
            }
        }
    }
}

// ── GPU 渲染后端（GLES3）：骨骼动画的终局路线 ────────────────────────────────
// CPU 每帧只剩骨骼计算+顶点上传（~1-3ms，DVFS 免疫）；光栅化交给 GPU（物理分辨率）。
// 裁剪段用 stencil 缓冲 + INVERT（偶数奇数规则硬件实现）；四种混合用精确 glBlendFuncSeparate。
static OHNativeWindow* g_win = nullptr;
static uint64_t g_winW = 0, g_winH = 0;

static EGLDisplay g_eglDisplay = EGL_NO_DISPLAY;
static EGLContext g_eglContext = EGL_NO_CONTEXT;
static EGLSurface g_eglSurface = EGL_NO_SURFACE;
static GLuint g_program = 0;
static GLint g_uViewportLoc = -1;
static GLint g_uClipIdLoc = -1;
static GLint g_uTexLoc = -1;
static GLint g_uMaskLoc = -1;
static GLuint g_vbo = 0;
static GLuint g_clipVbo = 0;
static GLuint g_texId = 0;
static GLuint g_maskTex = 0; // R8 掩码纹理（vp 分辨率，每像素=段 id+1）
static const uint8_t* g_texPtr = nullptr;
static int g_texW = 0, g_texH = 0;
static bool g_glReady = false;

static const char* VS_SRC = R"(#version 300 es
layout(location=0) in vec2 a_pos;    // vp 坐标（显示盒空间）
layout(location=1) in vec2 a_uv;
layout(location=2) in vec4 a_color;  // 槽位色 0-1（直通）
uniform vec2 u_viewport;             // (vpW, vpH)
out vec2 v_uv;
out vec4 v_color;
out vec2 v_maskUv;
void main() {
    vec2 ndc = vec2(a_pos.x / u_viewport.x * 2.0 - 1.0,
                    1.0 - a_pos.y / u_viewport.y * 2.0);
    gl_Position = vec4(ndc, 0.0, 1.0);
    v_uv = a_uv;
    v_color = a_color;
    v_maskUv = a_pos / u_viewport;
}
)";

static const char* FS_SRC = R"(#version 300 es
precision mediump float;
uniform sampler2D u_tex;
uniform sampler2D u_mask;   // R8：每像素=裁剪段 id+1（0=无裁剪；CPU 偶数奇数掩码，与原版一致）
uniform int u_clipId;       // 当前运行的段 id+1（0=不裁剪）
in vec2 v_uv;
in vec4 v_color;
in vec2 v_maskUv;
out vec4 fragColor;
void main() {
    if (u_clipId > 0) {
        float m = texture(u_mask, v_maskUv).r * 255.0;
        if (m + 0.5 < float(u_clipId) || m - 0.5 > float(u_clipId)) {
            discard;
        }
    }
    vec4 t = texture(u_tex, v_uv);   // 预乘纹理（上传时已转预乘，插值无黑边）
    vec3 straight = t.a > 0.0 ? t.rgb / t.a : vec3(0.0);
    vec3 c = straight * v_color.rgb;
    float a = t.a * v_color.a;
    fragColor = vec4(c * a, a);      // 预乘输出（表面合成语义）
}
)";

static GLuint compile_shader(GLenum type, const char* src) {
    GLuint sh = glCreateShader(type);
    glShaderSource(sh, 1, &src, nullptr);
    glCompileShader(sh);
    GLint ok = 0;
    glGetShaderiv(sh, GL_COMPILE_STATUS, &ok);
    if (!ok) {
        char log[512] = { 0 };
        glGetShaderInfoLog(sh, sizeof(log) - 1, nullptr, log);
        OH_LOG_Print(LOG_APP, LOG_ERROR, 0x0000, "PetGL", "shader fail: %{public}s", log);
        return 0;
    }
    return sh;
}

// 预乘纹理上传：直通字节 → 预乘（定律③：纹理插值必须预乘修正，否则透明边缘黑边）
static void upload_texture(const uint8_t* tex, int tw, int th) {
    static std::vector<uint8_t> s_pm;
    size_t n = (size_t)tw * th * 4;
    if (s_pm.size() < n) {
        s_pm.resize(n);
    }
    for (size_t i = 0; i < n; i += 4) {
        uint32_t a = tex[i + 3];
        s_pm[i] = (uint8_t)div255(tex[i] * a);
        s_pm[i + 1] = (uint8_t)div255(tex[i + 1] * a);
        s_pm[i + 2] = (uint8_t)div255(tex[i + 2] * a);
        s_pm[i + 3] = (uint8_t)a;
    }
    glBindTexture(GL_TEXTURE_2D, g_texId);
    glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, tw, th, 0, GL_RGBA, GL_UNSIGNED_BYTE, s_pm.data());
    g_texPtr = tex;
    g_texW = tw;
    g_texH = th;
}

// 耳切三角化（简单多边形，可凹；顶点数小，每帧重切）。返回三角形数，输出 x,y 对。
static int triangulate_polygon(const double* pts, int n, float* out) {
    if (n < 3) {
        return 0;
    }
    static std::vector<int> s_ring;
    s_ring.resize((size_t)n);
    for (int i = 0; i < n; i++) {
        s_ring[i] = i;
    }
    // 整体方向（有符号面积）
    double area = 0;
    for (int i = 0; i < n; i++) {
        int j = (i + 1) % n;
        area += pts[i * 2] * pts[j * 2 + 1] - pts[j * 2] * pts[i * 2 + 1];
    }
    int sign = area > 0 ? 1 : -1;
    int outN = 0;
    int guard = 0;
    while (s_ring.size() > 3 && guard++ < 2000) {
        bool clipped = false;
        for (size_t i = 0; i < s_ring.size(); i++) {
            int i0 = s_ring[(i + s_ring.size() - 1) % s_ring.size()];
            int i1 = s_ring[i];
            int i2 = s_ring[(i + 1) % s_ring.size()];
            double ax = pts[i0 * 2], ay = pts[i0 * 2 + 1];
            double bx = pts[i1 * 2], by = pts[i1 * 2 + 1];
            double cx = pts[i2 * 2], cy = pts[i2 * 2 + 1];
            double cross = (bx - ax) * (cy - ay) - (by - ay) * (cx - ax);
            if (cross * sign <= 0) {
                continue; // 凹顶点
            }
            bool contains = false;
            for (size_t j = 0; j < s_ring.size(); j++) {
                int p = s_ring[j];
                if (p == i0 || p == i1 || p == i2) {
                    continue;
                }
                double px = pts[p * 2], py = pts[p * 2 + 1];
                double d0 = (px - ax) * (by - ay) - (py - ay) * (bx - ax);
                double d1 = (px - bx) * (cy - by) - (py - by) * (cx - bx);
                double d2 = (px - cx) * (ay - cy) - (py - cy) * (ax - cx);
                bool neg = d0 < 0 || d1 < 0 || d2 < 0;
                bool pos = d0 > 0 || d1 > 0 || d2 > 0;
                if (!(neg && pos)) {
                    contains = true;
                    break;
                }
            }
            if (contains) {
                continue;
            }
            out[outN++] = (float)ax;
            out[outN++] = (float)ay;
            out[outN++] = (float)bx;
            out[outN++] = (float)by;
            out[outN++] = (float)cx;
            out[outN++] = (float)cy;
            s_ring.erase(s_ring.begin() + (ptrdiff_t)i);
            clipped = true;
            break;
        }
        if (!clipped) {
            break;
        }
    }
    if (s_ring.size() == 3) {
        for (int k = 0; k < 3; k++) {
            int p = s_ring[k];
            out[outN++] = (float)pts[p * 2];
            out[outN++] = (float)pts[p * 2 + 1];
        }
    }
    return outN / 6;
}

// 半平面裁剪（Sutherland-Hodgman 单边）：in/out 每顶点 8 floats（x,y,u,v,r,g,b,a）。
// wind = 裁剪多边形方向（1=CCW -1=CW），内侧 = wind×cross ≥ 0。返回输出顶点数。
static int sh_clip_edge(const float* in, int n, float* out,
    float ax, float ay, float bx, float by, int wind) {
    int outN = 0;
    for (int i = 0; i < n; i++) {
        const float* cur = in + (size_t)i * 8;
        const float* nxt = in + (size_t)((i + 1) % n) * 8;
        float dc = ((bx - ax) * (cur[1] - ay) - (by - ay) * (cur[0] - ax)) * (float)wind;
        float dn = ((bx - ax) * (nxt[1] - ay) - (by - ay) * (nxt[0] - ax)) * (float)wind;
        bool cin = dc >= 0.0f;
        bool nin = dn >= 0.0f;
        if (cin) {
            std::memcpy(out + (size_t)outN * 8, cur, 8 * sizeof(float));
            outN++;
        }
        if (cin != nin) {
            float t = dc / (dc - dn);
            float* o = out + (size_t)outN * 8;
            for (int k = 0; k < 8; k++) {
                o[k] = cur[k] + (nxt[k] - cur[k]) * t;
            }
            outN++;
        }
    }
    return outN;
}

static void set_blend(int blend) {
    switch (blend) {
        case 0:
            glBlendFuncSeparate(GL_ONE, GL_ONE_MINUS_SRC_ALPHA, GL_ONE, GL_ONE_MINUS_SRC_ALPHA);
            break;
        case 1:
            glBlendFuncSeparate(GL_ONE, GL_ONE, GL_ONE, GL_ONE);
            break;
        case 2:
            glBlendFuncSeparate(GL_DST_COLOR, GL_ONE_MINUS_SRC_ALPHA, GL_ZERO, GL_ONE);
            break;
        default:
            glBlendFuncSeparate(GL_DST_ALPHA, GL_ONE_MINUS_SRC_COLOR, GL_ZERO, GL_ONE);
            break;
    }
}

static void draw_run(int startVert, int vertCount, int blend, int clipId) {
    if (vertCount <= 0) {
        return;
    }
    glBindBuffer(GL_ARRAY_BUFFER, g_vbo);
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 8 * (GLsizei)sizeof(float), nullptr);
    glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, 8 * (GLsizei)sizeof(float),
        (const void*)(2 * sizeof(float)));
    glVertexAttribPointer(2, 4, GL_FLOAT, GL_FALSE, 8 * (GLsizei)sizeof(float),
        (const void*)(4 * sizeof(float)));
    glEnableVertexAttribArray(0);
    glEnableVertexAttribArray(1);
    glEnableVertexAttribArray(2);
    // 裁剪段 id（0=无裁剪）；掩码纹理绑定在 unit 1（GL_NEAREST/CLAMP）
    glUniform1i(g_uClipIdLoc, clipId);
    glActiveTexture(GL_TEXTURE1);
    glBindTexture(GL_TEXTURE_2D, g_maskTex);
    glActiveTexture(GL_TEXTURE0);
    set_blend(blend);
    glDrawArrays(GL_TRIANGLES, startVert, vertCount);
}

// 上屏（GPU 版）：收集的 vp 三角形 → 顶点缓冲 → stencil 裁剪 + 混合运行 → swap。
// 参数与 render_frame_to_window 相同（rasterScale 忽略——GPU 直接以表面物理分辨率渲染）。
static napi_value RenderFrameGL(napi_env env, napi_callback_info info) {
    size_t argc = 13;
    napi_value args[13] = { nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 13) {
        return nullptr;
    }
    double* tris = nullptr; size_t trisLen = 0;
    napi_get_arraybuffer_info(env, args[0], (void**)&tris, &trisLen);
    double* colors = nullptr; size_t colorsLen = 0;
    napi_get_arraybuffer_info(env, args[1], (void**)&colors, &colorsLen);
    int32_t* flags = nullptr; size_t flagsLen = 0;
    napi_get_arraybuffer_info(env, args[2], (void**)&flags, &flagsLen);
    int32_t triCount = 0;
    napi_get_value_int32(env, args[3], &triCount);
    double* segFlat = nullptr; size_t segFlatLen = 0;
    napi_get_arraybuffer_info(env, args[4], (void**)&segFlat, &segFlatLen);
    int32_t* segSizes = nullptr; size_t segSizesLen = 0;
    napi_get_arraybuffer_info(env, args[5], (void**)&segSizes, &segSizesLen);
    int32_t segCount = 0;
    napi_get_value_int32(env, args[6], &segCount);
    uint8_t* tex = nullptr; size_t texLen = 0;
    napi_get_arraybuffer_info(env, args[7], (void**)&tex, &texLen);
    int32_t texW = 0, texH = 0;
    napi_get_value_int32(env, args[8], &texW);
    napi_get_value_int32(env, args[9], &texH);
    double vpW = 1.0, vpH = 1.0;
    napi_get_value_double(env, args[10], &vpW);
    napi_get_value_double(env, args[11], &vpH);
    if (!g_glReady || triCount <= 0) {
        return nullptr;
    }
    if (eglMakeCurrent(g_eglDisplay, g_eglSurface, g_eglSurface, g_eglContext) == EGL_FALSE) {
        return nullptr;
    }
    // 表面真实尺寸每帧查询（init 时 GET_BUFFER_GEOMETRY 报的宽高是互换的，
    // 用错值 = 竖屏视口套横屏表面 → 角色横向压窄 9% 的根因）
    EGLint sw = 0, sh = 0;
    eglQuerySurface(g_eglDisplay, g_eglSurface, EGL_WIDTH, &sw);
    eglQuerySurface(g_eglDisplay, g_eglSurface, EGL_HEIGHT, &sh);
    glViewport(0, 0, sw, sh);
    glClearColor(0.0f, 0.0f, 0.0f, 0.0f);
    glClear(GL_COLOR_BUFFER_BIT | GL_STENCIL_BUFFER_BIT);
    glEnable(GL_BLEND);
    glDisable(GL_DEPTH_TEST);
    glDisable(GL_STENCIL_TEST);
    glUseProgram(g_program);
    glUniform2f(g_uViewportLoc, (float)vpW, (float)vpH);
    glUniform1i(g_uTexLoc, 0);
    glUniform1i(g_uMaskLoc, 1);
    glActiveTexture(GL_TEXTURE0);
    if (g_texPtr != tex || g_texW != texW || g_texH != texH) {
        upload_texture(tex, texW, texH);
    } else {
        glBindTexture(GL_TEXTURE_2D, g_texId);
    }
    // ── 裁剪掩码：CPU 偶数奇数填充（与原版语义一致，自交多边形也正确）→ R8 纹理 → 着色器丢弃 ──
    int vpw = (int)(vpW + 0.5);
    int vph = (int)(vpH + 0.5);
    if (vpw < 1) vpw = 1;
    if (vph < 1) vph = 1;
    static std::vector<uint8_t> s_maskPx;   // vpw×vph×4（RGBA8；R=段 id+1——R8 在本机驱动被拒）
    static std::vector<uint8_t> s_maskTmp;  // polygon_mask 暂存
    static std::vector<int> s_prevMasks;    // 上一帧各段 bbox
    static std::vector<int> s_upMasks;      // 本帧需上传的区域（旧∪新）
    static int s_maskTexW = 0;
    static int s_maskTexH = 0;
    if (s_maskPx.size() != (size_t)vpw * vph * 4) {
        s_maskPx.assign((size_t)vpw * vph * 4, 0);
        s_maskTmp.assign((size_t)vpw * vph, 0);
        s_prevMasks.clear();
    }
    s_upMasks.clear();
    for (size_t p = 0; p < s_prevMasks.size(); p += 4) {
        s_upMasks.push_back(s_prevMasks[p]);
        s_upMasks.push_back(s_prevMasks[p + 1]);
        s_upMasks.push_back(s_prevMasks[p + 2]);
        s_upMasks.push_back(s_prevMasks[p + 3]);
    }
    // 清旧区域
    for (size_t p = 0; p < s_prevMasks.size(); p += 4) {
        int x0 = s_prevMasks[p], y0 = s_prevMasks[p + 1], x1 = s_prevMasks[p + 2], y1 = s_prevMasks[p + 3];
        for (int cy = y0; cy < y1; cy++) {
            std::memset(s_maskPx.data() + ((size_t)cy * vpw + x0) * 4, 0, (size_t)(x1 - x0) * 4);
        }
    }
    s_prevMasks.clear();
    int poff = 0;
    for (int s = 0; s < segCount; s++) {
        const double* pts = segFlat + poff;
        int n = segSizes[s];
        poff += n * 2;
        ClipMask cm;
        polygon_mask(pts, n, vpw, vph, cm, s_maskTmp.data());
        if (cm.x1 <= cm.x0 || cm.y1 <= cm.y0) {
            continue;
        }
        uint8_t idv = (uint8_t)(s + 1);
        for (int cy = cm.y0; cy < cm.y1; cy++) {
            for (int cx = cm.x0; cx < cm.x1; cx++) {
                if (cm.mask[cy * vpw + cx] == 255) {
                    s_maskPx[((size_t)cy * vpw + cx) * 4] = idv;
                }
            }
        }
        s_prevMasks.push_back(cm.x0);
        s_prevMasks.push_back(cm.y0);
        s_prevMasks.push_back(cm.x1);
        s_prevMasks.push_back(cm.y1);
        s_upMasks.push_back(cm.x0);
        s_upMasks.push_back(cm.y0);
        s_upMasks.push_back(cm.x1);
        s_upMasks.push_back(cm.y1);
    }
    // 掩码纹理分配 + 分块上传
    glActiveTexture(GL_TEXTURE1);
    glBindTexture(GL_TEXTURE_2D, g_maskTex);
    if (s_maskTexW != vpw || s_maskTexH != vph) {
        while (glGetError() != GL_NO_ERROR) {
        }
        glPixelStorei(GL_UNPACK_ALIGNMENT, 4);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, vpw, vph, 0, GL_RGBA, GL_UNSIGNED_BYTE, s_maskPx.data());
        GLenum eAlloc = glGetError();
        if (eAlloc != GL_NO_ERROR) {
            OH_LOG_Print(LOG_APP, LOG_ERROR, 0x0000, "PetGL",
                "MaskAlloc err=0x%{public}x size=%{public}dx%{public}d", (int)eAlloc, vpw, vph);
        }
        s_maskTexW = vpw;
        s_maskTexH = vph;
    } else {
        for (size_t p = 0; p < s_upMasks.size(); p += 4) {
            int x0 = s_upMasks[p], y0 = s_upMasks[p + 1], x1 = s_upMasks[p + 2], y1 = s_upMasks[p + 3];
            if (x1 <= x0 || y1 <= y0) {
                continue;
            }
            glPixelStorei(GL_UNPACK_ALIGNMENT, 4);
            for (int cy = y0; cy < y1; cy++) {
                glTexSubImage2D(GL_TEXTURE_2D, 0, x0, cy, x1 - x0, 1, GL_RGBA, GL_UNSIGNED_BYTE,
                    s_maskPx.data() + ((size_t)cy * vpw + x0) * 4);
            }
        }
    }
    glActiveTexture(GL_TEXTURE0);
    // GL 错误检查（纹理上传后）
    {
        static int s_glErrN = 0;
        GLenum e = glGetError();
        if (e != GL_NO_ERROR && s_glErrN < 5) {
            s_glErrN++;
            OH_LOG_Print(LOG_APP, LOG_ERROR, 0x0000, "PetGL", "glError 0x%{public}x", (int)e);
        }
    }
    // 顶点填充：全部三角形直传（裁剪交给着色器掩码丢弃）
    static std::vector<float> s_vtx;
    size_t need = (size_t)triCount * 24;
    if (s_vtx.size() < need) {
        s_vtx.resize(need);
    }
    float* vp = s_vtx.data();
    for (int t = 0; t < triCount; t++) {
        const double* b = tris + (size_t)t * 12;
        const double* c = colors + (size_t)t * 5;
        float r = (float)c[0], g = (float)c[1], bl = (float)c[2], a = (float)c[3];
        float* o = vp + (size_t)t * 24;
        o[0] = (float)b[0]; o[1] = (float)b[1];
        o[2] = (float)b[6]; o[3] = (float)b[7];
        o[4] = r; o[5] = g; o[6] = bl; o[7] = a;
        o[8] = (float)b[2]; o[9] = (float)b[3];
        o[10] = (float)b[8]; o[11] = (float)b[9];
        o[12] = r; o[13] = g; o[14] = bl; o[15] = a;
        o[16] = (float)b[4]; o[17] = (float)b[5];
        o[18] = (float)b[10]; o[19] = (float)b[11];
        o[20] = r; o[21] = g; o[22] = bl; o[23] = a;
    }
    glBindBuffer(GL_ARRAY_BUFFER, g_vbo);
    glBufferData(GL_ARRAY_BUFFER, (GLsizeiptr)(need * sizeof(float)), s_vtx.data(), GL_STREAM_DRAW);
    // 按（混合模式, 裁剪段）刷运行：裁剪段经着色器掩码丢弃
    int runStart = 0;
    int runBlend = -1;
    int runFlag = -2;
    for (int t = 0; t < triCount; t++) {
        int blend = (int)colors[(size_t)t * 5 + 4];
        int flag = flags[t];
        if (runBlend != blend || runFlag != flag) {
            if (runBlend >= 0) {
                draw_run(runStart, t * 3 - runStart, runBlend, runFlag + 1);
            }
            runStart = t * 3;
            runBlend = blend;
            runFlag = flag;
        }
    }
    if (runBlend >= 0) {
        draw_run(runStart, triCount * 3 - runStart, runBlend, runFlag + 1);
    }
    eglSwapBuffers(g_eglDisplay, g_eglSurface);
    return nullptr;
}

// EGL 初始化（在 init_surface 建窗后调用一次）
static bool InitGL(OHNativeWindow* win) {
    g_eglDisplay = eglGetDisplay(EGL_DEFAULT_DISPLAY);
    if (g_eglDisplay == EGL_NO_DISPLAY) {
        OH_LOG_Print(LOG_APP, LOG_ERROR, 0x0000, "PetGL", "eglGetDisplay fail");
        return false;
    }
    EGLint maj = 0, min = 0;
    if (!eglInitialize(g_eglDisplay, &maj, &min)) {
        OH_LOG_Print(LOG_APP, LOG_ERROR, 0x0000, "PetGL", "eglInitialize fail err=%{public}d",
            (int)eglGetError());
        return false;
    }
    EGLint cfgAttr[] = {
        EGL_SURFACE_TYPE, EGL_WINDOW_BIT,
        EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
        EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8,
        EGL_ALPHA_SIZE, 8, EGL_STENCIL_SIZE, 8,
        EGL_NONE
    };
    EGLConfig cfg = nullptr;
    EGLint cfgN = 0;
    if (!eglChooseConfig(g_eglDisplay, cfgAttr, &cfg, 1, &cfgN) || cfgN == 0) {
        OH_LOG_Print(LOG_APP, LOG_ERROR, 0x0000, "PetGL", "eglChooseConfig fail err=%{public}d",
            (int)eglGetError());
        return false;
    }
    EGLint ctxAttr[] = { EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE };
    g_eglContext = eglCreateContext(g_eglDisplay, cfg, EGL_NO_CONTEXT, ctxAttr);
    if (g_eglContext == EGL_NO_CONTEXT) {
        OH_LOG_Print(LOG_APP, LOG_ERROR, 0x0000, "PetGL", "eglCreateContext fail err=%{public}d",
            (int)eglGetError());
        return false;
    }
    g_eglSurface = eglCreateWindowSurface(g_eglDisplay, cfg, (EGLNativeWindowType)win, nullptr);
    if (g_eglSurface == EGL_NO_SURFACE) {
        OH_LOG_Print(LOG_APP, LOG_ERROR, 0x0000, "PetGL", "eglCreateWindowSurface fail err=%{public}d",
            (int)eglGetError());
        return false;
    }
    if (!eglMakeCurrent(g_eglDisplay, g_eglSurface, g_eglSurface, g_eglContext)) {
        OH_LOG_Print(LOG_APP, LOG_ERROR, 0x0000, "PetGL", "eglMakeCurrent fail err=%{public}d",
            (int)eglGetError());
        return false;
    }
    GLuint vs = compile_shader(GL_VERTEX_SHADER, VS_SRC);
    GLuint fs = compile_shader(GL_FRAGMENT_SHADER, FS_SRC);
    if (vs == 0 || fs == 0) {
        return false;
    }
    g_program = glCreateProgram();
    glAttachShader(g_program, vs);
    glAttachShader(g_program, fs);
    glLinkProgram(g_program);
    GLint ok = 0;
    glGetProgramiv(g_program, GL_LINK_STATUS, &ok);
    if (!ok) {
        char log[512] = { 0 };
        glGetProgramInfoLog(g_program, sizeof(log) - 1, nullptr, log);
        OH_LOG_Print(LOG_APP, LOG_ERROR, 0x0000, "PetGL", "link fail: %{public}s", log);
        return false;
    }
    g_uViewportLoc = glGetUniformLocation(g_program, "u_viewport");
    g_uClipIdLoc = glGetUniformLocation(g_program, "u_clipId");
    g_uTexLoc = glGetUniformLocation(g_program, "u_tex");
    g_uMaskLoc = glGetUniformLocation(g_program, "u_mask");
    glUniform1i(g_uTexLoc, 0);
    glUniform1i(g_uMaskLoc, 1);
    glGenBuffers(1, &g_vbo);
    glGenBuffers(1, &g_clipVbo);
    glGenTextures(1, &g_texId);
    glGenTextures(1, &g_maskTex);
    glBindTexture(GL_TEXTURE_2D, g_maskTex);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glBindTexture(GL_TEXTURE_2D, g_texId);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glDisable(GL_DEPTH_TEST);
    glDisable(GL_CULL_FACE);
    g_glReady = true;
    return true;
}

// ── XComponent 表面直写显示（终局显示链路：无 PixelMap/无 @State/无 Image 管线） ──

static void OnSurfaceCreatedCB(OH_NativeXComponent* component, void* window) {
    g_win = static_cast<OHNativeWindow*>(window);
    OH_NativeXComponent_GetXComponentSize(component, g_win, &g_winW, &g_winH);
    OH_NativeWindow_NativeWindowHandleOpt(g_win, SET_BUFFER_GEOMETRY, g_winW, g_winH);
    OH_NativeWindow_NativeWindowHandleOpt(g_win, SET_FORMAT, NATIVEBUFFER_PIXEL_FMT_RGBA_8888);
    uint64_t usage = NATIVEBUFFER_USAGE_CPU_READ | NATIVEBUFFER_USAGE_CPU_WRITE | NATIVEBUFFER_USAGE_MEM_DMA;
    OH_NativeWindow_NativeWindowHandleOpt(g_win, SET_USAGE, usage);
}

static void OnSurfaceChangedCB(OH_NativeXComponent* component, void* window) {
    if (g_win != nullptr) {
        OH_NativeXComponent_GetXComponentSize(component, g_win, &g_winW, &g_winH);
    }
}

static void OnSurfaceDestroyedCB(OH_NativeXComponent* component, void* window) {
    g_win = nullptr;
}

static void OnDispatchTouchEventCB(OH_NativeXComponent* component, void* window) {
    // 触摸事件由 ArkTS 侧手势系统处理，native 侧不消费
}

static OH_NativeXComponent_Callback g_xcCallback = {
    OnSurfaceCreatedCB, OnSurfaceChangedCB, OnSurfaceDestroyedCB, OnDispatchTouchEventCB
};

// XComponent(libraryname: 'raster') 加载本 so 时框架自动调用：注册表面生命周期回调。
// 实测本机该机制未被调用（黑框根因），已改用 init_surface(surfaceId) 主动创建窗口；此处保留作回退。
extern "C" void OH_NativeXComponent_Export(OH_NativeXComponent* component, void* exportObj) {
    OH_NativeXComponent_RegisterCallback(component, &g_xcCallback);
}

// 主动建窗：ArkTS onLoad 里把 getXComponentSurfaceId() 传进来，
// 由 surfaceId 创建 OHNativeWindow（不依赖框架的 Export 回调链路）。
static napi_value InitSurface(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = { nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1) {
        return nullptr;
    }
    size_t len = 0;
    napi_get_value_string_utf8(env, args[0], nullptr, 0, &len);
    std::vector<char> idBuf(len + 1);
    napi_get_value_string_utf8(env, args[0], idBuf.data(), len + 1, &len);
    uint64_t sid = strtoull(idBuf.data(), nullptr, 10);
    OHNativeWindow* win = nullptr;
    int32_t ret = OH_NativeWindow_CreateNativeWindowFromSurfaceId(sid, &win);
    if (ret != 0 || win == nullptr) {
        OH_LOG_Print(LOG_APP, LOG_ERROR, 0x0000, "PetNative",
            "CreateNativeWindowFromSurfaceId ret=%{public}d id=%{public}s", ret, idBuf.data());
        return nullptr;
    }
    g_win = win;
    // 表面像素尺寸（默认缓冲几何即表面尺寸）；缓冲几何随后由渲染帧按光栅分辨率设定
    int32_t sw = 0, sh = 0;
    OH_NativeWindow_NativeWindowHandleOpt(win, GET_BUFFER_GEOMETRY, &sw, &sh);
    g_winW = (uint64_t)(sw > 0 ? sw : 0);
    g_winH = (uint64_t)(sh > 0 ? sh : 0);
    int32_t r2 = OH_NativeWindow_NativeWindowHandleOpt(win, SET_FORMAT, NATIVEBUFFER_PIXEL_FMT_RGBA_8888);
    uint64_t usage = NATIVEBUFFER_USAGE_CPU_READ | NATIVEBUFFER_USAGE_CPU_WRITE | NATIVEBUFFER_USAGE_MEM_DMA;
    int32_t r3 = OH_NativeWindow_NativeWindowHandleOpt(win, SET_USAGE, usage);
    // 本调用运行在 UI 线程（onLoad）：给 UI 线程提 QoS 到 USER_INTERACTIVE，
    // 尝试对抗周期性 DVFS 降频/让核（同样的工作耗时周期性翻 2.3 倍，实测现象）
    OH_QoS_SetThreadQoS(QOS_USER_INTERACTIVE);
    // GPU 后端初始化（TEXTURE 型 XComponent + EGL）
    InitGL(win);
    return nullptr;
}

// 每帧复用紧凑暂存（视窗缓冲 stride 可能大于 w*4）
static std::vector<uint8_t> s_frame;

// 上屏：ArkTS 收集（vp 坐标）→ C++ 光栅化（rasterScale 分辨率，与表面解耦）→
// 放大写入视窗缓冲（预乘 RGBA）→ Flush。零 PixelMap/零 @State/零 Image 管线。
static napi_value RenderFrameToWindow(napi_env env, napi_callback_info info) {
    size_t argc = 13;
    napi_value args[13] = { nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 13) {
        return nullptr;
    }
    double* tris = nullptr; size_t trisLen = 0;
    napi_get_arraybuffer_info(env, args[0], (void**)&tris, &trisLen);
    double* colors = nullptr; size_t colorsLen = 0;
    napi_get_arraybuffer_info(env, args[1], (void**)&colors, &colorsLen);
    int32_t* flags = nullptr; size_t flagsLen = 0;
    napi_get_arraybuffer_info(env, args[2], (void**)&flags, &flagsLen);
    int32_t triCount = 0;
    napi_get_value_int32(env, args[3], &triCount);
    double* segFlat = nullptr; size_t segFlatLen = 0;
    napi_get_arraybuffer_info(env, args[4], (void**)&segFlat, &segFlatLen);
    int32_t* segSizes = nullptr; size_t segSizesLen = 0;
    napi_get_arraybuffer_info(env, args[5], (void**)&segSizes, &segSizesLen);
    int32_t segCount = 0;
    napi_get_value_int32(env, args[6], &segCount);
    uint8_t* tex = nullptr; size_t texLen = 0;
    napi_get_arraybuffer_info(env, args[7], (void**)&tex, &texLen);
    int32_t texW = 0, texH = 0;
    napi_get_value_int32(env, args[8], &texW);
    napi_get_value_int32(env, args[9], &texH);
    double vpW = 1.0, vpH = 1.0, rasterScale = 1.0;
    napi_get_value_double(env, args[10], &vpW);
    napi_get_value_double(env, args[11], &vpH);
    napi_get_value_double(env, args[12], &rasterScale);
    if (g_win == nullptr || g_winW == 0 || g_winH == 0 || triCount <= 0) {
        return nullptr;
    }
    if (rasterScale < 0.25) {
        rasterScale = 1.0;
    }
    // 光栅分辨率与表面解耦：缓冲几何设为 vp×rasterScale，RS 负责缓冲→表面缩放。
    // rasterScale=设备密度 → 缓冲即表面像素（1:1 物理清晰度，光栅最贵）；
    // 小值 → 低分辨率光栅 + RS 放大（省光栅像素）。
    int rw = (int)(vpW * rasterScale + 0.5);
    int rh = (int)(vpH * rasterScale + 0.5);
    if (rw < 1) rw = 1;
    if (rh < 1) rh = 1;
    static int s_geomW = 0;
    static int s_geomH = 0;
    if (s_geomW != rw || s_geomH != rh) {
        OH_NativeWindow_NativeWindowHandleOpt(g_win, SET_BUFFER_GEOMETRY, rw, rh);
        s_geomW = rw;
        s_geomH = rh;
        OH_LOG_Print(LOG_APP, LOG_INFO, 0x0000, "PetNative",
            "SetGeometry %{public}dx%{public}d surface=%{public}llux%{public}llu",
            rw, rh, (unsigned long long)g_winW, (unsigned long long)g_winH);
    }
    if (s_frame.size() < (size_t)rw * rh * 4) {
        s_frame.resize((size_t)rw * rh * 4);
    }
    uint8_t* frame = s_frame.data();
    // vp 空间三角形并集包围盒（光栅清屏区与物理写入区都由它推导）
    double bbX0 = 1e30, bbY0 = 1e30, bbX1 = -1e30, bbY1 = -1e30;
    for (int t = 0; t < triCount; t++) {
        const double* b = tris + (size_t)t * 12;
        double mx0 = b[0] < b[2] ? b[0] : b[2];
        double mx1 = b[0] > b[2] ? b[0] : b[2];
        double my0 = b[1] < b[3] ? b[1] : b[3];
        double my1 = b[1] > b[3] ? b[1] : b[3];
        if (b[4] < mx0) mx0 = b[4];
        if (b[4] > mx1) mx1 = b[4];
        if (b[5] < my0) my0 = b[5];
        if (b[5] > my1) my1 = b[5];
        if (mx0 < bbX0) bbX0 = mx0;
        if (my0 < bbY0) bbY0 = my0;
        if (mx1 > bbX1) bbX1 = mx1;
        if (my1 > bbY1) bbY1 = my1;
    }
    // 与上一帧包围盒取并集（角色移动后旧位置也要清，防残影）
    static double s_pbx[4] = { 0, 0, 0, 0 };
    static bool s_hasPrev = false;
    if (s_hasPrev) {
        if (s_pbx[0] < bbX0) bbX0 = s_pbx[0];
        if (s_pbx[1] < bbY0) bbY0 = s_pbx[1];
        if (s_pbx[2] > bbX1) bbX1 = s_pbx[2];
        if (s_pbx[3] > bbY1) bbY1 = s_pbx[3];
    }
    if (!(bbX0 < bbX1 && bbY0 < bbY1)) {
        std::memset(frame, 0, (size_t)rw * rh * 4);
        s_hasPrev = false;
    } else {
        s_pbx[0] = bbX0; s_pbx[1] = bbY0; s_pbx[2] = bbX1; s_pbx[3] = bbY1;
        s_hasPrev = true;
        int rx0 = (int)std::floor(bbX0 * rasterScale);
        int ry0 = (int)std::floor(bbY0 * rasterScale);
        int rx1 = (int)std::ceil(bbX1 * rasterScale);
        int ry1 = (int)std::ceil(bbY1 * rasterScale);
        if (rx0 < 0) rx0 = 0;
        if (ry0 < 0) ry0 = 0;
        if (rx1 > rw) rx1 = rw;
        if (ry1 > rh) ry1 = rh;
        for (int cy = ry0; cy < ry1; cy++) {
            std::memset(frame + ((size_t)cy * rw + rx0) * 4, 0, (size_t)(rx1 - rx0) * 4);
        }
    }
    // 三角形坐标缩放（vp → 光栅空间）；缩放缓冲每帧复用（不 malloc）
    static std::vector<double> s_scaled;
    if (s_scaled.size() < (size_t)triCount * 12) {
        s_scaled.resize((size_t)triCount * 12);
    }
    double* scaled = s_scaled.data();
    for (int t = 0; t < triCount; t++) {
        const double* b = tris + (size_t)t * 12;
        double* o = scaled + (size_t)t * 12;
        o[0] = b[0] * rasterScale; o[1] = b[1] * rasterScale;
        o[2] = b[2] * rasterScale; o[3] = b[3] * rasterScale;
        o[4] = b[4] * rasterScale; o[5] = b[5] * rasterScale;
        o[6] = b[6]; o[7] = b[7]; o[8] = b[8]; o[9] = b[9];
        o[10] = b[10]; o[11] = b[11];
    }
    // napi_get_arraybuffer_info 返回字节数；segFlat 元素是 double，除以 8
    size_t segElemN = segFlatLen / 8;
    static std::vector<double> s_segScaled;
    if (s_segScaled.size() < segElemN) {
        s_segScaled.resize(segElemN);
    }
    for (size_t i = 0; i < segElemN; i += 2) {
        s_segScaled[i] = segFlat[i] * rasterScale;
        s_segScaled[i + 1] = segFlat[i + 1] * rasterScale;
    }
    static std::vector<uint8_t> s_tmp;
    static std::vector<ClipMask> s_masks;
    static std::vector<uint8_t> s_mask_mem;
    static size_t s_mask_off = 0;
    size_t planeBytes = (size_t)rw * rh * 4;
    if (s_tmp.size() < planeBytes) {
        s_tmp.resize(planeBytes);
    }
    uint8_t* tmp = s_tmp.data();
    if ((int)s_masks.size() < segCount) {
        s_masks.resize((size_t)segCount);
    }
    ClipMask* masks = s_masks.data();
    s_mask_off = 0;
    size_t maskNeed = (size_t)rw * rh;
    const double* segOff = s_segScaled.data();
    auto tp0 = std::chrono::steady_clock::now();
    for (int s = 0; s < segCount; s++) {
        if (s_mask_off + maskNeed > s_mask_mem.size()) {
            s_mask_mem.resize(s_mask_off + maskNeed + 256 * 1024);
        }
        polygon_mask(segOff, segSizes[s], rw, rh, masks[s], s_mask_mem.data() + s_mask_off);
        s_mask_off += maskNeed;
        segOff += (size_t)segSizes[s] * 2;
    }
    auto tp1 = std::chrono::steady_clock::now();
    int curSeg = -1;
    for (int t = 0; t < triCount; t++) {
        int b = t * 12;
        int flag = flags[t];
        uint8_t* target = nullptr;
        if (flag >= 0) {
            if (curSeg != flag) {
                if (curSeg >= 0) {
                    composite_over_pm(frame, tmp, masks[curSeg], rw);
                    clear_bbox(tmp, rw, masks[flag]);
                }
                curSeg = flag;
            }
            target = tmp;
        } else {
            if (curSeg >= 0) {
                composite_over_pm(frame, tmp, masks[curSeg], rw);
                clear_bbox(tmp, rw, masks[curSeg]);
                curSeg = -1;
            }
            target = frame;
        }
        int cb = t * 5;
        int blendMode = (int)colors[cb + 4];
        // 加法混合多为大面积低频特效（发光等），最近邻采样视觉无差但省 4 纹素插值
        int bil = blendMode == 1 ? 0 : 1;
        rasterize_triangle_t<true>(target, rw, rh, tex, texW, texH, texLen,
            scaled[b], scaled[b + 1], scaled[b + 2], scaled[b + 3],
            scaled[b + 4], scaled[b + 5],
            scaled[b + 6], scaled[b + 7], scaled[b + 8], scaled[b + 9],
            scaled[b + 10], scaled[b + 11],
            colors[cb], colors[cb + 1], colors[cb + 2], colors[cb + 3], blendMode, bil);
    }
    if (curSeg >= 0) {
        composite_over_pm(frame, tmp, masks[curSeg], rw);
    }
    auto tp2 = std::chrono::steady_clock::now();
    // 写入区 = vp 包围盒映射到光栅空间（±2px 余量）；区外缓冲保持原状（透明）
    int px0 = 0, py0 = 0, px1 = rw, py1 = rh;
    if (s_hasPrev) {
        px0 = (int)std::floor(bbX0 * rasterScale) - 2;
        py0 = (int)std::floor(bbY0 * rasterScale) - 2;
        px1 = (int)std::ceil(bbX1 * rasterScale) + 2;
        py1 = (int)std::ceil(bbY1 * rasterScale) + 2;
        if (px0 < 0) px0 = 0;
        if (py0 < 0) py0 = 0;
        if (px1 > rw) px1 = rw;
        if (py1 > rh) py1 = rh;
    }
    OHNativeWindowBuffer* buffer = nullptr;
    int fenceFd = 0;
    if (OH_NativeWindow_NativeWindowRequestBuffer(g_win, &buffer, &fenceFd) != 0 || buffer == nullptr) {
        return nullptr;
    }
    BufferHandle* bh = OH_NativeWindow_GetBufferHandleFromNative(buffer);
    uint32_t* dst = static_cast<uint32_t*>(
        mmap(bh->virAddr, bh->size, PROT_READ | PROT_WRITE, MAP_SHARED, bh->fd, 0));
    if (dst == MAP_FAILED) {
        return nullptr;
    }
    static bool s_loggedOnce = false;
    if (!s_loggedOnce) {
        s_loggedOnce = true;
        OH_LOG_Print(LOG_APP, LOG_INFO, 0x0000, "PetNative",
            "FirstFrame raster=%{public}dx%{public}d scale=%{public}.2f vp=%{public}.0fx%{public}.0f buf=%{public}dx%{public}d stride=%{public}d fmt=%{public}d size=%{public}d",
            rw, rh, rasterScale, vpW, vpH,
            (int)bh->width, (int)bh->height, (int)bh->stride, (int)bh->format, (int)bh->size);
    }
    // 首次拿到的缓冲整面清透明（gralloc 缓冲初值不确定；此后只写包围盒区）
    static std::vector<void*> s_seen;
    bool seen = false;
    for (size_t i = 0; i < s_seen.size(); i++) {
        if (s_seen[i] == buffer) {
            seen = true;
            break;
        }
    }
    if (!seen) {
        s_seen.push_back(buffer);
        std::memset(dst, 0, bh->size);
    }
    uint32_t strideWords = bh->stride / 4;
    // 1:1 拷贝（缓冲即光栅空间；RS 负责缓冲→表面缩放）。几何设置失败时钳制防越界。
    int cx1 = px1;
    if (cx1 > (int)bh->width) cx1 = (int)bh->width;
    int cy1 = py1;
    if (cy1 > (int)bh->height) cy1 = (int)bh->height;
    uint32_t maxA = 0;
    uint32_t maxRGB = 0;
    // 光栅缓冲已是预乘 RGBA，仅做字节序拷贝（小端内存序 = RGBA）
    for (int y = py0; y < cy1; y++) {
        const uint8_t* src = frame + (size_t)y * rw * 4;
        uint32_t* row = dst + (size_t)y * strideWords;
        for (int x = px0; x < cx1; x++) {
            if (src[x * 4 + 3] > maxA) maxA = src[x * 4 + 3];
            if (src[x * 4] > maxRGB) maxRGB = src[x * 4];
            if (src[x * 4 + 1] > maxRGB) maxRGB = src[x * 4 + 1];
            if (src[x * 4 + 2] > maxRGB) maxRGB = src[x * 4 + 2];
            row[x] = (uint32_t)src[x * 4] | ((uint32_t)src[x * 4 + 1] << 8) |
                     ((uint32_t)src[x * 4 + 2] << 16) | ((uint32_t)src[x * 4 + 3] << 24);
        }
    }
    munmap(dst, bh->size);
    Region region{ nullptr, 0 };
    OH_NativeWindow_NativeWindowFlushBuffer(g_win, buffer, fenceFd, region);
    auto tp3 = std::chrono::steady_clock::now();
    // 分段计时：每 60 帧汇总一次（定位周期性卡顿在哪个阶段）
    static long long s_accMask = 0, s_accRast = 0, s_accWrite = 0;
    static long long s_accMaskMax = 0, s_accRastMax = 0, s_accWriteMax = 0;
    static int s_accN = 0;
    static int s_maxSegs = 0;
    long long maskUs = std::chrono::duration_cast<std::chrono::microseconds>(tp1 - tp0).count();
    long long rastUs = std::chrono::duration_cast<std::chrono::microseconds>(tp2 - tp1).count();
    long long writeUs = std::chrono::duration_cast<std::chrono::microseconds>(tp3 - tp2).count();
    s_accMask += maskUs;
    s_accRast += rastUs;
    s_accWrite += writeUs;
    if (maskUs > s_accMaskMax) s_accMaskMax = maskUs;
    if (rastUs > s_accRastMax) s_accRastMax = rastUs;
    if (writeUs > s_accWriteMax) s_accWriteMax = writeUs;
    if (segCount > s_maxSegs) s_maxSegs = segCount;
    static uint32_t s_maxA = 0;
    static uint32_t s_maxRGB = 0;
    static int32_t s_fenceFd = -2;
    if (maxA > s_maxA) s_maxA = maxA;
    if (maxRGB > s_maxRGB) s_maxRGB = maxRGB;
    s_fenceFd = fenceFd;
    s_accN++;
    if (s_accN >= 60) {
        OH_LOG_Print(LOG_APP, LOG_INFO, 0x0000, "PetNative",
            "Phase avg(mask=%{public}lld rast=%{public}lld write=%{public}lld)us max(mask=%{public}lld rast=%{public}lld write=%{public}lld)us tris=%{public}d segs=%{public}d blendPx(norm=%{public}llu add=%{public}llu mul=%{public}llu scr=%{public}llu) fence=%{public}d",
            s_accMask / s_accN, s_accRast / s_accN, s_accWrite / s_accN,
            s_accMaskMax, s_accRastMax, s_accWriteMax, triCount, segCount,
            (unsigned long long)g_blendPx[0], (unsigned long long)g_blendPx[1],
            (unsigned long long)g_blendPx[2], (unsigned long long)g_blendPx[3], s_fenceFd);
        s_accMask = 0;
        s_accRast = 0;
        s_accWrite = 0;
        s_accMaskMax = 0;
        s_accRastMax = 0;
        s_accWriteMax = 0;
        s_accN = 0;
        s_maxSegs = 0;
        s_maxA = 0;
        s_maxRGB = 0;
        s_fenceFd = -2;
        g_blendPx[0] = 0;
        g_blendPx[1] = 0;
        g_blendPx[2] = 0;
        g_blendPx[3] = 0;
    }
    return nullptr;
}

// 整帧光栅化（含裁剪段）。args 全部零拷贝。
// tris: 每三角 12 个 double（屏幕坐标 x0,y0,... u0,v0,...）；colors: 每三角 5 个 double（r,g,b,a,blend）
// flags: 每三角裁剪段 id（-1=普通）；segFlat/segSizes: 各裁剪段多边形顶点（每顶点 2 个 double）与顶点数
static napi_value RasterizeFrame(napi_env env, napi_callback_info info) {
    size_t argc = 14;
    napi_value args[14] = { nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    double* tris = nullptr; size_t trisLen = 0;
    napi_get_arraybuffer_info(env, args[0], (void**)&tris, &trisLen);
    double* colors = nullptr; size_t colorsLen = 0;
    napi_get_arraybuffer_info(env, args[1], (void**)&colors, &colorsLen);
    int32_t* flags = nullptr; size_t flagsLen = 0;
    napi_get_arraybuffer_info(env, args[2], (void**)&flags, &flagsLen);
    int32_t triCount = 0;
    napi_get_value_int32(env, args[3], &triCount);
    double* segFlat = nullptr; size_t segFlatLen = 0;
    napi_get_arraybuffer_info(env, args[4], (void**)&segFlat, &segFlatLen);
    int32_t* segSizes = nullptr; size_t segSizesLen = 0;
    napi_get_arraybuffer_info(env, args[5], (void**)&segSizes, &segSizesLen);
    int32_t segCount = 0;
    napi_get_value_int32(env, args[6], &segCount);
    uint8_t* tex = nullptr; size_t texLen = 0;
    napi_get_arraybuffer_info(env, args[7], (void**)&tex, &texLen);
    int32_t texW = 0, texH = 0;
    napi_get_value_int32(env, args[8], &texW);
    napi_get_value_int32(env, args[9], &texH);
    uint8_t* out = nullptr; size_t outLen = 0;
    napi_get_arraybuffer_info(env, args[10], (void**)&out, &outLen);
    int32_t w = 0, h = 0;
    napi_get_value_int32(env, args[11], &w);
    napi_get_value_int32(env, args[12], &h);
    int32_t bilinear = 0;
    napi_get_value_int32(env, args[13], &bilinear);

    // 只清零三角形并集包围盒（1000vp 级画布全清每帧浪费数 MB 内存带宽）
    {
        double bbX0 = 1e30, bbY0 = 1e30, bbX1 = -1e30, bbY1 = -1e30;
        for (int t = 0; t < triCount; t++) {
            const double* b = tris + (size_t)t * 12;
            double mx0 = b[0] < b[2] ? b[0] : b[2];
            double mx1 = b[0] > b[2] ? b[0] : b[2];
            double my0 = b[1] < b[3] ? b[1] : b[3];
            double my1 = b[1] > b[3] ? b[1] : b[3];
            if (b[4] < mx0) mx0 = b[4];
            if (b[4] > mx1) mx1 = b[4];
            if (b[5] < my0) my0 = b[5];
            if (b[5] > my1) my1 = b[5];
            if (mx0 < bbX0) bbX0 = mx0;
            if (my0 < bbY0) bbY0 = my0;
            if (mx1 > bbX1) bbX1 = mx1;
            if (my1 > bbY1) bbY1 = my1;
        }
        // 与上一帧包围盒取并集（角色移动后旧位置也要清，防残影）
        static int s_px0 = -1, s_py0 = -1, s_px1 = -1, s_py1 = -1;
        if (s_px0 >= 0) {
            if (s_px0 < bbX0) bbX0 = s_px0;
            if (s_py0 < bbY0) bbY0 = s_py0;
            if (s_px1 > bbX1) bbX1 = s_px1;
            if (s_py1 > bbY1) bbY1 = s_py1;
        }
        if (bbX0 < bbX1 && bbY0 < bbY1) {
            int cx0 = (int)std::floor(bbX0);
            int cx1 = (int)std::ceil(bbX1);
            int cy0 = (int)std::floor(bbY0);
            int cy1 = (int)std::ceil(bbY1);
            if (cx0 < 0) cx0 = 0;
            if (cy0 < 0) cy0 = 0;
            if (cx1 > w) cx1 = w;
            if (cy1 > h) cy1 = h;
            for (int cy = cy0; cy < cy1; cy++) {
                std::memset(out + ((size_t)cy * w + cx0) * 4, 0, (size_t)(cx1 - cx0) * 4);
            }
            s_px0 = cx0; s_py0 = cy0; s_px1 = cx1; s_py1 = cy1;
        } else {
            std::memset(out, 0, outLen);
            s_px0 = -1; s_py0 = -1; s_px1 = -1; s_py1 = -1;
        }
    }
    // 每帧复用（避免 malloc/free 抖动——ArkTS GC 卡顿的同款思路，native 侧一并治理）
    static std::vector<uint8_t> s_tmp;
    static std::vector<ClipMask> s_masks;
    static std::vector<uint8_t> s_mask_mem;
    static size_t s_mask_off = 0;
    if (s_tmp.size() < outLen) {
        s_tmp.resize(outLen);
    }
    uint8_t* tmp = s_tmp.data();
    if ((int)s_masks.size() < segCount) {
        s_masks.resize((size_t)segCount);
    }
    ClipMask* masks = s_masks.data();
    s_mask_off = 0;
    size_t maskNeed = (size_t)w * h;
    const double* segOff = segFlat;
    for (int s = 0; s < segCount; s++) {
        if (s_mask_off + maskNeed > s_mask_mem.size()) {
            s_mask_mem.resize(s_mask_off + maskNeed + 256 * 1024);
        }
        polygon_mask(segOff, segSizes[s], w, h, masks[s], s_mask_mem.data() + s_mask_off);
        s_mask_off += maskNeed;
        segOff += (size_t)segSizes[s] * 2;
    }
    int curSeg = -1;
    for (int t = 0; t < triCount; t++) {
        int b = t * 12;
        int flag = flags[t];
        uint8_t* target = nullptr;
        if (flag >= 0) {
            if (curSeg != flag) {
                if (curSeg >= 0) {
                    composite_over(out, tmp, masks[curSeg], w);
                    clear_bbox(tmp, w, masks[flag]);
                }
                curSeg = flag;
            }
            target = tmp;
        } else {
            if (curSeg >= 0) {
                composite_over(out, tmp, masks[curSeg], w);
                clear_bbox(tmp, w, masks[curSeg]);
                curSeg = -1;
            }
            target = out;
        }
        int cb = t * 5;
        rasterize_triangle_t<false>(target, w, h, tex, texW, texH, texLen,
            tris[b], tris[b + 1], tris[b + 2], tris[b + 3], tris[b + 4], tris[b + 5],
            tris[b + 6], tris[b + 7], tris[b + 8], tris[b + 9], tris[b + 10], tris[b + 11],
            colors[cb], colors[cb + 1], colors[cb + 2], colors[cb + 3], (int)colors[cb + 4],
            bilinear);
    }
    if (curSeg >= 0) {
        composite_over(out, tmp, masks[curSeg], w);
    }
    return nullptr;
}

// 直通 alpha → 预乘 alpha（帧 PixelMap 声明 PREMUL，必须喂预乘数据——A/B 实证）。
// 整数乘法 + 舍入，比 ArkTS 的 Math.round 循环快约两个数量级。
static napi_value PremultiplyRgba(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = { nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    uint8_t* buf = nullptr;
    size_t len = 0;
    napi_get_arraybuffer_info(env, args[0], (void**)&buf, &len);
    for (size_t i = 0; i + 3 < len; i += 4) {
        uint32_t a = buf[i + 3];
        buf[i] = (uint8_t)((buf[i] * a + 127) / 255);
        buf[i + 1] = (uint8_t)((buf[i + 1] * a + 127) / 255);
        buf[i + 2] = (uint8_t)((buf[i + 2] * a + 127) / 255);
    }
    return nullptr;
}

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
        { "rasterize_frame", nullptr, RasterizeFrame, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "premultiply_rgba", nullptr, PremultiplyRgba, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "render_frame_to_window", nullptr, RenderFrameToWindow, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "render_frame_gl", nullptr, RenderFrameGL, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "init_surface", nullptr, InitSurface, nullptr, nullptr, nullptr, napi_default, nullptr }
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}
EXTERN_C_END

static napi_module rasterModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "raster",
    .nm_priv = nullptr,
    .reserved = { 0 },
};

extern "C" __attribute__((constructor)) void RegisterRasterModule(void) {
    napi_module_register(&rasterModule);
}
