// Resolves the element an action names to a point that can actually be clicked,
// or to nothing. Called immediately before input, so what it checks is what is
// true at the moment of the click rather than when the page was read.
//
// The node id is Rail's own, handed out by the snapshot: model output never
// becomes a selector, a coordinate or anything executable.
//
// Adapted from jev-ultrafast (https://github.com/browser-use/jev-ultrafast),
// MIT, Copyright (c) 2026 Browser Use.
(action => {
  const e = window.__railQa?.nodes.get(action.node);
  if (!e?.isConnected) return null;
  if (e.matches(':disabled') || e.closest('[aria-disabled="true"],[inert]')) return null;
  if (!e.checkVisibility({checkOpacity: true, checkVisibilityCSS: true})) return null;
  if (action.kind === 'fill' && (e.readOnly || e.getAttribute('aria-readonly') === 'true')) return null;

  const r = e.getBoundingClientRect(), x = r.x + r.width / 2, y = r.y + r.height / 2;
  if (!r.width || !r.height || x < 0 || y < 0 || x >= innerWidth || y >= innerHeight) return null;

  // Something drawn over it would take the click instead.
  if (!e.contains(document.elementFromPoint(x, y))) return null;

  // A date or time input takes its value the way a dropdown does: set while the
  // element is still held, because the browser draws its own segmented control
  // and no keystroke reaches it. `value` is always `yyyy-mm-dd` and friends
  // whatever the page's locale displays, so the format does not vary.
  if (action.kind === 'fill' && action.picker) {
    const wanted = action.text ?? '';
    e.value = wanted;
    if (e.value !== wanted) return {rejected: true};
    e.dispatchEvent(new Event('input', {bubbles: true}));
    e.dispatchEvent(new Event('change', {bubbles: true}));
  }

  if (action.kind === 'select') {
    if (e.tagName !== 'SELECT') return null;
    const option = [...e.options].find(o =>
      o.value === action.value && !o.disabled && !o.closest('optgroup[disabled]'));
    if (!option) return null;
    e.value = action.value;
    e.dispatchEvent(new Event('input', {bubbles: true}));
    e.dispatchEvent(new Event('change', {bubbles: true}));
  }

  return {x, y};
})(ACTION)
