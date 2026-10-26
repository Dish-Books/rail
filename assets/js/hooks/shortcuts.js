// A modal can hold several forms, so ⌘Enter submits only the one the cursor is in.
export const formSubmitButton = (target) => target.form?.querySelector("button[type='submit']") ?? null;

// A page's own modal overlay paints over New Issue, so ⌘N waits until it is closed; a button whose key ends in "-modal" is no overlay.
export const modalOpen = (doc) => doc.querySelector("div.fixed[id$='-modal'], [role='dialog']") !== null;

export const Shortcuts = {
  mounted() {
    this.handleKeyDown = (e) => {
      const isInput = e.target.matches("input, textarea, select, [contenteditable='true']");

      // Global capture shortcut: ⌘N / Ctrl+N
      if ((e.metaKey || e.ctrlKey) && (e.key === "n" || e.key === "N")) {
        if (!isInput) {
          e.preventDefault();
          if (modalOpen(document)) return;
          const button = document.querySelector("[data-qa='global_capture_idea_button']");
          if (button) {
            button.click();
          } else {
            this.pushEvent("open_new_issue", {});
          }
        }
      }

      // Dialog submit shortcut: ⌘Enter / Ctrl+Enter
      if ((e.metaKey || e.ctrlKey) && e.key === "Enter") {
        const modal = document.querySelector("[data-qa='capture_dialog'], #new-issue-modal, #project-modal");
        if (modal?.contains(e.target)) {
          e.preventDefault();
          formSubmitButton(e.target)?.click();
        }
      }
    };

    window.addEventListener("keydown", this.handleKeyDown);
  },

  destroyed() {
    window.removeEventListener("keydown", this.handleKeyDown);
  }
};
