// The TipTap pieces a Rail-tracked issue's description is edited with. The description's hook imports this module
// dynamically, so the bundle splits TipTap into a chunk only that page loads.
export { Editor, Extension } from "@tiptap/core";
export { Image } from "@tiptap/extension-image";
export { TaskItem, TaskList } from "@tiptap/extension-list";
export { TableKit } from "@tiptap/extension-table";
export { Placeholder } from "@tiptap/extensions";
export { Markdown } from "@tiptap/markdown";
export { Plugin, PluginKey } from "@tiptap/pm/state";
export { Decoration, DecorationSet } from "@tiptap/pm/view";
export { StarterKit } from "@tiptap/starter-kit";
