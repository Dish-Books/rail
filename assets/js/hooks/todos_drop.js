const TODO_TYPE = "application/x-rail-todo";

const parseUrl = (value) => {
  try {
    return new URL(value);
  } catch {
    return null;
  }
};

// Reads what was dropped: an http(s) link as { url, text }, anything else as { text }, or null.
// A link to Rail's own origin becomes its path, so the to-do opens within Rail.
export const readDrop = (dataTransfer, origin, htmlText) => {
  const uri = (dataTransfer.getData("text/uri-list") || "")
    .split(/\r?\n/)
    .find((line) => line && !line.startsWith("#"));
  const html = dataTransfer.getData("text/html");
  const plain = dataTransfer.getData("text/plain") || "";
  const parsed = uri ? parseUrl(uri) : null;
  const text = (html ? htmlText(html) : plain === uri ? "" : plain).trim().slice(0, 500);

  if (parsed && (parsed.protocol === "http:" || parsed.protocol === "https:")) {
    const url = parsed.origin === origin ? `${parsed.pathname}${parsed.search}${parsed.hash}` : parsed.href;
    return { url, text };
  }

  const fallback = text || plain.trim().slice(0, 500);
  return fallback ? { text: fallback } : null;
};

// The id of the row a drop at clientY lands in front of, or null at the end. The row being moved does not count.
export const dropBefore = (rows, clientY, movingId) => {
  const target = rows.filter((row) => row.id !== movingId).find((row) => clientY < row.top + row.height / 2);
  return target ? target.id : null;
};

// Where an arrow key moves a row, as { before } with the id it lands in front of or null for the end;
// null when it is already at that end or the key is another.
export const keyBefore = (ids, id, key) => {
  const index = ids.indexOf(id);
  if (key === "ArrowUp" && index > 0) return { before: ids[index - 1] };
  if (key === "ArrowDown" && index >= 0 && index < ids.length - 1) return { before: ids[index + 2] ?? null };
  return null;
};

// The second click of a double click on a to-do's checkbox. The first click moved its row, so this one would
// land on whichever row slid under the pointer.
export const repeatCheck = (event) => event.detail > 1 && Boolean(event.target?.closest?.("[data-todo-check]"));

// Enter in a to-do's editor saves it, since a text box that grows would take it as a new line.
// An IME's Enter accepts a candidate instead.
export const submitsEdit = (event) =>
  event.key === "Enter" &&
  !event.isComposing &&
  event.keyCode !== 229 &&
  Boolean(event.target?.closest?.("[data-todo-edit]"));

// Typing in a just-opened editor adds to the end of the text rather than in front of it.
export const caretToEnd = (textarea) => {
  const end = textarea.value.length;
  textarea.setSelectionRange(end, end);
};

const types = (event) => Array.from(event.dataTransfer?.types || []);
const droppable = (event) => ["text/uri-list", "text/plain", TODO_TYPE].some((type) => types(event).includes(type));

export const TodosDrop = {
  mounted() {
    const htmlText = (html) => new DOMParser().parseFromString(html, "text/html").body.textContent || "";
    const rowEls = () => Array.from(this.el.querySelectorAll("[data-todo-row]"));
    const rows = () =>
      rowEls().map((el) => {
        const box = el.getBoundingClientRect();
        return { id: el.dataset.todoRow, top: box.top, height: box.height };
      });

    const clearLine = () => {
      for (const el of this.el.querySelectorAll("[data-drop-before], [data-drop-end]")) {
        delete el.dataset.dropBefore;
        delete el.dataset.dropEnd;
      }
    };

    const clearMarks = () => {
      clearLine();
      for (const el of this.el.querySelectorAll("[data-moving]")) delete el.dataset.moving;
      delete this.el.dataset.dragging;
    };

    const drawLine = (before) => {
      clearLine();
      const target = before
        ? this.el.querySelector(`[data-todo-row="${before}"]`)
        : this.el.querySelector("#todos-list");
      if (target && before) target.dataset.dropBefore = "true";
      else if (target) target.dataset.dropEnd = "true";
    };

    // The panel names the control to take the focus after a save, a cancel or a delete, once the patch is in.
    this.handleEvent("todos-focus", ({ id }) => document.getElementById(id)?.focus());
    this.el.addEventListener("todos:caret-end", (event) => caretToEnd(event.target));

    const disarm = (event) => event.target.closest?.("[data-todo-row]")?.removeAttribute("draggable");

    // Firefox starts no drag from a button, so the handle arms its row and the row is dragged.
    this.el.addEventListener("pointerdown", (event) => {
      const handle = event.target.closest?.("[data-todo-handle]");
      if (handle) handle.closest("[data-todo-row]")?.setAttribute("draggable", "true");
    });

    // A press that never became a drag leaves the row as it was, so its text cannot start one.
    this.el.addEventListener("pointerup", disarm);

    this.el.addEventListener("dragstart", (event) => {
      const row = event.target.closest?.("[data-todo-row][draggable='true']");
      if (!row) return;
      this.moving = row.dataset.todoRow;
      row.dataset.moving = "true";
      event.dataTransfer.setData(TODO_TYPE, this.moving);
      event.dataTransfer.effectAllowed = "move";
    });

    this.el.addEventListener("dragend", (event) => {
      disarm(event);
      this.moving = null;
      clearMarks();
    });

    this.el.addEventListener("dragover", (event) => {
      if (!droppable(event)) return;
      event.preventDefault();
      // The outline and its note are for things coming in, not a row being moved.
      if (!types(event).includes(TODO_TYPE)) this.el.dataset.dragging = "true";
      drawLine(dropBefore(rows(), event.clientY, this.moving));
    });

    this.el.addEventListener("dragleave", (event) => {
      if (!this.el.contains(event.relatedTarget)) {
        clearLine();
        delete this.el.dataset.dragging;
      }
    });

    this.el.addEventListener("drop", (event) => {
      event.preventDefault();
      clearMarks();
      const moving = event.dataTransfer.getData(TODO_TYPE);
      const before_id = dropBefore(rows(), event.clientY, moving || this.moving);
      if (moving) return this.pushEventTo(this.el, "move", { todo_id: moving, before_id });

      const dropped = readDrop(event.dataTransfer, window.location.origin, htmlText);
      if (dropped?.url) this.pushEventTo(this.el, "drop_link", { ...dropped, before_id });
      else if (dropped) this.pushEventTo(this.el, "drop_text", { ...dropped, before_id });
    });

    // LiveView reads clicks on the window, so stopping one here keeps it from being pushed.
    this.el.addEventListener("click", (event) => {
      if (!repeatCheck(event)) return;
      event.preventDefault();
      event.stopPropagation();
    });

    // Redrawing the list can move the focused row, which takes the focus off its handle.
    this.el.addEventListener("keydown", (event) => {
      if (submitsEdit(event)) {
        event.preventDefault();
        event.target.form?.requestSubmit();
        return;
      }

      const handle = event.target.closest?.("[data-todo-handle]");
      if (!handle) return;
      const id = handle.dataset.todoHandle;
      const target = keyBefore(
        rowEls().map((el) => el.dataset.todoRow),
        id,
        event.key
      );
      if (!target) return;
      event.preventDefault();
      if (this.pending) return;
      this.pending = true;
      this.pushEventTo(this.el, "move", { todo_id: id, before_id: target.before }, () => {
        this.pending = false;
        document.getElementById(`todo-handle-${id}`)?.focus();
      });
    });
  }
};
