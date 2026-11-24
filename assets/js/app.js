import "phoenix_html";
import { Socket } from "phoenix";
import { LiveSocket } from "phoenix_live_view";
import topbar from "../vendor/topbar";
import { listenForDragLinks } from "./drag_link";
import { BrowserScreencast } from "./hooks/browser_screencast";
import { ChatAutoscroll } from "./hooks/chat_autoscroll";
import { ChatComposer } from "./hooks/chat_composer";
import { CommandOutput } from "./hooks/command_output";
import { CommentBox } from "./hooks/comment_box";
import { CopyText } from "./hooks/copy_text";
import { CurrentInView } from "./hooks/current_in_view";
import { CycleFigures } from "./hooks/cycle_figures";
import { DemoCaptions } from "./hooks/demo_captions";
import { DesignFrame, ElementPreview } from "./hooks/design_frame";
import { DiffScroller } from "./hooks/diff_scroller";
import { DiffSection } from "./hooks/diff_section";
import { DiffWrap } from "./hooks/diff_wrap";
import { Elapsed } from "./hooks/elapsed";
import { ImageFallback } from "./hooks/image_fallback";
import { ImagePaste } from "./hooks/image_paste";
import { IssueDescription } from "./hooks/issue_description";
import { IssueTitle } from "./hooks/issue_title";
import { JumpToLine } from "./hooks/jump_to_line";
import { LocalResetTime } from "./hooks/local_reset_time";
import { LocalTime } from "./hooks/local_time";
import { MarkdownPaste } from "./hooks/markdown_paste";
import { MenuKeys } from "./hooks/menu_keys";
import { ScrollSelectedTab } from "./hooks/scroll_selected_tab";
import { Shortcuts } from "./hooks/shortcuts";
import { SidebarResize } from "./hooks/sidebar_resize";
import { SketchesToggle } from "./hooks/sketches_toggle";
import { StartFocus } from "./hooks/start_focus";
import { StatusMenu } from "./hooks/status_menu";
import { Theme } from "./hooks/theme";
import { TodosDrop } from "./hooks/todos_drop";
import { readOpen, TodosOpen } from "./hooks/todos_open";
import { blockRepeatClicks } from "./no_repeat";
import { recordDrops } from "./socket_drops";

const Hooks = {
  DesignFrame,
  ElementPreview,
  Theme,
  Shortcuts,
  Elapsed,
  ChatAutoscroll,
  ChatComposer,
  CommandOutput,
  CommentBox,
  DiffScroller,
  DiffSection,
  DiffWrap,
  CopyText,
  JumpToLine,
  LocalTime,
  LocalResetTime,
  BrowserScreencast,
  DemoCaptions,
  CurrentInView,
  CycleFigures,
  ScrollSelectedTab,
  ImageFallback,
  SidebarResize,
  StatusMenu,
  MenuKeys,
  IssueTitle,
  ImagePaste,
  IssueDescription,
  MarkdownPaste,
  TodosDrop,
  TodosOpen,
  StartFocus,
  SketchesToggle
};

const csrfToken = document.querySelector("meta[name='csrf-token']")?.getAttribute("content");
const drops = recordDrops(window);
// One object, which LiveView adds each join's _mounts and _track_static to, so the server's CONNECTED line carries
// them beside the last drop.
const socketParams = { _csrf_token: csrfToken };
const liveSocket = new LiveSocket("/live", Socket, {
  // Read on every join, so a reconnect and the next page both show the panel as this browser left it.
  params: () =>
    Object.assign(socketParams, drops.params(), {
      todos_open: readOpen(window.localStorage),
      time_zone: Intl.DateTimeFormat().resolvedOptions().timeZone
    }),
  logger: drops.logger,
  hooks: Hooks
});
drops.watch(liveSocket.socket);
listenForDragLinks(document, window.location.origin);
blockRepeatClicks(document);

topbar.config({ barColors: { 0: "#6366f1" }, shadowColor: "rgba(0, 0, 0, 0)" });
window.addEventListener("phx:page-loading-start", (info) => {
  // An "error" load is a lost connection, which this bar does not report.
  if (info.detail.kind !== "error") topbar.show(250);
});
window.addEventListener("phx:page-loading-stop", () => topbar.hide());

liveSocket.connect();
window.liveSocket = liveSocket;
