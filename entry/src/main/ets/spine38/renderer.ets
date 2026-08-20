/**
 * Spine 3.8 CPU 光栅化渲染器 — 移植自 spine38/renderer.py + rasterize_fast.py（v2.0 成熟路线）。
 * 逐三角形重心坐标光栅化 + 四种混合 + 多边形裁剪掩码（偶数奇数规则）。
 * 架构定论（2026-08-15 实证）：ArkUI Canvas 逐三角形 clip+transform+drawImage 会每 op
 * 重传整张纹理（2000 三角形 ≈ 4.5GB GPU）→ render_service 击杀。CPU 光栅化每帧一张图，
 * 显示侧仅一次 drawImage。纹理需在加载时反预乘（wiki PNG 是预乘 alpha）。
 */
import {
  Skeleton, compute_region_vertices, compute_mesh_vertices
} from './skeleton'
import {
  Attachment, RegionAttachment, MeshAttachment, ClippingAttachment, AtlasRegion
} from './loader'
import { AtlasPage } from './atlas'
import { clipAttachmentPolys, clipTriangleToPolys } from './clipping'
import { rasterize_frame, premultiply_rgba } from 'libraster.so'

export class RenderTransform {
  scale: number = 1.0
  tx: number = 0.0
  ty: number = 0.0
  height: number = 0 // 画布像素高度（y 翻转用）
  stats: number[] = [0, 0, 0] // [顶点计算 ms, 光栅化 ms, 三角形数]（调试用）
}

export class Texture {
  width: number = 0
  height: number = 0
  pixels: Uint8Array = new Uint8Array(0) // RGBA（直通 alpha）
  debug: string = ''
}

// 单三角形扫描线光栅化（最近邻采样；blend: 0=normal 1=additive 2=multiply 3=screen）。
// 顶点按 y 排序 → 逐行求左右边界 → 行内增量插值 UV（仿射变换下屏幕空间线性插值精确）。
export function rasterize_triangle(out: Uint8Array, w: number, h: number, tex: Texture,
  t0x: number, t0y: number, t1x: number, t1y: number, t2x: number, t2y: number,
  u0: number, v0: number, u1: number, v1: number, u2: number, v2: number,
  cr: number, cg: number, cb: number, ca: number, blend: number): void {
  // 按 y 排序（顶/中/底）
  let xa = t0x
  let ya = t0y
  let ua = u0
  let va = v0
  let xb = t1x
  let yb = t1y
  let ub = u1
  let vb = v1
  let xc = t2x
  let yc = t2y
  let uc = u2
  let vc = v2
  let tmp: number
  if (ya > yb) {
    tmp = ya
    ya = yb
    yb = tmp
    tmp = xa
    xa = xb
    xb = tmp
    tmp = ua
    ua = ub
    ub = tmp
    tmp = va
    va = vb
    vb = tmp
  }
  if (yb > yc) {
    tmp = yb
    yb = yc
    yc = tmp
    tmp = xb
    xb = xc
    xc = tmp
    tmp = ub
    ub = uc
    uc = tmp
    tmp = vb
    vb = vc
    vc = tmp
  }
  if (ya > yb) {
    tmp = ya
    ya = yb
    yb = tmp
    tmp = xa
    xa = xb
    xb = tmp
    tmp = ua
    ua = ub
    ub = tmp
    tmp = va
    va = vb
    vb = tmp
  }
  let dLong = yc - ya
  if (dLong < 1e-6) {
    return // 水平退化三角形
  }
  // 行范围（像素中心 y+0.5 落在 [ya, yc]）
  let yStart = Math.max(0, Math.ceil(ya - 0.5))
  let yEnd = Math.min(h - 1, Math.floor(yc - 0.5))
  if (yEnd < yStart) {
    return
  }
  let dUpper = yb - ya
  let dLower = yc - yb
  let tw = tex.width
  let th = tex.height
  let tp = tex.pixels
  let caInv = ca / 255.0
  // 增量边步进：每边只除一次，之后每行 += 增量
  let dxLong = (xc - xa) / dLong
  let duLong = (uc - ua) / dLong
  let dvLong = (vc - va) / dLong
  let dxUp = 0.0
  let duUp = 0.0
  let dvUp = 0.0
  if (dUpper > 1e-6) {
    dxUp = (xb - xa) / dUpper
    duUp = (ub - ua) / dUpper
    dvUp = (vb - va) / dUpper
  }
  let dxLo = 0.0
  let duLo = 0.0
  let dvLo = 0.0
  if (dLower > 1e-6) {
    dxLo = (xc - xb) / dLower
    duLo = (uc - ub) / dLower
    dvLo = (vc - vb) / dLower
  }
  let y0f = yStart + 0.5
  let ex0 = xa + dxLong * (y0f - ya)
  let eu0 = ua + duLong * (y0f - ya)
  let ev0 = va + dvLong * (y0f - ya)
  let useUpper = y0f <= yb && dUpper > 1e-6
  let ex1: number
  let eu1: number
  let ev1: number
  if (useUpper) {
    ex1 = xa + dxUp * (y0f - ya)
    eu1 = ua + duUp * (y0f - ya)
    ev1 = va + dvUp * (y0f - ya)
  } else {
    ex1 = xb + dxLo * (y0f - yb)
    eu1 = ub + duLo * (y0f - yb)
    ev1 = vb + dvLo * (y0f - yb)
  }
  for (let y = yStart; y <= yEnd; y++) {
    let left: number
    let right: number
    let ul: number
    let vl: number
    let ur: number
    let vr: number
    if (ex0 < ex1) {
      left = ex0
      right = ex1
      ul = eu0
      vl = ev0
      ur = eu1
      vr = ev1
    } else {
      left = ex1
      right = ex0
      ul = eu1
      vl = ev1
      ur = eu0
      vr = ev0
    }
    let xStart = Math.max(0, Math.ceil(left - 0.5))
    let xEnd = Math.min(w - 1, Math.floor(right - 0.5))
    if (xEnd >= xStart) {
      let dRow = right - left
      if (dRow >= 1e-6) {
        let du = (ur - ul) / dRow
        let dv = (vr - vl) / dRow
        let u = ul + du * (xStart + 0.5 - left)
        let v = vl + dv * (xStart + 0.5 - left)
        let rowBase = y * w * 4
        for (let x = xStart; x <= xEnd; x++) {
          // UV 恒非负（顶点凸组合），位运算截断替代 floor；只防上界
          let ti = (v * th) | 0
          let tj = (u * tw) | 0
          if (ti >= th) {
            ti = th - 1
          }
          if (tj >= tw) {
            tj = tw - 1
          }
          let ti4 = (ti * tw + tj) * 4
          let sr = tp[ti4] * cr
          let sg = tp[ti4 + 1] * cg
          let sb = tp[ti4 + 2] * cb
          let sa = tp[ti4 + 3] * caInv
          let o = rowBase + x * 4
          if (blend === 0) {
            let da = out[o + 3] / 255.0
            let oa = sa + da * (1.0 - sa)
            if (oa > 0.0) {
              out[o] = (sr * sa + out[o] * da * (1.0 - sa)) / oa
              out[o + 1] = (sg * sa + out[o + 1] * da * (1.0 - sa)) / oa
              out[o + 2] = (sb * sa + out[o + 2] * da * (1.0 - sa)) / oa
              out[o + 3] = oa * 255.0
            }
          } else if (blend === 1) {
            // additive：预乘语义叠加（alpha 也相加，透明背景上特效可见）
            let da = out[o + 3] / 255.0
            let na = sa + da
            if (na > 1.0) {
              na = 1.0
            }
            if (na > 0.0) {
              let v0 = sr * sa + out[o] * da
              let v1 = sg * sa + out[o + 1] * da
              let v2 = sb * sa + out[o + 2] * da
              if (v0 > 255.0) {
                v0 = 255.0
              }
              if (v1 > 255.0) {
                v1 = 255.0
              }
              if (v2 > 255.0) {
                v2 = 255.0
              }
              out[o] = v0 / na
              out[o + 1] = v1 / na
              out[o + 2] = v2 / na
              out[o + 3] = na * 255.0
            }
          } else if (blend === 2) {
            let f = 1.0 - sa + sa * sr / 255.0
            out[o] = out[o] * f
            f = 1.0 - sa + sa * sg / 255.0
            out[o + 1] = out[o + 1] * f
            f = 1.0 - sa + sa * sb / 255.0
            out[o + 2] = out[o + 2] * f
          } else {
            let f = 1.0 - sa + sa * (1.0 - sr / 255.0)
            out[o] = 255.0 - (255.0 - out[o]) * f
            f = 1.0 - sa + sa * (1.0 - sg / 255.0)
            out[o + 1] = 255.0 - (255.0 - out[o + 1]) * f
            f = 1.0 - sa + sa * (1.0 - sb / 255.0)
            out[o + 2] = 255.0 - (255.0 - out[o + 2]) * f
          }
          u += du
          v += dv
        }
      }
    }
    // 行步进 + 短边换段（换段时用下段参数重算下一行起点）
    ex0 += dxLong
    eu0 += duLong
    ev0 += dvLong
    if (useUpper) {
      if (y + 1 + 0.5 > yb) {
        useUpper = false
        let ynf = y + 1 + 0.5
        ex1 = xb + dxLo * (ynf - yb)
        eu1 = ub + duLo * (ynf - yb)
        ev1 = vb + dvLo * (ynf - yb)
      } else {
        ex1 += dxUp
        eu1 += duUp
        ev1 += dvUp
      }
    } else {
      ex1 += dxLo
      eu1 += duLo
      ev1 += dvLo
    }
  }
}

export class ClipMask {
  mask: Uint8Array = new Uint8Array(0)
  x0: number = 0
  y0: number = 0
  x1: number = 0
  y1: number = 0
}

// 多边形填充掩码（偶数奇数规则），返回 0/255 掩码 + 有效包围盒（合成时只循环包围盒区域）
export function polygon_mask(pts: number[], h: number, w: number): ClipMask {
  let cm = new ClipMask()
  cm.mask = new Uint8Array(h * w)
  let n = Math.floor(pts.length / 2)
  if (n < 3) {
    return cm
  }
  let minX = pts[0]
  let maxX = pts[0]
  let minY = pts[1]
  let maxY = pts[1]
  for (let i = 2; i < pts.length; i += 2) {
    if (pts[i] < minX) {
      minX = pts[i]
    }
    if (pts[i] > maxX) {
      maxX = pts[i]
    }
    if (pts[i + 1] < minY) {
      minY = pts[i + 1]
    }
    if (pts[i + 1] > maxY) {
      maxY = pts[i + 1]
    }
  }
  cm.x0 = Math.max(0, Math.floor(minX))
  cm.x1 = Math.min(w, Math.ceil(maxX))
  cm.y0 = Math.max(0, Math.floor(minY))
  cm.y1 = Math.min(h, Math.ceil(maxY))
  if (cm.x1 <= cm.x0 || cm.y1 <= cm.y0) {
    return cm
  }
  let mask = cm.mask
  for (let y = cm.y0; y < cm.y1; y++) {
    let py = y + 0.5
    for (let x = cm.x0; x < cm.x1; x++) {
      let px = x + 0.5
      let inside = false
      for (let i = 0; i < n; i++) {
        let x1v = pts[i * 2]
        let y1v = pts[i * 2 + 1]
        let j = (i + 1) % n
        let x2v = pts[j * 2]
        let y2v = pts[j * 2 + 1]
        let cond = (y1v > py) !== (y2v > py)
        if (cond) {
          let denom = y2v - y1v
          if (denom === 0) {
            denom = 1e-9
          }
          let xint = (x2v - x1v) * (py - y1v) / denom + x1v
          if (px < xint) {
            inside = !inside
          }
        }
      }
      if (inside) {
        mask[y * w + x] = 255
      }
    }
  }
  return cm
}

// src 按 mask 门控叠加到 dst（直通 alpha source-over），只循环掩码包围盒
export function composite_over(dst: Uint8Array, src: Uint8Array, cm: ClipMask, w: number): void {
  for (let y = cm.y0; y < cm.y1; y++) {
    for (let x = cm.x0; x < cm.x1; x++) {
      let mi = y * w + x
      if (cm.mask[mi] === 0) {
        continue
      }
      let o = mi * 4
      let sa = src[o + 3] / 255.0
      let da = dst[o + 3] / 255.0
      let oa = sa + da * (1.0 - sa)
      if (oa > 0.0) {
        dst[o] = (src[o] * sa + dst[o] * da * (1.0 - sa)) / oa
        dst[o + 1] = (src[o + 1] * sa + dst[o + 1] * da * (1.0 - sa)) / oa
        dst[o + 2] = (src[o + 2] * sa + dst[o + 2] * da * (1.0 - sa)) / oa
        dst[o + 3] = oa * 255.0
      }
    }
  }
}

// 渲染骨架到 out（RGBA uint8，w×h×4）。语义与 Python render_skeleton_fast 一致。
export function render_skeleton_cpu(skeleton: Skeleton, out: Uint8Array, w: number, h: number,
  transform: RenderTransform): void {
  let scale = transform.scale
  let tx = transform.tx
  let ty = transform.ty
  out.fill(0)
  let clip_mask: ClipMask | null = null
  let clip_end_index = -1
  let tmp = new Uint8Array(w * h * 4)
  for (let i = 0; i < skeleton.draw_order.length; i++) {
    let slot = skeleton.draw_order[i]
    let attachment = slot.attachment
    if (attachment === null) {
      // 空附件也检查裁剪结束（勿删：end_slot 恰无附件时掩码永不结束）
      if (clip_mask !== null && slot.data.index === clip_end_index) {
        clip_mask = null
        clip_end_index = -1
      }
      continue
    }
    if (attachment instanceof ClippingAttachment) {
      // 已在裁剪中则忽略新裁剪；结束条件为遇到 end_slot（按 data.index）
      if (clip_mask === null) {
        let verts = compute_mesh_vertices(slot, attachment, 0,
          Math.floor(attachment.world_vertices_length / 2))
        let pts: number[] = []
        for (let v = 0; v < verts.length; v += 2) {
          pts.push(verts[v] * scale + tx)
          pts.push(h - (verts[v + 1] * scale + ty))
        }
        clip_mask = polygon_mask(pts, h, w)
        clip_end_index = attachment.end_slot !== null ? attachment.end_slot.index : skeleton.slots.length
      }
      continue
    }
    let verts: number[]
    let triangles: number[]
    let uvs: number[]
    let region: AtlasRegion | null
    let tv0 = Date.now()
    if (attachment instanceof RegionAttachment) {
      verts = compute_region_vertices(slot, attachment)
      triangles = [0, 1, 2, 2, 3, 0]
      region = attachment.region
      let r = region!
      // 角点顺序：BL, TL, TR, BR
      if (r.degrees === 90) {
        uvs = [r.u2, r.v2, r.u, r.v2, r.u, r.v, r.u2, r.v]
      } else {
        uvs = [r.u, r.v2, r.u, r.v, r.u2, r.v, r.u2, r.v2]
      }
    } else if (attachment instanceof MeshAttachment) {
      verts = compute_mesh_vertices(slot, attachment, 0,
        Math.floor(attachment.world_vertices_length / 2))
      triangles = attachment.triangles!
      uvs = attachment.uvs!
      region = attachment.region
    } else {
      continue
    }
    transform.stats[0] += Date.now() - tv0
    if (region === null || region.page === null) {
      continue
    }
    let page = region.page as AtlasPage
    if (page.texture === null) {
      continue
    }
    let tex = page.texture as Texture
    let cr = slot.color.r
    let cg = slot.color.g
    let cb = slot.color.b
    let ca = slot.color.a
    let blend = slot.data.blend_mode
    let target = clip_mask !== null ? tmp : out
    if (clip_mask !== null) {
      tmp.fill(0)
    }
    let tr0 = Date.now()
    for (let t = 0; t < triangles.length; t += 3) {
      let i0 = triangles[t] * 2
      let i1 = triangles[t + 1] * 2
      let i2 = triangles[t + 2] * 2
      rasterize_triangle(target, w, h, tex,
        verts[i0] * scale + tx, h - (verts[i0 + 1] * scale + ty),
        verts[i1] * scale + tx, h - (verts[i1 + 1] * scale + ty),
        verts[i2] * scale + tx, h - (verts[i2 + 1] * scale + ty),
        uvs[i0], uvs[i0 + 1], uvs[i1], uvs[i1 + 1], uvs[i2], uvs[i2 + 1],
        cr, cg, cb, ca, blend)
    }
    transform.stats[1] += Date.now() - tr0
    transform.stats[2] += Math.floor(triangles.length / 3)
    if (clip_mask !== null) {
      composite_over(out, tmp, clip_mask, w)
      // 裁剪结束：end_slot 本身也裁剪，渲染后结束裁剪
      if (slot.data.index === clip_end_index) {
        clip_mask = null
        clip_end_index = -1
      }
    }
  }
}

// ── C++ 光栅化内核（NAPI FFI，零拷贝；ArkTS 版保留作回退/参考） ─────────────────

export class TriBatch {
  tris: Float64Array = new Float64Array(0) // 每三角 12 个：x0,y0,x1,y1,x2,y2,u0,v0,u1,v1,u2,v2（帧空间）
  colors: Float64Array = new Float64Array(0) // 每三角 5 个：r,g,b,a,blend
  flags: Int32Array = new Int32Array(0) // 每三角：裁剪段 id，-1=普通
  segFlat: Float64Array = new Float64Array(0) // 各裁剪段多边形顶点拼接（x,y 交替）
  segSizes: Int32Array = new Int32Array(0) // 各段顶点数
  triCount: number = 0 // 有效三角形数（共享缓冲的容量可能更大）
  segCount: number = 0
}

// 每帧复用的收集缓冲（Windows render_skeleton_fast._bufs 同款经验：
// 杜绝每帧分配 → ArkTS Minor GC 的 STW 停顿是"第一轮流畅后卡顿"的根因）
let TRI_BUF: Float64Array = new Float64Array(4096 * 12)
let COLOR_BUF: Float64Array = new Float64Array(4096 * 5)
let FLAG_BUF: Int32Array = new Int32Array(4096)
let SEG_BUF: Float64Array = new Float64Array(256)
let SEGSIZE_BUF: Int32Array = new Int32Array(16)
let BATCH_REUSE: TriBatch | null = null
let LAST_TRI_COUNT: number = 0 // 上一帧有效三角形数（像素级命中测试用）

// 像素级命中测试：点 (x,y)（vp，与三角形同坐标系）是否落在上一帧任一三角形内。
// 符号一致性测试（三角形顶点为收集时的顺时针/逆时针序均可）。
export function hit_test_point(x: number, y: number): boolean {
  let n = LAST_TRI_COUNT
  for (let t = 0; t < n; t++) {
    let b = t * 12
    let x0 = TRI_BUF[b]
    let y0 = TRI_BUF[b + 1]
    let x1 = TRI_BUF[b + 2]
    let y1 = TRI_BUF[b + 3]
    let x2 = TRI_BUF[b + 4]
    let y2 = TRI_BUF[b + 5]
    let d0 = (x - x0) * (y1 - y0) - (y - y0) * (x1 - x0)
    let d1 = (x - x1) * (y2 - y1) - (y - y1) * (x2 - x1)
    let d2 = (x - x2) * (y0 - y2) - (y - y2) * (x0 - x2)
    let neg = d0 < 0 || d1 < 0 || d2 < 0
    let pos = d0 > 0 || d1 > 0 || d2 > 0
    if (!(neg && pos)) {
      return true
    }
  }
  return false
}

// 按绘制顺序收集整帧三角形（含裁剪段标记）。写入共享缓冲，零每帧分配。
export function collect_triangles(skeleton: Skeleton, w: number, h: number,
  transform: RenderTransform): TriBatch {
  let scale = transform.scale
  let tx = transform.tx
  let ty = transform.ty
  let triIdx = 0
  let colIdx = 0
  let flgIdx = 0
  let clipPolys: number[][] | null = null
  let clip_end_index = -1
  let emit = (x0: number, y0: number, x1: number, y1: number, x2: number, y2: number,
    u0: number, v0: number, u1: number, v1: number, u2: number, v2: number,
    cr: number, cg: number, cb: number, ca: number, blend: number, flag: number): void => {
    if (triIdx + 12 > TRI_BUF.length) {
      let nb = new Float64Array(TRI_BUF.length * 2)
      nb.set(TRI_BUF)
      TRI_BUF = nb
    }
    if (colIdx + 5 > COLOR_BUF.length) {
      let nb = new Float64Array(COLOR_BUF.length * 2)
      nb.set(COLOR_BUF)
      COLOR_BUF = nb
    }
    if (flgIdx + 1 > FLAG_BUF.length) {
      let nb = new Int32Array(FLAG_BUF.length * 2)
      nb.set(FLAG_BUF)
      FLAG_BUF = nb
    }
    TRI_BUF[triIdx] = x0
    TRI_BUF[triIdx + 1] = y0
    TRI_BUF[triIdx + 2] = x1
    TRI_BUF[triIdx + 3] = y1
    TRI_BUF[triIdx + 4] = x2
    TRI_BUF[triIdx + 5] = y2
    TRI_BUF[triIdx + 6] = u0
    TRI_BUF[triIdx + 7] = v0
    TRI_BUF[triIdx + 8] = u1
    TRI_BUF[triIdx + 9] = v1
    TRI_BUF[triIdx + 10] = u2
    TRI_BUF[triIdx + 11] = v2
    triIdx += 12
    COLOR_BUF[colIdx] = cr
    COLOR_BUF[colIdx + 1] = cg
    COLOR_BUF[colIdx + 2] = cb
    COLOR_BUF[colIdx + 3] = ca
    COLOR_BUF[colIdx + 4] = blend
    colIdx += 5
    FLAG_BUF[flgIdx] = flag
    flgIdx += 1
  }
  for (let i = 0; i < skeleton.draw_order.length; i++) {
    let slot = skeleton.draw_order[i]
    let attachment = slot.attachment
    if (attachment === null) {
      if (clipPolys !== null && slot.data.index === clip_end_index) {
        clipPolys = null
        clip_end_index = -1
      }
      continue
    }
    if (attachment instanceof ClippingAttachment) {
      // 官方语义：裁剪附件世界顶点 → 凸分解多边形（骨架坐标）；已在裁剪中则忽略新裁剪
      if (clipPolys === null) {
        let verts = compute_mesh_vertices(slot, attachment, 0,
          Math.floor(attachment.world_vertices_length / 2))
        clipPolys = clipAttachmentPolys(verts)
        clip_end_index = attachment.end_slot !== null ? attachment.end_slot.index : skeleton.slots.length
      }
      continue
    }
    let verts: number[]
    let triangles: number[]
    let uvs: number[]
    let region: AtlasRegion | null
    if (attachment instanceof RegionAttachment) {
      verts = compute_region_vertices(slot, attachment)
      triangles = [0, 1, 2, 2, 3, 0]
      region = attachment.region
      let r = region!
      if (r.degrees === 90) {
        uvs = [r.u2, r.v2, r.u, r.v2, r.u, r.v, r.u2, r.v]
      } else {
        uvs = [r.u, r.v2, r.u, r.v, r.u2, r.v, r.u2, r.v2]
      }
    } else if (attachment instanceof MeshAttachment) {
      verts = compute_mesh_vertices(slot, attachment, 0,
        Math.floor(attachment.world_vertices_length / 2))
      triangles = attachment.triangles!
      uvs = attachment.uvs!
      region = attachment.region
    } else {
      continue
    }
    if (region === null || region.page === null) {
      continue
    }
    let page = region.page as AtlasPage
    if (page.texture === null) {
      continue
    }
    let cr = slot.color.r
    let cg = slot.color.g
    let cb = slot.color.b
    let ca = slot.color.a
    let blend = slot.data.blend_mode
    if (clipPolys !== null) {
      // 裁剪段：官方 S-H 逐三角形裁剪（骨架坐标）→ 扇形三角化 → 帧坐标输出
      for (let t = 0; t < triangles.length; t += 3) {
        let i0 = triangles[t] * 2
        let i1 = triangles[t + 1] * 2
        let i2 = triangles[t + 2] * 2
        let results = clipTriangleToPolys(
          [verts[i0], verts[i0 + 1], verts[i1], verts[i1 + 1], verts[i2], verts[i2 + 1]],
          [uvs[i0], uvs[i0 + 1], uvs[i1], uvs[i1 + 1], uvs[i2], uvs[i2 + 1]],
          clipPolys)
        for (let r = 0; r < results.length; r++) {
          let pts = results[r].pts
          let uvr = results[r].uvs
          let m = Math.floor(pts.length / 2)
          if (m < 3) {
            continue
          }
          let fx0 = pts[0] * scale + tx
          let fy0 = h - (pts[1] * scale + ty)
          for (let f2 = 1; f2 < m - 1; f2++) {
            emit(fx0, fy0,
              pts[f2 * 2] * scale + tx, h - (pts[f2 * 2 + 1] * scale + ty),
              pts[(f2 + 1) * 2] * scale + tx, h - (pts[(f2 + 1) * 2 + 1] * scale + ty),
              uvr[0], uvr[1], uvr[f2 * 2], uvr[f2 * 2 + 1],
              uvr[(f2 + 1) * 2], uvr[(f2 + 1) * 2 + 1],
              cr, cg, cb, ca, blend, -1)
          }
        }
      }
    } else {
      for (let t = 0; t < triangles.length; t += 3) {
        let i0 = triangles[t] * 2
        let i1 = triangles[t + 1] * 2
        let i2 = triangles[t + 2] * 2
        emit(verts[i0] * scale + tx, h - (verts[i0 + 1] * scale + ty),
          verts[i1] * scale + tx, h - (verts[i1 + 1] * scale + ty),
          verts[i2] * scale + tx, h - (verts[i2 + 1] * scale + ty),
          uvs[i0], uvs[i0 + 1], uvs[i1], uvs[i1 + 1], uvs[i2], uvs[i2 + 1],
          cr, cg, cb, ca, blend, -1)
      }
    }
    if (clipPolys !== null && slot.data.index === clip_end_index) {
      clipPolys = null
      clip_end_index = -1
    }
  }
  // 复用批对象（每帧少一次分配；GC 压力直接降低）
  if (BATCH_REUSE === null) {
    BATCH_REUSE = new TriBatch()
  }
  let batch = BATCH_REUSE
  batch.tris = TRI_BUF
  batch.colors = COLOR_BUF
  batch.flags = FLAG_BUF
  batch.segFlat = SEG_BUF
  batch.segSizes = SEGSIZE_BUF
  batch.triCount = flgIdx
  batch.segCount = 0 // 掩码管线已废弃：裁剪在收集阶段完成（官方 S-H 语义，2026-08-20）
  LAST_TRI_COUNT = flgIdx
  return batch
}

// C++ 内核渲染（收集在 ArkTS，光栅化零拷贝直调 native）。tex 为模型唯一图集页纹理。
// bilinear: 1=双线性纹理采样（预乘修正，Python 同款），0=最近邻
export function render_skeleton_cpu_native(skeleton: Skeleton, tex: Texture, out: Uint8Array,
  w: number, h: number, transform: RenderTransform, bilinear: number = 0): void {
  let batch = collect_triangles(skeleton, w, h, transform)
  rasterize_frame(batch.tris.buffer, batch.colors.buffer, batch.flags.buffer, batch.triCount,
    batch.segFlat.buffer, batch.segSizes.buffer, batch.segCount,
    tex.pixels.buffer, tex.width, tex.height,
    out.buffer, w, h, bilinear)
}

// C++ 转预乘（ArkTS 的 Math.round 循环约 45ms/帧@300×366，native 约 0.5ms）
export function premultiply_native(buf: Uint8Array): void {
  premultiply_rgba(buf.buffer)
}
