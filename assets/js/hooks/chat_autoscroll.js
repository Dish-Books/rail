// Safari can throw a patched or resized scroller back to the top, so the reader's
// place, taken only from their own scrolling, is put back after a reset to the top.
export const ChatAutoscroll = {
  mounted() {
    this.follow = true;
    this.place = 0;
    this.runId = this.el.dataset.runId;
    this.reading = false;
    this.scrollToBottom();

    // Momentum keeps scrolling after the last input, so the reader's own scrolls extend it too.
    this.onRead = () => {
      this.reading = true;
      clearTimeout(this.readingTimer);
      this.readingTimer = setTimeout(() => (this.reading = false), 300);
    };

    this.onScroll = () => {
      // A reset fires a scroll event like any other, so it is undone here before it can be recorded.
      if (this.el.scrollTop === 0 && this.place > 0 && !this.reading) {
        this.el.scrollTop = this.place;
        return;
      }

      if (this.reading) this.onRead();

      const distance = this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight;
      // A clamp moves the offset up, so only moving down to the end turns following on.
      this.follow = distance <= 40 && (this.follow || this.el.scrollTop > this.place);
      this.place = this.el.scrollTop;
    };

    this.el.addEventListener("scroll", this.onScroll);

    for (const type of ["wheel", "touchmove", "keydown", "pointerdown"]) {
      this.el.addEventListener(type, this.onRead, { passive: true });
    }

    this.resized = new ResizeObserver(() => this.restore());
    this.resized.observe(this.el);
  },

  // The same scroller serves every stage tab, and another run opens at its end.
  updated() {
    if (this.el.dataset.runId !== this.runId) {
      this.runId = this.el.dataset.runId;
      this.follow = true;
      this.place = 0;
      this.scrollToBottom();
    } else {
      this.restore();
    }
  },

  destroyed() {
    if (this.onScroll) {
      this.el.removeEventListener("scroll", this.onScroll);
    }

    for (const type of ["wheel", "touchmove", "keydown", "pointerdown"]) {
      this.el.removeEventListener(type, this.onRead);
    }

    clearTimeout(this.readingTimer);

    if (this.resized) {
      this.resized.disconnect();
    }
  },

  restore() {
    if (this.follow && this.el.dataset.autoscroll !== "false") {
      this.scrollToBottom();
    } else if (this.el.scrollTop === 0 && this.place > 0) {
      this.el.scrollTop = this.place;
    }
  },

  scrollToBottom() {
    this.el.scrollTop = this.el.scrollHeight;
  }
};
