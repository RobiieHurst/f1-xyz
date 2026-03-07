# OpenLayers Driver/Track Calibration TODO

## Goal

Make driver locations and circuit overlays accurate and understandable by combining:

- OpenF1 local `x/y/z` motion data (for racing dynamics)
- OpenLayers world basemap context (for real location)
- A stable per-session transform + per-circuit calibration profile

## Phase 1 — Stable Foundation

- [ ] Ensure `session_meta` (including `circuit_key`, `circuit_short_name`, country/location) is pushed to the `TrackMap` hook on every session switch.
- [ ] Initialize OpenLayers with a circuit anchor center from `circuit_key` (fallback to name, then safe default).
- [ ] Build a single transform frame once per session:
  - [ ] anchor lat/lng
  - [ ] scale (meters per local unit)
  - [ ] rotation (degrees)
  - [ ] axis flips (`flip_x`, `flip_y`)
- [ ] Apply the same transform consistently to:
  - [ ] car positions
  - [ ] track outline/trail
- [ ] Do not recompute transform every frame from moving bounds (prevents drift/warping).
- [ ] If outline quality is poor (not enough points / not a loop), hide the line and keep only driver markers.

## Phase 2 — Per-Circuit Calibration Table

- [ ] Add a `circuit_key => calibration` map for known tracks.
- [ ] Start with problematic circuits:
  - [ ] Hungaroring (rotation/flip)
  - [ ] Melbourne (orientation/scale sanity)
- [ ] Add quick calibration toggles for development (temporary) to tune values safely.
- [ ] Persist tuned values in code once verified.

## Phase 3 — UX Improvements

- [ ] Add map HUD label with:
  - [ ] circuit name
  - [ ] country/location
  - [ ] mode badge (`LIVE` vs `REPLAY`)
- [ ] Keep auto-fit behavior only on initial load, then respect user pan/zoom.
- [ ] Ensure timing order and map labels align visually (`P# CODE`).

## Data Quality Guardrails

- [ ] Filter invalid lap durations before display (e.g. `< 20s` or `> 300s`).
- [ ] Ensure "latest lap" ignores incomplete/invalid laps.
- [ ] Keep best-lap calculations on valid laps only.

## Validation Checklist

- [ ] Hungary aligns with map roads/track orientation.
- [ ] Melbourne aligns and does not appear mirrored/offshore.
- [ ] Drivers visibly interpolate/move at replay 1x and higher speeds.
- [ ] Timing tower shows sane lap values (no multi-minute anomalies in qualifying).
- [ ] Session switching clears stale drivers/track state.
- [ ] `mix precommit` passes.
