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

  update() {
    const startedAt = this.el.dataset.startedAt;
    if (startedAt) {
      const startTime = new Date(startedAt).getTime();
      const now = Date.now();
      const diffSeconds = Math.floor((now - startTime) / 1000);
      this.el.textContent = formatDuration(diffSeconds);
    } else if (this.el.dataset.elapsedSeconds) {
      const secs = parseInt(this.el.dataset.elapsedSeconds, 10) || 0;
      this.el.textContent = formatDuration(secs);
    }
  }
};
