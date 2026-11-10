// A Rail-tracked issue's title, typed into in place. LiveView leaves the heading alone, so a title saved elsewhere
// arrives on data-saved and replaces the text only while nobody is typing in it.

// What to send for the typed title: nothing when it is empty or unchanged, else the title on one line, trimmed.
export function calculateTitleChange(typed, saved) {
  const title = typed.replace(/[\r\n]+/g, " ").trim();
  return title === "" || title === saved ? null : title;
}

export const IssueTitle = {
  mounted() {
    this.saved = this.el.dataset.saved;
    this.typed = false;

    this.onKeyDown = (event) => {
      // Mid-composition Enter is the IME accepting a candidate, not a save.
      if (event.isComposing || event.keyCode === 229) return;
      if (event.key === "Enter") {
        event.preventDefault();
        this.el.blur();
      } else if (event.key === "Escape") {
        event.preventDefault();
        this.typed = false;
        this.el.blur();
      }
    };
    this.onInput = () => {
      this.typed = true;
      // A browser leaves a <br> behind in an emptied heading, which would hide the placeholder.
      if (this.el.textContent === "") this.el.replaceChildren();
    };
    // Plain text only, so a pasted title brings no formatting with it.
    this.onPaste = (event) => {
      event.preventDefault();
      const text = event.clipboardData.getData("text/plain").replace(/[\r\n]+/g, " ");
      document.execCommand("insertText", false, text);
    };
    this.onDrop = (event) => event.preventDefault();
    this.onBlur = () => this.commit();

    this.el.addEventListener("keydown", this.onKeyDown);
    this.el.addEventListener("input", this.onInput);
    this.el.addEventListener("paste", this.onPaste);
    this.el.addEventListener("drop", this.onDrop);
    this.el.addEventListener("blur", this.onBlur);
  },

  // Only data-saved reaches an ignored heading. Its text waits for the blur while the heading has focus.
  updated() {
    const incoming = this.el.dataset.saved;
    if (incoming === this.saved) return;
    this.saved = incoming;
    if (document.activeElement !== this.el) this.el.textContent = incoming;
  },

  destroyed() {
    this.el.removeEventListener("keydown", this.onKeyDown);
    this.el.removeEventListener("input", this.onInput);
    this.el.removeEventListener("paste", this.onPaste);
    this.el.removeEventListener("drop", this.onDrop);
    this.el.removeEventListener("blur", this.onBlur);
  },

  commit() {
    const title = this.typed ? calculateTitleChange(this.el.textContent, this.saved) : null;
    this.typed = false;

    if (title === null) {
      this.el.textContent = this.saved;
      return;
    }

    this.saved = title;
    this.el.textContent = title;
    this.pushEvent("edit_issue", { title });
  }
};
