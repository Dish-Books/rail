import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { formSubmitButton, modalOpen } from "../js/hooks/shortcuts.js";

describe("formSubmitButton", () => {
  it("gives the submit button of the form the target belongs to", () => {
    const button = { id: "slack-channels-submit" };
    const target = {
      form: { querySelector: (selector) => (selector === "button[type='submit']" ? button : null) }
    };

    assert.equal(formSubmitButton(target), button);
  });

  it("gives nothing when the form has no submit button", () => {
    assert.equal(formSubmitButton({ form: { querySelector: () => null } }), null);
  });

  it("gives nothing when the target is in no form", () => {
    assert.equal(formSubmitButton({ form: null }), null);
  });

  it("gives nothing for a target with no form property, such as a link", () => {
    assert.equal(formSubmitButton({}), null);
  });
});

describe("modalOpen", () => {
  it("is true when the page shows a modal or dialog", () => {
    const doc = {
      querySelector: (selector) => (selector === "[id$='-modal'], [role='dialog']" ? { id: "project-modal" } : null)
    };

    assert.equal(modalOpen(doc), true);
  });

  it("is false when the page shows none", () => {
    assert.equal(modalOpen({ querySelector: () => null }), false);
  });
});
