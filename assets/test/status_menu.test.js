import assert from "node:assert/strict";
import { beforeEach, test } from "node:test";
import { calculateAwayAction, calculateMenuPosition, returnFocus } from "../js/hooks/status_menu.js";

const viewport = { width: 1280, height: 800 };
const menu = { width: 240, height: 266 };
const trigger = (top, left = 300) => ({ top, bottom: top + 24, left });

test("opens below its trigger, lined up with its left edge", () => {
  assert.deepEqual(calculateMenuPosition(trigger(100), menu, viewport), { top: 128, left: 300 });
});

test("opens upward at the foot of the viewport", () => {
  assert.deepEqual(calculateMenuPosition(trigger(760), menu, viewport), { top: 490, left: 300 });
});

test("stays below when it only just fits", () => {
  const top = viewport.height - 8 - menu.height - 24 - 4;
  assert.equal(calculateMenuPosition(trigger(top), menu, viewport).top, top + 28);
});

test("keeps to the side with more room and inside the viewport when neither side fits", () => {
  const tall = { width: 240, height: 500 };
  const short = { width: 1024, height: 400 };

  assert.equal(calculateMenuPosition(trigger(100), tall, short).top, 8);
  assert.equal(calculateMenuPosition(trigger(300), tall, short).top, 8);
});

test("moves left rather than run off the right edge", () => {
  assert.equal(calculateMenuPosition(trigger(100, 1200), menu, viewport).left, 1032);
});

test("never starts past the left edge", () => {
  assert.equal(calculateMenuPosition(trigger(100, 2), menu, viewport).left, 8);
});

test("a click in the menu is left alone, with or without a pick waiting", () => {
  assert.equal(calculateAwayAction({ inMenu: true, onTrigger: false, picking: false }), "none");
  assert.equal(calculateAwayAction({ inMenu: true, onTrigger: false, picking: true }), "none");
});

test("a click elsewhere closes the menu", () => {
  assert.equal(calculateAwayAction({ inMenu: false, onTrigger: false, picking: false }), "close");
});

test("a click on the trigger is left to LiveView", () => {
  assert.equal(calculateAwayAction({ inMenu: false, onTrigger: true, picking: false }), "none");
});

test("while a pick waits, any click outside the menu is stopped", () => {
  assert.equal(calculateAwayAction({ inMenu: false, onTrigger: false, picking: true }), "stop");
  assert.equal(calculateAwayAction({ inMenu: false, onTrigger: true, picking: true }), "stop");
});

let doc;
let fire;
let statusButton;
let focusCalls;

beforeEach(() => {
  const listeners = [];
  focusCalls = [];
  statusButton = { focus: (options) => focusCalls.push(options) };
  doc = {
    body: { name: "body" },
    activeElement: null,
    addEventListener: (type, listener, options) => listeners.push({ type, listener, signal: options.signal })
  };
  doc.activeElement = doc.body;
  fire = (type) => {
    for (const entry of listeners) {
      if (entry.type === type && !entry.signal.aborted) entry.listener();
    }
  };
});

test("focus goes to the trigger at once, leaving the page's scroll alone", () => {
  returnFocus(doc, statusButton);

  assert.deepEqual(focusCalls, [{ preventScroll: true }]);
});

test("the patch that drops focus to the body puts it back, once", () => {
  returnFocus(doc, statusButton);

  fire("phx:update");
  assert.deepEqual(focusCalls, [{ preventScroll: true }, { preventScroll: true }]);

  fire("phx:update");
  assert.equal(focusCalls.length, 2);
});

test("a patch with focus on something else does nothing and keeps watching", () => {
  returnFocus(doc, statusButton);
  doc.activeElement = { name: "comment box" };

  fire("phx:update");
  assert.equal(focusCalls.length, 1);

  doc.activeElement = doc.body;
  fire("phx:update");
  assert.equal(focusCalls.length, 2);
});

test("a key press ends the watch", () => {
  returnFocus(doc, statusButton);

  fire("keydown");
  fire("phx:update");

  assert.equal(focusCalls.length, 1);
});

test("a pointer press ends the watch", () => {
  returnFocus(doc, statusButton);

  fire("pointerdown");
  fire("phx:update");

  assert.equal(focusCalls.length, 1);
});

test("a missing trigger throws nothing", () => {
  assert.doesNotThrow(() => {
    returnFocus(doc, null);
    fire("phx:update");
  });
});
