import "phoenix_html";
import { Socket } from "phoenix";
import { LiveSocket } from "phoenix_live_view";

import { Theme, applyTheme } from "./hooks/theme";
import { Shortcuts } from "./hooks/shortcuts";
import { Elapsed } from "./hooks/elapsed";
import { ChatAutoscroll } from "./hooks/chat_autoscroll";
import { DiffHighlight } from "./hooks/diff_highlight";
import { DemoPlayer } from "./hooks/demo_player";

const Hooks = {
  Theme,
  Shortcuts,
  Elapsed,
  ChatAutoscroll,
  DiffHighlight,
  DemoPlayer
};

const csrfToken = document.querySelector("meta[name='csrf-token']")?.getAttribute("content");
const liveSocket = new LiveSocket("/live", Socket, {
  params: { _csrf_token: csrfToken },
  hooks: Hooks
});

// The appearance settings page picks a theme server-side; apply it here.
window.addEventListener("phx:set_theme", (event) => applyTheme(event.detail.theme));

liveSocket.connect();
window.liveSocket = liveSocket;
