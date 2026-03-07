/**
 * TrackMap LiveView Hook
 *
 * Integrates with GEOLYTIX/xyz MAPP library for rendering
 * the circuit map and car position markers.
 *
 * Falls back to a canvas-based renderer if MAPP is not loaded.
 */

const TrackMap = {
  mounted() {
    this.drivers = {};
    this.markers = {};
    this.mapReady = false;

    // Try to init MAPP, fall back to canvas
    this.initMap();

    // Handle LiveView events
    this.handleEvent("drivers_loaded", (data) => {
      this.drivers = data.drivers;
    });

    this.handleEvent("locations_update", (data) => {
      this.updateCarPositions(data.locations);
    });

    this.handleEvent("replay_data", (data) => {
      if (data.locations) {
        this.updateCarPositions(data.locations);
      }
    });
  },

  async initMap() {
    const container = this.el.querySelector("#map-container");

    // Check if MAPP (GEOLYTIX/xyz) is available
    if (window.mapp) {
      await this.initMAPP(container);
    } else {
      // Fallback: canvas-based track renderer
      this.initCanvas(container);
    }
  },

  async initMAPP(container) {
    try {
      const mapview = await mapp.Mapview({
        host: container,
        locale: {
          layers: {},
        },
        view: {
          lat: 0,
          lng: 0,
          z: 15,
        },
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
    // Create a canvas-based track visualization
    const canvas = document.createElement("canvas");
    canvas.id = "track-canvas";
    canvas.style.width = "100%";
    canvas.style.height = "100%";
    container.appendChild(canvas);

    this.canvas = canvas;
    this.ctx = canvas.getContext("2d");
    this.mapReady = true;

    // Handle resize
    const resize = () => {
      canvas.width = container.clientWidth;
      canvas.height = container.clientHeight;
      this.redraw();
    };

    window.addEventListener("resize", resize);
    resize();

    console.log("[TrackMap] Canvas renderer initialized");
  },

  updateCarPositions(locations) {
    if (!this.mapReady) return;

    if (this.mapview) {
      this.updateMAPPPositions(locations);
    } else if (this.canvas) {
      this.canvasLocations = locations;
      this.redraw();
    }
  },

  updateMAPPPositions(locations) {
    // Update or create markers on the MAPP mapview
    for (const [driverNum, loc] of Object.entries(locations)) {
      const id = `driver-${driverNum}`;
      const colour = `#${loc.team_colour || "FFFFFF"}`;

      if (this.markers[id]) {
        // Update existing marker position
        // MAPP marker position update depends on the layer type
        this.markers[id].setGeometry?.({
          type: "Point",
          coordinates: [loc.x, loc.y],
        });
      } else {
        // Create new marker
        // This is simplified — actual MAPP integration would use
        // a vector layer with features
        this.markers[id] = { x: loc.x, y: loc.y, colour, code: loc.code };
      }
    }
  },

  redraw() {
    if (!this.canvas || !this.ctx) return;

    const ctx = this.ctx;
    const w = this.canvas.width;
    const h = this.canvas.height;

    // Clear
    ctx.fillStyle = "#0a0a0a";
    ctx.fillRect(0, 0, w, h);

    const locations = this.canvasLocations;
    if (!locations || Object.keys(locations).length === 0) {
      // Draw placeholder
      ctx.fillStyle = "#333";
      ctx.font = "14px monospace";
      ctx.textAlign = "center";
      ctx.fillText("Waiting for car position data...", w / 2, h / 2);
      return;
    }

    // Find bounds of all car positions to auto-scale
    const points = Object.values(locations);
    const xs = points.map((p) => p.x).filter((x) => x != null);
    const ys = points.map((p) => p.y).filter((y) => y != null);

    if (xs.length === 0) return;

    const minX = Math.min(...xs);
    const maxX = Math.max(...xs);
    const minY = Math.min(...ys);
    const maxY = Math.max(...ys);

    const rangeX = maxX - minX || 1;
    const rangeY = maxY - minY || 1;

    const padding = 60;
    const scaleX = (w - padding * 2) / rangeX;
    const scaleY = (h - padding * 2) / rangeY;
    const scale = Math.min(scaleX, scaleY);

    const offsetX = (w - rangeX * scale) / 2;
    const offsetY = (h - rangeY * scale) / 2;

    // Draw each car
    for (const [driverNum, loc] of Object.entries(locations)) {
      if (loc.x == null || loc.y == null) continue;

      const px = (loc.x - minX) * scale + offsetX;
      const py = (loc.y - minY) * scale + offsetY;
      const colour = `#${loc.team_colour || "FFFFFF"}`;

      // Car dot
      ctx.beginPath();
      ctx.arc(px, py, 6, 0, Math.PI * 2);
      ctx.fillStyle = colour;
      ctx.fill();

      // Driver code label
      ctx.fillStyle = "#fff";
      ctx.font = "bold 10px monospace";
      ctx.textAlign = "center";
      ctx.fillText(loc.code || driverNum, px, py - 10);
    }
  },

  destroyed() {
    // Cleanup
    if (this.mapview) {
      // MAPP cleanup
    }
  },
};

export default TrackMap;
