import "phoenix_html";
import { Socket } from "phoenix";
import { LiveSocket } from "phoenix_live_view";
import topbar from "../vendor/topbar";

import { Theme } from "./hooks/theme";
import { Shortcuts } from "./hooks/shortcuts";
import { Elapsed } from "./hooks/elapsed";
import { ChatAutoscroll } from "./hooks/chat_autoscroll";
import { ChatComposer } from "./hooks/chat_composer";
import { DiffScroller } from "./hooks/diff_scroller";
import { DiffSection } from "./hooks/diff_section";
import { DiffWrap } from "./hooks/diff_wrap";
import { CopyText } from "./hooks/copy_text";
import { JumpToLine } from "./hooks/jump_to_line";
import { LocalTime } from "./hooks/local_time";
import { LocalResetTime } from "./hooks/local_reset_time";
import { DesignFrame } from "./hooks/design_frame";
import { BrowserScreencast } from "./hooks/browser_screencast";
import { DemoCaptions } from "./hooks/demo_captions";
import { CurrentInView } from "./hooks/current_in_view";
import { ScrollSelectedTab } from "./hooks/scroll_selected_tab";
import { PlanDiagram } from "./hooks/plan_diagram";
import { PlanLinks } from "./hooks/plan_links";
import { ImageFallback } from "./hooks/image_fallback";

const Hooks = {
  DesignFrame,
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
  PlanLinks,
  ImageFallback
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
