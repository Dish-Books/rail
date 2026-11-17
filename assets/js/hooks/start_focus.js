// A started row moves to In Progress, often far off screen, so the chip takes focus only where it can be seen. Otherwise
// the nearest Start that can be seen does, below the started row first, so a person starting several keeps their place.
export function calculateFocusTarget(doc, chipId, placeIds, view) {
  const seen = (element) => {
    const box = element?.getBoundingClientRect();
    return box !== undefined && box.bottom > view.top && box.top < view.bottom;
  };
  const chip = doc.getElementById(chipId);
  if (seen(chip)) return chip;
  return placeIds.map((id) => doc.getElementById(id)).find(seen) ?? chip;
}

// Focus left in Start's row falls to the body when a later patch moves the row, so the watch waits for that too. Each
// element is read by id every time, since a row built anew brings new ones, and any key or pointer press ends the watch.
export function handFocus(doc, hadFocus, chipId, placeIds, viewport) {
  if (!hadFocus || !doc.getElementById(chipId)) return;

  const settle = () => {
    if (doc.activeElement !== doc.body) return;
    calculateFocusTarget(doc, chipId, placeIds, viewport())?.focus({ preventScroll: true });
  };
  const watching = new AbortController();
  const { signal } = watching;

  settle();
  doc.addEventListener("phx:update", settle, { signal });
  doc.addEventListener("keydown", () => watching.abort(), { capture: true, signal });
  doc.addEventListener("pointerdown", () => watching.abort(), { capture: true, signal });
}

export const StartFocus = {
  mounted() {
    // An Issues page row, or nothing on the issue page, where only the button counts.
    this.row = this.el.closest("[id^='issue-card-']");
    this.hadFocus = this.holds(document.activeElement);
    this.notePlace();
    // Focus or a press anywhere else means the person has moved on, and the chip should not take focus from them.
    this.onFocusIn = (event) => {
      this.hadFocus = this.holds(event.target);
      if (this.hadFocus) this.notePlace();
    };
    this.onPointerDown = (event) => {
      if (!this.el.contains(event.target)) this.hadFocus = false;
    };
    document.addEventListener("focusin", this.onFocusIn);
    document.addEventListener("pointerdown", this.onPointerDown, true);
  },

  // Starting patches the button, and the other Starts may have changed since focus came in.
  updated() {
    this.notePlace();
  },

  destroyed() {
    document.removeEventListener("focusin", this.onFocusIn);
    document.removeEventListener("pointerdown", this.onPointerDown, true);
    // Only #main-content scrolls, under the app bar, so what can be seen is its box, not the window's.
    const viewport = () =>
      document.getElementById("main-content")?.getBoundingClientRect() ?? { top: 0, bottom: window.innerHeight };
    handFocus(document, this.hadFocus, this.el.dataset.chip, this.placeIds, viewport);
  },

  // Start's row counts, but not its status picker, whose menu hands focus back itself.
  holds(target) {
    if (!this.row) return target === this.el;
    return this.row.contains(target) && !target.closest("[id^='status-picker-']");
  },

  // The other Starts on the page, those below this one first, then those above it, nearest first.
  notePlace() {
    const starts = [...document.querySelectorAll("[phx-hook=StartFocus]")].map((start) => start.id);
    const at = starts.indexOf(this.el.id);
    this.placeIds = [...starts.slice(at + 1), ...starts.slice(0, at).reverse()];
  }
};
