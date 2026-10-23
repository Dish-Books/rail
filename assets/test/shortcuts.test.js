import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { formSubmitButton } from "../js/hooks/shortcuts.js";

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
