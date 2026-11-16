// A comment box a reconnect took away opens again on the same line, with what was typed in it.
//
// The box is its component's state, which a reconnect starts over, and LiveView only gives a form its text back
// when the page it draws again still has that form. So a box drawn away while the page was disconnected asks its
// component to open it again, with the event its data-reopen names, and the box that opens under the same id
// takes the text. A box with no data-reopen, or one the reader closed, is left closed.

// How long a taken box waits for its component to open it again before its text is dropped.
export const KEPT_MS = 15000;

// The push that opens a box again: its event and values, sent to the component the box was wired to, or to the
// page when it was wired to none.
export function calculateReopenCommand(reopen, target) {
  const push = { event: reopen.event, value: reopen.value };
  if (target) push.target = target;
  return JSON.stringify([["push", push]]);
}

// The form's phx-target as a selector that outlives a reconnect: a component's number can change when the page
// mounts again, but each component holding a comment box names its root with an id. Null is the page itself,
// and undefined a target that cannot be found again.
export function calculateTargetSelector(phxTarget, doc) {
  if (!phxTarget) return null;
  if (!/^\d+$/.test(phxTarget)) return phxTarget;
  const id = doc.querySelector(`[data-phx-component="${phxTarget}"]`)?.id;
  return id ? `[id="${id}"]` : undefined;
}

export function readReopen(json) {
  try {
    const reopen = JSON.parse(json);
    if (typeof reopen?.event !== "string") return null;
    const value = reopen.value && typeof reopen.value === "object" ? reopen.value : {};
    return { event: reopen.event, value };
  } catch (_unreadable) {
    return null;
  }
}

// kept: the boxes a reconnect took, by form id. A box that opens takes its text once; a stale one is dropped.
export function takeKept(kept, id, now) {
  for (const [key, entry] of kept) {
    if (now - entry.at > KEPT_MS) kept.delete(key);
  }

  const entry = kept.get(id);
  if (!entry) return null;
  kept.delete(id);
  return entry.body;
}

const kept = new Map();

export const CommentBox = {
  mounted() {
    this.reopen = readReopen(this.el.dataset.reopen);
    this.target = calculateTargetSelector(this.el.getAttribute("phx-target"), document);
    this.main = this.liveSocket.main;
    this.interrupted = false;

    const body = takeKept(kept, this.el.id, Date.now());
    if (body) this.restore(body);
  },

  disconnected() {
    this.interrupted = true;
  },

  reconnected() {
    this.interrupted = false;
  },

  // Drawn away while disconnected is the reconnect's doing; drawn away on another page, or by Cancel or Save,
  // is not. The page joining again is the same live view; navigating replaces it.
  destroyed() {
    if (!this.interrupted || !this.reopen || this.target === undefined) return;

    const { liveSocket, main, el, reopen, target } = this;
    kept.set(el.id, { body: el.querySelector("textarea")?.value ?? "", at: Date.now() });

    setTimeout(() => {
      if (liveSocket.main !== main) return;
      if (target && !document.querySelector(target)) return;
      liveSocket.execJS(main.el, calculateReopenCommand(reopen, target));
    }, 0);
  },

  // Sent as typing would be, so the component holds the text again before the reader types on.
  restore(body) {
    const textarea = this.el.querySelector("textarea");
    if (!textarea || textarea.value === body) return;

    textarea.value = body;
    textarea.setSelectionRange(body.length, body.length);
    textarea.dispatchEvent(new Event("input", { bubbles: true }));
  }
};
