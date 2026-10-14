// Lets the reader drag a sidebar wider or narrower by the handle on its edge, or
// step it with the arrow keys, and keeps the width for the next page in this
// browser. The width is a CSS variable, so the stacked layout on a narrow screen
// ignores it; the page keeps it through patches with JS.ignore_attributes.
const MIN = 280;
const STEP = 32;
// What the sidebar always leaves the pane beside it.
const PANE_MIN = 360;

export const SidebarResize = {
  mounted() {
    this.key = `rail:${this.el.id}-width`;
    this.handle = this.el.querySelector("[data-resize-handle]");
    this.apply(this.stored());

    this.onDown = (event) => this.start(event);
    this.onKey = (event) => this.keyStep(event);
    this.handle?.addEventListener("pointerdown", this.onDown);
    this.handle?.addEventListener("keydown", this.onKey);
  },

  destroyed() {
    this.handle?.removeEventListener("pointerdown", this.onDown);
    this.handle?.removeEventListener("keydown", this.onKey);
  },

  stored() {
    try {
      const width = parseInt(localStorage.getItem(this.key), 10);
      return Number.isFinite(width) ? width : null;
    } catch {
      return null;
    }
  },

  max() {
    const parent = this.el.parentElement;
    return Math.max(MIN, (parent ? parent.clientWidth : window.innerWidth) - PANE_MIN);
  },

  apply(width) {
    if (width == null) return;
    const clamped = Math.round(Math.min(Math.max(width, MIN), this.max()));
    this.el.style.setProperty("--sidebar-width", `${clamped}px`);
    this.handle?.setAttribute("aria-valuenow", String(clamped));
    return clamped;
  },

  save(width) {
    try {
      localStorage.setItem(this.key, String(width));
    } catch {
      // A browser that keeps nothing still resizes for this page.
    }
  },

  start(event) {
    event.preventDefault();
    const left = this.el.getBoundingClientRect().left;
    let width = null;

    const move = (moved) => {
      width = this.apply(moved.clientX - left);
    };

    const up = () => {
      document.removeEventListener("pointermove", move);
      document.removeEventListener("pointerup", up);
      document.body.style.removeProperty("cursor");
      document.body.style.removeProperty("user-select");
      if (width != null) this.save(width);
    };

    document.body.style.cursor = "col-resize";
    document.body.style.userSelect = "none";
    document.addEventListener("pointermove", move);
    document.addEventListener("pointerup", up);
  },

  keyStep(event) {
    const step = { ArrowLeft: -STEP, ArrowRight: STEP }[event.key];
    if (!step) return;
    event.preventDefault();
    const width = this.apply(this.el.getBoundingClientRect().width + step);
    if (width != null) this.save(width);
  }
};
