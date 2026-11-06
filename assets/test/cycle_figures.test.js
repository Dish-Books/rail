import assert from "node:assert/strict";
import { afterEach, beforeEach, describe, it } from "node:test";
import { CycleFigures, stepDay } from "../js/hooks/cycle_figures.js";

const panel = () => {
  const attributes = new Set();
  const field = (name, today) => ({ dataset: { field: name, today }, textContent: today });
  const marker = (index) => {
    const hidden = new Set(["hidden"]);
    return {
      dataset: { marker: String(index) },
      hidden,
      classList: { toggle: (name, on) => (on ? hidden.add(name) : hidden.delete(name)) }
    };
  };
  const days = [
    { dataset: { date: "Mon Oct 26 · day 1 of 28", scope: "324", scopeChange: "+0%" } },
    { dataset: { date: "Tue Oct 27 · day 2 of 28", scope: "338", scopeChange: "+4%" } }
  ];
  const fields = [field("date", "Oct 26 – Nov 22"), field("scope", "369"), field("scopeChange", "+14%")];
  const markers = [marker(0), marker(1)];
  const listeners = {};

  return {
    dataset: { cycle: "cyc_14" },
    attributes,
    days,
    fields,
    listeners,
    markers,
    addEventListener: (name, listener) => {
      listeners[name] = listener;
    },
    contains: (node) => node?.inside === true,
    toggleAttribute: (name, on) => (on ? attributes.add(name) : attributes.delete(name)),
    querySelector: (selector) => days[Number(selector.match(/data-day="(\d+)"/)[1])] ?? null,
    querySelectorAll: (selector) => {
      if (selector === "[data-field]") return fields;
      if (selector === "[data-marker]") return markers;
      return days;
    }
  };
};

const hook = (el) => Object.assign(Object.create(CycleFigures), { el, day: null, cycle: el.dataset.cycle });

const dayNode = (index) => ({ inside: true, dataset: { day: String(index) }, closest: () => dayNode(index) });

describe("stepDay", () => {
  it("moves one day either way and stays inside the days", () => {
    assert.equal(stepDay(3, 7, "ArrowLeft"), 2);
    assert.equal(stepDay(3, 7, "ArrowRight"), 4);
    assert.equal(stepDay(0, 7, "ArrowLeft"), 0);
    assert.equal(stepDay(7, 7, "ArrowRight"), 7);
  });

  it("starts from the latest day when none shows", () => {
    assert.equal(stepDay(null, 7, "ArrowLeft"), 7);
    assert.equal(stepDay(null, 7, "ArrowRight"), 7);
  });

  it("goes to either end", () => {
    assert.equal(stepDay(3, 7, "Home"), 0);
    assert.equal(stepDay(3, 7, "End"), 7);
    assert.equal(stepDay(null, 7, "Home"), 0);
  });
});

describe("CycleFigures", () => {
  it("shows a day's figures and only its marker", () => {
    const el = panel();
    const figures = hook(el);

    figures.show(1);

    assert.equal(figures.day, 1);
    assert.deepEqual(
      el.fields.map((field) => field.textContent),
      ["Tue Oct 27 · day 2 of 28", "338", "+4%"]
    );
    assert.equal(el.markers[0].hidden.has("hidden"), true);
    assert.equal(el.markers[1].hidden.has("hidden"), false);
    assert.equal(el.attributes.has("data-hovering"), true);
  });

  it("puts today's figures back and hides the marker", () => {
    const el = panel();
    const figures = hook(el);

    figures.show(1);
    figures.clear();

    assert.equal(figures.day, null);
    assert.deepEqual(
      el.fields.map((field) => field.textContent),
      ["Oct 26 – Nov 22", "369", "+14%"]
    );
    assert.equal(el.markers[1].hidden.has("hidden"), true);
    assert.equal(el.attributes.has("data-hovering"), false);
  });

  it("reads a day with no rect as today", () => {
    const el = panel();
    const figures = hook(el);

    figures.show(1);
    figures.show(9);

    assert.equal(figures.day, null);
    assert.equal(el.fields[1].textContent, "369");
  });

  it("shows the hovered day again after a patch writes today's figures back", () => {
    const el = panel();
    const figures = hook(el);

    figures.show(0);
    el.fields[1].textContent = "370";
    el.markers[0].hidden.add("hidden");
    el.attributes.clear();
    figures.updated();

    assert.equal(el.fields[1].textContent, "324");
    assert.equal(el.markers[0].hidden.has("hidden"), false);
    assert.equal(el.attributes.has("data-hovering"), true);
  });

  it("leaves a patch's figures alone when no day shows", () => {
    const el = panel();
    const figures = hook(el);

    el.fields[1].textContent = "370";
    figures.updated();

    assert.equal(el.fields[1].textContent, "370");
  });

  it("forgets the day when a patch brings another cycle into the same panel", () => {
    const el = panel();
    const figures = hook(el);

    figures.show(1);
    el.dataset.cycle = "cyc_13";
    el.fields[1].textContent = "412";
    figures.updated();

    assert.equal(figures.day, null);
    assert.equal(el.fields[1].textContent, "412");
  });

  it("counts its days for the arrow keys", () => {
    assert.equal(hook(panel()).lastDay(), 1);
  });
});

describe("CycleFigures listeners", () => {
  const realDocument = globalThis.document;
  const chart = { inside: true, matches: () => true };
  const button = { inside: true, matches: () => false };
  let el;
  let figures;
  let underFinger;
  let onDocument;
  let removed;

  beforeEach(() => {
    underFinger = null;
    onDocument = {};
    removed = {};
    globalThis.document = {
      addEventListener: (name, listener) => {
        onDocument[name] = listener;
      },
      removeEventListener: (name, listener) => {
        removed[name] = listener;
      },
      elementFromPoint: () => underFinger
    };
    el = panel();
    figures = hook(el);
    figures.mounted();
    figures.show(1);
  });

  afterEach(() => {
    globalThis.document = realDocument;
  });

  it("keeps a tapped day when the finger lifts and clears when a mouse leaves", () => {
    el.listeners.pointerleave({ pointerType: "touch" });
    assert.equal(figures.day, 1);

    el.listeners.pointerleave({ pointerType: "mouse" });
    assert.equal(figures.day, null);
  });

  it("clears when the browser takes the gesture for a scroll", () => {
    el.listeners.pointercancel({ pointerType: "touch" });

    assert.equal(figures.day, null);
    assert.equal(el.fields[1].textContent, "369");
  });

  it("follows a sliding finger from day to day and keeps the last it read", () => {
    underFinger = dayNode(0);
    el.listeners.pointermove({ pointerType: "touch", clientX: 40, clientY: 60 });
    assert.equal(figures.day, 0);

    underFinger = { closest: () => null };
    el.listeners.pointermove({ pointerType: "touch", clientX: 40, clientY: 140 });
    assert.equal(figures.day, 0);

    underFinger = null;
    el.listeners.pointermove({ pointerType: "touch", clientX: 4000, clientY: 60 });
    assert.equal(figures.day, 0);
  });

  it("reads no day from another panel under a sliding finger", () => {
    underFinger = { closest: () => ({ inside: false, dataset: { day: "0" } }) };

    el.listeners.pointermove({ pointerType: "touch", clientX: 40, clientY: 600 });

    assert.equal(figures.day, 1);
  });

  it("ignores a mouse's moves, which the hover already reads", () => {
    underFinger = dayNode(0);

    el.listeners.pointermove({ pointerType: "mouse", clientX: 40, clientY: 60 });

    assert.equal(figures.day, 1);
  });

  it("clears on a tap outside the panel and keeps the day on one inside it", () => {
    onDocument.pointerdown({ target: button });
    assert.equal(figures.day, 1);

    onDocument.pointerdown({ target: { inside: false } });
    assert.equal(figures.day, null);
  });

  it("takes its document listener away with it", () => {
    figures.destroyed();

    assert.ok(onDocument.pointerdown);
    assert.equal(removed.pointerdown, onDocument.pointerdown);
  });

  it("keeps the day when focus moves to its own chart and clears on any other move", () => {
    el.listeners.focusout({ relatedTarget: chart });
    assert.equal(figures.day, 1);

    el.listeners.focusout({ relatedTarget: button });
    assert.equal(figures.day, null);

    figures.show(1);
    el.listeners.focusout({ relatedTarget: { inside: false, matches: () => true } });
    assert.equal(figures.day, null);

    figures.show(1);
    el.listeners.focusout({ relatedTarget: null });
    assert.equal(figures.day, null);
  });
});
