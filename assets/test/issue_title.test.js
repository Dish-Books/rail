import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { calculateTitleChange } from "../js/hooks/issue_title.js";

describe("calculateTitleChange", () => {
  it("sends nothing for an emptied title, so the saved one goes back", () => {
    assert.equal(calculateTitleChange("", "Kept here"), null);
    assert.equal(calculateTitleChange("   \n ", "Kept here"), null);
  });

  it("sends nothing for an unchanged title", () => {
    assert.equal(calculateTitleChange("Kept here", "Kept here"), null);
    assert.equal(calculateTitleChange("  Kept here ", "Kept here"), null);
  });

  it("sends a changed title trimmed, on one line", () => {
    assert.equal(calculateTitleChange("  Renamed  ", "Kept here"), "Renamed");
    assert.equal(calculateTitleChange("Two\nlines", "Kept here"), "Two lines");
  });
});
