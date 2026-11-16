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

export const DiffSection = {
  mounted() {
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
  }
};
