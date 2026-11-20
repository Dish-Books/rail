import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { screenFromHash } from "../js/design_screens.js";

describe("screenFromHash", () => {
  it("reads a platform and its screen's place on the page", () => {
    assert.deepEqual(screenFromHash("#ios-2"), { name: "ios", index: 2 });
    assert.deepEqual(screenFromHash("#android-1"), { name: "android", index: 1 });
    assert.deepEqual(screenFromHash("#ios-999"), { name: "ios", index: 999 });
  });

  it("names no screen for the whole page, another platform, a place before the first, or no address", () => {
    for (const hash of ["", "#", "#ios", "#web", "#web-1", "#ios-0", "#ios-01", "#ios-1000", "#IOS-1", "#ios-1 ", null])
      assert.equal(screenFromHash(hash), null);
  });
});
