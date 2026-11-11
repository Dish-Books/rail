// A Rail-tracked issue's title, typed into in place. LiveView leaves the heading alone, so a title saved elsewhere
// arrives on data-saved and replaces the text only while nobody is typing in it.

// What to send for the typed title: nothing when it is empty or unchanged, else the title on one line, trimmed.
export function calculateTitleChange(typed, saved) {
  const title = typed.replace(/[\r\n]+/g, " ").trim();
  return title === "" || title === saved ? null : title;
}

// state: { saved, pending }, the title Rail confirmed and a typed one whose push has not resolved. Returns
// { state, push, text }: a title to send, and a text for the heading.
export function calculateTitleState(state, event) {
  const shown = state.pending ?? state.saved;
  switch (event.type) {
    case "commit": {
      const title = event.typed ? calculateTitleChange(event.text, shown) : null;
      if (title === null) return { state, text: shown };
      return { state: { ...state, pending: title }, push: title, text: title };
    }
    case "pushed":
      return { state: state.pending === event.title ? { ...state, pending: null } : state };
    case "reconnected":
      return { state, push: state.pending ?? undefined };
    case "saved": {
      const pending = state.pending === event.saved ? null : state.pending;
      const text = pending === null && !event.focused ? event.saved : undefined;
      return { state: { saved: event.saved, pending }, text };
    }
    default:
      return { state };
  }
}

export const IssueTitle = {
  mounted() {
    this.state = { saved: this.el.dataset.saved, pending: null };
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

  // Only data-saved reaches an ignored heading.
  updated() {
    const saved = this.el.dataset.saved;
    if (saved === this.state.saved) return;
    this.apply({ type: "saved", saved, focused: document.activeElement === this.el });
  },

  reconnected() {
    this.apply({ type: "reconnected" });
  },

  destroyed() {
    this.gone = true;
    this.el.removeEventListener("keydown", this.onKeyDown);
    this.el.removeEventListener("input", this.onInput);
    this.el.removeEventListener("paste", this.onPaste);
    this.el.removeEventListener("drop", this.onDrop);
    this.el.removeEventListener("blur", this.onBlur);
  },

  commit() {
    this.apply({ type: "commit", typed: this.typed, text: this.el.textContent });
    this.typed = false;
  },

  apply(event) {
    const { state, push, text } = calculateTitleState(this.state, event);
    this.state = state;
    if (text !== undefined) this.el.textContent = text;
    if (push) this.push(push);
  },

  push(title) {
    this.pushEvent("edit_issue", { title }).then(
      () => {
        if (!this.gone) this.apply({ type: "pushed", title });
      },
      // Still pending, so reconnected() sends it again.
      () => {}
    );
  }
};
