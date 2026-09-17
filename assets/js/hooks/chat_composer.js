// Enter sends, Shift+Enter writes a newline, and the box grows to what has been
// typed.
//
// A textarea does not submit its form on Enter the way a single-line input does,
// so sending is done here. Everything the agent is told is written in this box,
// including the multi-line notes a finding or a plan needs, which is why it is a
// textarea at all.
const MAX_HEIGHT = 160;

export const ChatComposer = {
  mounted() {
    this.fit();

    this.el.addEventListener("keydown", (event) => {
      if (event.key !== "Enter" || event.shiftKey) return;

      // Mid-composition Enter is the IME accepting a candidate, not a send.
      if (event.isComposing || event.keyCode === 229) return;

      event.preventDefault();

      if (!this.el.disabled && this.el.value.trim() !== "") {
        this.el.form?.requestSubmit();
      }
    });

    this.el.addEventListener("input", () => this.fit());
  },

  updated() {
    this.fit();
  },

  // The sent message is cleared by the server, so the box has to shrink back
  // rather than keep the height of what is no longer in it.
  fit() {
    this.el.style.height = "auto";
    this.el.style.height = `${Math.min(this.el.scrollHeight, MAX_HEIGHT)}px`;
    this.el.style.overflowY = this.el.scrollHeight > MAX_HEIGHT ? "auto" : "hidden";
  }
};
