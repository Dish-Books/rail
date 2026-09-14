// Shows a design mockup at its real 1920x1080 viewport, scaled down to fit the
// width it is given, so each option reads the way its screenshot will.
const VIEWPORT_WIDTH = 1920;
const VIEWPORT_HEIGHT = 1080;

export const DesignFrame = {
  mounted() {
    this.observer = new ResizeObserver(() => this.fit());
    this.observer.observe(this.el);
    this.fit();
  },

  updated() {
    this.fit();
  },

  destroyed() {
    this.observer?.disconnect();
  },

  fit() {
    const frame = this.el.querySelector("iframe");
    if (!frame) return;

    const scale = this.el.clientWidth / VIEWPORT_WIDTH;
    frame.style.width = `${VIEWPORT_WIDTH}px`;
    frame.style.height = `${VIEWPORT_HEIGHT}px`;
    frame.style.transformOrigin = "0 0";
    frame.style.transform = `scale(${scale})`;
    this.el.style.height = `${VIEWPORT_HEIGHT * scale}px`;
  }
};
