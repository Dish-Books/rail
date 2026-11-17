// The chip comes in the patch that removes Start, and a later patch can move its row, which drops focus again. Read by
// id each time, since a row built anew brings a new chip, and kept until the person presses a key or a pointer.
export function handFocus(doc, hadFocus, chipId) {
  if (!hadFocus || doc.activeElement !== doc.body || !doc.getElementById(chipId)) return;

  const focusChip = () => doc.getElementById(chipId)?.focus({ preventScroll: true });
  const watching = new AbortController();
  const { signal } = watching;

  focusChip();
  doc.addEventListener(
    "phx:update",
    () => {
      if (doc.activeElement === doc.body) focusChip();
    },
    { signal }
  );
  doc.addEventListener("keydown", () => watching.abort(), { capture: true, signal });
  doc.addEventListener("pointerdown", () => watching.abort(), { capture: true, signal });
}

export const StartFocus = {
  mounted() {
    this.hadFocus = document.activeElement === this.el;
    // Focus or a press anywhere else means the person has moved on, and the chip should not take focus from them.
    this.onFocusIn = (event) => {
      this.hadFocus = event.target === this.el;
    };
    this.onPointerDown = (event) => {
      if (!this.el.contains(event.target)) this.hadFocus = false;
    };
    document.addEventListener("focusin", this.onFocusIn);
    document.addEventListener("pointerdown", this.onPointerDown, true);
  },

  destroyed() {
    document.removeEventListener("focusin", this.onFocusIn);
    document.removeEventListener("pointerdown", this.onPointerDown, true);
    handFocus(document, this.hadFocus, this.el.dataset.chip);
  }
};
