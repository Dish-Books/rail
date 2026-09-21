// Resolves the element an action names to a point that can actually be clicked,
// or says why it will not. Called immediately before input, so what it checks is
// what is true at the moment of the click rather than when the page was read.
//
// A refusal carries its reason, because the reasons mean different things to
// whoever is driving: a control that went away is worth reading the page and
// trying again, one that is disabled is the answer to the check rather than an
// obstacle to it, and one that is covered names what is in the way.
//
// The node id is Rail's own, handed out by the snapshot: model output never
// becomes a selector, a coordinate or anything executable.
//
// Adapted from jev-ultrafast (https://github.com/browser-use/jev-ultrafast),
// MIT, Copyright (c) 2026 Browser Use.
(action => {
  const refused = (reason, by) => by ? {refused: reason, by} : {refused: reason};
  const describe = e => {
    if (!e) return 'nothing';
    const name = (e.getAttribute?.('aria-label') || e.textContent || '').trim().replace(/\s+/g, ' ').slice(0, 60);
    const tag = e.tagName ? e.tagName.toLowerCase() : 'node';
    return name ? tag + ' "' + name + '"' : tag + (e.className ? '.' + String(e.className).split(/\s+/)[0] : '');
  };

  const e = window.__railQa?.nodes.get(action.node);
  if (!e?.isConnected) return refused('gone');
  if (e.matches(':disabled') || e.closest('[aria-disabled="true"],[inert]')) return refused('disabled');
  if (!e.checkVisibility({checkOpacity: true, checkVisibilityCSS: true})) return refused('hidden');
  if (action.kind === 'fill' && (e.readOnly || e.getAttribute('aria-readonly') === 'true')) return refused('read only');

  const r = e.getBoundingClientRect(), x = r.x + r.width / 2, y = r.y + r.height / 2;
  if (!r.width || !r.height) return refused('hidden');

  // A dropdown and a date are set here rather than clicked, so where they sit and
  // what is drawn over them decides nothing: a select styled with its own chevron
  // laid over it is still a select whose value can be set.
  const clicked = !(action.kind === 'select' || (action.kind === 'fill' && action.picker));
  if (clicked && (x < 0 || y < 0 || x >= innerWidth || y >= innerHeight)) return refused('off screen');

  // Something drawn over it would take the click instead, and which thing that is
  // is the whole of what a person debugging this wants to know.
  const at = clicked ? document.elementFromPoint(x, y) : null;
  if (clicked && !e.contains(at)) return refused('covered', describe(at));

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
    if (e.tagName !== 'SELECT') return refused('not a dropdown');
    const option = [...e.options].find(o =>
      o.value === action.value && !o.disabled && !o.closest('optgroup[disabled]'));
    if (!option) return refused('no such option');
    e.value = action.value;
    e.dispatchEvent(new Event('input', {bubbles: true}));
    e.dispatchEvent(new Event('change', {bubbles: true}));
  }

  return {x, y};
})(ACTION)
