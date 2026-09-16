// Keeps a reader where they were while the diff underneath them changes, and
// takes them to one file when something else sent them here to read it.
//
// The engineer writes files as it works, so the pane re-reads and LiveView
// patches the rows. Anything that grows above the viewport would otherwise carry
// the reader down the page mid-sentence. Before a patch this records which file
// section the viewport is sitting in and how far into it; after, it puts that
// section back where it was.
export const DiffScroller = {
  mounted() {
    this.anchor = null;
    this.scrolledTo = null;
    this.honorScrollTo();
  },

  beforeUpdate() {
    this.anchor = this.currentAnchor();
  },

  updated() {
    // Being sent to a file wins over holding the reader's place: they asked for
    // this one, and the place they were holding is the one they just left.
    if (this.honorScrollTo()) {
      this.anchor = null;
      return;
    }

    if (!this.anchor) return;

    const section = this.el.querySelector(`#${CSS.escape(this.anchor.id)}`);

    if (section) {
      this.el.scrollTop += this.offsetOf(section) - this.anchor.offset;
    }

    this.anchor = null;
  },

  // Honored once per file asked for, so a later patch does not drag the reader
  // back to it after they have scrolled away.
  honorScrollTo() {
    const id = this.el.dataset.scrollTo;
    if (!id || id === this.scrolledTo) return false;

    const section = this.el.querySelector(`#${CSS.escape(id)}`);
    if (!section) return false;

    this.scrolledTo = id;
    this.el.scrollTop += this.offsetOf(section);
    return true;
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
