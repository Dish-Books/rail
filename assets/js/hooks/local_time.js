// Shows a moment in the viewer's own clock: the time of day when it was today,
// "Yest." when it was not. The server renders UTC as a fallback.
// With data-format="date-time" a moment before today keeps its time and gains
// a short date, for records read days later.
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

    const time = at.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", hour12: true });
    const today = new Date().toDateString() === at.toDateString();

    if (today) {
      this.el.textContent = time;
    } else if (this.el.dataset.format === "date-time") {
      this.el.textContent = `${at.toLocaleDateString([], { month: "short", day: "numeric" })}, ${time}`;
    } else {
      this.el.textContent = "Yest.";
    }
  }
};
