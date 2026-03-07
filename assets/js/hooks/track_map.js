const LERP_DURATION_MS = 500;
const TELEPORT_THRESHOLD = 5000;
const MAX_TRAIL_POINTS = 1000;
const MIN_TRAIL_DISTANCE = 35;
const MAX_TRACK_CLOUD_POINTS = 6000;
const TRACK_CLOUD_CELL = 70;

const DEFAULT_ANCHOR = [2.3522, 48.8566];
const MIN_FRAME_RANGE = 800;
const MAX_METERS_PER_UNIT = 1.2;
const MIN_METERS_PER_UNIT = 0.08;

const CIRCUIT_KEY_ANCHORS = {
  2: [-1.0169, 52.0733],
  4: [19.2486, 47.5789],
  6: [11.7132, 44.3439],
  7: [5.9714, 50.4372],
  9: [-97.6411, 30.1328],
  10: [144.968, -37.8497],
  14: [-46.6997, -23.7036],
  15: [2.2611, 41.57],
  19: [14.7647, 47.2197],
  22: [7.4206, 43.7347],
  23: [-73.5263, 45.5],
  39: [9.2811, 45.6156],
  46: [136.541, 34.8431],
  49: [121.219, 31.3389],
  55: [4.54, 52.3888],
  61: [103.8634, 1.2914],
  63: [50.5106, 26.0325],
  65: [-99.0907, 19.4042],
  70: [54.6031, 24.4672],
  144: [49.8533, 40.3725],
  149: [39.1044, 21.6319],
  150: [51.4542, 25.49],
  151: [-80.2389, 25.9581],
  152: [-115.1718, 36.1147],
};

const CIRCUIT_NAME_ANCHORS = {
  Melbourne: [144.968, -37.8497],
  Shanghai: [121.219, 31.3389],
  Suzuka: [136.541, 34.8431],
  Sakhir: [50.5106, 26.0325],
  Jeddah: [39.1044, 21.6319],
  Miami: [-80.2389, 25.9581],
  Imola: [11.7132, 44.3439],
  "Monte Carlo": [7.4206, 43.7347],
  Catalunya: [2.2611, 41.57],
  Montreal: [-73.5263, 45.5],
  Spielberg: [14.7647, 47.2197],
  Silverstone: [-1.0169, 52.0733],
  "Spa-Francorchamps": [5.9714, 50.4372],
  Hungaroring: [19.2486, 47.5789],
  Zandvoort: [4.54, 52.3888],
  Monza: [9.2811, 45.6156],
  Baku: [49.8533, 40.3725],
  Singapore: [103.8634, 1.2914],
  Austin: [-97.6411, 30.1328],
  "Mexico City": [-99.0907, 19.4042],
  Interlagos: [-46.6997, -23.7036],
  "Las Vegas": [-115.1718, 36.1147],
  Lusail: [51.4542, 25.49],
  "Yas Marina Circuit": [54.6031, 24.4672],
};

const CIRCUIT_CALIBRATIONS = {
  // Phase 2 refinement: populate per-circuit exact values.
  // These defaults keep behavior stable and avoid drift.
  4: { rotateDeg: 90, flipX: true, flipY: false, spanMeters: 2200 },
  // Melbourne currently needs a quarter-turn + mirror for OpenF1 local axes.
  10: { rotateDeg: 90, flipX: true, flipY: false, spanMeters: 2200 },
};

const TrackMap = {
  mounted() {
    this.drivers = {};
    this.mapReady = false;
    this.animFrameId = null;

    this.carStates = {};
    this.trackOutline = [];
    this.trackTrail = [];
    this.trackCloud = [];
    this.trackCloudCells = new Set();
    this.trailDriver = null;

    this.sessionMeta = null;
    this.localFrame = null;

    this.trackFeature = null;
    this.carFeatures = new globalThis.Map();
    this.hasFitView = false;
    this.userMovedMap = false;

    // Canvas interaction state (zoom + pan)
    this.viewZoom = 1;
    this.viewPanX = 0;
    this.viewPanY = 0;
    this.isDragging = false;
    this.dragLastX = 0;
    this.dragLastY = 0;

    this.initMap();

    this.handleEvent("drivers_loaded", ({ drivers }) => {
      this.drivers = drivers || {};
      this.resetSessionGraphics();
    });

    this.handleEvent("session_meta", ({ session }) => {
      this.sessionMeta = session || null;
      this.localFrame = null;
      this.hasFitView = false;
      this.userMovedMap = false;
      this.updateHud();

      if (this.olMap) {
        const view = this.olMap.getView();
        view.setCenter(fromLonLat(this.getAnchorLonLat()));
        view.setZoom(13);
      }
    });

    this.handleEvent("track_outline", ({ points }) => {
      if (points && points.length > 0) {
        this.trackOutline = points;
        this.localFrame = null;
        this.hasFitView = false;
      }
    });

    this.handleEvent("locations_update", ({ locations }) => {
      this.updateCarPositions(locations || {});
    });

    this.handleEvent("replay_data", (data) => {
      if (data.locations) {
        this.trackTrail = [];
        this.trailDriver = null;
        this.localFrame = null;
        this.hasFitView = false;
        this.updateCarPositions(data.locations, true);
      }
    });
  },

  resetSessionGraphics() {
    this.carStates = {};
    this.trackOutline = [];
    this.trackTrail = [];
    this.trackCloud = [];
    this.trackCloudCells = new Set();
    this.trailDriver = null;
    this.localFrame = null;
    this.hasFitView = false;
    this.userMovedMap = false;
    this.viewZoom = 1;
    this.viewPanX = 0;
    this.viewPanY = 0;
    this.isDragging = false;

    if (this.trackSource) {
      this.trackSource.clear();
      this.trackFeature = null;
    }

    if (this.carSource) {
      this.carSource.clear();
      this.carFeatures.clear();
    }

    this.updateHud();
  },

  initMap() {
    const container = this.el.querySelector("#map-container");

    // OpenF1 coordinates are local track-space values, not georeferenced lat/lng.
    // Rendering directly in local space is more reliable for car motion and order.
    this.initCanvas(container);
  },

  initOpenLayers(container) {
    container.style.position = "relative";

    this.trackSource = new VectorSource();
    this.carSource = new VectorSource();

    this.trackLayer = new VectorLayer({ source: this.trackSource });
    this.carLayer = new VectorLayer({ source: this.carSource });

    this.olMap = new OLMap({
      target: container,
      layers: [
        new TileLayer({ source: new OSM(), opacity: 0.95 }),
        this.trackLayer,
        this.carLayer,
      ],
      view: new View({
        center: fromLonLat(this.getAnchorLonLat()),
        zoom: 13,
        minZoom: 2,
        maxZoom: 19,
      }),
    });

    this.olMap.on("movestart", () => {
      if (this.hasFitView) this.userMovedMap = true;
    });

    this.hudEl = document.createElement("div");
    this.hudEl.className =
      "absolute top-3 left-3 z-20 rounded-md bg-gray-900/80 border border-gray-700 px-3 py-2 text-[11px] text-gray-200 backdrop-blur-sm pointer-events-none";
    container.appendChild(this.hudEl);
    this.updateHud();

    this.mapReady = true;
    this.startAnimationLoop();
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
    this.canvas.style.touchAction = "none";

    this._wheelHandler = (event) => {
      event.preventDefault();

      const rect = canvas.getBoundingClientRect();
      const mouseX = event.clientX - rect.left;
      const mouseY = event.clientY - rect.top;

      const oldZoom = this.viewZoom;
      const zoomFactor = event.deltaY < 0 ? 1.1 : 0.9;
      const newZoom = Math.max(0.6, Math.min(6, oldZoom * zoomFactor));

      if (newZoom === oldZoom) return;

      const cx = canvas.width / 2;
      const cy = canvas.height / 2;

      // Keep the point under cursor stable while zooming.
      this.viewPanX =
        mouseX - ((mouseX - cx - this.viewPanX) / oldZoom) * newZoom - cx;
      this.viewPanY =
        mouseY - ((mouseY - cy - this.viewPanY) / oldZoom) * newZoom - cy;

      this.viewZoom = newZoom;
    };

    this._pointerDownHandler = (event) => {
      this.isDragging = true;
      this.dragLastX = event.clientX;
      this.dragLastY = event.clientY;
      canvas.setPointerCapture?.(event.pointerId);
    };

    this._pointerMoveHandler = (event) => {
      if (!this.isDragging) return;

      const dx = event.clientX - this.dragLastX;
      const dy = event.clientY - this.dragLastY;
      this.dragLastX = event.clientX;
      this.dragLastY = event.clientY;

      this.viewPanX += dx;
      this.viewPanY += dy;
    };

    this._pointerUpHandler = (event) => {
      this.isDragging = false;
      canvas.releasePointerCapture?.(event.pointerId);
    };

    this._dblClickHandler = (event) => {
      event.preventDefault();
      this.viewZoom = 1;
      this.viewPanX = 0;
      this.viewPanY = 0;
    };

    canvas.addEventListener("wheel", this._wheelHandler, { passive: false });
    canvas.addEventListener("pointerdown", this._pointerDownHandler);
    canvas.addEventListener("pointermove", this._pointerMoveHandler);
    canvas.addEventListener("pointerup", this._pointerUpHandler);
    canvas.addEventListener("pointercancel", this._pointerUpHandler);
    canvas.addEventListener("dblclick", this._dblClickHandler);

    const resize = () => {
      canvas.width = container.clientWidth;
      canvas.height = container.clientHeight;
    };

    window.addEventListener("resize", resize);
    this._resizeHandler = resize;
    resize();

    this.startAnimationLoop();
  },

  updateHud() {
    if (!this.hudEl) return;
    const session = this.sessionMeta || {};
    const title = session.circuit_short_name || "Circuit";
    const subtitle = [session.location, session.country_name].filter(Boolean).join(", ");
    const base = subtitle ? `${title} - ${subtitle}` : title;

    if (!this.localFrame || this.localFrame.provisional) {
      this.hudEl.textContent = `${base} - calibrating track`;
    } else {
      this.hudEl.textContent = base;
    }
  },

  getCircuitKey() {
    const key = this.sessionMeta?.circuit_key;
    return Number.isInteger(key) ? key : null;
  },

  getAnchorLonLat() {
    const key = this.getCircuitKey();
    if (key && CIRCUIT_KEY_ANCHORS[key]) return CIRCUIT_KEY_ANCHORS[key];

    const shortName = this.sessionMeta?.circuit_short_name;
    if (shortName && CIRCUIT_NAME_ANCHORS[shortName]) return CIRCUIT_NAME_ANCHORS[shortName];

    return DEFAULT_ANCHOR;
  },

  getCalibration() {
    const key = this.getCircuitKey();
    return CIRCUIT_CALIBRATIONS[key] || { rotateDeg: 0, flipX: false, flipY: false, spanMeters: 2200 };
  },

  getTrackPath() {
    return this.trackOutline.length > 0 ? this.trackOutline : this.trackTrail;
  },

  pathLooksCircuit(path) {
    if (!path || path.length < 120) return false;

    const first = path[0];
    const last = path[path.length - 1];
    const dx = first.x - last.x;
    const dy = first.y - last.y;
    const closure = Math.sqrt(dx * dx + dy * dy);

    return closure < 1200;
  },

  ensureLocalFrame(entries) {
    if (this.localFrame && !this.localFrame.provisional) return;

    const path = this.getTrackPath();
    if (!this.pathLooksCircuit(path)) return;
    const points = path;

    const xs = points.map((pt) => pt.x).sort((a, b) => a - b);
    const ys = points.map((pt) => pt.y).sort((a, b) => a - b);

    // Robust bounds (ignore extreme outliers/teleports)
    const lo = Math.floor(xs.length * 0.05);
    const hi = Math.max(lo + 1, Math.ceil(xs.length * 0.95) - 1);

    const minX = xs[lo];
    const maxX = xs[hi];
    const minY = ys[lo];
    const maxY = ys[hi];

    const calibration = this.getCalibration();
    const dominantRange = Math.max(maxX - minX, maxY - minY) || 1;

    // Avoid locking transform while shape is too small/noisy
    if (dominantRange < MIN_FRAME_RANGE) return;

    const metersPerUnit = Math.max(
      MIN_METERS_PER_UNIT,
      Math.min(MAX_METERS_PER_UNIT, calibration.spanMeters / dominantRange),
    );

    this.localFrame = {
      centerX: (minX + maxX) / 2,
      centerY: (minY + maxY) / 2,
      metersPerUnit,
      rotateDeg: calibration.rotateDeg,
      flipX: calibration.flipX,
      flipY: calibration.flipY,
      anchor: this.getAnchorLonLat(),
      rawRange: dominantRange,
      provisional: false,
    };

    this.updateHud();
  },

  ensureProvisionalFrame(entries) {
    if (this.localFrame) return;
    if (!entries || entries.length < 4) return;

    const points = entries.map(([, car]) => car.current);
    const xs = points.map((pt) => pt.x).sort((a, b) => a - b);
    const ys = points.map((pt) => pt.y).sort((a, b) => a - b);

    const lo = Math.floor(xs.length * 0.05);
    const hi = Math.max(lo + 1, Math.ceil(xs.length * 0.95) - 1);

    const minX = xs[lo];
    const maxX = xs[hi];
    const minY = ys[lo];
    const maxY = ys[hi];

    const dominantRange = Math.max(maxX - minX, maxY - minY) || 1;
    if (dominantRange < 200) return;

    const calibration = this.getCalibration();
    const metersPerUnit = Math.max(
      MIN_METERS_PER_UNIT,
      Math.min(MAX_METERS_PER_UNIT, calibration.spanMeters / Math.max(dominantRange, MIN_FRAME_RANGE)),
    );

    this.localFrame = {
      centerX: (minX + maxX) / 2,
      centerY: (minY + maxY) / 2,
      metersPerUnit,
      rotateDeg: calibration.rotateDeg,
      flipX: calibration.flipX,
      flipY: calibration.flipY,
      anchor: this.getAnchorLonLat(),
      rawRange: dominantRange,
      provisional: true,
    };

    this.updateHud();
  },

  localToLonLat(x, y) {
    if (!this.localFrame) return this.getAnchorLonLat();

    let dx = x - this.localFrame.centerX;
    let dy = y - this.localFrame.centerY;

    if (this.localFrame.flipX) dx = -dx;
    if (this.localFrame.flipY) dy = -dy;

    if (this.localFrame.rotateDeg) {
      const rad = (this.localFrame.rotateDeg * Math.PI) / 180;
      const cos = Math.cos(rad);
      const sin = Math.sin(rad);
      const rx = dx * cos - dy * sin;
      const ry = dx * sin + dy * cos;
      dx = rx;
      dy = ry;
    }

    const mx = dx * this.localFrame.metersPerUnit;
    const my = -dy * this.localFrame.metersPerUnit;
    const [anchorLon, anchorLat] = this.localFrame.anchor;

    const dLat = my / 111_320;
    const dLon = mx / (111_320 * Math.cos((anchorLat * Math.PI) / 180));

    return [anchorLon + dLon, anchorLat + dLat];
  },

  addToTrail(locations) {
    if (!this.trailDriver) {
      const keys = Object.keys(locations);
      if (keys.length === 0) return;
      this.trailDriver = keys[0];
    }

    const loc = locations[this.trailDriver];
    if (!loc || loc.x == null || loc.y == null) {
      this.addToTrackCloud(locations);
      return;
    }

    if (this.trackTrail.length > 0) {
      const last = this.trackTrail[this.trackTrail.length - 1];
      const dx = loc.x - last.x;
      const dy = loc.y - last.y;
      const dist = Math.sqrt(dx * dx + dy * dy);
      if (dist < MIN_TRAIL_DISTANCE) {
        this.addToTrackCloud(locations);
        return;
      }

      // For big jumps, start a new segment by accepting the point anyway.
    }

    this.trackTrail.push({ x: loc.x, y: loc.y });
    if (this.trackTrail.length > MAX_TRAIL_POINTS) {
      this.trackTrail = this.trackTrail.slice(-MAX_TRAIL_POINTS);
    }

    this.addToTrackCloud(locations);
  },

  addToTrackCloud(locations) {
    for (const loc of Object.values(locations)) {
      if (!loc || loc.x == null || loc.y == null) continue;

      const gx = Math.round(loc.x / TRACK_CLOUD_CELL);
      const gy = Math.round(loc.y / TRACK_CLOUD_CELL);
      const key = `${gx}:${gy}`;

      if (this.trackCloudCells.has(key)) continue;

      this.trackCloudCells.add(key);
      this.trackCloud.push({ x: loc.x, y: loc.y, key });

      if (this.trackCloud.length > MAX_TRACK_CLOUD_POINTS) {
        const removed = this.trackCloud.shift();
        if (removed) this.trackCloudCells.delete(removed.key);
      }
    }
  },

  updateCarPositions(locations, snap = false) {
    if (!this.mapReady) return;

    const now = performance.now();
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
          position: loc.position || null,
        };
      } else {
        const dx = loc.x - existing.target.x;
        const dy = loc.y - existing.target.y;
        const dist = Math.sqrt(dx * dx + dy * dy);

        if (dist > TELEPORT_THRESHOLD) {
          // Snap large jumps (pit lane / data discontinuity) instead of dropping cars.
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
        existing.position = loc.position ?? existing.position;
      }
    }
  },

  updateOpenLayersFrame() {
    if (!this.olMap) return;

    const entries = Object.entries(this.carStates);
    if (entries.length === 0) return;

    const now = performance.now();
    for (const [, car] of entries) {
      const elapsed = now - car.startTime;
      const t = Math.min(elapsed / LERP_DURATION_MS, 1);
      const ease = 1 - Math.pow(1 - t, 3);
      car.current = {
        x: car.prev.x + (car.target.x - car.prev.x) * ease,
        y: car.prev.y + (car.target.y - car.prev.y) * ease,
      };
    }

    this.ensureLocalFrame(entries);
    this.ensureProvisionalFrame(entries);
    if (!this.localFrame) {
      return;
    }

    const path = this.getTrackPath();
    const shouldDrawTrack = this.pathLooksCircuit(path) && !this.localFrame.provisional;

    if (shouldDrawTrack) {
      const coords = path.map((pt) => fromLonLat(this.localToLonLat(pt.x, pt.y)));

      if (!this.trackFeature) {
        this.trackFeature = new Feature(new LineString(coords));
        this.trackFeature.setStyle(
          new Style({
            stroke: new Stroke({ color: "rgba(239,68,68,0.8)", width: 4 }),
          }),
        );
        this.trackSource.addFeature(this.trackFeature);
      } else {
        this.trackFeature.getGeometry().setCoordinates(coords);
      }
    } else if (this.trackFeature) {
      this.trackSource.removeFeature(this.trackFeature);
      this.trackFeature = null;
    }

    const activeIds = new Set(entries.map(([id]) => id));

    for (const [driverNum, feature] of this.carFeatures.entries()) {
      if (!activeIds.has(driverNum)) {
        this.carSource.removeFeature(feature);
        this.carFeatures.delete(driverNum);
      }
    }

    for (const [driverNum, car] of entries) {
      const projected = fromLonLat(this.localToLonLat(car.current.x, car.current.y));
      let feature = this.carFeatures.get(driverNum);

      if (!feature) {
        feature = new Feature(new Point(projected));
        this.carSource.addFeature(feature);
        this.carFeatures.set(driverNum, feature);
      } else {
        feature.getGeometry().setCoordinates(projected);
      }

      const label = car.position ? `P${car.position} ${car.code}` : car.code;

      feature.setStyle(
        new Style({
          image: new CircleStyle({
            radius: car.drs_active ? 7 : 6,
            fill: new Fill({ color: `#${car.team_colour}` }),
            stroke: new Stroke({ color: "#fff", width: 1.25 }),
          }),
          text: new Text({
            text: label,
            offsetY: -16,
            fill: new Fill({ color: "#fff" }),
            stroke: new Stroke({ color: "rgba(0,0,0,0.75)", width: 3 }),
            font: "bold 11px ui-monospace, SFMono-Regular, Menlo, monospace",
          }),
        }),
      );
    }

    if (!this.hasFitView && !this.userMovedMap) {
      const view = this.olMap.getView();
      if (this.trackFeature) {
        view.fit(this.trackFeature.getGeometry().getExtent(), {
          padding: [80, 80, 80, 80],
          duration: 600,
          maxZoom: 16,
        });
      } else {
        const center = fromLonLat(this.getAnchorLonLat());
        view.setCenter(center);
        view.setZoom(13);
      }

      this.hasFitView = true;
    }
  },

  startAnimationLoop() {
    const loop = () => {
      if (this.olMap) {
        this.updateOpenLayersFrame();
      } else {
        this.redrawCanvasFallback();
      }

      this.animFrameId = requestAnimationFrame(loop);
    };

    this.animFrameId = requestAnimationFrame(loop);
  },

  redrawCanvasFallback() {
    if (!this.canvas || !this.ctx) return;

    const ctx = this.ctx;
    const w = this.canvas.width;
    const h = this.canvas.height;
    const now = performance.now();

    for (const [, car] of Object.entries(this.carStates)) {
      const elapsed = now - car.startTime;
      const t = Math.min(elapsed / LERP_DURATION_MS, 1);
      const ease = 1 - Math.pow(1 - t, 3);
      car.current = {
        x: car.prev.x + (car.target.x - car.prev.x) * ease,
        y: car.prev.y + (car.target.y - car.prev.y) * ease,
      };
    }

    ctx.fillStyle = "#0a0a0a";
    ctx.fillRect(0, 0, w, h);

    const entries = Object.entries(this.carStates);
    if (entries.length === 0) {
      ctx.fillStyle = "#444";
      ctx.font = "14px monospace";
      ctx.textAlign = "center";
      ctx.fillText("Loading track data...", w / 2, h / 2);
      return;
    }

    const trackPath = this.getTrackPath();
    const xs = [
      ...entries.map(([, c]) => c.current.x),
      ...trackPath.map((p) => p.x),
      ...this.trackCloud.map((p) => p.x),
    ];
    const ys = [
      ...entries.map(([, c]) => c.current.y),
      ...trackPath.map((p) => p.y),
      ...this.trackCloud.map((p) => p.y),
    ];
    const minX = Math.min(...xs);
    const maxX = Math.max(...xs);
    const minY = Math.min(...ys);
    const maxY = Math.max(...ys);
    const rangeX = maxX - minX || 1;
    const rangeY = maxY - minY || 1;
    const scale = Math.min((w - 80) / rangeX, (h - 80) / rangeY);
    const offsetX = (w - rangeX * scale) / 2;
    const offsetY = (h - rangeY * scale) / 2;

    const centerX = w / 2;
    const centerY = h / 2;

    const transformScreen = (px, py) => ({
      x: (px - centerX) * this.viewZoom + centerX + this.viewPanX,
      y: (py - centerY) * this.viewZoom + centerY + this.viewPanY,
    });

    if (trackPath.length > 1) {
      ctx.beginPath();
      const firstX = (trackPath[0].x - minX) * scale + offsetX;
      const firstY = (trackPath[0].y - minY) * scale + offsetY;
      const firstT = transformScreen(firstX, firstY);
      ctx.moveTo(firstT.x, firstT.y);

      for (let i = 1; i < trackPath.length; i += 1) {
        const tx = (trackPath[i].x - minX) * scale + offsetX;
        const ty = (trackPath[i].y - minY) * scale + offsetY;
        const t = transformScreen(tx, ty);
        ctx.lineTo(t.x, t.y);
      }

      ctx.strokeStyle = "rgba(120, 130, 150, 0.45)";
      ctx.lineWidth = Math.max(2, 8 * this.viewZoom);
      ctx.lineCap = "round";
      ctx.lineJoin = "round";
      ctx.stroke();

      // Start/finish marker based on first segment direction
      const secondX = (trackPath[1].x - minX) * scale + offsetX;
      const secondY = (trackPath[1].y - minY) * scale + offsetY;
      const secondT = transformScreen(secondX, secondY);

      const dirX = secondT.x - firstT.x;
      const dirY = secondT.y - firstT.y;
      const dirLen = Math.sqrt(dirX * dirX + dirY * dirY) || 1;
      const nx = -dirY / dirLen;
      const ny = dirX / dirLen;

      const markerHalf = Math.max(6, 10 * this.viewZoom);

      const sx1 = firstT.x + nx * markerHalf;
      const sy1 = firstT.y + ny * markerHalf;
      const sx2 = firstT.x - nx * markerHalf;
      const sy2 = firstT.y - ny * markerHalf;

      ctx.beginPath();
      ctx.moveTo(sx1, sy1);
      ctx.lineTo(sx2, sy2);
      ctx.strokeStyle = "rgba(0,0,0,0.9)";
      ctx.lineWidth = Math.max(3, 5 * this.viewZoom);
      ctx.stroke();

      ctx.beginPath();
      ctx.moveTo(sx1, sy1);
      ctx.lineTo(sx2, sy2);
      ctx.strokeStyle = "rgba(255,255,255,0.95)";
      ctx.lineWidth = Math.max(1.5, 2.5 * this.viewZoom);
      ctx.stroke();

      ctx.fillStyle = "rgba(255,255,255,0.9)";
      ctx.font = `bold ${Math.max(8, 10 * this.viewZoom)}px monospace`;
      ctx.textAlign = "left";
      ctx.fillText("S/F", firstT.x + 8, firstT.y - 8);
    } else if (this.trackCloud.length > 0) {
      // Fallback: draw track density cloud while full outline is unavailable.
      ctx.fillStyle = "rgba(125, 140, 165, 0.35)";
      for (const pt of this.trackCloud) {
        const px0 = (pt.x - minX) * scale + offsetX;
        const py0 = (pt.y - minY) * scale + offsetY;
        const t = transformScreen(px0, py0);
        ctx.beginPath();
        ctx.arc(t.x, t.y, Math.max(1.5, 2 * this.viewZoom), 0, Math.PI * 2);
        ctx.fill();
      }
    }

    for (const [, car] of entries) {
      const px0 = (car.current.x - minX) * scale + offsetX;
      const py0 = (car.current.y - minY) * scale + offsetY;
      const transformed = transformScreen(px0, py0);
      const px = transformed.x;
      const py = transformed.y;

      ctx.beginPath();
      ctx.arc(px, py, Math.max(3, 5 * this.viewZoom), 0, Math.PI * 2);
      ctx.fillStyle = `#${car.team_colour}`;
      ctx.fill();

      const label = car.position ? `P${car.position} ${car.code}` : car.code;
      ctx.fillStyle = "rgba(255,255,255,0.95)";
      ctx.font = `bold ${Math.max(8, 10 * this.viewZoom)}px monospace`;
      ctx.textAlign = "center";
      ctx.fillText(label, px, py - Math.max(8, 10 * this.viewZoom));
    }

    const session = this.sessionMeta || {};
    const title = session.circuit_short_name || "Track";
    const subtitle = [session.location, session.country_name].filter(Boolean).join(", ");
    ctx.textAlign = "left";
    ctx.fillStyle = "rgba(255,255,255,0.8)";
    ctx.font = "12px sans-serif";
    ctx.fillText(subtitle ? `${title} - ${subtitle}` : title, 12, 20);
    ctx.font = "11px sans-serif";
    ctx.fillStyle = "rgba(180,180,180,0.8)";
    ctx.fillText("Scroll: zoom | Drag: pan | Double-click: reset", 12, 38);

    if (trackPath.length <= 1 && this.trackCloud.length > 0) {
      ctx.fillStyle = "rgba(180,180,180,0.7)";
      ctx.fillText("Building track outline...", 12, 56);
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

    if (this.canvas) {
      if (this._wheelHandler) this.canvas.removeEventListener("wheel", this._wheelHandler);
      if (this._pointerDownHandler) this.canvas.removeEventListener("pointerdown", this._pointerDownHandler);
      if (this._pointerMoveHandler) this.canvas.removeEventListener("pointermove", this._pointerMoveHandler);
      if (this._pointerUpHandler) {
        this.canvas.removeEventListener("pointerup", this._pointerUpHandler);
        this.canvas.removeEventListener("pointercancel", this._pointerUpHandler);
      }
      if (this._dblClickHandler) this.canvas.removeEventListener("dblclick", this._dblClickHandler);
    }

    if (this.olMap) {
      this.olMap.setTarget(undefined);
      this.olMap = null;
    }
  },
};

export default TrackMap;
