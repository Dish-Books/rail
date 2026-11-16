import assert from "node:assert/strict";
import { describe, it } from "node:test";
import {
  calculateReopenCommand,
  calculateTargetSelector,
  KEPT_MS,
  readReopen,
  takeKept
} from "../js/hooks/comment_box.js";

describe("calculateReopenCommand", () => {
  it("pushes the box's event and values to the component it was wired to", () => {
    const command = calculateReopenCommand(
      { event: "open_diff_comment", value: { path: "lib/a.ex", kind: "added", old_line: "4", new_line: "4" } },
      '[id="diff-view"]'
    );

    assert.deepEqual(JSON.parse(command), [
      [
        "push",
        {
          event: "open_diff_comment",
          value: { path: "lib/a.ex", kind: "added", old_line: "4", new_line: "4" },
          target: '[id="diff-view"]'
        }
      ]
    ]);
  });

  it("pushes to the page itself when the box was wired to no component", () => {
    const command = calculateReopenCommand({ event: "edit", value: {} }, null);

    assert.deepEqual(JSON.parse(command), [["push", { event: "edit", value: {} }]]);
  });
});

describe("calculateTargetSelector", () => {
  const doc = {
    querySelector: (selector) =>
      ({
        '[data-phx-component="3"]': { id: "plan-stage" },
        '[data-phx-component="4"]': { id: "" }
      })[selector] ?? null
  };

  it("names a component by its root's id, which outlives the number a reconnect can change", () => {
    assert.equal(calculateTargetSelector("3", doc), '[id="plan-stage"]');
  });

  it("keeps a selector as it is, and takes no target as the page", () => {
    assert.equal(calculateTargetSelector("#comment-7", doc), "#comment-7");
    assert.equal(calculateTargetSelector(null, doc), null);
  });

  it("finds no target for a component it cannot name again", () => {
    assert.equal(calculateTargetSelector("4", doc), undefined);
    assert.equal(calculateTargetSelector("9", doc), undefined);
  });
});

describe("readReopen", () => {
  it("reads the event and its values, with none taken as empty", () => {
    assert.deepEqual(readReopen('{"event":"open_document_comment","value":{"doc":"plan","key":"p-3"}}'), {
      event: "open_document_comment",
      value: { doc: "plan", key: "p-3" }
    });
    assert.deepEqual(readReopen('{"event":"edit","value":null}'), { event: "edit", value: {} });
  });

  it("reads nothing from a box with no reopen, or one it cannot read", () => {
    assert.equal(readReopen(undefined), null);
    assert.equal(readReopen("{not json"), null);
    assert.equal(readReopen('{"value":{}}'), null);
  });
});

describe("takeKept", () => {
  it("gives the box that opens again its text once", () => {
    const kept = new Map([["diff-comment-form-a", { body: "Half a thought", at: 1000 }]]);

    assert.equal(takeKept(kept, "diff-comment-form-a", 2000), "Half a thought");
    assert.equal(takeKept(kept, "diff-comment-form-a", 2000), null);
  });

  it("drops a box no component opened again in time", () => {
    const kept = new Map([
      ["stale", { body: "Gone", at: 1000 }],
      ["fresh", { body: "Kept", at: 1000 + KEPT_MS }]
    ]);

    assert.equal(takeKept(kept, "other", 1001 + KEPT_MS), null);
    assert.deepEqual([...kept.keys()], ["fresh"]);
  });
});
