import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { hasPictures } from "../js/hooks/chat_composer.js";
import { listenForPastedImages, pastedImages } from "../js/hooks/image_paste.js";

const png = { name: "shot.png", type: "image/png" };
const pdf = { name: "notes.pdf", type: "application/pdf" };

const hookOn = (el) => {
  const uploads = [];
  const hook = { el, uploadTo: (form, name, files) => uploads.push({ form, name, files }) };
  listenForPastedImages(hook);
  return uploads;
};

const box = (fields = {}) => {
  const listeners = {};
  return {
    form: "the form",
    dataset: { uploadName: "images" },
    disabled: false,
    readOnly: false,
    addEventListener: (type, listener) => {
      listeners[type] = listener;
    },
    paste: (files) => {
      const event = { clipboardData: { files }, prevented: false, preventDefault: () => (event.prevented = true) };
      listeners.paste(event);
      return event;
    },
    ...fields
  };
};

describe("pastedImages", () => {
  it("keeps only the pictures a paste carries", () => {
    assert.deepEqual(pastedImages([png, pdf]), [png]);
    assert.deepEqual(pastedImages(undefined), []);
  });
});

describe("listenForPastedImages", () => {
  it("adds a pasted picture to the box's upload in place of pasting it", () => {
    const el = box();
    const uploads = hookOn(el);

    const event = el.paste([png, pdf]);

    assert.equal(event.prevented, true);
    assert.deepEqual(uploads, [{ form: "the form", name: "images", files: [png] }]);
  });

  it("lets a paste with no picture paste as text", () => {
    const el = box();
    const uploads = hookOn(el);

    assert.equal(el.paste([pdf]).prevented, false);
    assert.deepEqual(uploads, []);
  });

  it("takes nothing into a box that is disabled or read-only", () => {
    for (const fields of [{ disabled: true }, { readOnly: true }]) {
      const el = box(fields);
      const uploads = hookOn(el);

      assert.equal(el.paste([png]).prevented, false);
      assert.deepEqual(uploads, []);
    }
  });
});

describe("hasPictures", () => {
  it("says whether a form holds a picture waiting to send", () => {
    assert.equal(hasPictures({ querySelector: () => ({}) }), true);
    assert.equal(hasPictures({ querySelector: () => null }), false);
    assert.equal(hasPictures(undefined), false);
  });
});
