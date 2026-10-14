import assert from "node:assert/strict";
import { afterEach, describe, it } from "node:test";
import { draftStore } from "../js/hooks/chat_composer.js";

const memory = () => {
  const items = new Map();
  return {
    getItem: (key) => (items.has(key) ? items.get(key) : null),
    setItem: (key, value) => items.set(key, value),
    removeItem: (key) => items.delete(key)
  };
};

describe("draftStore", () => {
  afterEach(() => {
    delete globalThis.window;
  });

  it("keeps what was typed under its key, and forgets it once the box is empty", () => {
    globalThis.window = { localStorage: memory() };

    draftStore.write("rail:draft:run_1", "Rename the filter");
    assert.equal(draftStore.read("rail:draft:run_1"), "Rename the filter");
    assert.equal(draftStore.read("rail:draft:run_2"), "");

    draftStore.write("rail:draft:run_1", "  ");
    assert.equal(draftStore.read("rail:draft:run_1"), "");
  });

  it("reads nothing and keeps nothing where the browser refuses storage", () => {
    globalThis.window = {
      get localStorage() {
        throw new Error("SecurityError");
      }
    };

    assert.equal(draftStore.read("rail:draft:run_1"), "");
    assert.doesNotThrow(() => draftStore.write("rail:draft:run_1", "Lost"));
  });
});
