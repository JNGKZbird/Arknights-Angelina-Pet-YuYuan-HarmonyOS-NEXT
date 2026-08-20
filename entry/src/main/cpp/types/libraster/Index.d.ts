export const rasterize_frame: (tris: ArrayBuffer, colors: ArrayBuffer, flags: ArrayBuffer,
  triCount: number, segFlat: ArrayBuffer, segSizes: ArrayBuffer, segCount: number,
  tex: ArrayBuffer, texW: number, texH: number, out: ArrayBuffer, w: number, h: number,
  bilinear: number) => void;

export const premultiply_rgba: (buf: ArrayBuffer) => void;

// XComponent 直写上屏：tris/colors/flags/seg* 均为 vp 坐标（相对 XComponent 盒），
// vpW/vpH = 盒尺寸（vp），rasterScale = 光栅分辨率 / vp（缓冲几何 = vp×rasterScale，
// RS 负责缓冲→表面缩放；=设备密度则物理 1:1）。表面与缓冲在 native 侧维护，无需 PixelMap。
export const render_frame_to_window: (tris: ArrayBuffer, colors: ArrayBuffer, flags: ArrayBuffer,
  triCount: number, segFlat: ArrayBuffer, segSizes: ArrayBuffer, segCount: number,
  tex: ArrayBuffer, texW: number, texH: number, vpW: number, vpH: number, rasterScale: number) => void;

// 由 XComponent 的 getXComponentSurfaceId() 字符串创建 OHNativeWindow
// （框架的 OH_NativeXComponent_Export 回调链在本机未触发，走主动建窗）。
export const init_surface: (surfaceId: string) => void;

// GPU 上屏（GLES3）：参数同 render_frame_to_window（rasterScale 忽略），
// GPU 直接以表面物理分辨率渲染。XComponent 需为 TEXTURE 型。
export const render_frame_gl: (tris: ArrayBuffer, colors: ArrayBuffer, flags: ArrayBuffer,
  triCount: number, segFlat: ArrayBuffer, segSizes: ArrayBuffer, segCount: number,
  tex: ArrayBuffer, texW: number, texH: number, vpW: number, vpH: number, rasterScale: number) => void;
