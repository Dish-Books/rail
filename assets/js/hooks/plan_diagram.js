// Draws one plan diagram with Mermaid. The server only sends the source as escaped
// text; "strict" is a secure key, so no directive in a plan can loosen it.
const LOAD_FAILED = "The diagram library could not load. Reload the page to draw it.";

const SHARED = {
  startOnLoad: false,
  securityLevel: "strict",
  suppressErrorRendering: true,
  // SVG text, not HTML, so markup in a label is drawn as the characters it holds.
  htmlLabels: false,
  flowchart: { htmlLabels: false, curve: "basis", padding: 14, nodeSpacing: 28, rankSpacing: 36 },
  sequence: { mirrorActors: false, actorMargin: 24, messageMargin: 30, boxMargin: 8 }
};

const DARK = {
  ...SHARED,
  theme: "base",
  themeVariables: {
    darkMode: true,
    fontFamily: '-apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif',
    fontSize: "14px",
    background: "#0f172a",
    primaryColor: "#1e293b",
    primaryTextColor: "#e2e8f0",
    primaryBorderColor: "#475569",
    secondaryColor: "#1e293b",
    tertiaryColor: "#0f172a",
    lineColor: "#64748b",
    textColor: "#cbd5e1",
    edgeLabelBackground: "#0f172a",
    clusterBkg: "#0b1222",
    clusterBorder: "#334155",
    actorBkg: "#1e293b",
    actorBorder: "#475569",
    actorTextColor: "#e2e8f0",
    actorLineColor: "#334155",
    signalColor: "#94a3b8",
    signalTextColor: "#e2e8f0",
    labelBoxBkgColor: "#1e293b",
    labelBoxBorderColor: "#475569",
    labelTextColor: "#e2e8f0",
    loopTextColor: "#cbd5e1",
    noteBkgColor: "#1e293b",
    noteTextColor: "#cbd5e1",
    noteBorderColor: "#475569",
    activationBkgColor: "#334155",
    activationBorderColor: "#64748b",
    sequenceNumberColor: "#0f172a"
  }
};

const LIGHT = { ...SHARED, theme: "neutral" };

// Mermaid strips markup from a label even as SVG text, so its entity codes keep the
// characters a quoted label holds. The Source view still shows the plan as written.
function literalLabels(source) {
  return source.replace(/"[^"\n]*"/g, (label) => label.replaceAll("<", "#lt;").replaceAll(">", "#gt;"));
}

// Which drawn element each node is. A sequence diagram's participant carries its id as data-id; a flowchart's
// g.node does not in Mermaid 11.17, but its DOM id is "<svg id>-flowchart-<node id>-<counter>".
export function findNodes(svg, svgId, ids) {
  const wanted = new Set(ids);
  const found = new Map();
  const prefix = `${svgId}-flowchart-`;

  for (const element of svg.querySelectorAll("g.node")) {
    if (!element.id.startsWith(prefix)) continue;
    const id = element.id.slice(prefix.length).replace(/-\d+$/, "");
    if (wanted.has(id) && !found.has(id)) found.set(id, element);
  }

  for (const element of svg.querySelectorAll('[data-et="participant"][data-id]')) {
    const id = element.getAttribute("data-id");
    if (wanted.has(id) && !found.has(id)) found.set(id, element);
  }

  return found;
}

// The node's top right corner in the layer's coordinates, the + overlapping it as it does a line's gutter.
export function cornerOf(nodeRect, layerRect) {
  return { left: Math.round(nodeRect.right - layerRect.left - 12), top: Math.round(nodeRect.top - layerRect.top - 8) };
}

// A node with a comment has its shape outlined amber, as a commented code line has its number.
export function outline(element, commented) {
  const shape = element.querySelector("rect, polygon, path, circle, ellipse");
  if (!shape) return;
  shape.style.stroke = commented ? "#f59e0b" : "";
  shape.style.strokeWidth = commented ? "2px" : "";
}

let mermaidLoad;

// A tab still on the app.js from before a deploy asks for a chunk that is gone, so
// a failed import ends in the same source view as a parse error.
async function loadMermaid() {
  mermaidLoad ||= (async () => {
    try {
      return (await import("mermaid")).default;
    } catch {
      throw new Error(LOAD_FAILED);
    }
  })();

  return mermaidLoad;
}

export const PlanDiagram = {
  mounted() {
    this.fullscreen = this.el.querySelector("[data-diagram-fullscreen]");

    // iPhone Safari has no element full screen, so the button only appears where it works.
    if (this.el.requestFullscreen) {
      this.js().show(this.fullscreen, { display: "grid" });
      this.openFullscreen = () => this.el.requestFullscreen();
      this.fullscreen.addEventListener("click", this.openFullscreen);
    }

    this.fitFullscreen = () => {
      this.sizeForFullscreen();
      this.placeNodes();
    };
    document.addEventListener("fullscreenchange", this.fitFullscreen);

    this.resizeObserver = new ResizeObserver(() => this.placeNodes());
    this.resizeObserver.observe(this.el.querySelector("[data-diagram-canvas]"));

    this.themeObserver = new MutationObserver(() => this.draw());
    this.themeObserver.observe(document.documentElement, { attributeFilter: ["data-theme"] });

    this.draw();
  },

  // Comments came or went, or commenting opened or closed, so the + and the outlines are placed again.
  updated() {
    this.placeNodes();
  },

  destroyed() {
    this.themeObserver?.disconnect();
    this.resizeObserver?.disconnect();
    this.nodeListeners?.abort();
    this.fullscreen?.removeEventListener("click", this.openFullscreen);
    document.removeEventListener("fullscreenchange", this.fitFullscreen);
  },

  async draw() {
    const theme = document.documentElement.dataset.theme;
    if (this.el.dataset.drawn === "error" || theme === this.theme) return;
    this.theme = theme;

    const source = this.el.querySelector("[data-diagram-source]").textContent;
    const canvas = this.el.querySelector("[data-diagram-canvas]");

    try {
      const mermaid = await loadMermaid();
      mermaid.initialize(theme === "dark" ? DARK : LIGHT);
      const drawable = literalLabels(source);
      await mermaid.parse(drawable);
      const { svg } = await mermaid.render(`${this.el.id}-svg`, drawable);
      canvas.innerHTML = svg;
      this.sizeForFullscreen();
      this.placeNodes();
    } catch (error) {
      // Mermaid's first line names only the line number; its second quotes the source there.
      const [first, excerpt] = String(error?.message ?? error).split("\n");
      this.el.querySelector("[data-diagram-error]").textContent = excerpt ? `${first} ${excerpt}` : first;
      this.js().setAttribute(this.el, "data-drawn", "error");
    }
  },

  // Inline, a diagram shrinks to fit its column. In full screen one wider than the screen
  // keeps its natural width, so its labels stay readable and the card scrolls sideways.
  sizeForFullscreen() {
    const canvas = this.el.querySelector("[data-diagram-canvas]");
    const svg = canvas.querySelector("svg");
    if (!svg) return;

    const natural = svg.viewBox.baseVal.width;
    const wide = document.fullscreenElement === this.el && natural > canvas.clientWidth;
    svg.style.width = wide ? `${natural}px` : "";
  },

  // A + on the corner of each node a reader can comment on, shown while the node or the + is pointed at or focused.
  placeNodes() {
    const layer = this.el.querySelector("[data-diagram-nodes]");
    const svg = this.el.querySelector("[data-diagram-canvas] svg");
    this.nodeListeners?.abort();
    this.nodeListeners = new AbortController();
    const signal = this.nodeListeners.signal;
    layer.replaceChildren();
    if (!svg) return;

    const nodes = JSON.parse(this.el.dataset.nodes || "[]");
    const found = findNodes(
      svg,
      svg.id,
      nodes.map((node) => node.id)
    );
    const offered = this.el.dataset.offered === "true";
    const layerRect = layer.getBoundingClientRect();

    for (const node of nodes) {
      const element = found.get(node.id);
      if (!element) continue;
      outline(element, node.commented);
      if (!offered) continue;

      const button = document.createElement("button");
      const { left, top } = cornerOf(element.getBoundingClientRect(), layerRect);
      button.type = "button";
      button.textContent = "+";
      button.className = "line-comment-add pointer-events-auto";
      button.dataset.qa = "node_comment_add";
      button.setAttribute("aria-label", `Comment on node ${node.id}`);
      button.style.left = `${left}px`;
      button.style.top = `${top}px`;

      const show = () => {
        button.style.opacity = "1";
      };
      const hide = () =>
        setTimeout(() => {
          if (!button.matches(":hover, :focus-visible")) button.style.opacity = "";
        }, 200);
      element.addEventListener("mouseenter", show, { signal });
      element.addEventListener("mouseleave", hide, { signal });
      button.addEventListener("mouseleave", hide, { signal });
      button.addEventListener(
        "click",
        () => this.pushEventTo(this.el, "open_document_comment", { doc: "plan", key: node.key }),
        {
          signal
        }
      );

      layer.append(button);
    }
  }
};
