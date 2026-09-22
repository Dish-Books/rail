// Paints what the task's browser is looking at, frame by frame.
//
// The frames arrive as server events rather than as an assign, because they come
// several times a second and nothing else on the page moves with them: sending
// them through the render would diff the whole panel to change one image. The
// previous frame is only swapped out once the next one has decoded, so the pane
// never blinks white between them.
export const BrowserScreencast = {
  mounted() {
    this.handleEvent("browser:frame", ({ data }) => this.paint(data));
  },

  destroyed() {
    this.pending = null;
  },

  paint(data) {
    const next = new Image();

    next.onload = () => {
      if (this.pending !== next) return;

      this.el.src = next.src;
      this.el.dataset.live = "true";
    };

    this.pending = next;
    next.src = `data:image/jpeg;base64,${data}`;
  }
};
