// Moves focus through a menu's items with the arrow keys. It reads the items on each key and keeps no state, so the
// same element can show another issue's options after a patch.

// The item to focus after an arrow key, wrapping at either end; null for any other key.
export function calculateNextItem(index, count, key) {
  if (count === 0 || (key !== "ArrowDown" && key !== "ArrowUp")) return null;
  const step = key === "ArrowDown" ? 1 : -1;
  return (index + step + count) % count;
}

export const MenuKeys = {
  mounted() {
    this.el.addEventListener("keydown", (event) => {
      const items = Array.from(this.el.querySelectorAll('[role="menuitem"]'));
      const next = calculateNextItem(items.indexOf(document.activeElement), items.length, event.key);
      if (next === null) return;
      event.preventDefault();
      items[next].focus();
    });
  }
};
