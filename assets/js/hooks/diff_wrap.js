const STORAGE_KEY = "diffWrap";

// Wrap is this browser's choice, like the theme, kept on <html data-diff-wrap> for the
// CSS `diff-wrap` variant so no line is re-sent for it. Scroll is stored as no choice.
const storedWrap = () => (localStorage.getItem(STORAGE_KEY) === "wrap" ? "wrap" : "scroll");

const appliedWrap = () => (document.documentElement.hasAttribute("data-diff-wrap") ? "wrap" : "scroll");

const applyWrap = (wrap) => document.documentElement.toggleAttribute("data-diff-wrap", wrap === "wrap");

export const DiffWrap = {
  mounted() {
    // The server draws Scroll pressed until it hears otherwise. Another tab may
    // have chosen since this page loaded, so the stored choice wins.
    const wrap = storedWrap();
    applyWrap(wrap);

    const pressed = this.el.querySelector("[aria-pressed='true']")?.getAttribute("phx-value-wrap");
    if (wrap !== pressed) this.pushEventTo(this.el.dataset.target, "select_diff_wrap", { wrap });

    // The button's own phx-click tells the stage; this only redraws the lines,
    // letting the scroller hold the reader's place around it.
    this.el.addEventListener("click", (event) => {
      const wrap = event.target.closest("[phx-value-wrap]")?.getAttribute("phx-value-wrap");
      if (!wrap || wrap === appliedWrap()) return;

      if (wrap === "wrap") {
        localStorage.setItem(STORAGE_KEY, wrap);
      } else {
        localStorage.removeItem(STORAGE_KEY);
      }

      window.dispatchEvent(new CustomEvent("diff:wrap-before"));
      applyWrap(wrap);
      window.dispatchEvent(new CustomEvent("diff:wrap-after"));
    });
  }
};
