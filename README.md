# F1 Tracker

Real-time Formula 1 tracker built with Phoenix LiveView and OpenF1.

## Features

- Live race tracking with car positions, timing, weather, race control, and team radio
- Driver follow mode with focused telemetry (speed, throttle, brake, gear, rpm, DRS)
- Replay mode with timeline scrubber and speed controls
- Circuit rendering from OpenF1 Meetings `circuit_info_url` (MultiViewer data)
- On-map event overlays for overtakes and incidents

## Data Flow

- **Session metadata**: OpenF1 `sessions` + `meetings` + `circuit_info_url`
- **Live positions/telemetry**:
  - Primary: OpenF1 MQTT (`v1/location`, `v1/car_data`)
  - Fallback: OpenF1 REST polling
- **Replay/historical**: OpenF1 REST range queries

## Architecture

```
OpenF1 (REST + MQTT)
        |
        v
SessionServer / ReplayServer (GenServer)
        |
        v
Phoenix PubSub ("f1:live")
        |
        v
TrackerLive (LiveView) -> TrackMap hook (canvas)
```

## Quick Start

```bash
mix setup
iex -S mix phx.server
```

Open `http://localhost:4000`, load sessions, and start tracking.

## MQTT Notes

- MQTT stream process: `F1Tracker.OpenF1.MQTTStream`
- Topics consumed: `v1/location`, `v1/car_data`
- MQTT updates are merged into `SessionServer` live state and broadcast via PubSub

## Simulate MQTT (No Live Race Required)

Use this to test the running app without waiting for an active session stream.

### Recommended (same VM as server)

Start server in IEx:

```bash
iex -S mix phx.server
```

Then in IEx:

```elixir
F1Tracker.Dev.MQTTSimulator.run()
F1Tracker.Dev.MQTTSimulator.run(ticks: 80, interval_ms: 150, drivers: [1, 16, 44, 55])
```

### Mix task

```bash
mix f1.simulate_mqtt
mix f1.simulate_mqtt --ticks 80 --interval-ms 150 --drivers 1,16,44,55 --session-key 9158
```

## Tests

Run full checks:

```bash
mix precommit
```

MQTT-specific tests:

```bash
mix test test/f1_tracker/f1/session_server_mqtt_test.exs
mix test test/f1_tracker/open_f1/mqtt_stream_simulation_test.exs
```
