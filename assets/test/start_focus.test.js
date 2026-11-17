import assert from "node:assert/strict";
import { beforeEach, test } from "node:test";
import { handFocus } from "../js/hooks/start_focus.js";

let doc;
let fire;
let chip;
let chips;
let focusCalls;

beforeEach(() => {
  const listeners = [];
  focusCalls = [];
  doc = {
    body: { name: "body" },
    activeElement: null,
    getElementById: (id) => chips[id] ?? null,
    addEventListener: (type, listener, options) => listeners.push({ type, listener, signal: options.signal })
  };
  doc.activeElement = doc.body;
  chip = (name) => ({
    name,
    focus(options) {
      focusCalls.push({ name, ...options });
      doc.activeElement = this;
    }
  });
  chips = { "task-link-iss_1": chip("chip") };
  fire = (type) => {
    for (const entry of listeners) {
      if (entry.type === type && !entry.signal.aborted) entry.listener();
    }
  };
});

test("a Start that had focus hands it to the chip that replaces it, leaving the scroll alone", () => {
  handFocus(doc, true, "task-link-iss_1");
  assert.deepEqual(focusCalls, [{ name: "chip", preventScroll: true }]);
});

test("a later patch that moves the row and drops focus gives it back to the chip, read again by id", () => {
  handFocus(doc, true, "task-link-iss_1");

  fire("phx:update");
  assert.equal(focusCalls.length, 1);

  chips["task-link-iss_1"] = chip("rebuilt chip");
  doc.activeElement = doc.body;
  fire("phx:update");
  assert.deepEqual(focusCalls.at(-1), { name: "rebuilt chip", preventScroll: true });

  doc.activeElement = doc.body;
  fire("phx:update");
  assert.equal(focusCalls.length, 3);
});

test("a key press ends the watch", () => {
  handFocus(doc, true, "task-link-iss_1");
  fire("keydown");
  doc.activeElement = doc.body;
  fire("phx:update");
  assert.equal(focusCalls.length, 1);
});

test("a pointer press ends the watch", () => {
  handFocus(doc, true, "task-link-iss_1");
  fire("pointerdown");
  doc.activeElement = doc.body;
  fire("phx:update");
  assert.equal(focusCalls.length, 1);
});

test("a Start the person had left keeps its hands off focus", () => {
  handFocus(doc, false, "task-link-iss_1");
  fire("phx:update");
  assert.deepEqual(focusCalls, []);
});

test("focus already somewhere else stays there", () => {
  doc.activeElement = { name: "filter" };
  handFocus(doc, true, "task-link-iss_1");
  doc.activeElement = doc.body;
  fire("phx:update");
  assert.deepEqual(focusCalls, []);
});

test("no chip, such as leaving the page, does nothing and watches nothing", () => {
  handFocus(doc, true, "task-link-iss_gone");
  chips["task-link-iss_gone"] = chip("late chip");
  fire("phx:update");
  assert.deepEqual(focusCalls, []);
});
