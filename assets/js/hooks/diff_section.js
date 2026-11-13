// A file section is patched on its own, without the pane around it, so the
// scroller would not hear about it. It says so itself, so the reader stays put
// while the file above them grows or folds.
//
// The "+" on each line is static markup, so a diff thousands of lines long pays
// nothing per line for it: which line it comments on is read off its row here.
const lineOf = (button) => {
  const row = button.closest(".diff-line");
  const [oldLine, newLine] = row.querySelectorAll(".diff-num");

  return { kind: row.dataset.kind, oldLine: oldLine.textContent.trim(), newLine: newLine.textContent.trim() };
};

// A file is sent no lines until the reader comes within a screen of it, then asks
// for them. One observer watches every file of a pane, and the files that
// come near together are asked for in one event.
const panes = new WeakMap();

// Outside a scroller the page itself scrolls, so the viewport is watched instead.
const paneFor = (scroller) => {
  let pane = panes.get(scroller || document);
  if (pane) return pane;

  const sections = new Map();
  const observer = new IntersectionObserver(
    (entries) => {
      for (const entry of entries) {
        const hook = sections.get(entry.target);
        if (!hook) continue;
        hook.near = entry.isIntersecting;
        hook.askToDraw();
      }
    },
    { root: scroller, rootMargin: "100% 0px" }
  );

  pane = { sections, observer, asked: new Map(), flush: null };
  panes.set(scroller || document, pane);
  return pane;
};

export const DiffSection = {
  mounted() {
    this.near = false;
    this.asked = false;
    this.pane = paneFor(this.el.closest("#diff-scroller"));
    this.pane.sections.set(this.el, this);
    this.pane.observer.observe(this.el);

    this.el.addEventListener("click", (event) => {
      const button = event.target.closest(".diff-comment-add");
      if (!button) return;

      const { kind, oldLine, newLine } = lineOf(button);

      this.pushEventTo(this.el.dataset.commentTarget, "open_diff_comment", {
        path: this.el.dataset.path,
        kind,
        old_line: oldLine,
        new_line: newLine
      });
    });

    // Named when it is reached rather than drawn, for the same reason.
    const name = (event) => {
      const button = event.target.closest?.(".diff-comment-add");
      if (!button || button.title) return;

      const { kind, oldLine, newLine } = lineOf(button);
      const label = `Comment on line ${kind === "deleted" ? oldLine : newLine}`;

      button.title = label;
      button.setAttribute("aria-label", label);
    };

    this.el.addEventListener("pointerover", name);
    this.el.addEventListener("focusin", name);
  },

  beforeUpdate() {
    this.el.dispatchEvent(new CustomEvent("diff:section-before-update", { bubbles: true }));
  },

  updated() {
    this.el.dispatchEvent(new CustomEvent("diff:section-updated", { bubbles: true }));

    // Drawn, or opened while already near.
    if (!this.el.hasAttribute("data-far")) this.asked = false;
    this.askToDraw();
  },

  destroyed() {
    this.pane.observer.unobserve(this.el);
    this.pane.sections.delete(this.el);
  },

  // A folded file shows no lines, so it waits until it is opened.
  askToDraw() {
    if (this.asked || !this.near || !this.el.hasAttribute("data-far")) return;
    if (!this.el.querySelector(".diff-far")) return;

    this.asked = true;
    const target = this.el.dataset.commentTarget;
    const { asked } = this.pane;
    if (!asked.has(target)) asked.set(target, new Set());
    asked.get(target).add(this.el.dataset.path);

    this.pane.flush ??= setTimeout(() => {
      this.pane.flush = null;
      for (const [to, paths] of asked) this.pushEventTo(to, "draw_diff_files", { paths: [...paths] });
      asked.clear();
    }, 50);
  }
};
