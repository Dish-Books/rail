// Keeps a reader where they were while the diff underneath them changes.
//
// The engineer writes files as it works, so the pane re-reads and LiveView
// patches the rows. Anything that grows above the viewport would otherwise carry
// the reader down the page mid-sentence. Before a patch this records which file
// section the viewport is sitting in and how far into it; after, it puts that
// section back where it was.
export const DiffScroller = {
  mounted() {
    this.anchor = null;
  },

  beforeUpdate() {
    this.anchor = this.currentAnchor();
  },

  updated() {
    if (!this.anchor) return;

    const section = this.el.querySelector(`#${CSS.escape(this.anchor.id)}`);

    if (section) {
      this.el.scrollTop += this.offsetOf(section) - this.anchor.offset;
    }

    this.anchor = null;
  },

  // The section the viewport is inside: the last one starting at or above it.
  currentAnchor() {
    let anchor = null;

    for (const section of this.el.querySelectorAll("[data-qa='diff_file_section']")) {
      const offset = this.offsetOf(section);

      if (offset <= 0 || anchor === null) {
        anchor = { id: section.id, offset };
      }

      if (offset > 0) break;
    }

    return anchor;
  },

  offsetOf(section) {
    return section.getBoundingClientRect().top - this.el.getBoundingClientRect().top;
  }
};
