// A plain text box that takes pasted and dropped files: each goes in at the cursor as an Uploading line, which
// becomes the file's markdown once Rail has it. Nothing submits while one is still going up.
import { uploadableFiles } from "./issue_description.js";
import { formSubmitButton } from "./shortcuts.js";

export function calculateUploadingText(name) {
  return `![Uploading ${calculateLabel(name)}...]()`;
}

export function calculateFileText({ name, url, image }) {
  const label = calculateLabel(name);
  return image ? `![${label}](${url})` : `[${label}](${url})`;
}

// A bracket or backslash in a file's name would end its markdown early.
export function calculateLabel(name) {
  return name.replace(/[\\[\]]/g, "\\$&");
}

// Two pasted `image.png` files read the same while uploading, so the first match is always a right one.
export function replaceFirst(text, find, replacement) {
  const at = text.indexOf(find);
  return at === -1 ? text : text.slice(0, at) + replacement + text.slice(at + find.length);
}

// A file that did not go up takes the line breaks it came in with, so the text reads as it did before.
export function calculateSettledText(text, name, replacement) {
  const line = calculateUploadingText(name);
  if (replacement === "" && text.includes(`\n${line}\n`)) return replaceFirst(text, `\n${line}\n`, "");
  return replaceFirst(text, line, replacement);
}

// Each lost file's Uploading line comes out with the breaks it came in with, as a refused file's does.
export function calculateLostText(text, names) {
  return names.reduce((settled, name) => calculateSettledText(settled, name, ""), text);
}

export function holdSubmit(event, pendingCount) {
  if (pendingCount === 0) return false;
  event.preventDefault();
  event.stopImmediatePropagation();
  return true;
}

function hasFiles(event) {
  return Array.from(event.dataTransfer?.types ?? []).includes("Files");
}

export const MarkdownPaste = {
  mounted() {
    this.pending = [];
    this.listeners = new AbortController();
    const { signal } = this.listeners;
    const form = this.el.form;
    const area = this.el.closest("[data-file-drop]") ?? form;
    const uploadForm = () => document.getElementById(this.el.dataset.uploadForm);

    this.el.addEventListener(
      "paste",
      (event) => {
        const files = uploadableFiles(event.clipboardData?.files);
        if (files.length === 0) return;
        event.preventDefault();
        this.addFiles(files, uploadForm());
      },
      { signal }
    );

    area.addEventListener(
      "dragover",
      (event) => {
        if (!hasFiles(event)) return;
        event.preventDefault();
        this.js().addClass(area, "is-drop-target");
      },
      { signal }
    );
    area.addEventListener(
      "dragleave",
      (event) => {
        if (!area.contains(event.relatedTarget)) this.js().removeClass(area, "is-drop-target");
      },
      { signal }
    );
    // Every dropped file goes up, so one Rail does not take is refused with its reason.
    area.addEventListener(
      "drop",
      (event) => {
        if (!hasFiles(event)) return;
        event.preventDefault();
        this.js().removeClass(area, "is-drop-target");
        const files = Array.from(event.dataTransfer.files);
        if (files.length > 0) this.addFiles(files, uploadForm());
      },
      { signal }
    );
    // On the form itself, so it runs before LiveView's submit listener on the window.
    form.addEventListener("submit", (event) => holdSubmit(event, this.pending.length), { signal });

    const mine = (payload) => payload.form === this.el.dataset.uploadForm;
    this.handleEvent("upload_started", (payload) => {
      if (!mine(payload)) return;
      const held = this.pending.find((file) => file.name === payload.name && file.ref === null);
      if (held) held.ref = payload.ref;
    });
    this.handleEvent("insert_file", (payload) => {
      if (mine(payload)) this.settle(payload.ref, calculateFileText(payload));
    });
    this.handleEvent("upload_failed", (payload) => {
      if (mine(payload)) this.settle(payload.ref, "");
    });

    // A rejoin can replace a box's textarea while its file was going up, and the old hook's mark on Send outlives it.
    this.markSubmit();
  },

  // The form outlives a sent comment's textarea, so its listeners go with the hook.
  destroyed() {
    this.listeners.abort();
  },

  // A reconnect starts a new LiveView process that never saw the files this box is waiting on, so none will be
  // answered. Each comes out, Send is released, and the box's upload says which did not go up.
  reconnected() {
    if (this.pending.length === 0) return;
    const names = this.pending.map((file) => file.name);
    this.pending = [];
    this.el.value = calculateLostText(this.el.value, names);
    this.changed();
    this.pushEventTo(`#${this.el.dataset.uploadForm}`, "upload_lost", { names });
  },

  addFiles(files, uploadForm) {
    const lines = files.map((file) => calculateUploadingText(file.name)).join("\n\n");
    this.el.focus();
    this.el.setRangeText(`\n${lines}\n`, this.el.selectionStart, this.el.selectionEnd, "end");
    for (const file of files) this.pending.push({ name: file.name, ref: null });
    this.changed();
    this.uploadTo(uploadForm, "file", files);
  },

  settle(ref, replacement) {
    const held = this.pending.find((file) => file.ref === ref);
    if (!held) return;
    this.pending = this.pending.filter((file) => file !== held);
    this.el.value = calculateSettledText(this.el.value, held.name, replacement);
    this.changed();
  },

  // Through the input event, so the form's phx-change sees the text.
  changed() {
    this.el.dispatchEvent(new Event("input", { bubbles: true }));
    this.markSubmit();
  },

  // The mark is a JS command, so a patch keeps it.
  markSubmit() {
    const submit = formSubmitButton(this.el);
    if (!submit) return;
    if (this.pending.length > 0) {
      this.js().setAttribute(submit, "data-uploading", "");
      this.js().setAttribute(submit, "aria-disabled", "true");
    } else {
      this.js().removeAttribute(submit, "data-uploading");
      this.js().removeAttribute(submit, "aria-disabled");
    }
  }
};
