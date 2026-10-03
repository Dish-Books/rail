// Safari can throw a patched or resized scroller back to the top, so the reader's
// place, taken only from their own scrolling, is put back after a reset to the top.
export const ChatAutoscroll = {
  mounted() {
    this.follow = true;
    this.place = 0;
    this.scrollToBottom();

    this.onScroll = () => {
      const distance = this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight;
      // A clamp moves the offset up, so only moving down to the end turns following on.
      this.follow = distance <= 40 && (this.follow || this.el.scrollTop > this.place);
      this.place = this.el.scrollTop;
    };

    this.el.addEventListener("scroll", this.onScroll);

    this.resized = new ResizeObserver(() => this.restore());
    this.resized.observe(this.el);
  },

  updated() {
    this.restore();
  },

  destroyed() {
    if (this.onScroll) {
      this.el.removeEventListener("scroll", this.onScroll);
    }

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
