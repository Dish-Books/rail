// Waits for the page to be worth reading again after an input, and no longer.
//
// Typing into a combobox is the one case where the useful change is not the
// keystroke but the suggestions it brings up, so that waits for a visible option
// and gives up at 200ms. Everything else gets two animation frames.
//
// Adapted from jev-ultrafast (https://github.com/browser-use/jev-ultrafast),
// MIT, Copyright (c) 2026 Browser Use.
(action => new Promise(resolve => {
  const field = window.__railQa?.nodes.get(action.node);
  const autocomplete = action.kind === 'fill' && field?.getAttribute('role') === 'combobox';
  let frames = 0, stopped = false;
  const finish = () => { stopped = true; resolve(); };
  setTimeout(finish, autocomplete ? 200 : 50);

  const ready = () => {
    if (stopped) return;
    const ids = (field?.getAttribute('aria-controls') || field?.getAttribute('aria-owns') || '')
      .split(/\s+/).filter(Boolean);
    const roots = ids.length ? ids.map(id => document.getElementById(id)).filter(Boolean) : [document];
    const options = roots.flatMap(root => [...root.querySelectorAll('[role="option"]')]);
    const showing = options.some(e => {
      const r = e.getBoundingClientRect();
      return r.width && r.height && r.bottom > 0 && r.top < innerHeight &&
        e.checkVisibility({checkOpacity: true, checkVisibilityCSS: true});
    });
    if (++frames >= 2 && (!autocomplete || showing)) finish();
    else requestAnimationFrame(ready);
  };

  requestAnimationFrame(ready);
}))(ACTION)
