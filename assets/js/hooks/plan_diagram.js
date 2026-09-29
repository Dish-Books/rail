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

    this.fitFullscreen = () => this.sizeForFullscreen();
    document.addEventListener("fullscreenchange", this.fitFullscreen);

    this.themeObserver = new MutationObserver(() => this.draw());
    this.themeObserver.observe(document.documentElement, { attributeFilter: ["data-theme"] });

    this.draw();
  },

  destroyed() {
    this.themeObserver?.disconnect();
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
  }
};
