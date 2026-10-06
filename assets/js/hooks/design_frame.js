// The design element, in one file built twice: into Rail's bundle for the hooks, and as a classic script the
// design page loads, where it starts the overlay that outlines and marks elements inside the mockup.
// The two halves speak only by postMessage, and everything one hears from the other is untrusted.
export const VIEWPORT_WIDTH = 1920;
export const VIEWPORT_HEIGHT = 1080;

// The same caps the changeset holds a comment to.
export const LIMITS = { selector: 1000, text: 200, tag: 64, html: 20000, missing: 500 };
export const CUT_MARK = "<!-- Rail cut the element's HTML here, at 20,000 characters. -->";

const CHANNEL = "rail-design-frame";
const OVERLAY_MARK = "data-rail-overlay";
const PLAIN_ID = /^[A-Za-z][A-Za-z0-9_-]*$/;
const SEGMENT = /^([A-Za-z][A-Za-z0-9-]*):nth-child\((\d+)\)$/;
const TAG = /^[A-Za-z][A-Za-z0-9-]*$/;

// --- Pure functions, shared by both halves and the tests ---

export function fitScale(available, size) {
  return available / size;
}

// A preview shrinks to fit the detail's width and never grows past the element's own size.
export function previewScale(available, width) {
  return Math.min(1, available / width);
}

function countId(node, id) {
  let count = node.id === id ? 1 : 0;
  for (const child of node.children || []) count += countId(child, id);
  return count;
}

// An element's own id when it is plain and unique, otherwise tags and positions from the nearest such id, or from
// the root. resolveSelector walks the same grammar, so the browser's selector engine never reads what the page wrote.
export function buildSelector(element, doc) {
  const segments = [];
  let node = element;

  while (node) {
    if (PLAIN_ID.test(node.id || "") && countId(doc.documentElement, node.id) === 1) {
      segments.unshift(`#${node.id}`);
      break;
    }

    const parent = node.parentElement;
    if (!parent) {
      segments.unshift(node.localName);
      break;
    }

    segments.unshift(`${node.localName}:nth-child(${Array.prototype.indexOf.call(parent.children, node) + 1})`);
    node = parent;
  }

  return segments.join(" > ");
}

export function resolveSelector(doc, selector) {
  if (typeof selector !== "string" || selector === "") return null;

  const [first, ...rest] = selector.split(" > ");
  let node = null;

  if (first.startsWith("#")) {
    node = doc.getElementById(first.slice(1));
  } else if (doc.documentElement && first === doc.documentElement.localName) {
    node = doc.documentElement;
  }

  for (const part of rest) {
    const match = SEGMENT.exec(part);
    if (!node || !match) return null;

    const child = node.children[Number(match[2]) - 1];
    node = child && child.localName === match[1] ? child : null;
  }

  return node || null;
}

export function cutHtml(html) {
  if (html.length <= LIMITS.html) return html;
  if (html.endsWith(CUT_MARK) && html.length - CUT_MARK.length <= LIMITS.html) return html;
  return html.slice(0, LIMITS.html) + CUT_MARK;
}

export function elementText(element) {
  return (element.textContent || "").split(/\s+/).filter(Boolean).join(" ").slice(0, LIMITS.text);
}

// What a comment keeps of its element: the element's own HTML and its box, and nothing else of the page.
export function captureElement(element) {
  const box = element.getBoundingClientRect();

  return {
    html: cutHtml(element.outerHTML || ""),
    width: Math.max(1, Math.round(box.width)),
    height: Math.max(1, Math.round(box.height)),
    x: Math.round(box.left),
    y: Math.round(box.top)
  };
}

export function describeElement(element, doc) {
  return {
    selector: buildSelector(element, doc).slice(0, LIMITS.selector),
    text: elementText(element),
    tag: element.localName.slice(0, LIMITS.tag),
    ...captureElement(element)
  };
}

// C and Esc, read the way the global shortcuts read keys: never from something being typed in, never with a modifier.
export function keyAction(event) {
  if (event.metaKey || event.ctrlKey || event.altKey || event.shiftKey) return null;

  const target = event.target;
  if (target && typeof target.matches === "function") {
    if (target.matches("input, textarea, select, [contenteditable], [contenteditable='true']")) return null;
  }
  if (target?.isContentEditable) return null;

  if (event.key === "c" || event.key === "C") return "c";
  if (event.key === "Escape") return "escape";
  return null;
}

function text(value, max) {
  return typeof value === "string" ? value.slice(0, max) : null;
}

function whole(value, least) {
  return typeof value === "number" && Number.isFinite(value) ? Math.max(least, Math.round(value)) : null;
}

// A report from the frame, checked and capped, or null for anything not from this frame, for another page version,
// of an unknown kind, or with a field of the wrong type.
export function checkMessage(event, source, version) {
  const data = event.data;
  if (event.source !== source || !data || data.channel !== CHANNEL || data.version !== version) return null;

  switch (data.kind) {
    case "select": {
      const report = {
        kind: "select",
        selector: text(data.selector, LIMITS.selector),
        text: text(data.text, LIMITS.text),
        tag: text(data.tag, LIMITS.tag),
        html: typeof data.html === "string" ? cutHtml(data.html) : null,
        width: whole(data.width, 1),
        height: whole(data.height, 1),
        x: whole(data.x, -100000),
        y: whole(data.y, -100000)
      };

      if (Object.values(report).some((value) => value === null) || !TAG.test(report.tag)) return null;
      return report;
    }

    case "key":
      return data.key === "c" || data.key === "escape" ? { kind: "key", key: data.key } : null;

    case "anchors":
      if (!Array.isArray(data.missing) || !data.missing.every((id) => typeof id === "string")) return null;
      return { kind: "anchors", missing: data.missing.slice(0, LIMITS.missing).map((id) => id.slice(0, 64)) };

    default:
      return null;
  }
}

export function storageKey(taskId, userId) {
  return `rail:design-comments:${taskId}:${userId}`;
}

// One tab's work in progress: whether commenting is on and the comment box open on an element, if any.
export function keepDraft(storage, key, state) {
  try {
    if (!state.commenting && !state.draft) storage.removeItem(key);
    else storage.setItem(key, JSON.stringify({ commenting: state.commenting, draft: state.draft }));
  } catch (_unavailable) {
    // A browser with no room or no storage keeps nothing; the comments themselves are rows.
  }
}

export function readDraft(storage, key) {
  try {
    const kept = JSON.parse(storage.getItem(key));
    if (!kept || typeof kept.commenting !== "boolean") return null;
    if (kept.draft !== null && (typeof kept.draft !== "object" || typeof kept.draft.selector !== "string")) return null;
    return { commenting: kept.commenting, draft: kept.draft };
  } catch (_unreadable) {
    return null;
  }
}

export function shouldStartOverlay(script) {
  return Boolean(script && typeof script.hasAttribute === "function" && script.hasAttribute(OVERLAY_MARK));
}

// --- Rail's page ---

function frameState(el) {
  let markers = [];
  try {
    markers = JSON.parse(el.dataset.markers || "[]");
  } catch (_unreadable) {
    markers = [];
  }

  return {
    channel: CHANNEL,
    kind: "state",
    commenting: el.dataset.commenting === "true",
    selected: el.dataset.selected || null,
    markers,
    version: el.dataset.version || null
  };
}

// Shows a design mockup at its real 1920x1080 viewport, scaled down to fit the width it is given, so each option
// reads the way its screenshot will; with comments on, it carries the mode, the clicks and the markers to the frame.
export const DesignFrame = {
  mounted() {
    this.observer = new ResizeObserver(() => this.fit());
    this.observer.observe(this.el);

    this.onMessage = (event) => this.receive(event);
    window.addEventListener("message", this.onMessage);

    this.onKey = (event) => {
      const action = keyAction(event);
      if (action) this.act(action);
    };
    window.addEventListener("keydown", this.onKey);

    this.fit();
    this.attachFrame();

    const key = this.storageKey();
    const kept = key && readDraft(window.localStorage, key);
    if (kept && this.el.dataset.comments === "true") this.pushEventTo(this.el, "restore_commenting", kept);

    this.postState();
  },

  updated() {
    this.fit();
    this.attachFrame();
    this.keep();
    this.postState();
  },

  destroyed() {
    this.observer?.disconnect();
    window.removeEventListener("message", this.onMessage);
    window.removeEventListener("keydown", this.onKey);
  },

  storageKey() {
    const { taskId, userId } = this.el.dataset;
    return taskId && userId ? storageKey(taskId, userId) : null;
  },

  keep() {
    const key = this.storageKey();
    if (!key || this.el.dataset.comments !== "true") return;

    let draft = null;
    try {
      draft = JSON.parse(this.el.dataset.draft || "null");
    } catch (_unreadable) {
      draft = null;
    }

    keepDraft(window.localStorage, key, { commenting: this.el.dataset.commenting === "true", draft });
  },

  act(action) {
    if (this.el.dataset.comments !== "true") return;
    const commenting = this.el.dataset.commenting === "true";

    if (action === "c" && !commenting) this.pushEventTo(this.el, "toggle_commenting", {});
    if (action === "escape" && commenting) this.pushEventTo(this.el, "stop_commenting", {});
  },

  attachFrame() {
    const frame = this.el.querySelector("iframe");
    if (frame === this.frame) return;

    this.frame = frame;
    frame?.addEventListener("load", () => this.postState());
  },

  postState() {
    if (this.el.dataset.comments !== "true") return;
    this.frame?.contentWindow?.postMessage(frameState(this.el), "*");
  },

  receive(event) {
    const report = checkMessage(event, this.frame?.contentWindow, this.el.dataset.version);
    if (!report) return;

    if (report.kind === "select" && this.el.dataset.commenting === "true") {
      const { kind: _kind, ...element } = report;
      this.pushEventTo(this.el, "select_element", element);
    }

    if (report.kind === "key") this.act(report.key);

    const conversation = this.el.dataset.conversation;
    if (report.kind === "anchors" && conversation && document.querySelector(conversation)) {
      this.pushEventTo(conversation, "plan_comment_anchors", { missing: report.missing });
    }
  },

  fit() {
    const frame = this.el.querySelector("iframe");
    if (!frame) return;

    const scale = fitScale(this.el.clientWidth, VIEWPORT_WIDTH);
    frame.style.width = `${VIEWPORT_WIDTH}px`;
    frame.style.height = `${VIEWPORT_HEIGHT}px`;
    frame.style.transformOrigin = "0 0";
    frame.style.transform = `scale(${scale})`;
    this.el.style.height = `${VIEWPORT_HEIGHT * scale}px`;
  }
};

// A captured element on the Learnings page, drawn at its own size and scaled down to the width there is.
export const ElementPreview = {
  mounted() {
    this.observer = new ResizeObserver(() => this.fit());
    this.observer.observe(this.el.parentElement);
    this.fit();
  },

  updated() {
    this.fit();
  },

  destroyed() {
    this.observer?.disconnect();
  },

  fit() {
    const frame = this.el.querySelector("iframe");
    const width = Number(this.el.dataset.width);
    const height = Number(this.el.dataset.height);
    if (!frame || !(width > 0) || !(height > 0)) return;

    const scale = previewScale(this.el.parentElement.clientWidth, width);
    frame.style.width = `${width}px`;
    frame.style.height = `${height}px`;
    frame.style.transformOrigin = "0 0";
    frame.style.transform = `scale(${scale})`;
    this.el.style.width = `${width * scale}px`;
    this.el.style.height = `${height * scale}px`;
  }
};

// --- Inside the mockup ---

const OVERLAY_STYLE = `
  :host { all: initial; }
  .layer { position: fixed; inset: 0; pointer-events: none; z-index: 2147483647; }
  .outline { position: absolute; display: none; border: 2px solid #3b82f6; background: rgba(59, 130, 246, 0.1); border-radius: 3px; box-sizing: border-box; }
  .label { position: absolute; top: -22px; left: -2px; max-width: 260px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; border-radius: 6px 6px 6px 0; background: #2563eb; color: #fff; padding: 2px 6px; font: 10.5px/1.4 ui-monospace, SFMono-Regular, Menlo, monospace; }
  .label span { color: #bfdbfe; }
  .marker { position: absolute; width: 22px; height: 22px; border-radius: 9999px; display: grid; place-items: center; background: #fbbf24; color: #0f172a; font: 700 11px/1 ui-sans-serif, system-ui, sans-serif; box-shadow: 0 0 0 2px #fff, 0 2px 6px rgba(0, 0, 0, 0.5); }
`;

function startOverlay(win) {
  const doc = win.document;
  const host = doc.createElement("rail-overlay");
  const root = host.attachShadow({ mode: "closed" });
  root.innerHTML = `<style>${OVERLAY_STYLE}</style><div class="layer"><div class="outline" data-kind="hover"><div class="label"></div></div><div class="outline" data-kind="selected"></div><div class="markers"></div></div>`;
  doc.documentElement.appendChild(host);

  const hover = root.querySelector("[data-kind='hover']");
  const label = hover.querySelector(".label");
  const selectedOutline = root.querySelector("[data-kind='selected']");
  const markerLayer = root.querySelector(".markers");

  let state = { commenting: false, selected: null, markers: [], version: null };
  let hovered = null;
  let lastMissing = null;
  let scheduled = false;

  const post = (message) => win.parent.postMessage({ channel: CHANNEL, version: state.version, ...message }, "*");

  const place = (box, element) => {
    const rect = element.getBoundingClientRect();
    box.style.display = "block";
    box.style.left = `${rect.left - 3}px`;
    box.style.top = `${rect.top - 3}px`;
    box.style.width = `${rect.width + 6}px`;
    box.style.height = `${rect.height + 6}px`;
  };

  const draw = () => {
    scheduled = false;

    if (state.commenting && hovered?.isConnected) {
      place(hover, hovered);
      label.textContent = "";
      label.append(hovered.localName);
      const words = elementText(hovered);
      if (words) {
        const span = doc.createElement("span");
        span.textContent = ` · ${words}`;
        label.append(span);
      }
    } else {
      hover.style.display = "none";
    }

    const selected = state.commenting ? resolveSelector(doc, state.selected) : null;
    if (selected) place(selectedOutline, selected);
    else selectedOutline.style.display = "none";

    markerLayer.textContent = "";
    const missing = [];
    for (const marker of state.markers) {
      const element = resolveSelector(doc, marker.selector);
      if (!element) {
        missing.push(String(marker.id));
        continue;
      }

      const rect = element.getBoundingClientRect();
      const dot = doc.createElement("div");
      dot.className = "marker";
      dot.textContent = String(marker.number);
      dot.style.left = `${Math.max(2, rect.left - 9)}px`;
      dot.style.top = `${Math.max(2, rect.top - 9)}px`;
      markerLayer.append(dot);
    }

    // Nothing is reported before Rail's page has said which page version it is showing.
    const key = missing.join(",");
    if (state.version !== null && key !== lastMissing) {
      lastMissing = key;
      post({ kind: "anchors", missing });
    }
  };

  const schedule = () => {
    if (scheduled) return;
    scheduled = true;
    win.requestAnimationFrame(draw);
  };

  const isOurs = (element) => element === host || !(element instanceof win.Element);

  win.addEventListener("message", (event) => {
    const data = event.data;
    if (event.source !== win.parent || !data || data.channel !== CHANNEL || data.kind !== "state") return;

    const markers = Array.isArray(data.markers)
      ? data.markers.filter((marker) => marker && typeof marker.selector === "string")
      : [];

    if (data.version !== state.version) lastMissing = null;
    state = {
      commenting: data.commenting === true,
      selected: typeof data.selected === "string" ? data.selected : null,
      markers,
      version: typeof data.version === "string" ? data.version : null
    };
    schedule();
  });

  win.addEventListener(
    "pointermove",
    (event) => {
      if (!state.commenting || isOurs(event.target)) return;
      hovered = event.target;
      schedule();
    },
    true
  );

  // While commenting, a click picks the element and the mockup never hears of it. Pointer events are only stopped:
  // cancelling one would cancel the click it leads to.
  const swallow = (event) => {
    if (!state.commenting) return;
    if (!event.type.startsWith("pointer")) event.preventDefault();
    event.stopImmediatePropagation();
  };

  for (const type of ["pointerdown", "mousedown", "pointerup", "mouseup", "dblclick", "auxclick", "submit"]) {
    win.addEventListener(type, swallow, true);
  }

  win.addEventListener(
    "click",
    (event) => {
      if (!state.commenting) return;
      swallow(event);
      if (isOurs(event.target)) return;
      post({ kind: "select", ...describeElement(event.target, doc) });
    },
    true
  );

  win.addEventListener("keydown", (event) => {
    const action = keyAction(event);
    if (action) post({ kind: "key", key: action });
  });

  win.addEventListener("scroll", schedule, true);
  win.addEventListener("resize", schedule);
  new win.MutationObserver(schedule).observe(doc.documentElement, {
    subtree: true,
    childList: true,
    attributes: true,
    characterData: true
  });
}

if (typeof document !== "undefined" && shouldStartOverlay(document.currentScript)) startOverlay(window);
