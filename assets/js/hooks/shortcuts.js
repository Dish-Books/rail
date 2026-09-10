export const Shortcuts = {
  mounted() {
    this.handleKeyDown = (e) => {
      const isInput = e.target.matches("input, textarea, select, [contenteditable='true']");

      // Global capture shortcut: ⌘N / Ctrl+N
      if ((e.metaKey || e.ctrlKey) && (e.key === "n" || e.key === "N")) {
        if (!isInput) {
          e.preventDefault();
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
        if (modal && modal.contains(e.target)) {
          e.preventDefault();
          const submitBtn = modal.querySelector("button[type='submit']");
          if (submitBtn) {
            submitBtn.click();
          }
        }
      }
    };

    window.addEventListener("keydown", this.handleKeyDown);
  },

  destroyed() {
    window.removeEventListener("keydown", this.handleKeyDown);
  }
};
