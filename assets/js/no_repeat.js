// A button marked data-no-repeat ignores clicks while LiveView still waits on its last one, so a double click sends
// once. phx-disable-with would do that, but it puts the button back by its text alone and drops the icon.
// Caught on the way down, before LiveView's own listener on the window sees the click.
export const blockRepeatClicks = (doc) => {
  doc.addEventListener(
    "click",
    (event) => {
      const button = event.target.closest?.("button[data-no-repeat]");
      if (!button?.classList.contains("phx-click-loading")) return;
      event.preventDefault();
      event.stopPropagation();
    },
    true
  );
};
