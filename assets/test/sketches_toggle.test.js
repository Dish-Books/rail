import assert from "node:assert/strict";
import { beforeEach, test } from "node:test";
import { toggleSketches } from "../js/hooks/sketches_toggle.js";

let doc;
let button;
let sketches;
let groups;

beforeEach(() => {
  // The second sketch is open already, as one opened by hand or holding the reader's comment is.
  sketches = [{ open: false }, { open: true }, { open: false }];
  // The reader folded the first group.
  groups = [{ open: false }, { open: true }];
  const cards = {
    querySelectorAll: (selector) =>
      ({ "[data-qa=plan_card_sketch]": sketches, "[data-qa=plan_group]": groups })[selector]
  };
  doc = { getElementById: (id) => (id === "plan-changes" ? cards : null) };
  const attributes = { "aria-expanded": "false", "aria-controls": "plan-changes" };
  button = {
    getAttribute: (name) => attributes[name],
    setAttribute: (name, value) => {
      attributes[name] = value;
    }
  };
});

test("a click on a collapsed link opens every sketch and every folded group, and marks the link expanded", () => {
  toggleSketches(button, doc);

  assert.deepEqual(sketches, [{ open: true }, { open: true }, { open: true }]);
  assert.deepEqual(groups, [{ open: true }, { open: true }]);
  assert.equal(button.getAttribute("aria-expanded"), "true");
});

test("a click on an expanded link closes every sketch, one open before it included, and leaves the groups open", () => {
  toggleSketches(button, doc);
  sketches[2].open = false;
  groups[1].open = false;

  toggleSketches(button, doc);

  assert.deepEqual(sketches, [{ open: false }, { open: false }, { open: false }]);
  assert.deepEqual(groups, [{ open: true }, { open: false }]);
  assert.equal(button.getAttribute("aria-expanded"), "false");
});

test("the link reads its last click, not the sketches, so closing them by hand leaves the next click closing", () => {
  toggleSketches(button, doc);
  for (const sketch of sketches) sketch.open = false;

  toggleSketches(button, doc);

  assert.deepEqual(sketches, [{ open: false }, { open: false }, { open: false }]);
  assert.equal(button.getAttribute("aria-expanded"), "false");
});
