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

// Only keyboard focus is the person's place, since a clicked button is focused too and would hand on focus unseen.
// With no row, on the issue page, only the button counts; a row's status picker hands focus back itself.
export function holdsPlace(target, button, row) {
  if (!target?.matches(":focus-visible")) return false;
  if (!row) return target === button;
  return row.contains(target) && !target.closest("[id^='status-picker-']");
}

// A patch that moves rows can drop this row's focus to the body: the control comes back, or Start if it was rebuilt.
// A Start already removed is left to handFocus, since phx:update comes before destroyed in the patch that removes it.
export function restoreFocus(doc, hadFocus, focused, button) {
  if (!hadFocus || !button.isConnected || doc.activeElement !== doc.body) return;
  (focused?.isConnected ? focused : button).focus({ preventScroll: true });
}

export const StartFocus = {
  mounted() {
    // An Issues page row, or nothing on the issue page, where only the button counts.
    this.row = this.el.closest("[id^='issue-card-']");
    this.notePlace();
    this.noteFocus(document.activeElement);
    // Focus anywhere else means the person has moved on. Any press, on Start too, means a pointer is in use, and a
    // mouse Start leaves focus where the browser puts it.
    this.onFocusIn = (event) => this.noteFocus(event.target);
    this.onPointerDown = () => {
      this.hadFocus = false;
    };
    this.onUpdate = () => restoreFocus(document, this.hadFocus, this.focused, this.el);
    document.addEventListener("focusin", this.onFocusIn);
    document.addEventListener("pointerdown", this.onPointerDown, true);
    document.addEventListener("phx:update", this.onUpdate);
  },

  // Starting patches the button, and the other Starts may have changed since focus came in.
  updated() {
    this.notePlace();
  },

  destroyed() {
    document.removeEventListener("focusin", this.onFocusIn);
    document.removeEventListener("pointerdown", this.onPointerDown, true);
    document.removeEventListener("phx:update", this.onUpdate);
    // Only #main-content scrolls, under the app bar, so what can be seen is its box, not the window's.
    const viewport = () =>
      document.getElementById("main-content")?.getBoundingClientRect() ?? { top: 0, bottom: window.innerHeight };
    handFocus(document, this.hadFocus, this.el.dataset.chip, this.placeIds, viewport);
  },

  noteFocus(target) {
    this.hadFocus = holdsPlace(target, this.el, this.row);
    if (!this.hadFocus) return;
    this.focused = target;
    this.notePlace();
  },

  // The other Starts on the page, those below this one first, then those above it, nearest first.
  notePlace() {
    const starts = [...document.querySelectorAll("[phx-hook=StartFocus]")].map((start) => start.id);
    const at = starts.indexOf(this.el.id);
    this.placeIds = [...starts.slice(at + 1), ...starts.slice(0, at).reverse()];
  }
};
