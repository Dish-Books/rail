import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { calculateNextItem } from "../js/hooks/menu_keys.js";

describe("calculateNextItem", () => {
  it("moves down and up one item", () => {
    assert.equal(calculateNextItem(0, 4, "ArrowDown"), 1);
    assert.equal(calculateNextItem(2, 4, "ArrowUp"), 1);
  });

  it("wraps from the last item to the first and from the first to the last", () => {
    assert.equal(calculateNextItem(3, 4, "ArrowDown"), 0);
    assert.equal(calculateNextItem(0, 4, "ArrowUp"), 3);
  });

  it("starts at the first item when focus is on none of them", () => {
    assert.equal(calculateNextItem(-1, 4, "ArrowDown"), 0);
  });

  it("leaves every other key alone, and an empty menu", () => {
    for (const key of ["Enter", " ", "Escape", "Tab"]) assert.equal(calculateNextItem(1, 4, key), null);
    assert.equal(calculateNextItem(-1, 0, "ArrowDown"), null);
  });
});
