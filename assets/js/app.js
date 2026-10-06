import "phoenix_html";
import { Socket } from "phoenix";
import { LiveSocket } from "phoenix_live_view";
import topbar from "../vendor/topbar";
import { BrowserScreencast } from "./hooks/browser_screencast";
import { ChatAutoscroll } from "./hooks/chat_autoscroll";
import { ChatComposer } from "./hooks/chat_composer";
import { CopyText } from "./hooks/copy_text";
import { CurrentInView } from "./hooks/current_in_view";
import { DemoCaptions } from "./hooks/demo_captions";
import { DesignFrame, ElementPreview } from "./hooks/design_frame";
import { DiffScroller } from "./hooks/diff_scroller";
import { DiffSection } from "./hooks/diff_section";
import { DiffWrap } from "./hooks/diff_wrap";
import { Elapsed } from "./hooks/elapsed";
import { JumpToLine } from "./hooks/jump_to_line";
import { LocalResetTime } from "./hooks/local_reset_time";
import { LocalTime } from "./hooks/local_time";
import { PlanDiagram } from "./hooks/plan_diagram";
import { PlanLinks } from "./hooks/plan_links";
import { ScrollSelectedTab } from "./hooks/scroll_selected_tab";
import { Shortcuts } from "./hooks/shortcuts";
import { Theme } from "./hooks/theme";

const Hooks = {
  DesignFrame,
  ElementPreview,
  Theme,
  Shortcuts,
  Elapsed,
  ChatAutoscroll,
  ChatComposer,
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
  ScrollSelectedTab,
  PlanDiagram,
  PlanLinks
};

const csrfToken = document.querySelector("meta[name='csrf-token']")?.getAttribute("content");
const liveSocket = new LiveSocket("/live", Socket, {
  params: { _csrf_token: csrfToken },
  hooks: Hooks
});

topbar.config({ barColors: { 0: "#6366f1" }, shadowColor: "rgba(0, 0, 0, 0)" });
window.addEventListener("phx:page-loading-start", (info) => {
  // An "error" load is a lost connection, which this bar does not report.
  if (info.detail.kind !== "error") topbar.show(250);
});
window.addEventListener("phx:page-loading-stop", () => topbar.hide());

liveSocket.connect();
window.liveSocket = liveSocket;
