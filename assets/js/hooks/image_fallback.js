// Marks its element loaded or failed from the image inside it, so the markup picks
// a pulse, the image or a placeholder. Sticky commands keep the mark across patches.
export const ImageFallback = {
  mounted() {
    const img = this.el.querySelector("img");

    // An image already in the cache can finish before the hook mounts.
    if (img.complete && img.naturalWidth > 0) return this.loaded(img);
    if (img.complete && img.currentSrc) return this.failed();

    img.addEventListener("load", () => this.loaded(img), { once: true });
    img.addEventListener("error", () => this.failed(), { once: true });
  },

  // The size goes on first, so the image first appears at the size the view gives it.
  loaded(img) {
    this.js().setAttribute(
      this.el,
      "style",
      `--natural-width: ${img.naturalWidth}; --natural-height: ${img.naturalHeight}`
    );
    this.js().setAttribute(this.el, "data-image", "loaded");
  },

  failed() {
    this.js().setAttribute(this.el, "data-image", "failed");
  }
};
