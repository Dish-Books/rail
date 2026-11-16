// Passes what a person does over the App item's picture to the tab in Rail's browser it is a picture of: clicks,
// moves, the wheel and keys, in the tab's own 1920x1080 pixels. The picture is sized as a design is, whole on screen. While commenting, a click picks the element under it
// instead, and nothing reaches the tab.
import { fitWidth, VIEWPORT_HEIGHT, VIEWPORT_WIDTH, visibleHeight } from "./design_frame.js";

export { VIEWPORT_HEIGHT, VIEWPORT_WIDTH };

const MOVE_EVERY_MS = 50;
const BUTTONS = ["left", "middle", "right"];

// The picture fills the frame at the tab's own shape, so a point maps by the frame's size alone.
export function toViewport(event, rect) {
  const x = ((event.clientX - rect.left) / rect.width) * VIEWPORT_WIDTH;
  const y = ((event.clientY - rect.top) / rect.height) * VIEWPORT_HEIGHT;

  return {
    x: Math.round(Math.min(Math.max(x, 0), VIEWPORT_WIDTH)),
    y: Math.round(Math.min(Math.max(y, 0), VIEWPORT_HEIGHT))
  };
}

// Alt 1, Ctrl 2, Meta 4, Shift 8, as Chrome adds them up.
export function modifiers(event) {
  return (event.altKey ? 1 : 0) | (event.ctrlKey ? 2 : 0) | (event.metaKey ? 4 : 0) | (event.shiftKey ? 8 : 0);
}

// The text a key types, as Chrome wants it with the key: one character, or a carriage return for Enter.
export function keyText(event) {
  if (event.ctrlKey || event.metaKey) return null;
  if (event.key === "Enter") return "\r";
  return event.key.length === 1 ? event.key : null;
}

export const AppInput = {
  mounted() {
    this.fit = () => {
      if (this.el.parentElement.clientWidth === 0) return;
      const width = fitWidth(this.el.parentElement.clientWidth, visibleHeight(this.el, 24));
      this.el.style.width = `${width}px`;
      this.el.style.height = `${(width * VIEWPORT_HEIGHT) / VIEWPORT_WIDTH}px`;
    };
    this.observer = new ResizeObserver(this.fit);
    this.observer.observe(this.el.parentElement);
    window.addEventListener("resize", this.fit);
    this.fit();

    this.lastMove = 0;
    this.pressed = "none";

    this.point = (event) => toViewport(event, this.el.getBoundingClientRect());
    // The comment box floats over the picture, and what is done in it is Rail's, not the app's.
    this.ours = (event) => event.target instanceof Element && event.target.closest("[data-app-ui]") !== null;
    this.commenting = () => this.el.dataset.commenting === "true";
    this.send = (payload) => this.pushEventTo(this.el, "app_input", payload);

    this.onDown = (event) => {
      if (this.ours(event)) return;
      event.preventDefault();
      this.el.focus();
      if (this.commenting()) return;
      this.pressed = BUTTONS[event.button] || "left";
      this.send({
        kind: "mouse",
        type: "mousePressed",
        button: this.pressed,
        click_count: event.detail || 1,
        modifiers: modifiers(event),
        ...this.point(event)
      });
    };

    this.onUp = (event) => {
      if (this.ours(event)) return;
      if (this.commenting()) {
        this.pushEventTo(this.el, "app_pick", this.point(event));
        return;
      }
      const button = BUTTONS[event.button] || "left";
      this.pressed = "none";
      this.send({
        kind: "mouse",
        type: "mouseReleased",
        button,
        click_count: event.detail || 1,
        modifiers: modifiers(event),
        ...this.point(event)
      });
    };

    this.onMove = (event) => {
      if (this.ours(event)) return;
      if (this.commenting()) return;
      const now = Date.now();
      if (now - this.lastMove < MOVE_EVERY_MS) return;
      this.lastMove = now;
      this.send({
        kind: "mouse",
        type: "mouseMoved",
        button: this.pressed,
        modifiers: modifiers(event),
        ...this.point(event)
      });
    };

    this.onWheel = (event) => {
      if (this.ours(event)) return;
      event.preventDefault();
      if (this.commenting()) return;
      this.send({ kind: "wheel", dx: event.deltaX, dy: event.deltaY, ...this.point(event) });
    };

    // Keys typed here are the app's, never Rail's own shortcuts, so they stop at the picture.
    this.onKey = (event) => {
      if (this.ours(event)) return;
      if (this.commenting()) return;
      event.preventDefault();
      event.stopPropagation();
      const down = event.type === "keydown";
      const text = down ? keyText(event) : null;
      const payload = {
        kind: "key",
        type: down ? (text ? "keyDown" : "rawKeyDown") : "keyUp",
        key: event.key,
        code: event.code,
        key_code: event.keyCode,
        modifiers: modifiers(event)
      };
      if (text) payload.text = text;
      this.send(payload);
    };

    this.onPaste = (event) => {
      if (this.ours(event)) return;
      if (this.commenting()) return;
      const text = event.clipboardData?.getData("text/plain");
      if (!text) return;
      event.preventDefault();
      this.send({ kind: "text", text });
    };

    this.onContextMenu = (event) => {
      if (!this.ours(event)) event.preventDefault();
    };

    this.el.addEventListener("mousedown", this.onDown);
    this.el.addEventListener("mouseup", this.onUp);
    this.el.addEventListener("mousemove", this.onMove);
    this.el.addEventListener("wheel", this.onWheel, { passive: false });
    this.el.addEventListener("keydown", this.onKey);
    this.el.addEventListener("keyup", this.onKey);
    this.el.addEventListener("paste", this.onPaste);
    this.el.addEventListener("contextmenu", this.onContextMenu);
  },

  updated() {
    this.fit();
  },

  destroyed() {
    this.observer?.disconnect();
    window.removeEventListener("resize", this.fit);
  }
};
