const SCROLL_KEYS = ["PageUp", "PageDown", "Home", "End", "ArrowUp", "ArrowDown", " "];

// Safari can throw a patched or resized scroller back to the top, so the reader's
// place, taken only from their own scrolling, is put back after a reset to the top.
export const ChatAutoscroll = {
  mounted() {
    this.follow = true;
    this.place = 0;
    this.runId = this.el.dataset.runId;
    this.reading = false;
    this.pressed = false;
    this.scrollToBottom();

    // Momentum keeps scrolling after the last input, so the reader's own scrolls extend it too.
    this.onRead = () => {
      this.reading = true;
      clearTimeout(this.readingTimer);
      if (!this.pressed) {
        this.readingTimer = setTimeout(() => {
          this.reading = false;
        }, 300);
      }
    };

    // A held scrollbar thumb or selection drag is the reader's for as long as it is held.
    this.onPress = () => {
      this.pressed = true;
      this.onRead();
    };

    this.onRelease = () => {
      if (!this.pressed) return;
      this.pressed = false;
      this.onRead();
    };

    // Keys on the body scroll the conversation last clicked; typing in the card or composer does not.
    this.onKey = (event) => {
      const target = event.target;
      const scrolls = target === document.body || this.el.contains(target);
      const editable = target.isContentEditable || target.matches("input, textarea, select");
      if (SCROLL_KEYS.includes(event.key) && scrolls && !editable) this.onRead();
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

    for (const type of ["wheel", "touchmove"]) {
      this.el.addEventListener(type, this.onRead, { passive: true });
    }

    this.el.addEventListener("pointerdown", this.onPress);
    window.addEventListener("pointerup", this.onRelease);
    window.addEventListener("pointercancel", this.onRelease);
    window.addEventListener("keydown", this.onKey);

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

    for (const type of ["wheel", "touchmove"]) {
      this.el.removeEventListener(type, this.onRead);
    }

    this.el.removeEventListener("pointerdown", this.onPress);
    window.removeEventListener("pointerup", this.onRelease);
    window.removeEventListener("pointercancel", this.onRelease);
    window.removeEventListener("keydown", this.onKey);

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
