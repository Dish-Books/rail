// Copies data-copy-text to the clipboard on click and briefly says so.
export const CopyText = {
  mounted() {
    this.el.addEventListener("click", () => {
      navigator.clipboard.writeText(this.el.dataset.copyText).then(() => {
        this.el.dataset.copied = "true";
        clearTimeout(this.timeout);
        this.timeout = setTimeout(() => delete this.el.dataset.copied, 1500);
      });
    });
  },

  destroyed() {
    clearTimeout(this.timeout);
  }
};
