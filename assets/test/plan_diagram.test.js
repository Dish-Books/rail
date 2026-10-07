import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { cornerOf, findNodes, outline } from "../js/hooks/plan_diagram.js";

function svg(flowchart, participants) {
  return {
    querySelectorAll: (selector) => (selector === "g.node" ? flowchart : participants)
  };
}

function participant(id) {
  return { getAttribute: (name) => (name === "data-id" ? id : null) };
}

describe("findNodes", () => {
  it("finds a flowchart node by the id Mermaid gives its g, and only when its id is in the list", () => {
    const changed = { id: "plan-diagram-change-1-svg-flowchart-PS-0" };
    const longer = { id: "plan-diagram-change-1-svg-flowchart-PS-2-4" };
    const unlisted = { id: "plan-diagram-change-1-svg-flowchart-DB-3" };
    const other = { id: "other-svg-flowchart-PS-0" };

    const found = findNodes(svg([other, changed, longer, unlisted], []), "plan-diagram-change-1-svg", ["PS", "PS-2"]);

    assert.equal(found.get("PS"), changed);
    assert.equal(found.get("PS-2"), longer);
    assert.equal(found.has("DB"), false);
  });

  it("finds a sequence diagram's participant by its data-id, and only when its id is in the list", () => {
    const person = participant("U");
    const found = findNodes(svg([], [person, participant("PS")]), "plan-diagram-call_flow-1-svg", ["U"]);

    assert.equal(found.get("U"), person);
    assert.equal(found.has("PS"), false);
  });
});

describe("cornerOf", () => {
  it("puts the + over the node's top right corner, in the layer's coordinates", () => {
    assert.deepEqual(cornerOf({ right: 420.4, top: 140.2 }, { left: 100, top: 60 }), { left: 308, top: 72 });
  });
});

describe("outline", () => {
  it("outlines a commented node's shape amber, and takes it off again", () => {
    const shape = { style: {} };
    const node = { querySelector: () => shape };

    outline(node, true);
    assert.deepEqual(shape.style, { stroke: "#f59e0b", strokeWidth: "2px" });

    outline(node, false);
    assert.deepEqual(shape.style, { stroke: "", strokeWidth: "" });
  });

  it("leaves a node with no shape alone", () => {
    assert.doesNotThrow(() => outline({ querySelector: () => null }, true));
  });
});
