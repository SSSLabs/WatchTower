import { useEffect, useRef } from 'react'
import * as maplibregl from 'maplibre-gl'
import 'maplibre-gl/dist/maplibre-gl.css'
import { clampZoom, formatLngLat } from '../lib/geo'

const DEMO_STYLE_URL = 'https://demotiles.maplibre.org/style.json'
const DEFAULT_CENTER: [number, number] = [116.4, 39.9]
const DEFAULT_ZOOM = 11

export function MapView() {
  const containerRef = useRef<HTMLDivElement>(null)

  useEffect(() => {
    const container = containerRef.current
    if (!container) return

    const map = new maplibregl.Map({
      container,
      style: DEMO_STYLE_URL,
      center: DEFAULT_CENTER,
      zoom: clampZoom(DEFAULT_ZOOM),
    })
    map.addControl(new maplibregl.NavigationControl(), 'top-right')

    return () => {
      map.remove()
    }
  }, [])

  return (
    <div className="relative h-full w-full">
      <div ref={containerRef} className="h-full w-full" />
      <div className="absolute bottom-2 left-2 rounded bg-black/60 px-2 py-1 text-xs text-white">
        {formatLngLat(DEFAULT_CENTER[0], DEFAULT_CENTER[1])}
      </div>
    </div>
  )
}
