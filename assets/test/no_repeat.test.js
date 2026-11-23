import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { blockRepeatClicks } from "../js/no_repeat.js";

describe("blockRepeatClicks", () => {
  const listen = () => {
    let listener;
    let capture;
    blockRepeatClicks({
      addEventListener: (_type, fn, useCapture) => {
        listener = fn;
        capture = useCapture;
      }
    });
    return { listener, capture };
  };

  const clickOn = (button) => {
    const event = { stopped: false, prevented: false };
    event.target = { closest: (selector) => (button && selector === "button[data-no-repeat]" ? button : null) };
    event.stopPropagation = () => (event.stopped = true);
    event.preventDefault = () => (event.prevented = true);
    return event;
  };

  const button = (...classes) => ({ classList: { contains: (name) => classes.includes(name) } });

  it("listens on the way down, ahead of LiveView", () => {
    assert.equal(listen().capture, true);
  });

  it("stops a click on a marked button still waiting on its last one", () => {
    const event = clickOn(button("phx-click-loading"));
    listen().listener(event);
    assert.equal(event.stopped, true);
    assert.equal(event.prevented, true);
  });

  it("lets the first click on a marked button through", () => {
    const event = clickOn(button());
    listen().listener(event);
    assert.equal(event.stopped, false);
    assert.equal(event.prevented, false);
  });

  it("leaves clicks outside any marked button alone", () => {
    const event = clickOn(null);
    listen().listener(event);
    assert.equal(event.stopped, false);
  });
});
