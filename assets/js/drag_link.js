// The entries a dragged link carries, so any drop target reads this element as a link.
export const dragData = (origin, href, text) => {
  const url = new URL(href, origin).href;
  return [
    ["text/uri-list", url],
    ["text/plain", text || url]
  ];
};

// One listener for the page, since a row that opens by click may already carry a hook of its own.
export const listenForDragLinks = (doc, origin) => {
  doc.addEventListener("dragstart", (event) => {
    const row = event.target.closest?.("[data-drag-href]");
    if (!row) return;
    for (const [type, value] of dragData(origin, row.dataset.dragHref, row.dataset.dragText)) {
      event.dataTransfer.setData(type, value);
    }
    event.dataTransfer.effectAllowed = "link";
  });
};
