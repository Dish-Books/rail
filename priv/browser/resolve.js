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

  // A dropdown and a date are set here rather than clicked, so where they sit and
  // what is drawn over them decides nothing: a select styled with its own chevron
  // laid over it is still a select whose value can be set.
  const clicked = !(action.kind === 'select' || (action.kind === 'fill' && action.picker));

  // An element below the fold, or under a sticky header or footer, is one the
  // page will happily show if asked. Refusing it instead sends whoever is driving
  // looking for another way to do something that was always possible.
  if (clicked) {
    const r0 = e.getBoundingClientRect();
    if (r0.height && (r0.top < 0 || r0.bottom > innerHeight)) {
      e.scrollIntoView({block: 'center', inline: 'nearest', behavior: 'instant'});
    }
  }

  const r = e.getBoundingClientRect();
  if (!r.width || !r.height) return refused('hidden');

  const x = r.x + r.width / 2, y = r.y + r.height / 2;
  if (clicked && (x < 0 || y < 0 || x >= innerWidth || y >= innerHeight)) return refused('off screen');

  // Something drawn over the middle of it does not mean it cannot be clicked: a
  // long dropdown option crossed by a sticky total bar is still reachable at
  // either end. So the centre is tried first and then points inset from each
  // edge, and only an element covered at every one of them is covered - with the
  // thing over its centre named, because that is what a person debugging this is
  // looking at.
  if (clicked) {
    const inset = Math.min(12, r.width / 4, r.height / 4);
    const points = [
      [x, y],
      [r.x + inset, y], [r.right - inset, y],
      [x, r.y + inset], [x, r.bottom - inset]
    ].filter(([px, py]) => px >= 0 && py >= 0 && px < innerWidth && py < innerHeight);

    const reachable = points.find(([px, py]) => e.contains(document.elementFromPoint(px, py)));
    if (!reachable) return refused('covered', describe(document.elementFromPoint(x, y)));

    return {x: reachable[0], y: reachable[1]};
  }

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
