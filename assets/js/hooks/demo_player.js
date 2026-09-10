export const DemoPlayer = {
  mounted() {
    this.handleKeyDown = (e) => {
      const isInput = e.target.matches("input[type='text'], textarea, select, [contenteditable='true']");
      if (isInput) return;

      if (e.code === "Space") {
        e.preventDefault();
        this.pushEvent("player_toggle_play", {});
      } else if (e.code === "ArrowRight") {
        e.preventDefault();
        this.pushEvent("player_next_frame", {});
      } else if (e.code === "ArrowLeft") {
        e.preventDefault();
        this.pushEvent("player_prev_frame", {});
      } else if (e.code === "Escape") {
        e.preventDefault();
        this.pushEvent("close_demo_player", {});
      }
    };

    window.addEventListener("keydown", this.handleKeyDown);
  },

  destroyed() {
    if (this.handleKeyDown) {
      window.removeEventListener("keydown", this.handleKeyDown);
    }
  }
};
