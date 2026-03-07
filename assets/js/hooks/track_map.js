/**
 * TrackMap LiveView Hook
 *
 * Renders an auto-generated circuit outline from car position history,
 * with smooth position interpolation and DRS indicators.
 *
 * Falls back to canvas-based rendering (MAPP integration ready for future).
 */

// Duration to interpolate over (matches server poll interval)
const LERP_DURATION_MS = 500;
// Distance threshold — if a car jumps further than this, skip lerp (pit lane teleport)
const TELEPORT_THRESHOLD = 5000;
// Max track trail points to keep (one full lap is ~300-500 points at 500ms intervals)
const MAX_TRAIL_POINTS = 800;
// Minimum distance between trail points (prevents clustering)
const MIN_TRAIL_DISTANCE = 40;

const TrackMap = {
  mounted() {
    this.drivers = {};
    this.markers = {};
    this.mapReady = false;

    // Interpolation state per driver
    this.carStates = {};
    this.animFrameId = null;

    // Definitive track outline from server (single driver's lap trace)
    this.trackOutline = [];
    // Fallback trail built from accumulated car positions (used when no outline)
    this.trackTrail = [];
    // Bounds cache (updated when outline/trail changes, not every frame)
    this.cachedBounds = null;

    // Try to init MAPP, fall back to canvas
    this.initMap();

    // Handle LiveView events
    this.handleEvent("drivers_loaded", (data) => {
      this.drivers = data.drivers;
      // Reset all state on new session
      this.carStates = {};
      this.markers = {};
      this.trackOutline = [];
      this.trackTrail = [];
      this.trailDriver = null;
      this.cachedBounds = null;
    });

    this.handleEvent("track_outline", (data) => {
      if (data.points && data.points.length > 0) {
        this.trackOutline = data.points;
        this.cachedBounds = null;
        console.log(`[TrackMap] Track outline loaded: ${data.points.length} points`);
      }
    });

    this.handleEvent("locations_update", (data) => {
      this.updateCarPositions(data.locations);
    });

    this.handleEvent("replay_data", (data) => {
      if (data.locations) {
        this.trackTrail = [];
        this.cachedBounds = null;
        this.updateCarPositions(data.locations, true);
      }
    });
  },

  async initMap() {
    const container = this.el.querySelector("#map-container");

    if (window.mapp) {
      await this.initMAPP(container);
    } else {
      this.initCanvas(container);
    }
  },

  async initMAPP(container) {
    try {
      const mapview = await mapp.Mapview({
        host: container,
        locale: { layers: {} },
        view: { lat: 0, lng: 0, z: 15 },
      });

      this.mapview = mapview;
      this.mapReady = true;
      console.log("[TrackMap] MAPP initialized");
    } catch (e) {
      console.warn("[TrackMap] MAPP init failed, using canvas fallback", e);
      this.initCanvas(container);
    }
  },

  initCanvas(container) {
    const canvas = document.createElement("canvas");
    canvas.id = "track-canvas";
    canvas.style.width = "100%";
    canvas.style.height = "100%";
    container.appendChild(canvas);

    this.canvas = canvas;
    this.ctx = canvas.getContext("2d");
    this.mapReady = true;

    const resize = () => {
      canvas.width = container.clientWidth;
      canvas.height = container.clientHeight;
    };

    window.addEventListener("resize", resize);
    this._resizeHandler = resize;
    resize();

    this.startAnimationLoop();
    console.log("[TrackMap] Canvas renderer initialized");
  },

  startAnimationLoop() {
    const loop = () => {
      this.redraw();
      this.animFrameId = requestAnimationFrame(loop);
    };
    this.animFrameId = requestAnimationFrame(loop);
  },

  /**
   * Accumulate car positions into the track trail.
   * Tracks a single driver's path over time to trace a clean circuit outline.
   * Falls back to choosing the first available driver.
   */
  addToTrail(locations) {
    // Pick a trail driver — stick with it once chosen
    if (!this.trailDriver) {
      const keys = Object.keys(locations);
      if (keys.length === 0) return;
      this.trailDriver = keys[0];
    }

    const loc = locations[this.trailDriver];
    if (!loc || loc.x == null || loc.y == null) return;

    let trailChanged = false;

    if (this.trackTrail.length > 0) {
      const last = this.trackTrail[this.trackTrail.length - 1];
      const dx = loc.x - last.x;
      const dy = loc.y - last.y;
      const dist = Math.sqrt(dx * dx + dy * dy);

      // Skip if too close (clustering) or too far (pit teleport)
      if (dist < MIN_TRAIL_DISTANCE || dist > TELEPORT_THRESHOLD) return;
    }

    this.trackTrail.push({ x: loc.x, y: loc.y });
    trailChanged = true;

    // Trim trail if too long
    if (this.trackTrail.length > MAX_TRAIL_POINTS) {
      this.trackTrail = this.trackTrail.slice(-MAX_TRAIL_POINTS);
    }

    // Invalidate bounds cache when trail changes
    if (trailChanged) {
      this.cachedBounds = null;
    }
  },

  updateCarPositions(locations, snap = false) {
    if (!this.mapReady) return;

    const now = performance.now();

    // Build track trail from position data
    this.addToTrail(locations);

    for (const [driverNum, loc] of Object.entries(locations)) {
      if (loc.x == null || loc.y == null) continue;

      const existing = this.carStates[driverNum];

      if (!existing || snap) {
        this.carStates[driverNum] = {
          prev: { x: loc.x, y: loc.y },
          target: { x: loc.x, y: loc.y },
          current: { x: loc.x, y: loc.y },
          startTime: now,
          code: loc.code || driverNum,
          team_colour: loc.team_colour || "FFFFFF",
          drs_active: loc.drs_active || false,
          drs_eligible: loc.drs_eligible || false,
          speed: loc.speed || null,
          position: loc.position || null,
          last_lap: loc.last_lap || null,
          gap: loc.gap || null,
          interval: loc.interval || null,
          compound: loc.compound || null,
        };
      } else {
        const dx = loc.x - existing.target.x;
        const dy = loc.y - existing.target.y;
        const dist = Math.sqrt(dx * dx + dy * dy);

        if (dist > TELEPORT_THRESHOLD) {
          existing.prev = { x: loc.x, y: loc.y };
          existing.target = { x: loc.x, y: loc.y };
          existing.current = { x: loc.x, y: loc.y };
        } else {
          existing.prev = { x: existing.current.x, y: existing.current.y };
          existing.target = { x: loc.x, y: loc.y };
        }

        existing.startTime = now;
        existing.code = loc.code || existing.code;
        existing.team_colour = loc.team_colour || existing.team_colour;
        existing.drs_active = loc.drs_active || false;
        existing.drs_eligible = loc.drs_eligible || false;
        existing.speed = loc.speed || existing.speed;
        existing.position = loc.position ?? existing.position;
        existing.last_lap = loc.last_lap ?? existing.last_lap;
        existing.gap = loc.gap ?? existing.gap;
        existing.interval = loc.interval ?? existing.interval;
        existing.compound = loc.compound ?? existing.compound;
      }
    }

    if (this.mapview) {
      this.updateMAPPPositions(locations);
    }
  },

  updateMAPPPositions(locations) {
    for (const [driverNum, loc] of Object.entries(locations)) {
      const id = `driver-${driverNum}`;
      const colour = `#${loc.team_colour || "FFFFFF"}`;

      if (this.markers[id]) {
        this.markers[id].setGeometry?.({
          type: "Point",
          coordinates: [loc.x, loc.y],
        });
      } else {
        this.markers[id] = { x: loc.x, y: loc.y, colour, code: loc.code };
      }
    }
  },

  /**
   * Get the active track path — prefer server-provided outline, fall back to trail.
   */
  getTrackPath() {
    return this.trackOutline.length > 0 ? this.trackOutline : this.trackTrail;
  },

  /**
   * Compute bounds from track path + car positions, with caching.
   */
  computeBounds(entries) {
    if (this.cachedBounds && entries.length > 0) {
      // Only recompute if we have new car positions outside cached bounds
      let needsUpdate = false;
      for (const [, car] of entries) {
        if (
          car.current.x < this.cachedBounds.minX ||
          car.current.x > this.cachedBounds.maxX ||
          car.current.y < this.cachedBounds.minY ||
          car.current.y > this.cachedBounds.maxY
        ) {
          needsUpdate = true;
          break;
        }
      }
      if (!needsUpdate) return this.cachedBounds;
    }

    const xs = [];
    const ys = [];

    // Include track path points (outline or trail)
    for (const pt of this.getTrackPath()) {
      xs.push(pt.x);
      ys.push(pt.y);
    }

    // Include current car positions
    for (const [, car] of entries) {
      if (car.current.x != null) xs.push(car.current.x);
      if (car.current.y != null) ys.push(car.current.y);
    }

    if (xs.length === 0) return null;

    this.cachedBounds = {
      minX: Math.min(...xs),
      maxX: Math.max(...xs),
      minY: Math.min(...ys),
      maxY: Math.max(...ys),
    };

    return this.cachedBounds;
  },

  /**
   * Render the track outline and car positions.
   */
  redraw() {
    if (!this.canvas || !this.ctx) return;

    const ctx = this.ctx;
    const w = this.canvas.width;
    const h = this.canvas.height;
    const now = performance.now();

    // Clear
    ctx.fillStyle = "#0a0a0a";
    ctx.fillRect(0, 0, w, h);

    const entries = Object.entries(this.carStates);
    if (entries.length === 0) {
      ctx.fillStyle = "#333";
      ctx.font = "14px monospace";
      ctx.textAlign = "center";
      ctx.fillText("Waiting for car position data...", w / 2, h / 2);
      return;
    }

    // Compute interpolated positions
    for (const [, car] of entries) {
      const elapsed = now - car.startTime;
      const t = Math.min(elapsed / LERP_DURATION_MS, 1);
      const ease = 1 - Math.pow(1 - t, 3);

      car.current = {
        x: car.prev.x + (car.target.x - car.prev.x) * ease,
        y: car.prev.y + (car.target.y - car.prev.y) * ease,
      };
    }

    // Compute bounds
    const bounds = this.computeBounds(entries);
    if (!bounds) return;

    const { minX, maxX, minY, maxY } = bounds;
    const rangeX = maxX - minX || 1;
    const rangeY = maxY - minY || 1;

    const padding = 60;
    const scaleX = (w - padding * 2) / rangeX;
    const scaleY = (h - padding * 2) / rangeY;
    const scale = Math.min(scaleX, scaleY);

    const offsetX = (w - rangeX * scale) / 2;
    const offsetY = (h - rangeY * scale) / 2;

    // Helper to transform track coords to canvas coords
    const toScreen = (x, y) => ({
      px: (x - minX) * scale + offsetX,
      py: (y - minY) * scale + offsetY,
    });

    // === Draw track outline ===
    const trackPath = this.getTrackPath();
    const hasOutline = this.trackOutline.length > 0;

    if (trackPath.length >= 2) {
      // Build the screen-space path once
      const screenPts = trackPath.map(pt => toScreen(pt.x, pt.y));

      // Helper: trace the full path (optionally closing it)
      const tracePath = (close) => {
        ctx.beginPath();
        ctx.moveTo(screenPts[0].px, screenPts[0].py);
        for (let i = 1; i < screenPts.length; i++) {
          ctx.lineTo(screenPts[i].px, screenPts[i].py);
        }
        if (close) ctx.closePath();
      };

      // Outer track edge (wider, darker)
      tracePath(hasOutline);
      ctx.strokeStyle = "rgba(55, 65, 81, 0.7)";
      ctx.lineWidth = 14;
      ctx.lineCap = "round";
      ctx.lineJoin = "round";
      ctx.stroke();

      // Inner track surface
      tracePath(hasOutline);
      ctx.strokeStyle = "rgba(75, 85, 99, 0.4)";
      ctx.lineWidth = 10;
      ctx.lineCap = "round";
      ctx.lineJoin = "round";
      ctx.stroke();

      // Racing line (bright centre)
      tracePath(hasOutline);
      ctx.strokeStyle = "rgba(107, 114, 128, 0.15)";
      ctx.lineWidth = 2;
      ctx.lineCap = "round";
      ctx.lineJoin = "round";
      ctx.stroke();
    }

    // === Draw cars ===
    // Collect label rects for anti-collision
    const labelRects = [];

    // Sort entries by position (leaders drawn last = on top)
    const sorted = [...entries].sort((a, b) => {
      const pa = a[1].position || 99;
      const pb = b[1].position || 99;
      return pb - pa;
    });

    for (const [driverNum, car] of sorted) {
      const { px, py } = toScreen(car.current.x, car.current.y);
      const colour = `#${car.team_colour}`;

      // DRS active indicator — green pulsing ring
      if (car.drs_active) {
        const pulse = 0.5 + 0.5 * Math.sin(now / 200);
        const drsRadius = 14 + pulse * 3;
        ctx.beginPath();
        ctx.arc(px, py, drsRadius, 0, Math.PI * 2);
        ctx.strokeStyle = `rgba(34, 197, 94, ${0.4 + pulse * 0.3})`;
        ctx.lineWidth = 2;
        ctx.stroke();
      } else if (car.drs_eligible) {
        ctx.beginPath();
        ctx.arc(px, py, 13, 0, Math.PI * 2);
        ctx.strokeStyle = "rgba(34, 197, 94, 0.3)";
        ctx.lineWidth = 1;
        ctx.setLineDash([3, 3]);
        ctx.stroke();
        ctx.setLineDash([]);
      }

      // Glow
      ctx.beginPath();
      ctx.arc(px, py, 10, 0, Math.PI * 2);
      ctx.fillStyle = colour + "22";
      ctx.fill();

      // Car dot
      ctx.beginPath();
      ctx.arc(px, py, 6, 0, Math.PI * 2);
      ctx.fillStyle = colour;
      ctx.fill();

      // Dot border
      ctx.strokeStyle = car.drs_active
        ? "rgba(34, 197, 94, 0.8)"
        : "rgba(255,255,255,0.3)";
      ctx.lineWidth = car.drs_active ? 1.5 : 1;
      ctx.stroke();

      // === Timing label ===
      const hasTimingData = car.position || car.gap || car.last_lap || car.compound;

      if (hasTimingData) {
        this.drawTimingLabel(ctx, car, driverNum, px, py, colour, now, labelRects);
      } else {
        // Fallback: just driver code
        ctx.fillStyle = car.drs_active ? "#22c55e" : "#fff";
        ctx.font = "bold 10px monospace";
        ctx.textAlign = "center";
        ctx.fillText(car.code || driverNum, px, py - 12);

        if (car.drs_active && car.speed) {
          ctx.fillStyle = "rgba(34, 197, 94, 0.7)";
          ctx.font = "9px monospace";
          ctx.fillText(`${car.speed}`, px, py + 16);
        }
      }
    }

    // === Track info overlay ===
    const trackPtCount = this.getTrackPath().length;
    if (trackPtCount > 0) {
      ctx.fillStyle = "rgba(107, 114, 128, 0.4)";
      ctx.font = "10px monospace";
      ctx.textAlign = "left";
      ctx.fillText(
        `Track: ${trackPtCount} pts`,
        8,
        h - 8,
      );
    }
  },

  /**
   * Draw a compact timing label card next to a car dot.
   * Shows: P{position} {CODE} | {gap} | {compound}
   * Uses anti-collision to offset overlapping labels.
   */
  drawTimingLabel(ctx, car, driverNum, px, py, colour, now, labelRects) {
    // Build label text parts
    const parts = [];
    if (car.position) parts.push(`P${car.position}`);
    parts.push(car.code || driverNum);

    // Secondary line: gap/interval and lap time
    const secondParts = [];
    if (car.interval) secondParts.push(car.interval);
    else if (car.gap) secondParts.push(car.gap);
    if (car.last_lap) secondParts.push(car.last_lap);

    const line1 = parts.join(" ");
    const line2 = secondParts.join(" | ");

    // Measure text dimensions
    ctx.font = "bold 9px monospace";
    const line1Width = ctx.measureText(line1).width;
    ctx.font = "8px monospace";
    const line2Width = line2 ? ctx.measureText(line2).width : 0;

    const tyreSize = car.compound ? 10 : 0;
    const innerPad = 5;
    const cardWidth = Math.max(line1Width, line2Width) + innerPad * 2 + tyreSize + 2;
    const cardHeight = line2 ? 26 : 16;

    // Default label position: to the right of the dot
    let lx = px + 12;
    let ly = py - cardHeight / 2;

    // Anti-collision: try 4 positions (right, left, above, below)
    const offsets = [
      { x: px + 12, y: py - cardHeight / 2 },                  // right
      { x: px - 12 - cardWidth, y: py - cardHeight / 2 },      // left
      { x: px - cardWidth / 2, y: py - 18 - cardHeight },      // above
      { x: px - cardWidth / 2, y: py + 18 },                   // below
    ];

    let bestPos = offsets[0];
    let minOverlap = Infinity;

    for (const pos of offsets) {
      let overlap = 0;
      for (const rect of labelRects) {
        const ox = Math.max(0, Math.min(pos.x + cardWidth, rect.x + rect.w) - Math.max(pos.x, rect.x));
        const oy = Math.max(0, Math.min(pos.y + cardHeight, rect.y + rect.h) - Math.max(pos.y, rect.y));
        overlap += ox * oy;
      }
      if (overlap < minOverlap) {
        minOverlap = overlap;
        bestPos = pos;
        if (overlap === 0) break;
      }
    }

    lx = bestPos.x;
    ly = bestPos.y;

    // Register this label rect
    labelRects.push({ x: lx, y: ly, w: cardWidth, h: cardHeight });

    // Draw connection line from dot to label
    ctx.beginPath();
    ctx.moveTo(px, py);
    const edgeX = lx < px ? lx + cardWidth : lx;
    const edgeY = ly + cardHeight / 2;
    ctx.lineTo(edgeX, edgeY);
    ctx.strokeStyle = "rgba(255,255,255,0.1)";
    ctx.lineWidth = 0.5;
    ctx.stroke();

    // Draw card background
    const radius = 3;
    ctx.beginPath();
    ctx.roundRect(lx, ly, cardWidth, cardHeight, radius);
    ctx.fillStyle = "rgba(10, 10, 10, 0.85)";
    ctx.fill();
    ctx.strokeStyle = colour + "55";
    ctx.lineWidth = 1;
    ctx.stroke();

    // Tyre compound indicator circle
    let textStartX = lx + innerPad;
    if (car.compound) {
      const tyreX = lx + innerPad + 3;
      const tyreY = ly + (line2 ? 9 : cardHeight / 2);
      const tyreR = 3.5;

      ctx.beginPath();
      ctx.arc(tyreX, tyreY, tyreR, 0, Math.PI * 2);
      ctx.fillStyle = this.tyreColour(car.compound);
      ctx.fill();

      // Compound letter
      ctx.fillStyle = car.compound === "H" ? "#000" : "#fff";
      ctx.font = "bold 5px monospace";
      ctx.textAlign = "center";
      ctx.fillText(car.compound, tyreX, tyreY + 2);

      textStartX += tyreSize;
    }

    // Line 1: position + code
    ctx.font = "bold 9px monospace";
    ctx.textAlign = "left";
    ctx.fillStyle = car.drs_active ? "#22c55e" : "#fff";
    ctx.fillText(line1, textStartX, ly + (line2 ? 10 : 12));

    // Line 2: gap/interval + lap time
    if (line2) {
      ctx.font = "8px monospace";
      ctx.fillStyle = "rgba(156, 163, 175, 0.9)";
      ctx.fillText(line2, textStartX, ly + 22);
    }
  },

  /**
   * Map tyre compound letter to canvas colour.
   */
  tyreColour(compound) {
    switch (compound) {
      case "S": return "#ef4444";
      case "M": return "#eab308";
      case "H": return "#ffffff";
      case "I": return "#22c55e";
      case "W": return "#3b82f6";
      default:  return "#6b7280";
    }
  },

  destroyed() {
    if (this.animFrameId) {
      cancelAnimationFrame(this.animFrameId);
      this.animFrameId = null;
    }
    if (this._resizeHandler) {
      window.removeEventListener("resize", this._resizeHandler);
    }
  },
};

export default TrackMap;
