export const Theme = {
  mounted() {
    this.initTheme();
    this.handleToggle = () => this.toggleTheme();
    this.el.addEventListener("click", this.handleToggle);

    window.addEventListener("phx:toggle-theme", this.handleToggle);

    this.mediaQuery = window.matchMedia("(prefers-color-scheme: dark)");
    this.handleSystemThemeChange = (e) => {
      if (!localStorage.getItem("theme")) {
        document.documentElement.setAttribute("data-theme", e.matches ? "dark" : "light");
      }
    };
    this.mediaQuery.addEventListener("change", this.handleSystemThemeChange);
  },

  destroyed() {
    this.el.removeEventListener("click", this.handleToggle);
    window.removeEventListener("phx:toggle-theme", this.handleToggle);
    if (this.mediaQuery) {
      this.mediaQuery.removeEventListener("change", this.handleSystemThemeChange);
    }
  },

  initTheme() {
    const saved = localStorage.getItem("theme");
    if (saved) {
      document.documentElement.setAttribute("data-theme", saved);
    } else {
      const prefersDark = window.matchMedia("(prefers-color-scheme: dark)").matches;
      document.documentElement.setAttribute("data-theme", prefersDark ? "dark" : "light");
    }
  },

  toggleTheme() {
    const current = document.documentElement.getAttribute("data-theme") || "dark";
    const next = current === "dark" ? "light" : "dark";
    document.documentElement.setAttribute("data-theme", next);
    localStorage.setItem("theme", next);
    this.pushEvent("theme_changed", { theme: next });
  }
};
