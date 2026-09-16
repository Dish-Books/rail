function formatDuration(seconds) {
  const d = Math.max(0, Math.floor(seconds));
  const h = Math.floor(d / 3600);
  const m = Math.floor((d % 3600) / 60);
  const s = d % 60;

  if (h > 0) {
    return `${h}h ${m}m ${s}s`;
  }
  if (m > 0) {
    return `${m}m ${s}s`;
  }
  return `${s}s`;
}

export const Elapsed = {
  mounted() {
    this.update();
    this.interval = setInterval(() => this.update(), 1000);
  },

  updated() {
    this.update();
  },

  destroyed() {
    if (this.interval) {
      clearInterval(this.interval);
    }
  },

  // Total time across every turn of the run. Turns that have finished arrive as
  // a number; a turn still going arrives as the time it began and keeps counting
  // here, so the two are added rather than one replacing the other.
  update() {
    const settled = parseInt(this.el.dataset.elapsedSeconds, 10) || 0;
    const startedAt = this.el.dataset.startedAt;

    if (startedAt) {
      const startTime = new Date(startedAt).getTime();
      if (!Number.isNaN(startTime)) {
        const running = Math.max(0, Math.floor((Date.now() - startTime) / 1000));
        this.el.textContent = formatDuration(settled + running);
        return;
      }
    }

    if (this.el.dataset.elapsedSeconds) {
      this.el.textContent = formatDuration(settled);
    }
  }
};
