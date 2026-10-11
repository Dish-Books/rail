// Paints what the task's browser is looking at, frame by frame, and once the run driving it has finished,
// sends the teammate's clicks, keys and scrolls to it.
//
// The frames arrive as server events rather than as an assign, because they come
// several times a second and nothing else on the page moves with them: sending
// them through the render would diff the whole panel to change one image. The
// previous frame is only swapped out once the next one has decoded, so the pane
// never blinks white between them.

export const PAGE = { width: 1920, height: 1080 };

// Where a point on the shown frame falls on the page, through the letterboxing `object-contain` adds.
export function pagePoint(rect, clientX, clientY, page = PAGE) {
  const scale = Math.min(rect.width / page.width, rect.height / page.height);
  const left = rect.left + (rect.width - page.width * scale) / 2;
  const top = rect.top + (rect.height - page.height * scale) / 2;
  const clamp = (value, limit) => Math.min(Math.max(value, 0), limit);

  return {
    x: Math.round(clamp((clientX - left) / scale, page.width)),
    y: Math.round(clamp((clientY - top) / scale, page.height))
  };
}

// DevTools' modifier bits: Alt 1, Ctrl 2, Meta 4, Shift 8.
export function modifiers(event) {
  return (event.altKey ? 1 : 0) | (event.ctrlKey ? 2 : 0) | (event.metaKey ? 4 : 0) | (event.shiftKey ? 8 : 0);
}

// A trackpad sends dozens of wheel events a second, so the deltas of one animation frame go as one event.
export function wheelBatcher(push, schedule) {
  let pending = null;

  return (dx, dy, point) => {
    if (pending) {
      pending.dx += dx;
      pending.dy += dy;
      pending.x = point.x;
      pending.y = point.y;
      return;
    }

    pending = { type: "wheel", x: point.x, y: point.y, dx, dy };
    schedule(() => {
      const event = pending;
      pending = null;
      push(event);
    });
  };
}

export const BrowserScreencast = {
  mounted() {
    this.handleEvent("browser:frame", ({ data }) => this.paint(data));

    // LiveView leaves the image unpatched, so the mode is read off its wrapper at each event.
    this.frame = this.el.parentElement;
    const interactive = () => this.frame?.dataset.interactive === "true";
    const send = (event) => this.pushEventTo(this.el, "browser_input", event);
    const point = (event) => pagePoint(this.el.getBoundingClientRect(), event.clientX, event.clientY);
    const wheel = wheelBatcher(send, (callback) => window.requestAnimationFrame(callback));

    this.onClick = (event) => {
      if (!interactive()) return;
      this.frame.focus();
      send({ type: "click", ...point(event) });
    };

    this.onKey = (event) => {
      if (!interactive()) return;
      event.preventDefault();
      send({ type: "key", key: event.key, code: event.code, modifiers: modifiers(event) });
      // Sent on to the page too, so a dialog in it closes, and the frame lets go so the keyboard can leave it.
      if (event.key === "Escape") this.frame.blur();
    };

    this.onWheel = (event) => {
      if (!interactive()) return;
      event.preventDefault();
      wheel(event.deltaX, event.deltaY, point(event));
    };

    this.frame?.addEventListener("click", this.onClick);
    this.frame?.addEventListener("keydown", this.onKey);
    this.frame?.addEventListener("wheel", this.onWheel, { passive: false });
  },

  destroyed() {
    this.pending = null;
    this.frame?.removeEventListener("click", this.onClick);
    this.frame?.removeEventListener("keydown", this.onKey);
    this.frame?.removeEventListener("wheel", this.onWheel);
  },

  paint(data) {
    const next = new Image();

    next.onload = () => {
      if (this.pending !== next) return;

      this.el.src = next.src;
      this.el.dataset.live = "true";
    };

    this.pending = next;
    next.src = `data:image/jpeg;base64,${data}`;
  }
};
