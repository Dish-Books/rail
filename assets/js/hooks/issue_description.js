// A Rail-tracked issue's description, typed into in place with TipTap and kept as markdown. Every edit is copied to
// this browser before it is saved, so a save Rail cannot take is kept and retried until it can.
import { draftStore } from "./chat_composer.js";

const UPLOADABLE_TYPES = ["image/png", "image/jpeg", "image/gif", "image/webp", "application/pdf"];
const TEXTBLOCKS = ["paragraph", "heading"];
const SAVE_AFTER_MS = 1000;
const REPLY_WITHIN_MS = 10000;
const RETRY_EVERY_MS = 15000;

// The files a paste carries that the description takes, so a paste with none of them pastes as text.
export function uploadableFiles(fileList) {
  return Array.from(fileList ?? []).filter((file) => UPLOADABLE_TYPES.includes(file.type));
}

// TipTap's paragraph parser lifts an image alone on its line out of its paragraph, where an inline image may not be.
export function wrapLoneImages(node) {
  if (!node.content) return node;
  const inText = TEXTBLOCKS.includes(node.type);
  return {
    ...node,
    content: node.content.map((child) =>
      child.type === "image" && !inText ? { type: "paragraph", content: [child] } : wrapLoneImages(child)
    )
  };
}

// At the cursor, or while the editor has never had focus at the end: inside a trailing empty paragraph, not after it.
export function calculateDropPosition(doc, selectionFrom, everFocused) {
  if (everFocused) return selectionFrom;
  const last = doc.lastChild;
  const emptyParagraph = last?.type.name === "paragraph" && last.content.size === 0;
  return emptyParagraph ? doc.content.size - 1 : doc.content.size;
}

// What to do with a stored copy on mount: load one that differs from every form of the saved text, clear one that
// matches it, or do nothing when there is none.
export function calculateRestore(stored, saved) {
  if (stored === null) return "none";
  return [saved].flat().includes(stored) ? "clear" : "load";
}

// Whether a new saved text from the server replaces the editor's now, waits for the next blur, or changes nothing.
export function calculateReplace({ focused, dirty, pending, unsaved, baseline, incoming }) {
  if (incoming === baseline) return "none";
  return focused || dirty || pending || unsaved ? "later" : "now";
}

// state: { baseline, text, seq, inFlight, failed }. Each call returns { state, push, notice, draft, retry }; a reply
// or a timeout counts only for the latest save, so a stale one neither raises nor clears the notice.
export function calculateSaveState(state, event) {
  switch (event.type) {
    case "edit": {
      const text = event.text;
      if (text === state.baseline) {
        return { state: { ...state, text, failed: false }, notice: "hide", draft: "clear", retry: "stop" };
      }
      return { state: { ...state, text }, draft: "write" };
    }
    case "save":
    case "reconnected": {
      if (state.text === state.baseline) return { state };
      const seq = state.seq + 1;
      return { state: { ...state, seq, inFlight: seq }, push: { seq, text: state.text }, draft: "write" };
    }
    case "ok": {
      if (event.seq !== state.inFlight) return { state };
      const baseline = event.text;
      const settled = state.text === baseline;
      return {
        state: { ...state, baseline, inFlight: null, failed: !settled && state.failed },
        notice: settled ? "hide" : undefined,
        draft: settled ? "clear" : "write",
        retry: settled ? "stop" : undefined
      };
    }
    case "refused":
    case "timeout":
      if (event.seq !== state.inFlight || state.text === state.baseline) return { state };
      return { state: { ...state, inFlight: null, failed: true }, notice: "show", draft: "write", retry: "start" };
    case "disconnected":
      if (state.text === state.baseline) return { state };
      return { state: { ...state, inFlight: null, failed: true }, notice: "show", draft: "write", retry: "start" };
    default:
      return { state };
  }
}

// Wrapped, since draftStore drops an empty value and an emptied description is an edit to keep.
function readDraft(key) {
  try {
    const { text } = JSON.parse(draftStore.read(key));
    return typeof text === "string" ? text : null;
  } catch {
    return null;
  }
}

function hasFiles(event) {
  return Array.from(event.dataTransfer?.types ?? []).includes("Files");
}

function placeholderNode(name) {
  const node = document.createElement("span");
  node.className =
    "upload-placeholder flex items-center justify-center gap-2 w-[560px] max-w-full h-28 my-3 px-4 rounded-lg border border-dashed border-slate-300 dark:border-slate-600 bg-slate-50 dark:bg-slate-800/50 text-xs text-slate-500 dark:text-slate-400";
  node.contentEditable = "false";
  node.setAttribute("aria-busy", "true");
  const spinner = document.createElement("span");
  spinner.className = "pi-circle-notch h-4 w-4 shrink-0 motion-safe:animate-spin";
  spinner.setAttribute("aria-hidden", "true");
  const label = document.createElement("span");
  label.className = "min-w-0 truncate";
  label.textContent = `Uploading ${name}...`;
  node.append(spinner, label);
  return node;
}

export const IssueDescription = {
  mounted() {
    this.key = `rail:description:${this.el.dataset.issueId}`;
    this.savedRaw = this.el.dataset.saved;
    this.timers = new Set();
    this.placeholders = [];
    this.everFocused = false;
    this.waiting = null;

    import("./issue_editor_kit.js").then((kit) => {
      if (!this.gone) this.start(kit);
    });
  },

  // Only data-saved reaches an ignored container.
  updated() {
    const incoming = this.el.dataset.saved;
    if (!this.editor || incoming === this.savedRaw) return;
    this.savedRaw = incoming;
    this.waiting = incoming;
    this.takeWaiting();
  },

  disconnected() {
    this.dispatch({ type: "disconnected" });
  },

  reconnected() {
    this.dispatch({ type: "reconnected" });
  },

  destroyed() {
    this.gone = true;
    if (this.editor && this.state.text !== this.state.baseline) {
      this.writeDraft();
      try {
        this.pushEventTo(this.el, "save_description", { description: this.state.text });
      } catch {
        // The stored copy is saved when the description next mounts.
      }
    }
    for (const timer of this.timers) clearTimeout(timer);
    clearInterval(this.retryTimer);
    clearTimeout(this.saveTimer);
    this.listeners?.abort();
    this.editor?.destroy();
  },

  start(kit) {
    const key = new kit.PluginKey("uploadPlaceholders");
    this.placeholderKey = key;

    // Each file waiting on its upload holds its place as a decoration, so a save never writes it.
    const placeholders = kit.Extension.create({
      name: "uploadPlaceholders",
      addProseMirrorPlugins: () => [
        new kit.Plugin({
          key,
          state: {
            init: () => kit.DecorationSet.empty,
            apply: (tr, set) => {
              const mapped = set.map(tr.mapping, tr.doc);
              const action = tr.getMeta(key);
              if (action?.add) {
                const { id, name, pos } = action.add;
                return mapped.add(tr.doc, [kit.Decoration.widget(pos, () => placeholderNode(name), { id })]);
              }
              if (action?.remove) return mapped.remove(mapped.find(null, null, (spec) => spec.id === action.remove));
              return mapped;
            }
          },
          props: { decorations: (state) => key.getState(state) }
        })
      ]
    });

    this.el.replaceChildren();
    this.editor = new kit.Editor({
      element: this.el,
      extensions: [
        kit.StarterKit.configure({ underline: false }),
        kit.Image.configure({ inline: true }),
        kit.TableKit,
        kit.TaskList,
        kit.TaskItem.configure({ nested: true }),
        kit.Markdown,
        kit.Placeholder.configure({ placeholder: "Add description..." }),
        placeholders
      ],
      editorProps: {
        attributes: {
          role: "textbox",
          "aria-multiline": "true",
          "aria-label": "Description",
          class:
            "prose prose-slate dark:prose-invert max-w-none text-sm leading-relaxed text-slate-700 dark:text-slate-300 min-h-6 cursor-text focus:outline-none"
        },
        handlePaste: (_view, event) => {
          const files = uploadableFiles(event.clipboardData?.files);
          if (files.length === 0) return false;
          this.addFiles(files);
          return true;
        }
      }
    });

    this.loadMarkdown(this.savedRaw);
    const baseline = this.editor.getMarkdown();
    this.state = { baseline, text: baseline, seq: 0, inFlight: null, failed: false };

    const stored = readDraft(this.key);
    const restore = calculateRestore(stored, [this.savedRaw, baseline]);
    if (restore === "clear") draftStore.write(this.key, "");
    if (restore === "load") {
      this.loadMarkdown(stored);
      this.dispatch({ type: "edit", text: this.editor.getMarkdown() });
      this.dispatch({ type: "save" });
    }

    this.editor.on("update", () => {
      this.dispatch({ type: "edit", text: this.editor.getMarkdown() });
      this.scheduleSave();
    });
    this.editor.on("focus", () => {
      this.everFocused = true;
    });
    this.editor.on("blur", () => {
      this.flushSave();
      this.takeWaiting();
    });

    this.bindPage();
  },

  bindPage() {
    this.listeners = new AbortController();
    const { signal } = this.listeners;
    const overlay = document.getElementById(this.el.dataset.overlay);
    const notice = document.getElementById(this.el.dataset.notice);
    this.notice = notice;

    // Bound here, since the server cannot handle a click while it is unreachable.
    document
      .getElementById(this.el.dataset.retry)
      ?.addEventListener("click", () => this.dispatch({ type: "save" }), { signal });

    const showOverlay = (shown) => {
      if (!overlay) return;
      if (shown) this.js().show(overlay, { display: "flex" });
      else this.js().hide(overlay);
    };

    window.addEventListener(
      "dragover",
      (event) => {
        if (!hasFiles(event)) return;
        event.preventDefault();
        showOverlay(true);
      },
      { signal }
    );
    window.addEventListener(
      "dragleave",
      (event) => {
        if (event.relatedTarget === null) showOverlay(false);
      },
      { signal }
    );
    // Capture, so a drop on the comment box or the editor itself lands in the description too.
    window.addEventListener(
      "drop",
      (event) => {
        if (!hasFiles(event)) return;
        event.preventDefault();
        event.stopPropagation();
        showOverlay(false);
        // Every dropped file goes up, so one Rail does not take is refused with its reason.
        const files = Array.from(event.dataTransfer.files);
        if (files.length > 0) this.addFiles(files);
      },
      { signal, capture: true }
    );

    this.handleEvent("upload_started", ({ ref, name }) => {
      const held = this.placeholders.find((placeholder) => placeholder.name === name && placeholder.ref === null);
      if (held) held.ref = ref;
    });
    // A link mark takes in what is typed right after it, so a plain space follows a file's link.
    this.handleEvent("insert_file", ({ ref, url, name, image }) =>
      this.settleFile(
        ref,
        image
          ? [{ type: "image", attrs: { src: url, alt: name } }]
          : [
              { type: "text", text: name, marks: [{ type: "link", attrs: { href: url } }] },
              { type: "text", text: " " }
            ]
      )
    );
    this.handleEvent("upload_failed", ({ ref }) => this.settleFile(ref, null));
  },

  // Outside the undo history, so Ctrl+Z never goes back past the text that was loaded.
  loadMarkdown(markdown) {
    const json = wrapLoneImages(this.editor.markdown.parse(markdown));
    this.editor.chain().setMeta("addToHistory", false).setContent(json, { emitUpdate: false }).run();
  },

  addFiles(files) {
    const { state, view } = this.editor;
    const pos = calculateDropPosition(state.doc, state.selection.from, this.everFocused);
    let tr = state.tr;

    for (const file of files) {
      const id = `${Date.now()}-${Math.random()}`;
      this.placeholders.push({ id, name: file.name, ref: null });
      tr = tr.setMeta(this.placeholderKey, { add: { id, name: file.name, pos } });
      view.dispatch(tr);
      tr = view.state.tr;
    }

    this.uploadTo(document.getElementById(this.el.dataset.uploadForm), "file", files);
  },

  settleFile(ref, content) {
    const held = this.placeholders.find((placeholder) => placeholder.ref === ref);
    if (!held) return;
    this.placeholders = this.placeholders.filter((placeholder) => placeholder !== held);

    const { state, view } = this.editor;
    const [found] = this.placeholderKey.getState(state).find(null, null, (spec) => spec.id === held.id);
    view.dispatch(state.tr.setMeta(this.placeholderKey, { remove: held.id }));

    if (content) {
      const pos = found ? found.from : this.editor.state.doc.content.size;
      this.editor.chain().insertContentAt(pos, content).run();
    }
    this.takeWaiting();
  },

  scheduleSave() {
    clearTimeout(this.saveTimer);
    this.saveTimer = setTimeout(() => this.dispatch({ type: "save" }), SAVE_AFTER_MS);
  },

  flushSave() {
    clearTimeout(this.saveTimer);
    this.dispatch({ type: "save" });
  },

  dispatch(event) {
    if (!this.state) return;
    const { state, push, notice, draft, retry } = calculateSaveState(this.state, event);
    this.state = state;

    if (draft === "write") this.writeDraft();
    if (draft === "clear") draftStore.write(this.key, "");
    if (notice === "show") this.js().show(this.notice, { display: "flex" });
    if (notice === "hide") this.js().hide(this.notice);
    if (retry === "start" && !this.retryTimer) {
      this.retryTimer = setInterval(() => this.dispatch({ type: "save" }), RETRY_EVERY_MS);
    }
    if (retry === "stop") {
      clearInterval(this.retryTimer);
      this.retryTimer = null;
    }
    if (push) this.push(push);
  },

  push({ seq, text }) {
    // Last save wins, so a text saved elsewhere before this one is no longer what Rail holds.
    this.waiting = null;
    const timeout = setTimeout(() => {
      this.timers.delete(timeout);
      this.dispatch({ type: "timeout", seq });
    }, REPLY_WITHIN_MS);
    this.timers.add(timeout);

    this.pushEventTo(this.el, "save_description", { description: text }, (reply) => {
      clearTimeout(timeout);
      this.timers.delete(timeout);
      if (this.gone) return;
      this.dispatch(reply?.ok ? { type: "ok", seq, text } : { type: "refused", seq });
      // An edit made while this save was out still needs one of its own.
      if (this.state.text !== this.state.baseline && this.state.inFlight === null) this.scheduleSave();
      this.takeWaiting();
    });
  },

  writeDraft() {
    draftStore.write(this.key, JSON.stringify({ text: this.state.text }));
  },

  // A text saved elsewhere is taken only while nobody is typing, saving or uploading here.
  takeWaiting() {
    if (this.waiting === null || !this.editor) return;

    const action = calculateReplace({
      focused: this.editor.isFocused,
      dirty: this.state.text !== this.state.baseline,
      pending: this.placeholders.length > 0 || this.state.inFlight !== null,
      unsaved: this.state.failed,
      baseline: this.state.baseline,
      incoming: this.waiting
    });

    if (action === "later") return;
    const incoming = this.waiting;
    this.waiting = null;
    if (action === "none") return;

    this.loadMarkdown(incoming);
    const baseline = this.editor.getMarkdown();
    this.state = { ...this.state, baseline, text: baseline };
  }
};
