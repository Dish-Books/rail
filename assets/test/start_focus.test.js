import assert from "node:assert/strict";
import { beforeEach, test } from "node:test";
import { calculateFocusTarget, handFocus } from "../js/hooks/start_focus.js";

let doc;
let fire;
let chip;
let chips;
let focusCalls;
// #main-content, under the 44px app bar.
const viewport = () => ({ top: 44, bottom: 1080 });
const onScreen = { top: 400, bottom: 424 };
const offScreen = { top: -1757, bottom: -1733 };

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
  // A chip, a Start or any control: what focus can land on, with where it sits.
  chip = (name, box = onScreen) => ({
    name,
    getBoundingClientRect: () => box,
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

test("a chip on screen takes focus, leaving the scroll alone", () => {
  handFocus(doc, true, "task-link-iss_1", ["issue-start-iss_2"], viewport);
  assert.deepEqual(focusCalls, [{ name: "chip", preventScroll: true }]);
});

test("a chip moved off screen leaves focus with the next Start, where the person was", () => {
  chips["task-link-iss_1"] = chip("chip", offScreen);
  chips["issue-start-iss_2"] = chip("next start");
  chips["issue-start-iss_0"] = chip("previous start");
  handFocus(doc, true, "task-link-iss_1", ["issue-start-iss_2", "issue-start-iss_0"], viewport);
  assert.deepEqual(focusCalls, [{ name: "next start", preventScroll: true }]);
});

test("a Start gone or moved off screen is passed over for the next one that can be seen", () => {
  chips["task-link-iss_1"] = chip("chip", offScreen);
  chips["issue-start-iss_3"] = chip("moved start", offScreen);
  chips["issue-start-iss_0"] = chip("previous start");
  handFocus(doc, true, "task-link-iss_1", ["issue-start-iss_2", "issue-start-iss_3", "issue-start-iss_0"], viewport);
  assert.deepEqual(focusCalls, [{ name: "previous start", preventScroll: true }]);
});

test("with no Start in sight, an off-screen chip still takes focus rather than the body", () => {
  chips["task-link-iss_1"] = chip("chip", offScreen);
  handFocus(doc, true, "task-link-iss_1", [], viewport);
  assert.deepEqual(focusCalls, [{ name: "chip", preventScroll: true }]);
});

test("a chip hidden under the app bar does not count as seen", () => {
  chips["task-link-iss_1"] = chip("chip", { top: 10, bottom: 34 });
  chips["issue-start-iss_2"] = chip("next start");
  assert.equal(calculateFocusTarget(doc, "task-link-iss_1", ["issue-start-iss_2"], viewport()).name, "next start");
});

test("focus on another control of the row waits for the patch that moves the row and drops it", () => {
  doc.activeElement = { name: "open in new" };
  chips["task-link-iss_1"] = chip("chip", offScreen);
  chips["issue-start-iss_2"] = chip("next start");
  handFocus(doc, true, "task-link-iss_1", ["issue-start-iss_2"], viewport);
  assert.deepEqual(focusCalls, []);

  doc.activeElement = doc.body;
  fire("phx:update");
  assert.deepEqual(focusCalls, [{ name: "next start", preventScroll: true }]);
});

test("calculateFocusTarget gives nothing when there is neither chip nor Start", () => {
  assert.equal(calculateFocusTarget(doc, "task-link-iss_gone", ["issue-start-iss_gone"], viewport()), null);
});

test("a later patch that moves the row and drops focus gives it back to the chip, read again by id", () => {
  handFocus(doc, true, "task-link-iss_1", ["issue-start-iss_2"], viewport);

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
  handFocus(doc, true, "task-link-iss_1", ["issue-start-iss_2"], viewport);
  fire("keydown");
  doc.activeElement = doc.body;
  fire("phx:update");
  assert.equal(focusCalls.length, 1);
});

test("a pointer press ends the watch", () => {
  handFocus(doc, true, "task-link-iss_1", ["issue-start-iss_2"], viewport);
  fire("pointerdown");
  doc.activeElement = doc.body;
  fire("phx:update");
  assert.equal(focusCalls.length, 1);
});

test("a Start the person had left keeps its hands off focus", () => {
  handFocus(doc, false, "task-link-iss_1", ["issue-start-iss_2"], viewport);
  fire("phx:update");
  assert.deepEqual(focusCalls, []);
});

test("no chip, such as leaving the page, does nothing and watches nothing", () => {
  chips["issue-start-iss_2"] = chip("next start");
  handFocus(doc, true, "task-link-iss_gone", ["issue-start-iss_2"], viewport);
  chips["task-link-iss_gone"] = chip("late chip");
  fire("phx:update");
  assert.deepEqual(focusCalls, []);
});
