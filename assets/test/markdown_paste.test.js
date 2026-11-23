import assert from "node:assert/strict";
import { describe, it } from "node:test";
import {
  calculateFileText,
  calculateLabel,
  calculateSettledText,
  calculateUploadingText,
  holdSubmit,
  replaceFirst
} from "../js/hooks/markdown_paste.js";

describe("calculateUploadingText", () => {
  it("names the file in an empty image while it goes up", () => {
    assert.equal(
      calculateUploadingText("Screenshot 2026-11-23 at 14.02.11.png"),
      "![Uploading Screenshot 2026-11-23 at 14.02.11.png...]()"
    );
  });
});

describe("calculateFileText", () => {
  it("writes an image as an image", () => {
    assert.equal(
      calculateFileText({ name: "shot.png", url: "https://rail.test/issues/iss_1/assets/a-shot.png", image: true }),
      "![shot.png](https://rail.test/issues/iss_1/assets/a-shot.png)"
    );
  });

  it("writes a PDF as a link", () => {
    assert.equal(
      calculateFileText({ name: "SPEC.PDF", url: "https://rail.test/issues/iss_1/assets/a-SPEC.PDF", image: false }),
      "[SPEC.PDF](https://rail.test/issues/iss_1/assets/a-SPEC.PDF)"
    );
  });

  it("escapes brackets in the name so the markdown does not end early", () => {
    assert.equal(
      calculateFileText({ name: "shot [1].png", url: "https://rail.test/a.png", image: true }),
      "![shot \\[1\\].png](https://rail.test/a.png)"
    );
  });
});

describe("calculateLabel", () => {
  it("escapes brackets and backslashes and leaves the rest", () => {
    assert.equal(calculateLabel("a\\b]c[d.png"), "a\\\\b\\]c\\[d.png");
    assert.equal(calculateLabel("plain.png"), "plain.png");
  });
});

describe("replaceFirst", () => {
  it("replaces only the first of two identical Uploading lines", () => {
    const line = calculateUploadingText("image.png");
    const text = `Before\n${line}\n\n${line}\nAfter`;

    assert.equal(replaceFirst(text, line, "![image.png](one)"), `Before\n![image.png](one)\n\n${line}\nAfter`);
  });

  it("leaves the text alone when the person deleted the line", () => {
    assert.equal(replaceFirst("Typed only", calculateUploadingText("gone.png"), "![gone.png](x)"), "Typed only");
  });
});

describe("calculateSettledText", () => {
  const line = calculateUploadingText("shot.png");

  it("puts the file's markdown where its Uploading line was", () => {
    assert.equal(calculateSettledText(`Typed\n${line}\n`, "shot.png", "![shot.png](u)"), "Typed\n![shot.png](u)\n");
  });

  it("takes a refused file's line out with the breaks it came in with, so the typed text is as it was", () => {
    assert.equal(calculateSettledText(`Typed\n${line}\n`, "shot.png", ""), "Typed");
  });

  it("leaves the other files of the same drop in place", () => {
    const other = calculateUploadingText("other.png");
    assert.equal(calculateSettledText(`Typed\n${line}\n\n${other}\n`, "shot.png", ""), `Typed\n${other}\n`);
  });

  it("removes only the line when the person moved the text around it", () => {
    assert.equal(calculateSettledText(`Typed ${line} more`, "shot.png", ""), "Typed  more");
  });
});

describe("holdSubmit", () => {
  it("stops a submit while a file is still going up", () => {
    const calls = [];
    const event = {
      preventDefault: () => calls.push("preventDefault"),
      stopImmediatePropagation: () => calls.push("stopImmediatePropagation")
    };

    assert.equal(holdSubmit(event, 1), true);
    assert.deepEqual(calls, ["preventDefault", "stopImmediatePropagation"]);
  });

  it("lets a submit through once nothing is pending", () => {
    const calls = [];
    const event = {
      preventDefault: () => calls.push("preventDefault"),
      stopImmediatePropagation: () => calls.push("stopImmediatePropagation")
    };

    assert.equal(holdSubmit(event, 0), false);
    assert.deepEqual(calls, []);
  });
});
