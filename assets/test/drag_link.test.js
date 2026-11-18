import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { dragData, listenForDragLinks } from "../js/drag_link.js";

describe("dragData", () => {
  it("makes a row's path a full address, with its name as the text", () => {
    assert.deepEqual(dragData("https://rail.example.com", "/issues/iss_1", "RAIL-1 Fix the thing"), [
      ["text/uri-list", "https://rail.example.com/issues/iss_1"],
      ["text/plain", "RAIL-1 Fix the thing"]
    ]);
  });

  it("names a row with no text by its address", () => {
    assert.deepEqual(dragData("https://rail.example.com", "/tasks/tsk_1?item=findings&finding=F3", ""), [
      ["text/uri-list", "https://rail.example.com/tasks/tsk_1?item=findings&finding=F3"],
      ["text/plain", "https://rail.example.com/tasks/tsk_1?item=findings&finding=F3"]
    ]);
  });
});

describe("listenForDragLinks", () => {
  const listen = () => {
    let listener;
    listenForDragLinks({ addEventListener: (_type, fn) => (listener = fn) }, "https://rail.example.com");
    return listener;
  };

  const dragEvent = (row) => {
    const data = new Map();
    return {
      data,
      target: { closest: () => row },
      dataTransfer: { setData: (type, value) => data.set(type, value), effectAllowed: "all" }
    };
  };

  it("hands a drag from a marked row a link to its address", () => {
    const event = dragEvent({ dataset: { dragHref: "/issues/iss_1", dragText: "RAIL-1 Fix" } });
    listen()(event);
    assert.equal(event.data.get("text/uri-list"), "https://rail.example.com/issues/iss_1");
    assert.equal(event.data.get("text/plain"), "RAIL-1 Fix");
    assert.equal(event.dataTransfer.effectAllowed, "link");
  });

  it("sets nothing on a drag that starts outside any marked row", () => {
    const event = dragEvent(null);
    listen()(event);
    assert.equal(event.data.size, 0);
    assert.equal(event.dataTransfer.effectAllowed, "all");
  });
});
