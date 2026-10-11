import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { atEnd, CommandOutput, scrollTopFor } from "../js/hooks/command_output.js";

describe("atEnd", () => {
  it("is true at the bottom and within a few pixels of it", () => {
    assert.equal(atEnd({ scrollHeight: 1000, scrollTop: 616, clientHeight: 384 }), true);
    assert.equal(atEnd({ scrollHeight: 1000, scrollTop: 612.5, clientHeight: 384 }), true);
  });

  it("is false once the reader has scrolled further up", () => {
    assert.equal(atEnd({ scrollHeight: 1000, scrollTop: 500, clientHeight: 384 }), false);
  });
});

describe("scrollTopFor", () => {
  it("gives the end while following, so the newest line is in view", () => {
    assert.equal(scrollTopFor({ scrollHeight: 1200 }, true, 300), 1200);
  });

  it("gives the reader's own offset once they have scrolled up", () => {
    assert.equal(scrollTopFor({ scrollHeight: 1200 }, false, 300), 300);
  });
});

describe("CommandOutput", () => {
  it("opens at the end, keeps a scrolled-up reader's place, and follows again at the bottom", () => {
    const listeners = {};
    const touched = [];
    const el = {
      scrollHeight: 1000,
      clientHeight: 384,
      scrollTop: 0,
      addEventListener: (type, listener) => {
        listeners[type] = listener;
      },
      removeEventListener: (type) => {
        delete listeners[type];
      },
      scrollIntoView: () => touched.push("scrollIntoView"),
      focus: () => touched.push("focus")
    };
    const hook = { el };

    CommandOutput.mounted.call(hook);
    assert.equal(el.scrollTop, 1000);

    el.scrollHeight = 1100;
    CommandOutput.updated.call(hook);
    assert.equal(el.scrollTop, 1100);

    el.scrollTop = 200;
    listeners.scroll();
    el.scrollHeight = 1300;
    CommandOutput.updated.call(hook);
    assert.equal(el.scrollTop, 200);

    el.scrollTop = 1300 - 384;
    listeners.scroll();
    el.scrollHeight = 1400;
    CommandOutput.updated.call(hook);
    assert.equal(el.scrollTop, 1400);

    // Moving the block's own box must not move the conversation around it.
    assert.deepEqual(touched, []);

    CommandOutput.destroyed.call(hook);
    assert.equal(listeners.scroll, undefined);
  });
});
