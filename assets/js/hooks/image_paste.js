// Pasting a picture into a text box adds it to the box's upload, the way a chat box takes a screenshot, and a paste
// with no picture in it pastes as text.
const IMAGE_TYPES = ["image/png", "image/jpeg", "image/gif", "image/webp"];

export function pastedImages(fileList) {
  return Array.from(fileList ?? []).filter((file) => IMAGE_TYPES.includes(file.type));
}

// Adds `hook`'s pasted pictures to the upload its element names in `data-upload-name`, in the element's own form.
export function listenForPastedImages(hook) {
  hook.el.addEventListener("paste", (event) => {
    const files = pastedImages(event.clipboardData?.files);
    if (files.length === 0 || hook.el.disabled || hook.el.readOnly) return;

    event.preventDefault();
    hook.uploadTo(hook.el.form, hook.el.dataset.uploadName, files);
  });
}

// For a box with no other hook; the chat composer listens itself.
export const ImagePaste = {
  mounted() {
    listenForPastedImages(this);
  }
};
