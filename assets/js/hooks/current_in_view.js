// Scrolls a list row into view when it becomes the one being read, since a ruling
// can move the selection to a row scrolled out of sight.
export const CurrentInView = {
  mounted() {
    this.current = this.isCurrent();
  },

  updated() {
    const current = this.isCurrent();
    if (current && !this.current) this.el.scrollIntoView({ block: "nearest" });
    this.current = current;
  },

  isCurrent() {
    return this.el.getAttribute("aria-current") === "true";
  }
};
