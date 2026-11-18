import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { readOpen, writeOpen } from "../js/hooks/todos_open.js";

const memoryStorage = () => {
  const entries = new Map();
  return {
    entries,
    getItem: (key) => (entries.has(key) ? entries.get(key) : null),
    setItem: (key, value) => entries.set(key, value),
    removeItem: (key) => entries.delete(key)
  };
};

describe("readOpen and writeOpen", () => {
  it("reads the panel open once it was written open", () => {
    const storage = memoryStorage();
    writeOpen(storage, true);
    assert.equal(readOpen(storage), true);
  });

  it("removes the entry when the panel is closed, so a read gives false", () => {
    const storage = memoryStorage();
    writeOpen(storage, true);
    writeOpen(storage, false);
    assert.equal(storage.entries.size, 0);
    assert.equal(readOpen(storage), false);
  });

  it("reads a browser that never opened the panel as closed", () => {
    assert.equal(readOpen(memoryStorage()), false);
  });
});
