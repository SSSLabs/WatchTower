export const MIN_ZOOM = 0
export const MAX_ZOOM = 22

/** 把缩放级别限制在 [min, max] 内；NaN 返回 min。 */
export function clampZoom(zoom: number, min = MIN_ZOOM, max = MAX_ZOOM): number {
  if (Number.isNaN(zoom)) return min
  return Math.min(max, Math.max(min, zoom))
}

/** 把经纬度格式化为 "39.90°N, 116.40°E" 形式。 */
export function formatLngLat(lng: number, lat: number): string {
  const ns = lat >= 0 ? 'N' : 'S'
  const ew = lng >= 0 ? 'E' : 'W'
  return `${Math.abs(lat).toFixed(2)}°${ns}, ${Math.abs(lng).toFixed(2)}°${ew}`
}
