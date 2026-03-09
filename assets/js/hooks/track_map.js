const DEFAULT_LERP_MS = 500;
const MIN_LERP_MS = 120;
const MAX_LERP_MS = 1600;
const TELEPORT_THRESHOLD = 5000;
const MAX_LABEL_DISTANCE = 20000;
const TRACK_EVENT_TTL_MS = 10000;
const POSITION_NOISE_THRESHOLD = 1.8;

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
    this.circuitCorners = [];
    this.circuitPath = [];
    this.trackEvents = [];

    this.sessionMeta = null;
    this.localFrame = null;

    this.trackFeature = null;
    this.carFeatures = new globalThis.Map();
    this.avatarCache = new globalThis.Map();
    this.hasFitView = false;
    this.userMovedMap = false;
    this.followDriver = null;
    this.trackBounds = null;
    this.trackBoundsKey = null;
    this.driverHitAreas = [];
    this.pendingTap = null;
    this.debugMapSelection = false;
    this.lastSelectProbe = null;

    try {
      const params = new URLSearchParams(globalThis.location?.search || "");
      this.debugMapSelection =
        params.get("map_debug") === "1" || globalThis.localStorage?.getItem("f1_map_debug") === "1";
    } catch (_error) {
      this.debugMapSelection = false;
    }

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
      this.circuitCorners = Array.isArray(session?.circuit_corners) ? session.circuit_corners : [];
      this.circuitPath = Array.isArray(session?.circuit_path) ? session.circuit_path : [];
      this.updateHud();

      if (this.olMap) {
        const view = this.olMap.getView();
        view.setCenter(fromLonLat(this.getAnchorLonLat()));
        view.setZoom(13);
      }
    });

    this.handleEvent("track_outline", () => {
      // Track rendering now relies exclusively on meetings.circuit_info_url data.
    });

    this.handleEvent("locations_update", ({ locations }) => {
      this.updateCarPositions(locations || {});
    });

    this.handleEvent("follow_driver", ({ driver_number }) => {
      this.followDriver = Number.isInteger(driver_number) ? String(driver_number) : null;
    });

    this.handleEvent("track_events", ({ events }) => {
      this.addTrackEvents(events || []);
    });

    this.handleEvent("replay_data", (data) => {
      if (data.locations) {
        this.localFrame = null;
        this.hasFitView = false;
        this.updateCarPositions(data.locations, true);
      }
    });
  },

  resetSessionGraphics() {
    this.carStates = {};
    this.circuitCorners = [];
    this.circuitPath = [];
    this.trackEvents = [];
    this.localFrame = null;
    this.hasFitView = false;
    this.userMovedMap = false;
    this.followDriver = null;
    this.trackBounds = null;
    this.trackBoundsKey = null;
    this.driverHitAreas = [];
    this.pendingTap = null;
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
    this.activePointers = new globalThis.Map();
    this.pinchLastDistance = null;
    this.pinchLastCenter = null;
    this.canvasCssWidth = 0;
    this.canvasCssHeight = 0;
    this.mouseTapCandidate = null;

    this._wheelHandler = (event) => {
      event.preventDefault();

      const { x: mouseX, y: mouseY } = this.getEventCanvasPoint(event, canvas);

      const zoomFactor = event.deltaY < 0 ? 1.1 : 0.9;
      this.zoomAroundPoint(mouseX, mouseY, zoomFactor);
    };

    this._pointerDownHandler = (event) => {
      const { x: localX, y: localY } = this.getEventCanvasPoint(event, canvas);

      this.activePointers.set(event.pointerId, {
        x: localX,
        y: localY,
      });

      if (this.activePointers.size === 1) {
        this.isDragging = true;
        this.dragLastX = event.clientX;
        this.dragLastY = event.clientY;

        if (event.pointerType === "mouse" && event.button === 0) {
          this.mouseTapCandidate = {
            pointerId: event.pointerId,
            x: localX,
            y: localY,
            moved: false,
          };
          this.pendingTap = null;
        } else {
          this.pendingTap = {
            pointerId: event.pointerId,
            x: localX,
            y: localY,
            startedAt: performance.now(),
            moved: false,
          };
        }
      } else {
        this.isDragging = false;
        this.pendingTap = null;

        const pinch = this.getPinchData();
        if (pinch) {
          this.pinchLastDistance = pinch.distance;
          this.pinchLastCenter = pinch.center;
        }
      }

      if (event.pointerType !== "mouse") {
        canvas.setPointerCapture?.(event.pointerId);
      }
    };

    this._pointerMoveHandler = (event) => {
      const { x: localX, y: localY } = this.getEventCanvasPoint(event, canvas);

      if (this.activePointers.has(event.pointerId)) {
        this.activePointers.set(event.pointerId, { x: localX, y: localY });
      }

      if (this.pendingTap && this.pendingTap.pointerId === event.pointerId) {
        const movedDist = Math.hypot(localX - this.pendingTap.x, localY - this.pendingTap.y);
        if (movedDist > 9) this.pendingTap.moved = true;
      }

      if (this.mouseTapCandidate && this.mouseTapCandidate.pointerId === event.pointerId) {
        const movedDist = Math.hypot(localX - this.mouseTapCandidate.x, localY - this.mouseTapCandidate.y);
        if (movedDist > 6) this.mouseTapCandidate.moved = true;
      }

      if (this.activePointers.size >= 2) {
        const pinch = this.getPinchData();
        if (!pinch) return;

        if (this.pinchLastDistance && pinch.distance > 0) {
          const factor = pinch.distance / this.pinchLastDistance;
          this.zoomAroundPoint(pinch.center.x, pinch.center.y, factor);

          if (this.pinchLastCenter) {
            this.viewPanX += pinch.center.x - this.pinchLastCenter.x;
            this.viewPanY += pinch.center.y - this.pinchLastCenter.y;
          }
        }

        this.pinchLastDistance = pinch.distance;
        this.pinchLastCenter = pinch.center;
        return;
      }

      if (!this.isDragging) return;

      const dx = event.clientX - this.dragLastX;
      const dy = event.clientY - this.dragLastY;

      this.dragLastX = event.clientX;
      this.dragLastY = event.clientY;

      this.viewPanX += dx;
      this.viewPanY += dy;
    };

    this._pointerUpHandler = (event) => {
      const { x: localX, y: localY } = this.getEventCanvasPoint(event, canvas);

      const tap = this.pendingTap;
      const now = performance.now();

      if (
        tap &&
        tap.pointerId === event.pointerId &&
        !tap.moved &&
        now - tap.startedAt <= 350 &&
        this.activePointers.size === 1
      ) {
        this.selectDriverAt(localX, localY);
      }

      this.pendingTap = null;

      if (this.mouseTapCandidate && this.mouseTapCandidate.pointerId === event.pointerId) {
        if (event.pointerType === "mouse" && !this.mouseTapCandidate.moved) {
          this.selectDriverAt(this.mouseTapCandidate.x, this.mouseTapCandidate.y);
        }

        this.mouseTapCandidate = null;
      }

      this.activePointers.delete(event.pointerId);
      this.isDragging = false;
      this.pinchLastDistance = null;
      this.pinchLastCenter = null;

      if (this.activePointers.size === 1) {
        const remaining = this.activePointers.values().next().value;
        if (remaining) {
          const rect = canvas.getBoundingClientRect();
          this.isDragging = true;
          this.dragLastX = rect.left + remaining.x;
          this.dragLastY = rect.top + remaining.y;
        }
      }

      if (event.pointerType !== "mouse") {
        canvas.releasePointerCapture?.(event.pointerId);
      }
    };

    this._zoomInBtn = this.el.querySelector("[data-map-zoom-in]");
    this._zoomOutBtn = this.el.querySelector("[data-map-zoom-out]");
    this._zoomInHandler = (event) => {
      event.preventDefault();
      this.zoomByFactor(1.2);
    };
    this._zoomOutHandler = (event) => {
      event.preventDefault();
      this.zoomByFactor(0.84);
    };

    this._zoomInBtn?.addEventListener("click", this._zoomInHandler);
    this._zoomOutBtn?.addEventListener("click", this._zoomOutHandler);

    this._spacePauseHandler = (event) => {
      const isSpace = event.code === "Space" || event.key === " ";
      if (!isSpace || event.repeat) return;

      const target = event.target;
      const editable =
        target instanceof HTMLElement &&
          (target.tagName === "INPUT" ||
            target.tagName === "TEXTAREA" ||
            target.isContentEditable) ||
        false;

      if (editable) return;

      event.preventDefault();
      this.pushEvent("replay_toggle_pause", {});
    };

    window.addEventListener("keydown", this._spacePauseHandler);

    canvas.addEventListener("wheel", this._wheelHandler, { passive: false });
    canvas.addEventListener("pointerdown", this._pointerDownHandler);
    canvas.addEventListener("pointermove", this._pointerMoveHandler);
    canvas.addEventListener("pointerup", this._pointerUpHandler);
    canvas.addEventListener("pointercancel", this._pointerUpHandler);

    const resize = () => this.resizeCanvas();

    window.addEventListener("resize", resize);
    this._resizeHandler = resize;
    resize();

    this.startAnimationLoop();
  },

  resetView() {
    this.viewZoom = 1;
    this.viewPanX = 0;
    this.viewPanY = 0;
  },

  resizeCanvas() {
    if (!this.canvas || !this.ctx) return;

    const cssWidth = Math.max(1, this.canvas.parentElement?.clientWidth || this.canvas.clientWidth || 1);
    const cssHeight = Math.max(1, this.canvas.parentElement?.clientHeight || this.canvas.clientHeight || 1);
    const dpr = Math.min(globalThis.devicePixelRatio || 1, 3);

    this.canvasCssWidth = cssWidth;
    this.canvasCssHeight = cssHeight;

    this.canvas.width = Math.round(cssWidth * dpr);
    this.canvas.height = Math.round(cssHeight * dpr);
    this.ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    this.ctx.imageSmoothingEnabled = true;
  },

  getPinchData() {
    if (this.activePointers.size < 2) return null;

    const [a, b] = Array.from(this.activePointers.values());
    const dx = b.x - a.x;
    const dy = b.y - a.y;

    return {
      distance: Math.hypot(dx, dy),
      center: {
        x: (a.x + b.x) / 2,
        y: (a.y + b.y) / 2,
      },
    };
  },

  getEventCanvasPoint(event, canvas) {
    if (event.target === canvas && Number.isFinite(event.offsetX) && Number.isFinite(event.offsetY)) {
      return { x: event.offsetX, y: event.offsetY };
    }

    const rect = canvas.getBoundingClientRect();
    return {
      x: event.clientX - rect.left,
      y: event.clientY - rect.top,
    };
  },

  selectDriverAt(x, y) {
    if (!Array.isArray(this.driverHitAreas) || this.driverHitAreas.length === 0) return;

    let closest = null;
    let bestDistSq = Infinity;

    for (const area of this.driverHitAreas) {
      const dx = x - area.x;
      const dy = y - area.y;
      const distSq = dx * dx + dy * dy;

      if (distSq <= area.radius * area.radius && distSq < bestDistSq) {
        bestDistSq = distSq;
        closest = area;
      }
    }

    if (closest) {
      this.pushEvent("select_driver", { driver_number: String(closest.driverNumber) });
    }

    if (this.debugMapSelection) {
      this.lastSelectProbe = {
        x,
        y,
        driverNumber: closest ? String(closest.driverNumber) : null,
        hitRadius: closest?.radius || null,
        hitCount: this.driverHitAreas.length,
        at: performance.now(),
      };

      globalThis.console.debug("[TrackMap debug] select probe", this.lastSelectProbe);
    }
  },

  zoomByFactor(factor) {
    if (!this.canvas || !Number.isFinite(factor) || factor <= 0) return;

    const cx = this.canvasCssWidth || this.canvas.clientWidth || this.canvas.width;
    const cy = this.canvasCssHeight || this.canvas.clientHeight || this.canvas.height;
    const centerX = cx / 2;
    const centerY = cy / 2;
    this.zoomAroundPoint(centerX, centerY, factor);
  },

  zoomAroundPoint(pointX, pointY, factor) {
    if (!this.canvas) return;

    const oldZoom = this.viewZoom;
    const newZoom = Math.max(0.6, Math.min(6, oldZoom * factor));

    if (newZoom === oldZoom) return;

    const canvasWidth = this.canvasCssWidth || this.canvas.clientWidth || this.canvas.width;
    const canvasHeight = this.canvasCssHeight || this.canvas.clientHeight || this.canvas.height;
    const cx = canvasWidth / 2;
    const cy = canvasHeight / 2;

    this.viewPanX = pointX - ((pointX - cx - this.viewPanX) / oldZoom) * newZoom - cx;
    this.viewPanY = pointY - ((pointY - cy - this.viewPanY) / oldZoom) * newZoom - cy;
    this.viewZoom = newZoom;
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
    if (this.circuitPath.length >= 20) {
      const points = this.circuitPath
        .filter((p) => Number.isFinite(p.x) && Number.isFinite(p.y))
        .map((p) => ({ x: p.x, y: p.y }));

      if (points.length >= 20) {
        return [...points, points[0]];
      }
    }

    return this.getCircuitPath();
  },

  getTrackBounds(path) {
    if (!Array.isArray(path) || path.length < 2) return null;

    const first = path[0];
    const mid = path[Math.floor(path.length / 2)];
    const last = path[path.length - 1];
    const key = [
      path.length,
      first.x.toFixed(1),
      first.y.toFixed(1),
      mid.x.toFixed(1),
      mid.y.toFixed(1),
      last.x.toFixed(1),
      last.y.toFixed(1),
    ].join(":");

    if (this.trackBoundsKey === key && this.trackBounds) {
      return this.trackBounds;
    }

    let minX = Infinity;
    let maxX = -Infinity;
    let minY = Infinity;
    let maxY = -Infinity;

    for (const point of path) {
      if (!Number.isFinite(point.x) || !Number.isFinite(point.y)) continue;
      if (point.x < minX) minX = point.x;
      if (point.x > maxX) maxX = point.x;
      if (point.y < minY) minY = point.y;
      if (point.y > maxY) maxY = point.y;
    }

    if (!Number.isFinite(minX) || !Number.isFinite(maxX) || !Number.isFinite(minY) || !Number.isFinite(maxY)) {
      return null;
    }

    const pad = 140;
    this.trackBounds = {
      minX: minX - pad,
      maxX: maxX + pad,
      minY: minY - pad,
      maxY: maxY + pad,
    };
    this.trackBoundsKey = key;

    return this.trackBounds;
  },

  getCircuitPath() {
    if (!Array.isArray(this.circuitCorners) || this.circuitCorners.length < 3) return [];

    const points = this.circuitCorners
      .filter((c) => Number.isFinite(c.x) && Number.isFinite(c.y))
      .map((c) => ({ x: c.x, y: c.y }));

    if (points.length < 3) return [];

    // Close the loop for drawing.
    return [...points, points[0]];
  },

  getCircuitCorners() {
    if (!Array.isArray(this.circuitCorners)) return [];

    return this.circuitCorners
      .filter((c) => Number.isFinite(c.x) && Number.isFinite(c.y) && Number.isFinite(c.number))
      .map((c) => ({
        x: c.x,
        y: c.y,
        number: c.number,
        letter: c.letter,
        angle: Number.isFinite(c.angle) ? c.angle : null,
      }));
  },

  pathLooksCircuit(path) {
    if (!path || path.length < 4) return false;

    if (path.length < 60) {
      const xs = path.map((pt) => pt.x);
      const ys = path.map((pt) => pt.y);
      const rangeX = Math.max(...xs) - Math.min(...xs);
      const rangeY = Math.max(...ys) - Math.min(...ys);
      return Math.max(rangeX, rangeY) > 2_000;
    }

    if (path.length < 120) return false;

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

  updateCarPositions(locations, snap = false) {
    if (!this.mapReady) return;

    const now = performance.now();

    for (const [driverNum, loc] of Object.entries(locations)) {
      if (loc.x == null || loc.y == null) continue;

      const existing = this.carStates[driverNum];

      if (!existing || snap) {
        this.carStates[driverNum] = {
          prev: { x: loc.x, y: loc.y },
          target: { x: loc.x, y: loc.y },
          current: { x: loc.x, y: loc.y },
          startTime: now,
          lastUpdateAt: now,
          lerpMs: DEFAULT_LERP_MS,
          code: loc.code || driverNum,
          team_colour: loc.team_colour || "FFFFFF",
          headshot_url: loc.headshot_url || null,
          drs_active: loc.drs_active || false,
          position: loc.position || null,
        };
      } else {
        const dx = loc.x - existing.target.x;
        const dy = loc.y - existing.target.y;
        const dist = Math.sqrt(dx * dx + dy * dy);

        if (dist > MAX_LABEL_DISTANCE && !snap) {
          continue;
        }

        if (dist > TELEPORT_THRESHOLD) {
          // Snap large jumps (pit lane / data discontinuity) instead of dropping cars.
          existing.prev = { x: loc.x, y: loc.y };
          existing.target = { x: loc.x, y: loc.y };
          existing.current = { x: loc.x, y: loc.y };
          existing.lerpMs = MIN_LERP_MS;
        } else {
          const updateGap = Math.max(1, now - (existing.lastUpdateAt || now));

          // Ignore tiny telemetry jitter and smooth toward the incoming target.
          const nextTarget =
            dist < POSITION_NOISE_THRESHOLD
              ? {
                x: existing.target.x + (loc.x - existing.target.x) * 0.35,
                y: existing.target.y + (loc.y - existing.target.y) * 0.35,
              }
              : { x: loc.x, y: loc.y };

          // Follow real update cadence: long polling intervals get longer blend,
          // high-frequency MQTT updates stay snappy.
          existing.lerpMs = Math.max(MIN_LERP_MS, Math.min(MAX_LERP_MS, updateGap * 1.05));
          existing.prev = { x: existing.current.x, y: existing.current.y };
          existing.target = nextTarget;
        }

        existing.startTime = now;
        existing.lastUpdateAt = now;
        existing.code = loc.code || existing.code;
        existing.team_colour = loc.team_colour || existing.team_colour;
        existing.headshot_url = loc.headshot_url || existing.headshot_url;
        existing.drs_active = loc.drs_active || false;
        existing.position = loc.position ?? existing.position;
      }
    }
  },

  addTrackEvents(events) {
    if (!Array.isArray(events) || events.length === 0) return;

    const now = performance.now();

    for (const event of events) {
      if (!event || !Number.isFinite(event.x) || !Number.isFinite(event.y)) continue;

      this.trackEvents.push({
        id: event.id || `evt-${now}-${Math.random()}`,
        type: event.type || "event",
        x: event.x,
        y: event.y,
        label: event.label || "Event",
        createdAt: now,
      });
    }

    const seen = new Set();
    this.trackEvents = this.trackEvents.filter((event) => {
      if (seen.has(event.id)) return false;
      seen.add(event.id);
      return true;
    });
  },

  getAvatarImage(url) {
    if (!url || typeof url !== "string") return null;

    let entry = this.avatarCache.get(url);

    if (!entry) {
      const image = new Image();
      entry = { status: "loading", image };
      this.avatarCache.set(url, entry);

      image.crossOrigin = "anonymous";
      image.onload = () => {
        const current = this.avatarCache.get(url);
        if (current) current.status = "loaded";
      };
      image.onerror = () => {
        const current = this.avatarCache.get(url);
        if (current) current.status = "error";
      };
      image.src = url;
    }

    if (entry.status === "loaded") return entry.image;
    return null;
  },

  pruneTrackEvents(now) {
    this.trackEvents = this.trackEvents.filter((event) => now - event.createdAt <= TRACK_EVENT_TTL_MS);
  },

  updateOpenLayersFrame() {
    if (!this.olMap) return;

    const entries = Object.entries(this.carStates);
    if (entries.length === 0) return;

    const now = performance.now();
    this.pruneTrackEvents(now);
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
    const w = this.canvasCssWidth || this.canvas.clientWidth || this.canvas.width;
    const h = this.canvasCssHeight || this.canvas.clientHeight || this.canvas.height;
    const now = performance.now();
    this.pruneTrackEvents(now);

    for (const [, car] of Object.entries(this.carStates)) {
      const elapsed = now - car.startTime;
      const lerpMs = Number.isFinite(car.lerpMs) ? car.lerpMs : DEFAULT_LERP_MS;
      const t = Math.min(elapsed / lerpMs, 1);
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
    const trackBounds = this.getTrackBounds(trackPath);

    let minX;
    let maxX;
    let minY;
    let maxY;

    if (trackBounds) {
      minX = trackBounds.minX;
      maxX = trackBounds.maxX;
      minY = trackBounds.minY;
      maxY = trackBounds.maxY;
    } else {
      const xs = entries.map(([, c]) => c.current.x);
      const ys = entries.map(([, c]) => c.current.y);
      minX = Math.min(...xs);
      maxX = Math.max(...xs);
      minY = Math.min(...ys);
      maxY = Math.max(...ys);
    }

    const rangeX = maxX - minX || 1;
    const rangeY = maxY - minY || 1;
    const scale = Math.min((w - 80) / rangeX, (h - 80) / rangeY);
    const offsetX = (w - rangeX * scale) / 2;
    const offsetY = (h - rangeY * scale) / 2;

    if (this.followDriver) {
      const followed = this.carStates[this.followDriver];

      if (followed?.current) {
        const px0 = (followed.current.x - minX) * scale + offsetX;
        const py0 = (followed.current.y - minY) * scale + offsetY;
        const cx = w / 2;
        const cy = h / 2;

        const targetPanX = -((px0 - cx) * this.viewZoom);
        const targetPanY = -((py0 - cy) * this.viewZoom);

        this.viewPanX += (targetPanX - this.viewPanX) * 0.22;
        this.viewPanY += (targetPanY - this.viewPanY) * 0.22;
      }
    }

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

      // Corner markers from circuit_info_url metadata
      const corners = this.getCircuitCorners();
      if (corners.length > 0) {
        for (const corner of corners) {
          const cx0 = (corner.x - minX) * scale + offsetX;
          const cy0 = (corner.y - minY) * scale + offsetY;
          const cpt = transformScreen(cx0, cy0);

          const angleDeg = corner.angle ?? -90;
          const angleRad = (angleDeg * Math.PI) / 180;
          const labelDist = Math.max(12, 18 * this.viewZoom);
          const lx = cpt.x + Math.cos(angleRad) * labelDist;
          const ly = cpt.y + Math.sin(angleRad) * labelDist;

          // guide tick
          ctx.beginPath();
          ctx.moveTo(cpt.x, cpt.y);
          ctx.lineTo(lx, ly);
          ctx.strokeStyle = "rgba(148, 163, 184, 0.6)";
          ctx.lineWidth = Math.max(1, 1.5 * this.viewZoom);
          ctx.stroke();

          // marker point
          ctx.beginPath();
          ctx.arc(cpt.x, cpt.y, Math.max(1.5, 2.5 * this.viewZoom), 0, Math.PI * 2);
          ctx.fillStyle = "rgba(226, 232, 240, 0.9)";
          ctx.fill();

          const label = `T${corner.number}${corner.letter || ""}`;
          ctx.font = `bold ${Math.max(7, 9 * this.viewZoom)}px monospace`;
          ctx.textAlign = "center";
          ctx.fillStyle = "rgba(226, 232, 240, 0.95)";
          ctx.strokeStyle = "rgba(15, 23, 42, 0.8)";
          ctx.lineWidth = Math.max(1.5, 2 * this.viewZoom);
          ctx.strokeText(label, lx, ly - 2);
          ctx.fillText(label, lx, ly - 2);
        }
      }
    }

    this.driverHitAreas = [];

    for (const [driverNum, car] of entries) {
      const px0 = (car.current.x - minX) * scale + offsetX;
      const py0 = (car.current.y - minY) * scale + offsetY;
      const transformed = transformScreen(px0, py0);
      const px = transformed.x;
      const py = transformed.y;

      const avatarRadius = Math.max(5, 8 * this.viewZoom);
      const avatarImage = this.getAvatarImage(car.headshot_url);

      if (avatarImage) {
        ctx.save();
        ctx.beginPath();
        ctx.arc(px, py, avatarRadius, 0, Math.PI * 2);
        ctx.clip();
        ctx.drawImage(avatarImage, px - avatarRadius, py - avatarRadius, avatarRadius * 2, avatarRadius * 2);
        ctx.restore();

        ctx.beginPath();
        ctx.arc(px, py, avatarRadius, 0, Math.PI * 2);
        ctx.strokeStyle = `#${car.team_colour}`;
        ctx.lineWidth = Math.max(1.5, 2.2 * this.viewZoom);
        ctx.stroke();
      } else {
        ctx.beginPath();
        ctx.arc(px, py, Math.max(3, 5 * this.viewZoom), 0, Math.PI * 2);
        ctx.fillStyle = `#${car.team_colour}`;
        ctx.fill();
      }

      const label = car.position ? `P${car.position} ${car.code}` : car.code;
      ctx.fillStyle = "rgba(255,255,255,0.95)";
      ctx.font = `bold ${Math.max(8, 10 * this.viewZoom)}px monospace`;
      ctx.textAlign = "center";
      ctx.fillText(label, px, py - Math.max(8, 10 * this.viewZoom));

      this.driverHitAreas.push({
        driverNumber: driverNum,
        x: px,
        y: py,
        radius: Math.max(20, avatarRadius + 12),
      });

    }

    if (this.followDriver) {
      const followed = this.carStates[this.followDriver];
      if (followed?.current) {
        const fx0 = (followed.current.x - minX) * scale + offsetX;
        const fy0 = (followed.current.y - minY) * scale + offsetY;
        const fp = transformScreen(fx0, fy0);

        ctx.beginPath();
        ctx.arc(fp.x, fp.y, Math.max(10, 16 * this.viewZoom), 0, Math.PI * 2);
        ctx.strokeStyle = "rgba(59,130,246,0.8)";
        ctx.lineWidth = Math.max(2, 3 * this.viewZoom);
        ctx.stroke();
      }
    }

    if (this.trackEvents.length > 0) {
      for (const event of this.trackEvents) {
        const px0 = (event.x - minX) * scale + offsetX;
        const py0 = (event.y - minY) * scale + offsetY;
        const transformed = transformScreen(px0, py0);
        const age = now - event.createdAt;
        const fade = Math.max(0, 1 - age / TRACK_EVENT_TTL_MS);

        const eventColor = event.type === "incident" ? "239, 68, 68" : "34, 197, 94";

        ctx.beginPath();
        ctx.arc(transformed.x, transformed.y, Math.max(8, 12 * this.viewZoom), 0, Math.PI * 2);
        ctx.strokeStyle = `rgba(${eventColor}, ${0.75 * fade})`;
        ctx.lineWidth = Math.max(2, 3 * this.viewZoom);
        ctx.stroke();

        ctx.beginPath();
        ctx.arc(transformed.x, transformed.y, Math.max(2.5, 3.5 * this.viewZoom), 0, Math.PI * 2);
        ctx.fillStyle = `rgba(${eventColor}, ${0.95 * fade})`;
        ctx.fill();

        ctx.font = `bold ${Math.max(8, 10 * this.viewZoom)}px monospace`;
        ctx.textAlign = "left";
        ctx.fillStyle = `rgba(241, 245, 249, ${0.95 * fade})`;
        ctx.strokeStyle = `rgba(2, 6, 23, ${0.9 * fade})`;
        ctx.lineWidth = Math.max(1, 2 * this.viewZoom);
        const labelX = transformed.x + Math.max(10, 14 * this.viewZoom);
        const labelY = transformed.y - Math.max(8, 10 * this.viewZoom);
        ctx.strokeText(event.label, labelX, labelY);
        ctx.fillText(event.label, labelX, labelY);
      }
    }

    const session = this.sessionMeta || {};
    const title = session.circuit_short_name || "Track";
    const subtitle = [session.location, session.country_name].filter(Boolean).join(", ");
    ctx.textAlign = "left";
    ctx.fillStyle = "rgba(255,255,255,0.8)";
    ctx.font = "12px sans-serif";
    ctx.fillText(subtitle ? `${title} - ${subtitle}` : title, 12, 20);

    if (trackPath.length <= 1) {
      ctx.fillStyle = "rgba(180,180,180,0.7)";
      ctx.font = "11px sans-serif";
      ctx.fillText("Waiting for circuit info...", 12, 38);
    }

    if (this.debugMapSelection) {
      for (const area of this.driverHitAreas) {
        ctx.beginPath();
        ctx.arc(area.x, area.y, area.radius, 0, Math.PI * 2);
        ctx.strokeStyle = "rgba(251, 191, 36, 0.45)";
        ctx.lineWidth = 1;
        ctx.stroke();

        ctx.fillStyle = "rgba(251, 191, 36, 0.9)";
        ctx.font = "10px monospace";
        ctx.textAlign = "center";
        ctx.fillText(String(area.driverNumber), area.x, area.y + 3);
      }

      const probe = this.lastSelectProbe;
      if (probe && performance.now() - probe.at <= 3_000) {
        ctx.beginPath();
        ctx.arc(probe.x, probe.y, 5, 0, Math.PI * 2);
        ctx.fillStyle = probe.driverNumber ? "rgba(34,197,94,0.9)" : "rgba(239,68,68,0.9)";
        ctx.fill();

        ctx.textAlign = "left";
        ctx.font = "11px monospace";
        ctx.fillStyle = "rgba(248,250,252,0.95)";
        const msg = probe.driverNumber ? `hit ${probe.driverNumber}` : `miss (${probe.hitCount} areas)`;
        ctx.fillText(msg, 12, h - 14);
      }
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
    }

    if (this._zoomInBtn && this._zoomInHandler) {
      this._zoomInBtn.removeEventListener("click", this._zoomInHandler);
    }

    if (this._zoomOutBtn && this._zoomOutHandler) {
      this._zoomOutBtn.removeEventListener("click", this._zoomOutHandler);
    }

    if (this._spacePauseHandler) {
      window.removeEventListener("keydown", this._spacePauseHandler);
    }

    if (this.olMap) {
      this.olMap.setTarget(undefined);
      this.olMap = null;
    }
  },
};

export default TrackMap;
