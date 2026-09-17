// Keeps a reader where they were while the diff underneath them changes, and
// takes them to one file when they ask for it.
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

    // Picking a file out of the tree is asking to read it, so the server says
    // which one and the scroller goes there. It is an event rather than an
    // attribute because asking twice for the same file has to work twice.
    this.handleEvent("diff:scroll_to", ({ path }) => this.scrollTo(path));

    // A header pinned to the top of the pane is no longer the top of its own
    // card, so it drops its rounded corners. It sits a pixel above the scrollport
    // to be told: pinned is exactly when that pixel is clipped away.
    this.stuck = new IntersectionObserver(
      entries => {
        for (const entry of entries) entry.target.toggleAttribute("data-stuck", entry.intersectionRatio < 1);
      },
      { root: this.el, threshold: [1] }
    );

    this.watchHeaders();
  },

  destroyed() {
    this.stuck.disconnect();
  },

  watchHeaders() {
    this.stuck.disconnect();

    for (const header of this.el.querySelectorAll("[data-qa='diff_file_header']")) {
      this.stuck.observe(header);
    }
  },

  beforeUpdate() {
    this.anchor = this.currentAnchor();
  },

  updated() {
    this.watchHeaders();

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
    const path = this.el.dataset.scrollTo;
    if (!path || path === this.scrolledTo) return false;
    if (!this.scrollTo(path)) return false;

    this.scrolledTo = path;
    return true;
  },

  scrollTo(path) {
    const section = this.sectionFor(path);
    if (!section) return false;

    this.el.scrollTop += this.offsetOf(section);
    this.settle(path, 3);

    return true;
  },

  // A section is only laid out once it is scrolled near, so the first jump lands
  // against `contain-intrinsic-size` rather than the real thing. Re-measuring
  // over the next few frames closes the gap the real layout opened.
  settle(path, frames) {
    if (frames <= 0) return;

    requestAnimationFrame(() => {
      const section = this.sectionFor(path);
      if (!section) return;

      const offset = this.offsetOf(section);
      if (Math.abs(offset) > 1) this.el.scrollTop += offset;

      this.settle(path, frames - 1);
    });
  },

  sectionFor(path) {
    for (const section of this.sections()) {
      if (section.dataset.path === path) return section;
    }

    return null;
  },

  // The section the viewport is inside: the last one starting at or above it.
  currentAnchor() {
    let anchor = null;

    for (const section of this.sections()) {
      const offset = this.offsetOf(section);

      if (offset <= 0 || anchor === null) {
        anchor = { id: section.id, offset };
      }

      if (offset > 0) break;
    }

    return anchor;
  },

  sections() {
    return this.el.querySelectorAll("[data-qa='diff_file_section']");
  },

  offsetOf(section) {
    return section.getBoundingClientRect().top - this.el.getBoundingClientRect().top;
  }
};
