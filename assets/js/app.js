import "phoenix_html";
import { Socket } from "phoenix";
import { LiveSocket } from "phoenix_live_view";

import { Theme } from "./hooks/theme";
import { Shortcuts } from "./hooks/shortcuts";
import { Elapsed } from "./hooks/elapsed";
import { ChatAutoscroll } from "./hooks/chat_autoscroll";
import { DiffScroller } from "./hooks/diff_scroller";
import { DemoPlayer } from "./hooks/demo_player";
import { CopyText } from "./hooks/copy_text";
import { LocalTime } from "./hooks/local_time";
import { DesignFrame } from "./hooks/design_frame";

const Hooks = {
  DesignFrame,
  Theme,
  Shortcuts,
  Elapsed,
  ChatAutoscroll,
  DiffScroller,
  DemoPlayer,
  CopyText,
  LocalTime
};

const csrfToken = document.querySelector("meta[name='csrf-token']")?.getAttribute("content");
const liveSocket = new LiveSocket("/live", Socket, {
  params: { _csrf_token: csrfToken },
  hooks: Hooks
});

liveSocket.connect();
window.liveSocket = liveSocket;
