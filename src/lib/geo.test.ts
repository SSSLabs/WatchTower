import { describe, expect, it } from 'vitest'
import { clampZoom, formatLngLat } from './geo'

describe('clampZoom', () => {
  it('把越界值限制在 [0, 22]', () => {
    expect(clampZoom(-5)).toBe(0)
    expect(clampZoom(30)).toBe(22)
    expect(clampZoom(11)).toBe(11)
  })

  it('NaN 返回最小值', () => {
    expect(clampZoom(Number.NaN)).toBe(0)
  })
})

describe('formatLngLat', () => {
  it('格式化北京坐标', () => {
    expect(formatLngLat(116.4, 39.9)).toBe('39.90°N, 116.40°E')
  })

  it('处理南半球 / 西半球', () => {
    expect(formatLngLat(-70.66, -33.45)).toBe('33.45°S, 70.66°W')
  })
})
