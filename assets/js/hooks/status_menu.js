// Shows a status picker's menu as a popover, placed against its trigger in viewport
// coordinates. The page keeps the placement through patches with JS.ignore_attributes.
const GAP = 4;
const MARGIN = 8;

// Below the trigger, or above it when it would run off the bottom and there is more room there.
export function calculateMenuPosition(trigger, menu, viewport) {
  const below = trigger.bottom + GAP;
  const above = trigger.top - GAP - menu.height;
  const fits = below + menu.height <= viewport.height - MARGIN;
  const roomier = viewport.height - trigger.bottom >= trigger.top;
  const top = fits || roomier ? below : above;
  const maxTop = viewport.height - menu.height - MARGIN;
  const maxLeft = viewport.width - menu.width - MARGIN;

  return {
    top: Math.max(MARGIN, Math.min(top, maxTop)),
    left: Math.max(MARGIN, Math.min(trigger.left, maxLeft))
  };
}

export const StatusMenu = {
  mounted() {
    this.place = () => this.position();
    // A row moved by a patch can come back out of the top layer, in a browser with no moveBefore.
    this.keepOpen = () => this.show();
    this.onKey = (event) => this.step(event);
    this.onAway = (event) => this.closeOnAway(event);

    this.show();
    this.position();
    this.focusCurrent();

    // Capture, since the page's scrollers are inner elements and scroll does not bubble.
    window.addEventListener("scroll", this.place, true);
    window.addEventListener("resize", this.place);
    document.addEventListener("phx:update", this.keepOpen);
    // Here rather than phx-click-away, which skips a row scrolled out of view. Capture, since a row's links stop theirs.
    document.addEventListener("click", this.onAway, true);
    this.el.addEventListener("keydown", this.onKey);
  },

  updated() {
    this.show();
    // Only a change of size moves it: a row that moved under an open menu leaves the menu where it is.
    if (this.el.offsetHeight !== this.height) this.position();
    if (document.activeElement === document.body) this.focusCurrent();
  },

  destroyed() {
    window.removeEventListener("scroll", this.place, true);
    window.removeEventListener("resize", this.place);
    document.removeEventListener("phx:update", this.keepOpen);
    document.removeEventListener("click", this.onAway, true);
    if (document.activeElement === document.body) this.trigger()?.focus();
  },

  trigger() {
    return document.getElementById(this.el.dataset.trigger);
  },

  show() {
    if (this.el.isConnected && !this.el.matches(":popover-open")) this.el.showPopover();
  },

  position() {
    const trigger = this.trigger();
    if (!trigger) return;

    const { top, left } = calculateMenuPosition(trigger.getBoundingClientRect(), this.el.getBoundingClientRect(), {
      width: window.innerWidth,
      height: window.innerHeight
    });
    this.el.style.top = `${top}px`;
    this.el.style.left = `${left}px`;
    this.height = this.el.offsetHeight;
  },

  closeOnAway(event) {
    if (this.el.contains(event.target) || this.trigger()?.contains(event.target)) return;
    this.pushEventTo(this.el, "close");
  },

  items() {
    return Array.from(this.el.querySelectorAll("button"));
  },

  focusCurrent() {
    (this.el.querySelector('[aria-current="true"]') ?? this.items()[0])?.focus();
  },

  step(event) {
    if (event.key !== "ArrowDown" && event.key !== "ArrowUp") return;
    event.preventDefault();
    const items = this.items();
    const step = event.key === "ArrowDown" ? 1 : -1;
    const index = items.indexOf(document.activeElement) + step;
    items[(index + items.length) % items.length]?.focus();
  }
};
