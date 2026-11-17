import assert from "node:assert/strict";
import { beforeEach, test } from "node:test";
import { calculateFocusTarget, handFocus, holdsPlace, restoreFocus } from "../js/hooks/start_focus.js";

let doc;
let fire;
let chip;
let chips;
let control;
let rowOf;
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
  // A control in a row: whether the browser shows its focus ring, and whether it sits in the status picker.
  control = (name, { visible = true, picker = false } = {}) => ({
    name,
    matches: (selector) => selector === ":focus-visible" && visible,
    closest: (selector) => (picker && selector === "[id^='status-picker-']" ? { name: "status picker" } : null)
  });
  rowOf = (...members) => ({ contains: (target) => members.includes(target) });
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

test("a Start focused by a mouse click is not the person's place, on either page", () => {
  const start = control("start", { visible: false });
  assert.equal(holdsPlace(start, start, rowOf(start)), false);
  assert.equal(holdsPlace(start, start, null), false);
});

test("keyboard focus on the row's Start or link holds the place, not its status picker", () => {
  const start = control("start");
  const link = control("open in new");
  const picker = control("status", { picker: true });
  const row = rowOf(start, link, picker);
  assert.equal(holdsPlace(start, start, row), true);
  assert.equal(holdsPlace(link, start, row), true);
  assert.equal(holdsPlace(picker, start, row), false);
  assert.equal(holdsPlace(control("search"), start, row), false);
});

test("on the issue page only the button holds the place", () => {
  const start = control("start");
  assert.equal(holdsPlace(start, start, null), true);
  assert.equal(holdsPlace(control("title"), start, null), false);
});

test("nothing focused holds no place", () => {
  assert.equal(holdsPlace(null, control("start"), null), false);
});

test("a patch that drops focus to the body gives it back to the control the person was on", () => {
  const start = chip("start");
  start.isConnected = true;
  const link = chip("open in new");
  link.isConnected = true;
  restoreFocus(doc, true, link, start);
  assert.deepEqual(focusCalls, [{ name: "open in new", preventScroll: true }]);
});

test("a control the patch rebuilt gives focus to the row's Start instead", () => {
  const start = chip("start");
  start.isConnected = true;
  const link = chip("open in new");
  link.isConnected = false;
  restoreFocus(doc, true, link, start);
  assert.deepEqual(focusCalls, [{ name: "start", preventScroll: true }]);
});

test("a Start already removed leaves focus to handFocus, even with its link still in the page", () => {
  const start = chip("start");
  start.isConnected = false;
  const link = chip("open in new");
  link.isConnected = true;
  restoreFocus(doc, true, link, start);
  assert.deepEqual(focusCalls, []);
});

// A guard beside the two tests above: it fails if restoreFocus stops checking where focus is or whose row it was.
test("focus still on something, or a row the person left, is not touched", () => {
  const start = chip("start");
  start.isConnected = true;
  const link = chip("open in new");
  link.isConnected = true;
  doc.activeElement = { name: "search" };
  restoreFocus(doc, true, link, start);
  doc.activeElement = doc.body;
  restoreFocus(doc, false, link, start);
  assert.deepEqual(focusCalls, []);
});
