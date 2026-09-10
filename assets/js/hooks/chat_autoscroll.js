export const ChatAutoscroll = {
  mounted() {
    this.el.scrollTop = this.el.scrollHeight;
  },
  updated() {
    if (this.el.dataset.autoscroll !== "false") {
      this.el.scrollTop = this.el.scrollHeight;
    }
  }
};
