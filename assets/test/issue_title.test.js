import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { calculateTitleChange, calculateTitleState } from "../js/hooks/issue_title.js";

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

describe("calculateTitleState", () => {
  const confirmed = { saved: "Kept here", pending: null };

  it("sends a rename and shows it, and sends it again on reconnect when its push never resolved", () => {
    const committed = calculateTitleState(confirmed, { type: "commit", typed: true, text: "Renamed offline" });
    assert.deepEqual(committed, {
      state: { saved: "Kept here", pending: "Renamed offline" },
      push: "Renamed offline",
      text: "Renamed offline"
    });

    const reconnected = calculateTitleState(committed.state, { type: "reconnected" });
    assert.deepEqual(reconnected, { state: committed.state, push: "Renamed offline" });
  });

  it("sends nothing on reconnect with nothing waiting", () => {
    assert.deepEqual(calculateTitleState(confirmed, { type: "reconnected" }), { state: confirmed, push: undefined });
  });

  it("stops waiting once the push of that title resolves, and not for an older one", () => {
    const waiting = { saved: "Kept here", pending: "Second" };
    assert.deepEqual(calculateTitleState(waiting, { type: "pushed", title: "Second" }).state, {
      saved: "Kept here",
      pending: null
    });
    assert.deepEqual(calculateTitleState(waiting, { type: "pushed", title: "First" }).state, waiting);
  });

  it("stops waiting when Rail saves that title, and shows it only while the heading has no focus", () => {
    const waiting = { saved: "Kept here", pending: "Renamed" };
    assert.deepEqual(calculateTitleState(waiting, { type: "saved", saved: "Renamed", focused: false }), {
      state: { saved: "Renamed", pending: null },
      text: "Renamed"
    });
    assert.equal(calculateTitleState(confirmed, { type: "saved", saved: "Theirs", focused: true }).text, undefined);
  });

  it("keeps a waiting title on screen when another tab saves a different one", () => {
    const waiting = { saved: "Kept here", pending: "Mine" };
    assert.deepEqual(calculateTitleState(waiting, { type: "saved", saved: "Theirs", focused: false }), {
      state: { saved: "Theirs", pending: "Mine" },
      text: undefined
    });
  });

  it("puts back the waiting title, or else the saved one, for Esc or an emptied title, and sends nothing", () => {
    const waiting = { saved: "Kept here", pending: "Renamed" };
    assert.deepEqual(calculateTitleState(waiting, { type: "commit", typed: false, text: "Half typed" }), {
      state: waiting,
      text: "Renamed"
    });
    assert.deepEqual(calculateTitleState(confirmed, { type: "commit", typed: true, text: "  " }), {
      state: confirmed,
      text: "Kept here"
    });
  });

  it("sends a title typed again while one waits, measured against the waiting one", () => {
    const waiting = { saved: "Kept here", pending: "Renamed" };
    assert.equal(calculateTitleState(waiting, { type: "commit", typed: true, text: "Renamed" }).push, undefined);
    assert.equal(calculateTitleState(waiting, { type: "commit", typed: true, text: "Renamed again" }).push, "Renamed again");
  });

  it("changes nothing for an event it does not know", () => {
    assert.deepEqual(calculateTitleState(confirmed, { type: "unknown" }), { state: confirmed });
  });
});
