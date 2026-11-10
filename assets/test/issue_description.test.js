import assert from "node:assert/strict";
import { describe, it } from "node:test";
import {
  calculateReplace,
  calculateRestore,
  calculateSaveState,
  imageFiles
} from "../js/hooks/issue_description.js";

const settled = { baseline: "Saved", text: "Saved", seq: 0, inFlight: null, failed: false };

const run = (state, events) =>
  events.reduce(
    ({ state: current, outputs }, event) => {
      const output = calculateSaveState(current, event);
      return { state: output.state, outputs: [...outputs, output] };
    },
    { state, outputs: [] }
  );

describe("calculateSaveState", () => {
  it("keeps every edit in the browser and pushes it numbered on save", () => {
    const { state, outputs } = run(settled, [{ type: "edit", text: "Typed" }, { type: "save" }]);

    assert.equal(outputs[0].draft, "write");
    assert.deepEqual(outputs[1].push, { seq: 1, text: "Typed" });
    assert.equal(outputs[1].draft, "write");
    assert.equal(state.inFlight, 1);
  });

  it("saves nothing when nothing changed, so clicking in and out sends nothing", () => {
    assert.equal(calculateSaveState(settled, { type: "save" }).push, undefined);
  });

  it("clears the stored copy and the notice once exactly that text is confirmed", () => {
    const { state, outputs } = run(settled, [
      { type: "edit", text: "Typed" },
      { type: "save" },
      { type: "ok", seq: 1, text: "Typed" }
    ]);

    assert.deepEqual(
      { notice: outputs[2].notice, draft: outputs[2].draft, retry: outputs[2].retry },
      { notice: "hide", draft: "clear", retry: "stop" }
    );
    assert.equal(state.baseline, "Typed");
  });

  it("keeps the stored copy when the text moved on while the save was out", () => {
    const { state, outputs } = run(settled, [
      { type: "edit", text: "Typed" },
      { type: "save" },
      { type: "edit", text: "Typed more" },
      { type: "ok", seq: 1, text: "Typed" }
    ]);

    assert.equal(outputs[3].draft, "write");
    assert.equal(outputs[3].notice, undefined);
    assert.equal(state.text, "Typed more");
  });

  it("shows no notice for a timeout of an older save after a newer one was confirmed", () => {
    const { outputs } = run(settled, [
      { type: "edit", text: "First" },
      { type: "save" },
      { type: "edit", text: "Second" },
      { type: "save" },
      { type: "ok", seq: 2, text: "Second" },
      { type: "timeout", seq: 1 }
    ]);

    assert.equal(outputs[5].notice, undefined);
    assert.equal(outputs[5].draft, undefined);
  });

  it("ignores a reply to a save a newer one replaced", () => {
    const { state, outputs } = run(settled, [
      { type: "edit", text: "First" },
      { type: "save" },
      { type: "edit", text: "Second" },
      { type: "save" },
      { type: "ok", seq: 1, text: "First" }
    ]);

    assert.equal(outputs[4].draft, undefined);
    assert.equal(state.baseline, "Saved");
    assert.equal(state.inFlight, 2);
  });

  it("shows the notice for a refused save, keeps the stored copy and starts retrying", () => {
    const { state, outputs } = run(settled, [
      { type: "edit", text: "Typed" },
      { type: "save" },
      { type: "refused", seq: 1 }
    ]);

    assert.deepEqual(
      { notice: outputs[2].notice, draft: outputs[2].draft, retry: outputs[2].retry },
      { notice: "show", draft: "write", retry: "start" }
    );
    assert.equal(state.failed, true);
  });

  it("shows the notice for a save with no reply in time", () => {
    const { outputs } = run(settled, [{ type: "edit", text: "Typed" }, { type: "save" }, { type: "timeout", seq: 1 }]);
    assert.equal(outputs[2].notice, "show");
  });

  it("shows the notice on a disconnect only while text is unsaved, and saves again on reconnect", () => {
    assert.equal(calculateSaveState(settled, { type: "disconnected" }).notice, undefined);

    const { state, outputs } = run(settled, [
      { type: "edit", text: "Typed" },
      { type: "disconnected" },
      { type: "reconnected" }
    ]);

    assert.equal(outputs[1].notice, "show");
    assert.equal(outputs[1].retry, "start");
    assert.deepEqual(outputs[2].push, { seq: 1, text: "Typed" });
    assert.equal(state.failed, true);
  });

  it("keeps the notice up until a save after a failure is confirmed", () => {
    const { outputs } = run(settled, [
      { type: "edit", text: "Typed" },
      { type: "save" },
      { type: "refused", seq: 1 },
      { type: "save" },
      { type: "ok", seq: 2, text: "Typed" }
    ]);

    assert.equal(outputs[3].draft, "write");
    assert.deepEqual(
      { notice: outputs[4].notice, draft: outputs[4].draft, retry: outputs[4].retry },
      { notice: "hide", draft: "clear", retry: "stop" }
    );
  });

  it("hides the notice and clears the stored copy when an undo brings the saved text back", () => {
    const { state, outputs } = run(settled, [
      { type: "edit", text: "Typed" },
      { type: "save" },
      { type: "refused", seq: 1 },
      { type: "edit", text: "Saved" }
    ]);

    assert.deepEqual(
      { notice: outputs[3].notice, draft: outputs[3].draft, retry: outputs[3].retry },
      { notice: "hide", draft: "clear", retry: "stop" }
    );
    assert.equal(state.failed, false);
  });

  it("keeps an emptied description as an edit to store and save", () => {
    const { outputs } = run(settled, [{ type: "edit", text: "" }, { type: "save" }]);

    assert.equal(outputs[0].draft, "write");
    assert.deepEqual(outputs[1].push, { seq: 1, text: "" });
  });

  it("changes nothing for an event it does not know", () => {
    assert.deepEqual(calculateSaveState(settled, { type: "unknown" }), { state: settled });
  });
});

describe("calculateRestore", () => {
  it("loads a stored copy only when it differs from the saved markdown", () => {
    assert.equal(calculateRestore("Typed offline", "Saved"), "load");
    assert.equal(calculateRestore("", "Saved"), "load");
  });

  it("clears a stored copy that matches any form of the saved markdown", () => {
    assert.equal(calculateRestore("Saved", "Saved"), "clear");
    assert.equal(calculateRestore("- item", ["* item", "- item"]), "clear");
  });

  it("does nothing without a stored copy", () => {
    assert.equal(calculateRestore(null, "Saved"), "none");
  });
});

describe("calculateReplace", () => {
  const idle = { focused: false, dirty: false, pending: false, unsaved: false, baseline: "Saved", incoming: "Theirs" };

  it("takes a new saved text at once while nobody is typing here", () => {
    assert.equal(calculateReplace(idle), "now");
  });

  it("keeps the text while focused, dirty, uploading or holding an unsaved copy", () => {
    assert.equal(calculateReplace({ ...idle, focused: true }), "later");
    assert.equal(calculateReplace({ ...idle, dirty: true }), "later");
    assert.equal(calculateReplace({ ...idle, pending: true }), "later");
    assert.equal(calculateReplace({ ...idle, unsaved: true }), "later");
  });

  it("changes nothing when the saved text is what the editor already holds", () => {
    assert.equal(calculateReplace({ ...idle, focused: true, incoming: "Saved" }), "none");
  });
});

describe("imageFiles", () => {
  it("keeps only PNG, JPEG, GIF and WebP files", () => {
    const files = ["image/png", "image/jpeg", "image/gif", "image/webp", "image/svg+xml", "text/html", ""].map(
      (type) => ({ name: `file-${type}`, type })
    );

    assert.deepEqual(
      imageFiles(files).map((file) => file.type),
      ["image/png", "image/jpeg", "image/gif", "image/webp"]
    );
  });

  it("finds nothing in a missing list", () => {
    assert.deepEqual(imageFiles(undefined), []);
  });
});
