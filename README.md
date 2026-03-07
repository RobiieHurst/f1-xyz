# F1 Tracker 🏎️

Real-time Formula 1 car tracker and timing display built with Elixir, Phoenix LiveView, and GEOLYTIX/xyz.

## Features

- **Live track map** — car positions plotted in real-time using OpenF1 x,y,z telemetry
- **Timing tower** — positions, lap times, gaps, intervals (just like the TV broadcast)
- **Race control** — flags, penalties, safety car notifications
- **Weather** — live track conditions
- **Replay** — pick any point in time and replay the session from there
- **Canvas fallback** — works without GEOLYTIX/xyz loaded (auto-scales car dots to canvas)

## Stack

- **Elixir / Phoenix LiveView** — real-time server-rendered UI
- **GEOLYTIX/xyz MAPP** — OpenLayers-based spatial visualization (optional, canvas fallback included)
- **OpenF1 API** — free F1 telemetry data (https://openf1.org)
- **Req** — HTTP client for API calls

## Architecture

```
┌─────────────────┐     ┌──────────────────┐     ┌─────────────┐
│   OpenF1 API    │────▶│  SessionServer   │────▶│   PubSub    │
│  (polling)      │     │  (GenServer)     │     │             │
└─────────────────┘     └──────────────────┘     └──────┬──────┘
                                                        │
                                                        ▼
                                                 ┌─────────────┐
                                                 │ TrackerLive  │
                                                 │ (LiveView)   │
                                                 └──────┬──────┘
                                                        │
                                                 push_event
                                                        │
                                                        ▼
                                                 ┌─────────────┐
                                                 │  TrackMap    │
                                                 │  (JS Hook)  │
                                                 │  MAPP/Canvas│
                                                 └─────────────┘
```

## Getting Started

```bash
# Install deps
mix setup

# Start the server
mix phx.server

# Or in IEx
iex -S mix phx.server
```

Visit `http://localhost:4000` — click "Get Started", pick a session, and watch it go.

## GEOLYTIX/xyz Integration

For the full map experience with proper circuit overlays:

```bash
cd assets && npm install @geolytix/xyz
```

Then import MAPP in your JS. The app falls back to a canvas renderer if MAPP isn't loaded.

## TODO

- [x] Proper MAPP layer with circuit GeoJSON overlay
- [x] Tyre compound indicators in timing tower
- [x] Sector time colouring (purple/green/yellow)
- [x] Driver headshot images
- [x] Smooth car position interpolation (lerp between updates)
- [x] Historical session browser with search/filter
- [x] DRS detection zones on track map
- [x] Team radio playback integration
- [x] Mobile-responsive layout
