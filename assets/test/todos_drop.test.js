import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { dropBefore, keyBefore, readDrop } from "../js/hooks/todos_drop.js";

const transfer = (entries) => ({ getData: (type) => entries[type] ?? "" });
const htmlText = (html) => html.replace(/<[^>]*>/g, "");
const origin = "https://rail.example.com";

describe("readDrop", () => {
  it("turns a link to the page's own origin into its path, named by its text", () => {
    const dropped = transfer({
      "text/uri-list": "https://rail.example.com/tasks/tsk_1?item=findings&finding=F3#top",
      "text/plain": "Ruling Fix scrolls the list"
    });

    assert.deepEqual(readDrop(dropped, origin, htmlText), {
      url: "/tasks/tsk_1?item=findings&finding=F3#top",
      text: "Ruling Fix scrolls the list"
    });
  });

  it("keeps another origin's link whole, named by the link's own markup", () => {
    const dropped = transfer({
      "text/uri-list": "# a comment\r\nhttps://github.com/acme/rail/pull/268",
      "text/plain": "https://github.com/acme/rail/pull/268",
      "text/html": '<a href="https://github.com/acme/rail/pull/268">Workflows for everyone</a>'
    });

    assert.deepEqual(readDrop(dropped, origin, htmlText), {
      url: "https://github.com/acme/rail/pull/268",
      text: "Workflows for everyone"
    });
  });

  it("names a link whose only text is its address by nothing, for the server to fill in", () => {
    const dropped = transfer({ "text/uri-list": "https://example.com/a", "text/plain": "https://example.com/a" });
    assert.deepEqual(readDrop(dropped, origin, htmlText), { url: "https://example.com/a", text: "" });
  });

  it("reads a mailto: link as text only", () => {
    const dropped = transfer({ "text/uri-list": "mailto:ana@example.com", "text/plain": "mailto:ana@example.com" });
    assert.deepEqual(readDrop(dropped, origin, htmlText), { text: "mailto:ana@example.com" });
  });

  it("reads selected text as text only, trimmed and cut to 500 characters", () => {
    assert.deepEqual(readDrop(transfer({ "text/plain": "  Upload the bills  " }), origin, htmlText), {
      text: "Upload the bills"
    });

    assert.equal(readDrop(transfer({ "text/plain": "x".repeat(600) }), origin, htmlText).text.length, 500);
  });

  it("gives nothing for a drop with no text at all", () => {
    assert.equal(readDrop(transfer({}), origin, htmlText), null);
  });
});

describe("dropBefore", () => {
  const rows = [
    { id: "a", top: 0, height: 40 },
    { id: "b", top: 40, height: 40 },
    { id: "c", top: 80, height: 40 }
  ];

  it("names the row whose middle is below the pointer", () => {
    assert.equal(dropBefore(rows, 10, null), "a");
    assert.equal(dropBefore(rows, 30, null), "b");
    assert.equal(dropBefore(rows, 99, null), "c");
  });

  it("gives null below the last row's middle", () => {
    assert.equal(dropBefore(rows, 110, null), null);
  });

  it("skips the row being moved", () => {
    assert.equal(dropBefore(rows, 30, "b"), "c");
  });
});

describe("keyBefore", () => {
  const ids = ["a", "b", "c"];

  it("moves a row up in front of the one above it", () => {
    assert.deepEqual(keyBefore(ids, "b", "ArrowUp"), { before: "a" });
  });

  it("moves a row down in front of the one after the next, or to the end", () => {
    assert.deepEqual(keyBefore(ids, "a", "ArrowDown"), { before: "c" });
    assert.deepEqual(keyBefore(ids, "b", "ArrowDown"), { before: null });
  });

  it("does nothing at either end or for another key", () => {
    assert.equal(keyBefore(ids, "a", "ArrowUp"), null);
    assert.equal(keyBefore(ids, "c", "ArrowDown"), null);
    assert.equal(keyBefore(ids, "b", "Enter"), null);
    assert.equal(keyBefore(ids, "z", "ArrowDown"), null);
  });
});
