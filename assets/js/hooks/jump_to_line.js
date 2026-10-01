// Scrolls the element named by data-target into the middle of its scroll container on click.
export const JumpToLine = {
  mounted() {
    this.el.addEventListener("click", () => {
      document.getElementById(this.el.dataset.target)?.scrollIntoView({ block: "center", behavior: "smooth" });
    });
  }
};
