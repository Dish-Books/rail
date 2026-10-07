import assert from "node:assert/strict";
import { describe, it } from "node:test";
import {
  buildSelector,
  CUT_MARK,
  captureElement,
  elementText,
  checkMessage,
  cutHtml,
  describeElement,
  fitScale,
  keepDraft,
  keyAction,
  LIMITS,
  markerBox,
  previewScale,
  readDraft,
  resolveSelector,
  shouldStartOverlay,
  storageKey
} from "../js/hooks/design_frame.js";

function node(localName, attrs = {}, children = []) {
  const element = {
    localName,
    id: attrs.id || "",
    textContent: attrs.text ?? children.map((child) => child.textContent).join(" "),
    outerHTML: attrs.html || `<${localName}></${localName}>`,
    children,
    parentElement: null,
    getBoundingClientRect: () => attrs.rect || { left: 0, top: 0, width: 10, height: 10 }
  };
  for (const child of children) child.parentElement = element;
  return element;
}

function page() {
  const heading = node("h2", { text: "Needs   you\n 3", rect: { left: 240.4, top: 120.6, width: 180.2, height: 21.6 } });
  const first = node("li", { text: "RAIL-41" });
  const answer = node("button", { text: "Answer" });
  const second = node("li", {}, [node("p", { text: "RAIL-66" }), answer]);
  const lane = node("section", { id: "lane-needs-you" }, [node("header", {}, [heading]), node("ul", {}, [first, second])]);
  const twin = node("div", { id: "twin" });
  const twinAgain = node("div", { id: "twin" }, [node("span", { text: "inside" })]);
  const fancy = node("div", { id: "a b" }, [node("em", { text: "fancy" })]);
  const body = node("body", {}, [lane, twin, twinAgain, fancy]);
  const root = node("html", {}, [node("head"), body]);

  const all = [];
  const walk = (element) => {
    all.push(element);
    for (const child of element.children) walk(child);
  };
  walk(root);

  const doc = { documentElement: root, getElementById: (id) => all.find((element) => element.id === id) || null };
  return { doc, lane, heading, second, answer, twinAgain, fancy };
}

function remove(element) {
  const siblings = element.parentElement.children;
  siblings.splice(siblings.indexOf(element), 1);
}

describe("selectors", () => {
  it("is the element's id when that id is unique and plain", () => {
    const { doc, lane } = page();
    assert.equal(buildSelector(lane, doc), "#lane-needs-you");
  });

  it("is a path of tags and positions from the nearest unique plain id otherwise", () => {
    const { doc, heading, answer } = page();
    assert.equal(buildSelector(heading, doc), "#lane-needs-you > header:nth-child(1) > h2:nth-child(1)");
    assert.equal(buildSelector(answer, doc), "#lane-needs-you > ul:nth-child(2) > li:nth-child(2) > button:nth-child(2)");
  });

  it("starts from the root when no ancestor has an id it can stand on", () => {
    const { doc, twinAgain, fancy } = page();
    assert.equal(buildSelector(twinAgain.children[0], doc), "html > body:nth-child(2) > div:nth-child(3) > span:nth-child(1)");
    assert.equal(buildSelector(fancy.children[0], doc), "html > body:nth-child(2) > div:nth-child(4) > em:nth-child(1)");
  });

  it("resolves to the same element it was built for", () => {
    const { doc, heading, answer, twinAgain } = page();
    for (const element of [heading, answer, twinAgain.children[0]]) {
      assert.equal(resolveSelector(doc, buildSelector(element, doc)), element);
    }
  });

  it("finds nothing once the element is gone, or for a selector outside its grammar", () => {
    const { doc, heading, answer } = page();
    const selector = buildSelector(answer, doc);
    remove(answer);
    assert.equal(resolveSelector(doc, selector), null);

    const headingSelector = buildSelector(heading, doc);
    remove(heading);
    assert.equal(resolveSelector(doc, headingSelector), null);

    for (const bad of ["", null, 7, "#missing", "body", "#lane-needs-you > header", "#lane-needs-you > ul:nth-child(9)"]) {
      assert.equal(resolveSelector(doc, bad), null);
    }
  });

  it("finds the next sibling's element after a sibling before it is removed", () => {
    const { doc, lane, second } = page();
    const list = lane.children[1];
    const firstSelector = buildSelector(list.children[0], doc);
    remove(list.children[0]);
    assert.equal(resolveSelector(doc, firstSelector), second);
  });
});

describe("capture", () => {
  it("takes the element's own HTML and its box, and nothing else of the page", () => {
    const { doc, heading } = page();
    heading.outerHTML = "<h2>Needs you <span>3</span></h2>";

    assert.deepEqual(describeElement(heading, doc), {
      selector: "#lane-needs-you > header:nth-child(1) > h2:nth-child(1)",
      text: "Needs you 3",
      tag: "h2",
      html: "<h2>Needs you <span>3</span></h2>",
      width: 180,
      height: 22,
      x: 240,
      y: 121
    });
  });

  it("keeps HTML of 20,000 characters whole and cuts longer HTML with Rail's mark", () => {
    const whole = "a".repeat(LIMITS.html);
    assert.equal(cutHtml(whole), whole);

    const long = `<div>${"b".repeat(LIMITS.html)}</div>`;
    assert.equal(cutHtml(long), long.slice(0, LIMITS.html) + CUT_MARK);
    assert.equal(cutHtml(cutHtml(long)), cutHtml(long));

    const element = node("div", { html: long, rect: { left: 0, top: 0, width: 0.2, height: 0 } });
    assert.deepEqual(captureElement(element), { html: cutHtml(long), width: 1, height: 1, x: 0, y: 0 });
  });
});

describe("what an element says", () => {
  const text = (data) => ({ nodeType: 3, data });
  const element = (localName, childNodes) => ({ localName, childNodes, textContent: "never read" });

  it("is the text a person sees, not the source of a script or style inside it", () => {
    const widget = element("div", [
      element("b", [text("Pay  now")]),
      element("script", [text("document.title = 'x'")]),
      element("style", [text(".q{color:red}")]),
      element("template", [text("later")]),
      element("noscript", [text("no js")])
    ]);

    assert.equal(elementText(widget), "Pay now");
  });

  it("is what the browser renders when it can say", () => {
    assert.equal(elementText({ innerText: "Needs you\n3", textContent: "Needs you 3 .css{}" }), "Needs you 3");
  });
});

describe("messages from the frame", () => {
  const frame = { name: "frame" };
  const select = {
    channel: "rail-design-frame",
    kind: "select",
    version: "v1",
    selector: "#group-by-project",
    text: "Group by project",
    tag: "label",
    html: "<label>Group by project</label>",
    width: 160.4,
    height: 20,
    x: 1300,
    y: 90
  };

  it("passes a select from its own frame for the page shown, rounded", () => {
    assert.deepEqual(checkMessage({ source: frame, data: select }, frame, "v1"), {
      kind: "select",
      selector: "#group-by-project",
      text: "Group by project",
      tag: "label",
      html: "<label>Group by project</label>",
      width: 160,
      height: 20,
      x: 1300,
      y: 90
    });
  });

  it("drops a message from another window, for an older page, of an unknown kind or with a wrong field", () => {
    assert.equal(checkMessage({ source: {}, data: select }, frame, "v1"), null);
    assert.equal(checkMessage({ source: frame, data: select }, frame, "v2"), null);
    assert.equal(checkMessage({ source: frame, data: { ...select, kind: "eval" } }, frame, "v1"), null);
    assert.equal(checkMessage({ source: frame, data: { ...select, channel: "other" } }, frame, "v1"), null);
    assert.equal(checkMessage({ source: frame, data: null }, frame, "v1"), null);
    assert.equal(checkMessage({ source: frame, data: { ...select, width: "wide" } }, frame, "v1"), null);
    assert.equal(checkMessage({ source: frame, data: { ...select, html: { toString: () => "x" } } }, frame, "v1"), null);
    assert.equal(checkMessage({ source: frame, data: { ...select, tag: "<script>" } }, frame, "v1"), null);
    assert.equal(checkMessage({ source: frame, data: { ...select, width: Number.NaN } }, frame, "v1"), null);
    assert.equal(checkMessage({ source: frame, data: { ...select, kind: "key", key: "x" } }, frame, "v1"), null);
    assert.equal(checkMessage({ source: frame, data: { ...select, kind: "anchors", missing: [1] } }, frame, "v1"), null);
  });

  it("caps overlong strings to the changeset's limits", () => {
    const data = { ...select, selector: "#a".repeat(900), text: "t".repeat(500), html: "h".repeat(30000) };
    const report = checkMessage({ source: frame, data }, frame, "v1");

    assert.equal(report.selector.length, LIMITS.selector);
    assert.equal(report.text.length, LIMITS.text);
    assert.equal(report.html, "h".repeat(LIMITS.html) + CUT_MARK);
  });

  it("passes keys and the comments whose elements are missing", () => {
    assert.deepEqual(checkMessage({ source: frame, data: { ...select, kind: "key", key: "escape" } }, frame, "v1"), {
      kind: "key",
      key: "escape"
    });

    assert.deepEqual(
      checkMessage({ source: frame, data: { ...select, kind: "anchors", missing: ["pcm_1"] } }, frame, "v1"),
      { kind: "anchors", missing: ["pcm_1"] }
    );
  });
});

describe("keys", () => {
  const target = (typing) => ({ matches: () => typing });

  it("reads C as on and Esc as off", () => {
    assert.equal(keyAction({ key: "c", target: target(false) }), "c");
    assert.equal(keyAction({ key: "Escape", target: target(false) }), "escape");
    assert.equal(keyAction({ key: "x", target: target(false) }), null);
  });

  it("means nothing from an input, textarea, select or editable element, or with a modifier", () => {
    assert.equal(keyAction({ key: "c", target: target(true) }), null);
    assert.equal(keyAction({ key: "Escape", target: { matches: () => false, isContentEditable: true } }), null);

    for (const modifier of ["metaKey", "ctrlKey", "altKey", "shiftKey"]) {
      assert.equal(keyAction({ key: "c", [modifier]: true, target: target(false) }), null);
    }
  });
});

describe("the work in progress a reload keeps", () => {
  function memory() {
    const items = new Map();
    return {
      items,
      getItem: (key) => (items.has(key) ? items.get(key) : null),
      setItem: (key, value) => items.set(key, value),
      removeItem: (key) => items.delete(key)
    };
  }

  const draft = {
    option_key: "waiting-lanes",
    selector: "#lane-failed",
    text: "Failed",
    tag: "section",
    html: "<section>Failed</section>",
    width: 300,
    height: 400,
    x: 1200,
    y: 100,
    body: "Failed should come first."
  };

  it("keeps the mode and the open box, capture included, under the task's and user's key", () => {
    const storage = memory();
    const key = storageKey("tsk_1", "usr_1");
    keepDraft(storage, key, { commenting: true, draft });

    assert.equal(key, "rail:design-comments:tsk_1:usr_1");
    assert.deepEqual(readDraft(storage, key), { commenting: true, draft });
    assert.equal(readDraft(storage, storageKey("tsk_1", "usr_2")), null);
  });

  it("is gone once commenting is off with no box open, as after save, cancel or leaving commenting", () => {
    const storage = memory();
    const key = storageKey("tsk_1", "usr_1");
    keepDraft(storage, key, { commenting: true, draft });
    keepDraft(storage, key, { commenting: true, draft: null });
    assert.deepEqual(readDraft(storage, key), { commenting: true, draft: null });

    keepDraft(storage, key, { commenting: false, draft: null });
    assert.equal(storage.items.size, 0);
  });

  it("ignores what it cannot read, and a storage that refuses", () => {
    const storage = memory();
    for (const value of ["{", "null", '{"commenting":"yes"}', '{"commenting":true,"draft":{"selector":7}}']) {
      storage.setItem("k", value);
      assert.equal(readDraft(storage, "k"), null);
    }

    const full = {
      getItem: () => null,
      removeItem: () => {},
      setItem: () => {
        throw new Error("QuotaExceededError");
      }
    };
    assert.doesNotThrow(() => keepDraft(full, "k", { commenting: true, draft: null }));
  });
});

describe("fitting", () => {
  it("scales the option's frame to the width it is given", () => {
    assert.equal(fitScale(960, 1920), 0.5);
    assert.equal(fitScale(1920, 1920), 1);
  });

  it("scales an element preview down to fit and never past its own size", () => {
    assert.equal(previewScale(400, 800), 0.5);
    assert.equal(previewScale(1100, 180), 1);
  });
});

describe("markers", () => {
  it("are drawn larger by as much as the frame is scaled down, so each is about 20px on screen", () => {
    for (const scale of [0.287, 0.466, 1]) {
      const box = markerBox(scale);
      assert.ok(Math.abs(box.size * scale - 20) < 0.001);
      assert.ok(Math.abs(box.font * scale - 11) < 0.001);
    }
  });

  it("are drawn at their own size for a scale that is missing or not a number", () => {
    for (const scale of [undefined, null, "0.5", Number.NaN, 0, -1]) assert.equal(markerBox(scale).size, 20);
    assert.equal(markerBox(0.001).size, 400);
  });
});

describe("the overlay", () => {
  it("does not start when the file is loaded without Rail's overlay mark", () => {
    assert.equal(shouldStartOverlay(null), false);
    assert.equal(shouldStartOverlay({ hasAttribute: () => false }), false);
    assert.equal(shouldStartOverlay({ hasAttribute: (name) => name === "data-rail-overlay" }), true);
  });
});
