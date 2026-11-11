import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { getSchema } from "@tiptap/core";
import { Image } from "@tiptap/extension-image";
import { TaskItem, TaskList } from "@tiptap/extension-list";
import { TableKit } from "@tiptap/extension-table";
import { MarkdownManager } from "@tiptap/markdown";
import { StarterKit } from "@tiptap/starter-kit";
import {
  calculateDropPosition,
  calculateReplace,
  calculateRestore,
  calculateSaveState,
  uploadableFiles,
  wrapLoneImages
} from "../js/hooks/issue_description.js";

// The extensions the hook edits the description with, less the ones that only draw in a browser.
const extensions = [
  StarterKit.configure({ underline: false }),
  Image.configure({ inline: true }),
  TableKit,
  TaskList,
  TaskItem.configure({ nested: true })
];
const schema = getSchema(extensions);
const markdown = new MarkdownManager({ extensions });

const settled = { baseline: "Saved", text: "Saved", seq: 0, inFlight: null, failed: false };

const run = (state, events) =>
  events.reduce(
    ({ state: current, outputs }, event) => {
      const output = calculateSaveState(current, event);
      return { state: output.state, outputs: [...outputs, output] };
    },
    { state, outputs: [] }
  );

describe("calculateSaveState", () => {
  it("keeps every edit in the browser and pushes it numbered on save", () => {
    const { state, outputs } = run(settled, [{ type: "edit", text: "Typed" }, { type: "save" }]);

    assert.equal(outputs[0].draft, "write");
    assert.deepEqual(outputs[1].push, { seq: 1, text: "Typed" });
    assert.equal(outputs[1].draft, "write");
    assert.equal(state.inFlight, 1);
  });

  it("saves nothing when nothing changed, so clicking in and out sends nothing", () => {
    assert.equal(calculateSaveState(settled, { type: "save" }).push, undefined);
  });

  it("clears the stored copy and the notice once exactly that text is confirmed", () => {
    const { state, outputs } = run(settled, [
      { type: "edit", text: "Typed" },
      { type: "save" },
      { type: "ok", seq: 1, text: "Typed" }
    ]);

    assert.deepEqual(
      { notice: outputs[2].notice, draft: outputs[2].draft, retry: outputs[2].retry },
      { notice: "hide", draft: "clear", retry: "stop" }
    );
    assert.equal(state.baseline, "Typed");
  });

  it("keeps the stored copy when the text moved on while the save was out", () => {
    const { state, outputs } = run(settled, [
      { type: "edit", text: "Typed" },
      { type: "save" },
      { type: "edit", text: "Typed more" },
      { type: "ok", seq: 1, text: "Typed" }
    ]);

    assert.equal(outputs[3].draft, "write");
    assert.equal(outputs[3].notice, undefined);
    assert.equal(state.text, "Typed more");
  });

  it("shows no notice for a timeout of an older save after a newer one was confirmed", () => {
    const { outputs } = run(settled, [
      { type: "edit", text: "First" },
      { type: "save" },
      { type: "edit", text: "Second" },
      { type: "save" },
      { type: "ok", seq: 2, text: "Second" },
      { type: "timeout", seq: 1 }
    ]);

    assert.equal(outputs[5].notice, undefined);
    assert.equal(outputs[5].draft, undefined);
  });

  it("ignores a reply to a save a newer one replaced", () => {
    const { state, outputs } = run(settled, [
      { type: "edit", text: "First" },
      { type: "save" },
      { type: "edit", text: "Second" },
      { type: "save" },
      { type: "ok", seq: 1, text: "First" }
    ]);

    assert.equal(outputs[4].draft, undefined);
    assert.equal(state.baseline, "Saved");
    assert.equal(state.inFlight, 2);
  });

  it("shows the notice for a refused save, keeps the stored copy and starts retrying", () => {
    const { state, outputs } = run(settled, [
      { type: "edit", text: "Typed" },
      { type: "save" },
      { type: "refused", seq: 1 }
    ]);

    assert.deepEqual(
      { notice: outputs[2].notice, draft: outputs[2].draft, retry: outputs[2].retry },
      { notice: "show", draft: "write", retry: "start" }
    );
    assert.equal(state.failed, true);
  });

  it("shows the notice for a save with no reply in time", () => {
    const { outputs } = run(settled, [{ type: "edit", text: "Typed" }, { type: "save" }, { type: "timeout", seq: 1 }]);
    assert.equal(outputs[2].notice, "show");
  });

  it("shows the notice on a disconnect only while text is unsaved, and saves again on reconnect", () => {
    assert.equal(calculateSaveState(settled, { type: "disconnected" }).notice, undefined);

    const { state, outputs } = run(settled, [
      { type: "edit", text: "Typed" },
      { type: "disconnected" },
      { type: "reconnected" }
    ]);

    assert.equal(outputs[1].notice, "show");
    assert.equal(outputs[1].retry, "start");
    assert.deepEqual(outputs[2].push, { seq: 1, text: "Typed" });
    assert.equal(state.failed, true);
  });

  it("keeps the notice up until a save after a failure is confirmed", () => {
    const { outputs } = run(settled, [
      { type: "edit", text: "Typed" },
      { type: "save" },
      { type: "refused", seq: 1 },
      { type: "save" },
      { type: "ok", seq: 2, text: "Typed" }
    ]);

    assert.equal(outputs[3].draft, "write");
    assert.deepEqual(
      { notice: outputs[4].notice, draft: outputs[4].draft, retry: outputs[4].retry },
      { notice: "hide", draft: "clear", retry: "stop" }
    );
  });

  it("hides the notice and clears the stored copy when an undo brings the saved text back", () => {
    const { state, outputs } = run(settled, [
      { type: "edit", text: "Typed" },
      { type: "save" },
      { type: "refused", seq: 1 },
      { type: "edit", text: "Saved" }
    ]);

    assert.deepEqual(
      { notice: outputs[3].notice, draft: outputs[3].draft, retry: outputs[3].retry },
      { notice: "hide", draft: "clear", retry: "stop" }
    );
    assert.equal(state.failed, false);
  });

  it("keeps an emptied description as an edit to store and save", () => {
    const { outputs } = run(settled, [{ type: "edit", text: "" }, { type: "save" }]);

    assert.equal(outputs[0].draft, "write");
    assert.deepEqual(outputs[1].push, { seq: 1, text: "" });
  });

  it("changes nothing for an event it does not know", () => {
    assert.deepEqual(calculateSaveState(settled, { type: "unknown" }), { state: settled });
  });
});

describe("calculateRestore", () => {
  it("loads a stored copy only when it differs from the saved markdown", () => {
    assert.equal(calculateRestore("Typed offline", "Saved"), "load");
    assert.equal(calculateRestore("", "Saved"), "load");
  });

  it("clears a stored copy that matches any form of the saved markdown", () => {
    assert.equal(calculateRestore("Saved", "Saved"), "clear");
    assert.equal(calculateRestore("- item", ["* item", "- item"]), "clear");
  });

  it("does nothing without a stored copy", () => {
    assert.equal(calculateRestore(null, "Saved"), "none");
  });
});

describe("calculateReplace", () => {
  const idle = { focused: false, dirty: false, pending: false, unsaved: false, baseline: "Saved", incoming: "Theirs" };

  it("takes a new saved text at once while nobody is typing here", () => {
    assert.equal(calculateReplace(idle), "now");
  });

  it("keeps the text while focused, dirty, uploading or holding an unsaved copy", () => {
    assert.equal(calculateReplace({ ...idle, focused: true }), "later");
    assert.equal(calculateReplace({ ...idle, dirty: true }), "later");
    assert.equal(calculateReplace({ ...idle, pending: true }), "later");
    assert.equal(calculateReplace({ ...idle, unsaved: true }), "later");
  });

  it("changes nothing when the saved text is what the editor already holds", () => {
    assert.equal(calculateReplace({ ...idle, focused: true, incoming: "Saved" }), "none");
  });
});

describe("uploadableFiles", () => {
  it("keeps PNG, JPEG, GIF, WebP and PDF files", () => {
    const types = ["image/png", "image/jpeg", "image/gif", "image/webp", "application/pdf"];
    const others = [
      "image/svg+xml",
      "text/html",
      "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
      ""
    ];
    const files = [...types, ...others].map((type) => ({ name: `file-${type}`, type }));

    assert.deepEqual(
      uploadableFiles(files).map((file) => file.type),
      types
    );
  });

  it("finds nothing in a missing list", () => {
    assert.deepEqual(uploadableFiles(undefined), []);
  });
});

describe("wrapLoneImages", () => {
  it("puts an image alone on its line back in a paragraph, so the document is valid and saves as it was", () => {
    for (const saved of ["Ship it today.\n\n![Shot](https://x/a.png)", "> ![Shot](https://x/a.png)"]) {
      const parsed = markdown.parse(saved);
      assert.throws(() => schema.nodeFromJSON(parsed).check());

      const wrapped = wrapLoneImages(parsed);
      assert.doesNotThrow(() => schema.nodeFromJSON(wrapped).check());
      assert.equal(markdown.serialize(wrapped), saved);
    }
  });

  it("leaves an image in the middle of a sentence inline", () => {
    const parsed = markdown.parse("Before ![Shot](https://x/a.png) after");
    assert.deepEqual(wrapLoneImages(parsed), parsed);
  });
});

describe("calculateDropPosition", () => {
  const empty = schema.nodeFromJSON({ type: "doc", content: [{ type: "paragraph" }] });
  const written = schema.nodeFromJSON({
    type: "doc",
    content: [{ type: "paragraph", content: [{ type: "text", text: "Typed" }] }]
  });

  it("drops into an empty description's paragraph, not after it", () => {
    assert.equal(calculateDropPosition(empty, 1, false), empty.content.size - 1);
  });

  it("drops after the last block of a description ending in text", () => {
    assert.equal(calculateDropPosition(written, 1, false), written.content.size);
  });

  it("drops at the cursor once the description has had focus", () => {
    assert.equal(calculateDropPosition(written, 3, true), 3);
  });
});

describe("a PDF's link", () => {
  it("saves as a markdown link named for the file, with the space after it outside the link", () => {
    const doc = {
      type: "doc",
      content: [
        {
          type: "paragraph",
          content: [
            { type: "text", text: "spec.pdf", marks: [{ type: "link", attrs: { href: "https://x/spec.pdf" } }] },
            { type: "text", text: " " }
          ]
        }
      ]
    };

    assert.equal(markdown.serialize(doc), "[spec.pdf](https://x/spec.pdf) ");
  });
});
