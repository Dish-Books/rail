const SETTLE_FRAMES = 3;
const SETTLE_CAP = 30;
const READER_SCROLLS = ["wheel", "touchstart", "keydown"];

// A line goes by what an edit above it does not renumber: its old number, or for an
// added line, which has none, its text.
const keyOf = (row) => {
  const { kind } = row.dataset;

  return kind === "added"
    ? `added:${row.querySelector(".diff-text")?.textContent}`
    : `${kind}:${row.querySelector(".diff-num").textContent}`;
};

// Keeps a reader where they were while the diff underneath them changes, and
// takes them to one file or comment when they ask for it.
//
// The engineer writes files as it works, so the pane re-reads and LiveView
// patches the rows. Anything that grows above the viewport would otherwise carry
// the reader down the page mid-sentence. Before a patch this records the line at
// the top of the viewport, or its file when there is none; after, it puts that
// line back where it was. A wrapped line above it may now take more rows.
export const DiffScroller = {
  mounted() {
    this.anchor = null;
    this.scrolledTo = null;
    this.pendingComment = null;
    this.settling = null;

    this.stopSettling = () => {
      this.settling = null;
      for (const type of READER_SCROLLS) this.el.removeEventListener(type, this.stopSettling);
    };

    this.honorScrollTo();

    // Picking a file or a comment out of the list beside the diff is asking to
    // read it, so the server says which and the scroller goes there. It is an
    // event rather than an attribute because asking twice has to work twice.
    this.handleEvent("diff:scroll_to", ({ path, id }) => (id ? this.scrollToComment(id) : this.scrollTo(path)));

    // A header pinned to the top of the pane is no longer the top of its own
    // card, so it drops its rounded corners. It sits a pixel above the scrollport
    // to be told: pinned is exactly when that pixel is clipped away.
    this.stuck = new IntersectionObserver(
      (entries) => {
        for (const entry of entries) entry.target.toggleAttribute("data-stuck", entry.intersectionRatio < 1);
      },
      { root: this.el, threshold: [1] }
    );

    // A file section is patched on its own when only it moved, and says so, so
    // its growing or folding holds the reader's place the same way.
    this.el.addEventListener("diff:section-before-update", () => {
      if (!this.anchor) this.anchor = this.currentAnchor();
    });

    // A comment in a folded file is only drawn once that file's own patch lands,
    // which can be after the event asking for it. It is looked for that once, and
    // reaching it drops the place held from before the jump.
    this.el.addEventListener("diff:section-updated", () => {
      if (this.retryComment()) {
        this.anchor = null;
        return;
      }

      this.restoreAnchor();
    });

    // Turning wrap on or off re-flows every line without a patch, so the toolbar
    // says when, and the line the reader is on stays put.
    this.holdForWrap = () => {
      this.anchor = this.currentAnchor();
    };
    this.restoreForWrap = () => this.restoreAnchor();
    window.addEventListener("diff:wrap-before", this.holdForWrap);
    window.addEventListener("diff:wrap-after", this.restoreForWrap);

    this.watchHeaders();
  },

  destroyed() {
    this.stuck.disconnect();
    this.stopSettling();
    window.removeEventListener("diff:wrap-before", this.holdForWrap);
    window.removeEventListener("diff:wrap-after", this.restoreForWrap);
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
    if (this.honorScrollTo() || this.retryComment()) {
      this.anchor = null;
      return;
    }

    this.restoreAnchor();
  },

  restoreAnchor() {
    if (!this.anchor) return;

    const section = this.el.querySelector(`#${CSS.escape(this.anchor.id)}`);
    const row = section && this.anchor.key ? this.rowFor(section, this.anchor) : null;

    if (row) {
      this.el.scrollTop += this.offsetOf(row) - this.anchor.rowOffset;
    } else if (section) {
      this.el.scrollTop += this.offsetOf(section) - this.anchor.offset;
    }

    this.anchor = null;
  },

  // A patch reuses row elements for whatever line now sits there, so the line is
  // looked for by its key; of repeated added text, the one nearest its old place.
  rowFor(section, { key, rowOffset }) {
    let found = null;
    let distance = Infinity;

    for (const candidate of section.querySelectorAll(".diff-line")) {
      if (keyOf(candidate) !== key) continue;

      const away = Math.abs(this.offsetOf(candidate) - rowOffset);
      if (away < distance) [found, distance] = [candidate, away];
    }

    return found;
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
    return this.jump(
      () => this.sectionFor(path),
      () => 0
    );
  },

  scrollToComment(id) {
    this.pendingComment = this.commentJump(id) ? null : id;
  },

  retryComment() {
    const id = this.pendingComment;
    this.pendingComment = null;

    return id ? this.commentJump(id) : false;
  },

  // A comment is put just under its file's header, which stays pinned over it.
  commentJump(id) {
    return this.jump(
      () => this.el.querySelector(`#${CSS.escape(id)}`),
      (comment) => {
        const header = comment.closest("[data-qa='diff_file_section']")?.querySelector("[data-qa='diff_file_header']");

        return (header ? header.offsetHeight : 0) + 8;
      }
    );
  },

  jump(find, under) {
    const target = find();
    if (!target) return false;

    this.el.scrollTop += this.offsetOf(target) - under(target);

    // The reader scrolling on their own is not layout settling, so it ends the pull.
    this.stopSettling();
    const token = {};
    this.settling = token;
    for (const type of READER_SCROLLS) this.el.addEventListener(type, this.stopSettling, { passive: true });
    this.settle(find, under, 0, token);

    return true;
  },

  // A section is only laid out once it is scrolled near, so the first jump lands
  // against `contain-intrinsic-size` rather than the real thing, which wrapped lines
  // make far taller. Re-measuring until the target holds still closes that gap.
  settle(find, under, frame, token) {
    requestAnimationFrame(() => {
      if (this.settling !== token) return;

      const target = find();
      if (!target) return this.stopSettling();

      const offset = this.offsetOf(target) - under(target);
      const moved = Math.abs(offset) > 1;
      if (moved) this.el.scrollTop += offset;

      if ((moved || frame + 1 < SETTLE_FRAMES) && frame + 1 < SETTLE_CAP) {
        this.settle(find, under, frame + 1, token);
      } else {
        this.stopSettling();
      }
    });
  },

  sectionFor(path) {
    for (const section of this.sections()) {
      if (section.dataset.path === path) return section;
    }

    return null;
  },

  // The section the viewport is inside, the last one starting at or above it, and
  // the first of its lines still showing at the top.
  currentAnchor() {
    let section = null;

    for (const candidate of this.sections()) {
      const offset = this.offsetOf(candidate);

      if (offset <= 0 || section === null) section = candidate;
      if (offset > 0) break;
    }

    if (!section) return null;

    const row = this.rowAtTop(section);
    const anchor = { id: section.id, offset: this.offsetOf(section) };

    return row ? { ...anchor, key: keyOf(row), rowOffset: this.offsetOf(row) } : anchor;
  },

  // Rows run top to bottom, so the first one not wholly above the viewport is
  // found by halving rather than measuring thousands.
  rowAtTop(section) {
    const rows = section.querySelectorAll(".diff-line");
    const top = this.el.getBoundingClientRect().top;
    let low = 0;
    let high = rows.length;

    while (low < high) {
      const middle = (low + high) >> 1;

      if (rows[middle].getBoundingClientRect().bottom <= top) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }

    return rows[low] || null;
  },

  sections() {
    return this.el.querySelectorAll("[data-qa='diff_file_section']");
  },

  offsetOf(element) {
    return element.getBoundingClientRect().top - this.el.getBoundingClientRect().top;
  }
};
