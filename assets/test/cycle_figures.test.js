import assert from "node:assert/strict";
import { describe, it } from "node:test";
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

  return {
    dataset: { cycle: "cyc_14" },
    attributes,
    fields,
    markers,
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
