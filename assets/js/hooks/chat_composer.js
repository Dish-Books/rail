// Enter sends, Shift+Enter writes a newline, the box grows to what has been
// typed, and what is typed is kept in this browser until it is sent, so a refresh
// or a tab closed by mistake loses nothing.
//
// A textarea does not submit its form on Enter the way a single-line input does,
// so sending is done here. Everything the agent is told is written in this box,
// including the multi-line notes a finding or a plan needs, which is why it is a
// textarea at all.
const MAX_HEIGHT = 160;

// Storage can be full, or refused in a private window; the draft is a nicety, so
// either just means it is not kept.
export const draftStore = {
  read(key) {
    try {
      return window.localStorage.getItem(key) || "";
    } catch {
      return "";
    }
  },
  write(key, value) {
    try {
      if (value.trim() === "") window.localStorage.removeItem(key);
      else window.localStorage.setItem(key, value);
    } catch {
      // Not kept.
    }
  }
};

export const ChatComposer = {
  mounted() {
    this.key = this.el.dataset.draftKey;
    this.restore();
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

    this.el.addEventListener("input", () => {
      this.fit();
      if (this.key) draftStore.write(this.key, this.el.value);
    });

    // A sent message is the server's now, so the draft of it goes.
    this.el.form?.addEventListener("submit", () => {
      if (this.key) draftStore.write(this.key, "");
    });
  },

  // A draft only fills a box the server left empty, and the server hears it as typed,
  // so the next render does not clear it.
  restore() {
    const draft = this.key ? draftStore.read(this.key) : "";
    if (draft === "" || this.el.value !== "") return;

    this.el.value = draft;
    this.el.dispatchEvent(new Event("input", { bubbles: true }));
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
