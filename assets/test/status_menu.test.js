import assert from "node:assert/strict";
import { test } from "node:test";
import { calculateMenuPosition } from "../js/hooks/status_menu.js";

const viewport = { width: 1280, height: 800 };
const menu = { width: 240, height: 266 };
const trigger = (top, left = 300) => ({ top, bottom: top + 24, left });

test("opens below its trigger, lined up with its left edge", () => {
  assert.deepEqual(calculateMenuPosition(trigger(100), menu, viewport), { top: 128, left: 300 });
});

test("opens upward at the foot of the viewport", () => {
  assert.deepEqual(calculateMenuPosition(trigger(760), menu, viewport), { top: 490, left: 300 });
});

test("stays below when it only just fits", () => {
  const top = viewport.height - 8 - menu.height - 24 - 4;
  assert.equal(calculateMenuPosition(trigger(top), menu, viewport).top, top + 28);
});

test("keeps to the side with more room and inside the viewport when neither side fits", () => {
  const tall = { width: 240, height: 500 };
  const short = { width: 1024, height: 400 };

  assert.equal(calculateMenuPosition(trigger(100), tall, short).top, 8);
  assert.equal(calculateMenuPosition(trigger(300), tall, short).top, 8);
});

test("moves left rather than run off the right edge", () => {
  assert.equal(calculateMenuPosition(trigger(100, 1200), menu, viewport).left, 1032);
});

test("never starts past the left edge", () => {
  assert.equal(calculateMenuPosition(trigger(100, 2), menu, viewport).left, 8);
});
