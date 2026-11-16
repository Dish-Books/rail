import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { keyText, modifiers, toViewport, VIEWPORT_HEIGHT, VIEWPORT_WIDTH } from "../js/hooks/app_input.js";

describe("toViewport", () => {
  const rect = { left: 100, top: 50, width: 960, height: 540 };

  it("maps a point on the picture to the tab's own pixels", () => {
    assert.deepEqual(toViewport({ clientX: 100, clientY: 50 }, rect), { x: 0, y: 0 });
    assert.deepEqual(toViewport({ clientX: 580, clientY: 320 }, rect), { x: 960, y: 540 });
    assert.deepEqual(toViewport({ clientX: 1060, clientY: 590 }, rect), { x: VIEWPORT_WIDTH, y: VIEWPORT_HEIGHT });
  });

  it("rounds to whole pixels", () => {
    assert.deepEqual(toViewport({ clientX: 100.3, clientY: 50.3 }, rect), { x: 1, y: 1 });
  });

  it("keeps a point off the picture's edge inside the tab", () => {
    assert.deepEqual(toViewport({ clientX: 0, clientY: 0 }, rect), { x: 0, y: 0 });
    assert.deepEqual(toViewport({ clientX: 5000, clientY: 5000 }, rect), { x: VIEWPORT_WIDTH, y: VIEWPORT_HEIGHT });
  });
});

describe("modifiers", () => {
  it("is 0 with none held", () => {
    assert.equal(modifiers({}), 0);
  });

  it("adds Alt 1, Ctrl 2, Meta 4 and Shift 8 as Chrome does", () => {
    assert.equal(modifiers({ altKey: true }), 1);
    assert.equal(modifiers({ ctrlKey: true }), 2);
    assert.equal(modifiers({ metaKey: true }), 4);
    assert.equal(modifiers({ shiftKey: true }), 8);
    assert.equal(modifiers({ altKey: true, ctrlKey: true, metaKey: true, shiftKey: true }), 15);
    assert.equal(modifiers({ ctrlKey: true, shiftKey: true }), 10);
  });
});

describe("keyText", () => {
  it("is the character a printable key types", () => {
    assert.equal(keyText({ key: "a" }), "a");
    assert.equal(keyText({ key: "A", shiftKey: true }), "A");
    assert.equal(keyText({ key: " " }), " ");
  });

  it("is a carriage return for Enter", () => {
    assert.equal(keyText({ key: "Enter" }), "\r");
  });

  it("is nothing for a key that types nothing", () => {
    assert.equal(keyText({ key: "ArrowLeft" }), null);
    assert.equal(keyText({ key: "Backspace" }), null);
    assert.equal(keyText({ key: "Shift" }), null);
  });

  it("is nothing for a shortcut held with Ctrl or Meta", () => {
    assert.equal(keyText({ key: "c", ctrlKey: true }), null);
    assert.equal(keyText({ key: "v", metaKey: true }), null);
    assert.equal(keyText({ key: "Enter", metaKey: true }), null);
  });
});
