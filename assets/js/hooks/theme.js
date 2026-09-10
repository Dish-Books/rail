const STORAGE_KEY = "theme";

// The chosen theme lives on <html data-theme>, which the CSS `dark` variant keys off.
// "system" is stored as the absence of a preference, so the OS setting keeps winning.
export function applyTheme(theme) {
  if (theme === "system") {
    localStorage.removeItem(STORAGE_KEY);
  } else {
    localStorage.setItem(STORAGE_KEY, theme);
  }

  document.documentElement.setAttribute("data-theme", resolveTheme(theme));
}

export function storedTheme() {
  return localStorage.getItem(STORAGE_KEY) || "system";
}

function resolveTheme(theme) {
  if (theme === "light" || theme === "dark") return theme;

  return window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light";
}

export const Theme = {
  mounted() {
    // The server renders a default theme it cannot know; tell it what the browser holds.
    applyTheme(storedTheme());
    this.pushEvent("theme_changed", { theme: storedTheme() });

    this.handleToggle = () => this.toggleTheme();
    this.el.addEventListener("click", this.handleToggle);
    window.addEventListener("phx:toggle-theme", this.handleToggle);

    this.mediaQuery = window.matchMedia("(prefers-color-scheme: dark)");
    this.handleSystemThemeChange = () => {
      if (storedTheme() === "system") applyTheme("system");
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

  toggleTheme() {
    const next =
      document.documentElement.getAttribute("data-theme") === "dark" ? "light" : "dark";

    applyTheme(next);
    this.pushEvent("theme_changed", { theme: next });
  }
};
