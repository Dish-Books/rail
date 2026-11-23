// Opens or closes every code sketch in a plan's cards. Opening also opens folded groups, so the code it opened is in view.
export function setSketches(cards, open) {
  for (const sketch of cards.querySelectorAll("[data-qa=plan_card_sketch]")) sketch.open = open;
  if (!open) return;
  for (const group of cards.querySelectorAll("[data-qa=plan_group]")) group.open = true;
}

// The state is the button's own attribute, which patches leave alone, so it reads as the reader left it.
export function toggleSketches(button, doc) {
  const open = button.getAttribute("aria-expanded") !== "true";
  button.setAttribute("aria-expanded", String(open));
  setSketches(doc.getElementById(button.getAttribute("aria-controls")), open);
}

export const SketchesToggle = {
  mounted() {
    this.el.addEventListener("click", () => toggleSketches(this.el, document));
  }
};
