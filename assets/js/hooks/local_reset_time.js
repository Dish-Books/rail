// Quota windows reset at a UTC instant, and "today" only means anything on the
// viewer's own clock. The server renders the UTC wording as a fallback.
export const LocalResetTime = {
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

    const time = at.toLocaleTimeString([], { hour: "numeric", minute: "2-digit", hour12: true });
    this.el.textContent = `resets ${day(at)} ${time}`;
  }
};

// Whole days apart on the local calendar, not hours apart on the clock.
function day(at) {
  const midnight = (d) => new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime();
  const days = Math.round((midnight(at) - midnight(new Date())) / 86400000);

  switch (days) {
    case 0:
      return "today";
    case 1:
      return "tomorrow";
    default:
      return `${at.toLocaleDateString([], { weekday: "short", day: "numeric" })},`;
  }
}
