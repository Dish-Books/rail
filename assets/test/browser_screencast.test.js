import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { modifiers, pagePoint, wheelBatcher } from "../js/hooks/browser_screencast.js";

describe("pagePoint", () => {
  it("maps a click on the frame to the matching point on the 1920 by 1080 page", () => {
    const rect = { left: 100, top: 50, width: 960, height: 540 };

    assert.deepEqual(pagePoint(rect, 100, 50), { x: 0, y: 0 });
    assert.deepEqual(pagePoint(rect, 580, 320), { x: 960, y: 540 });
    assert.deepEqual(pagePoint(rect, 1060, 590), { x: 1920, y: 1080 });
  });

  it("allows for the bars object-contain adds, and keeps a point on them on the page's edge", () => {
    // Twice as tall as 16:9, so the picture sits in the middle with 270px above and below it.
    const rect = { left: 0, top: 0, width: 960, height: 1080 };

    assert.deepEqual(pagePoint(rect, 480, 540), { x: 960, y: 540 });
    assert.deepEqual(pagePoint(rect, 0, 270), { x: 0, y: 0 });
    assert.deepEqual(pagePoint(rect, 480, 10), { x: 960, y: 0 });
  });
});

describe("modifiers", () => {
  it("sets DevTools' bits for each key held", () => {
    assert.equal(modifiers({}), 0);
    assert.equal(modifiers({ ctrlKey: true }), 2);
    assert.equal(modifiers({ altKey: true, metaKey: true, shiftKey: true }), 13);
  });
});

describe("wheelBatcher", () => {
  it("sums the deltas of one animation frame into one event at the last point", () => {
    const pushed = [];
    const frames = [];
    const wheel = wheelBatcher((event) => pushed.push(event), (callback) => frames.push(callback));

    wheel(0, 40, { x: 10, y: 20 });
    wheel(5, 60, { x: 12, y: 22 });
    wheel(0, -20, { x: 14, y: 24 });

    assert.equal(frames.length, 1);
    assert.deepEqual(pushed, []);

    frames[0]();
    assert.deepEqual(pushed, [{ type: "wheel", x: 14, y: 24, dx: 5, dy: 80 }]);

    wheel(0, 10, { x: 1, y: 1 });
    frames[1]();
    assert.deepEqual(pushed[1], { type: "wheel", x: 1, y: 1, dx: 0, dy: 10 });
  });
});
