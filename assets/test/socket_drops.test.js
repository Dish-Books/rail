import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { calculateDrop, describeDrop, recordDrops } from "../js/socket_drops.js";

const state = {
  openedAt: 10_000,
  receivedAt: 100_000,
  sentAt: 95_000,
  visible: true,
  visibilityAt: 4_000,
  online: true
};

describe("calculateDrop", () => {
  it("keeps the connection's times as they were when it dropped", () => {
    const drop = calculateDrop(state, null, { how: "closed", code: 1006, clean: false }, 101_000);

    assert.equal(
      describeDrop(drop, 103_000),
      "how=closed code=1006 clean=false ago=2 open=91 quiet=1 sent=6 visible=true seen=97 online=true drops=1"
    );
  });

  it("takes the close a heartbeat timeout makes as the same drop, with its code", () => {
    const timedOut = calculateDrop(state, null, { how: "heartbeat_timeout" }, 101_000);
    const closed = calculateDrop(state, timedOut, { how: "closed", code: 1000, clean: true }, 101_050);

    assert.equal(closed.how, "heartbeat_timeout");
    assert.equal(closed.code, 1000);
    assert.equal(closed.count, 1);
  });

  it("takes an error and the close after it as one closed drop", () => {
    const failed = calculateDrop(state, null, { how: "error" }, 101_000);
    const closed = calculateDrop(state, failed, { how: "closed", code: 1006, clean: false }, 101_010);

    assert.equal(describeDrop(closed, 101_010).split(" ").slice(0, 3).join(" "), "how=closed code=1006 clean=false");
    assert.equal(closed.count, 1);
  });

  it("counts a drop on a connection opened since as another one, however soon", () => {
    const first = calculateDrop(state, null, { how: "closed", code: 1006, clean: false }, 101_000);
    const second = calculateDrop({ ...state, openedAt: 102_000 }, first, { how: "heartbeat_timeout" }, 103_000);

    assert.equal(second.how, "heartbeat_timeout");
    assert.equal(second.code, undefined);
    assert.equal(second.count, 2);
  });

  it("counts a later drop as another one", () => {
    const first = calculateDrop(state, null, { how: "error" }, 101_000);
    const second = calculateDrop(state, first, { how: "closed", code: 1006, clean: false }, 200_000);

    assert.equal(second.count, 2);
    assert.equal(second.at, 200_000);
  });

  it("says nothing was sent when nothing was", () => {
    const drop = calculateDrop({ ...state, sentAt: null }, null, { how: "error" }, 101_000);

    assert.match(describeDrop(drop, 101_000), /^how=error ago=0 open=91 quiet=1 sent=- /);
  });
});

describe("recordDrops", () => {
  it("sends nothing until the connection drops, then the drop with every connect after it", () => {
    let now = 1_000;
    const listeners = {};
    const win = {
      navigator: { onLine: true },
      document: {
        visibilityState: "visible",
        addEventListener: (name, listener) => {
          listeners[name] = listener;
        }
      }
    };
    const socket = {};
    for (const name of ["onOpen", "onMessage", "onClose", "onError"]) {
      socket[name] = (callback) => {
        listeners[name] = callback;
      };
    }

    const drops = recordDrops(win, () => now);
    drops.watch(socket);
    assert.deepEqual(drops.params(), {});

    now = 2_000;
    listeners.onOpen();
    now = 31_000;
    drops.logger("push", "phoenix heartbeat (null, 3)");
    win.document.visibilityState = "hidden";
    listeners.visibilitychange();
    now = 61_000;
    drops.logger("transport", "heartbeat timeout. Attempting to re-establish connection");
    listeners.onClose({ code: 1000, wasClean: true });

    assert.deepEqual(drops.params(), {
      _drop: "how=heartbeat_timeout code=1000 clean=true ago=0 open=59 quiet=59 sent=30 visible=false seen=30 online=true drops=1"
    });
  });
});
