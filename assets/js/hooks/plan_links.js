// Pointing at a file or a module in a plan marks every element naming the same path,
// so a module and its line in File-level changes light up together.
export const PlanLinks = {
  mounted() {
    this.mark = (event, linked) => {
      const path = event.target.closest("[data-plan-file]")?.dataset.planFile;
      if (!path) return;

      for (const el of this.el.querySelectorAll(`[data-plan-file="${CSS.escape(path)}"]`)) {
        el.toggleAttribute("data-linked", linked);
      }
    };

    this.over = (event) => this.mark(event, true);
    this.out = (event) => this.mark(event, false);
    this.el.addEventListener("mouseover", this.over);
    this.el.addEventListener("mouseout", this.out);
  },

  destroyed() {
    this.el.removeEventListener("mouseover", this.over);
    this.el.removeEventListener("mouseout", this.out);
  }
};
