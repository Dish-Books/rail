// A file section is patched on its own, without the pane around it, so the
// scroller would not hear about it. It says so itself, so the reader stays put
// while the file above them grows or folds.
export const DiffSection = {
  beforeUpdate() {
    this.el.dispatchEvent(new CustomEvent("diff:section-before-update", { bubbles: true }));
  },

  updated() {
    this.el.dispatchEvent(new CustomEvent("diff:section-updated", { bubbles: true }));
  }
};
