// Shows a status picker's menu as a popover, placed against its trigger in viewport
// coordinates. The page keeps the placement through patches with JS.ignore_attributes.
import { calculateNextItem } from "./menu_keys.js";

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

// What a click does to an open menu. A pick in flight keeps the menu and the page, since a refusal shows there.
export function calculateAwayAction({ inMenu, onTrigger, picking }) {
  if (inMenu) return "none";
  if (picking) return "stop";
  return onTrigger ? "none" : "close";
}

// A pick moves its row in a later patch, and LiveView restores focus only to inputs. Any press ends the watch.
export function returnFocus(doc, trigger) {
  const focusTrigger = () => trigger?.focus({ preventScroll: true });
  const watching = new AbortController();
  const { signal } = watching;

  focusTrigger();
  doc.addEventListener(
    "phx:update",
    () => {
      if (doc.activeElement !== doc.body) return;
      watching.abort();
      focusTrigger();
    },
    { signal }
  );
  doc.addEventListener("keydown", () => watching.abort(), { capture: true, signal });
  doc.addEventListener("pointerdown", () => watching.abort(), { capture: true, signal });
}

export const StatusMenu = {
  mounted() {
    // Morphdom keeps this node through a row move, and a detached one takes no focus after a navigation.
    this.triggerEl = this.trigger();
    this.place = () => this.position();
    // A row moved by a patch can come back out of the top layer, in a browser with no moveBefore.
    this.keepOpen = () => {
      if (this.shown) this.show();
    };
    this.onKey = (event) => this.step(event);
    this.onAway = (event) => this.closeOnAway(event);
    this.onEscape = (event) => this.holdEscape(event);

    this.reveal();

    // Capture, since the page's scrollers are inner elements and scroll does not bubble.
    window.addEventListener("scroll", this.place, true);
    window.addEventListener("resize", this.place);
    document.addEventListener("phx:update", this.keepOpen);
    // Here rather than phx-click-away, which skips a row scrolled out of view. Capture, since a row's links stop theirs.
    document.addEventListener("click", this.onAway, true);
    // Capture on document runs ahead of LiveView's listeners on the window.
    document.addEventListener("keydown", this.onEscape, true);
    this.el.addEventListener("keydown", this.onKey);
  },

  updated() {
    this.reveal();
    if (!this.shown) return;
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
    document.removeEventListener("keydown", this.onEscape, true);
    if (this.shown && document.activeElement === document.body) returnFocus(document, this.triggerEl);
  },

  trigger() {
    return document.getElementById(this.el.dataset.trigger);
  },

  // The menu mounts with the click, empty until the read answers, so a click away reaches it during the read.
  reveal() {
    if (this.shown || !this.el.querySelector("button")) return;
    const active = document.activeElement;
    if (active !== document.body && !this.triggerEl?.contains(active)) {
      this.pushEventTo(this.el, "close");
      return;
    }
    this.shown = true;
    this.show();
    this.position();
    this.focusCurrent();
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

  picking() {
    return this.el.querySelector('[role="menuitem"].phx-click-loading') !== null;
  },

  closeOnAway(event) {
    const action = calculateAwayAction({
      inMenu: this.el.contains(event.target),
      onTrigger: Boolean(this.trigger()?.contains(event.target)),
      picking: this.picking()
    });
    if (action === "stop") {
      event.preventDefault();
      event.stopPropagation();
    }
    if (action === "close") this.pushEventTo(this.el, "close");
  },

  holdEscape(event) {
    if (event.key === "Escape" && this.picking()) event.stopPropagation();
  },

  items() {
    return Array.from(this.el.querySelectorAll("button"));
  },

  focusCurrent() {
    (this.el.querySelector('[aria-current="true"]') ?? this.items()[0])?.focus();
  },

  step(event) {
    const items = this.items();
    const next = calculateNextItem(items.indexOf(document.activeElement), items.length, event.key);
    if (next === null) return;
    event.preventDefault();
    items[next].focus();
  }
};
