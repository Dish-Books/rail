export const ChatAutoscroll = {
  mounted() {
    this.follow = true;
    this.scrollToBottom();

    this.onScroll = () => {
      const distance = this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight;
      this.follow = distance <= 40;
    };

    this.el.addEventListener("scroll", this.onScroll);
  },

  updated() {
    if (this.follow && this.el.dataset.autoscroll !== "false") {
      this.scrollToBottom();
    }
  },

  destroyed() {
    if (this.onScroll) {
      this.el.removeEventListener("scroll", this.onScroll);
    }
  },

  scrollToBottom() {
    this.el.scrollTop = this.el.scrollHeight;
  }
};
