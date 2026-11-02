const STEP_KEYS = ["ArrowLeft", "ArrowRight", "Home", "End"];

// The day an arrow key lands on. With no day shown yet, the arrows start from the latest one.
export function stepDay(index, last, key) {
  if (key === "Home") return 0;
  if (key === "End" || index === null) return last;
  return key === "ArrowLeft" ? Math.max(index - 1, 0) : Math.min(index + 1, last);
}

// The server renders every day's figures on its rect and today's on each field as `data-today`,
// so this holds only which day shows. A patch writes today's figures back, so each one re-applies it.
export const CycleFigures = {
  mounted() {
    this.day = null;
    this.cycle = this.el.dataset.cycle;

    this.el.addEventListener("pointerover", (event) => {
      const day = event.target.closest("[data-day]");
      if (day) this.show(Number(day.dataset.day));
      else this.clear();
    });
    this.el.addEventListener("pointerleave", () => this.clear());

    // Only a keyboard's focus shows a day, so a click on a day still to come keeps today's figures.
    this.el.addEventListener("focusin", (event) => {
      if (this.day === null && event.target.matches("svg[tabindex]:focus-visible")) this.show(this.lastDay());
    });
    this.el.addEventListener("focusout", () => this.clear());

    this.el.addEventListener("keydown", (event) => {
      if (!event.target.matches("svg[tabindex]")) return;
      if (event.key === "Escape") this.clear();
      if (!STEP_KEYS.includes(event.key)) return;
      event.preventDefault();
      this.show(stepDay(this.day, this.lastDay(), event.key));
    });
  },

  // The panel's element carries on when the page steps to another cycle, whose days are not these.
  updated() {
    if (this.el.dataset.cycle !== this.cycle) {
      this.cycle = this.el.dataset.cycle;
      this.day = null;
    } else if (this.day !== null) {
      this.show(this.day);
    }
  },

  lastDay() {
    return this.el.querySelectorAll("[data-day]").length - 1;
  },

  show(index) {
    const day = this.el.querySelector(`[data-day="${index}"]`);
    if (!day) return this.clear();

    this.day = index;
    this.el.toggleAttribute("data-hovering", true);
    this.mark(index);
    for (const field of this.el.querySelectorAll("[data-field]")) {
      field.textContent = day.dataset[field.dataset.field];
    }
  },

  clear() {
    if (this.day === null) return;

    this.day = null;
    this.el.toggleAttribute("data-hovering", false);
    this.mark(null);
    for (const field of this.el.querySelectorAll("[data-field]")) {
      field.textContent = field.dataset.today;
    }
  },

  mark(index) {
    for (const marker of this.el.querySelectorAll("[data-marker]")) {
      marker.classList.toggle("hidden", marker.dataset.marker !== String(index));
    }
  }
};
