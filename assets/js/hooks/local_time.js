// Shows a moment in the viewer's own clock: the time of day when it was today,
// "Yest." when it was not. The server renders UTC as a fallback.
export const LocalTime = {
  mounted() {
    this.update();
  },

  updated() {
    this.update();
  },

  update() {
    const at = new Date(this.el.dataset.at);
    if (Number.isNaN(at.getTime())) {
      return;
    }

    const today = new Date().toDateString() === at.toDateString();
    this.el.textContent = today
      ? at.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", hour12: true })
      : "Yest.";
  }
};
