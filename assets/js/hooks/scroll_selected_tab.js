// Answered tabs stay in the strip, so the selected one can sit past either edge
// of a long round; each patch brings it back into view. Only the strip scrolls,
// so the sidebar around it never jumps.
export const ScrollSelectedTab = {
  mounted() {
    this.reveal();
  },

  updated() {
    this.reveal();
  },

  reveal() {
    const tab = this.el.querySelector("[aria-selected='true']");
    if (!tab) return;

    const strip = this.el.getBoundingClientRect();
    const selected = tab.getBoundingClientRect();

    if (selected.left < strip.left) {
      this.el.scrollLeft -= strip.left - selected.left;
    } else if (selected.right > strip.left + this.el.clientWidth) {
      this.el.scrollLeft += selected.right - (strip.left + this.el.clientWidth);
    }
  }
};
