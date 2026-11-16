// Why the page's connection last dropped, sent with its next connect, so the server's CONNECTED line says.
//
// Rail only sees a tab connect again. The browser alone knows whether its heartbeat went unanswered, the connection
// was closed or failed under it, how long it had been quiet, and whether the tab was hidden or offline then.

// Events this close together are one drop: an error before its close, or the close a heartbeat timeout makes.
const SAME_DROP_MS = 5000;

// One drop, as a single param: short to read in a log line, and nothing in it names the reader.
export function describeDrop(drop, now) {
  const since = (at) => (at == null ? "-" : Math.round((drop.at - at) / 1000));

  return [
    `how=${drop.how}`,
    ...(drop.code === undefined ? [] : [`code=${drop.code}`, `clean=${drop.clean}`]),
    `ago=${Math.round((now - drop.at) / 1000)}`,
    `open=${since(drop.openedAt)}`,
    `quiet=${since(drop.receivedAt)}`,
    `sent=${since(drop.sentAt)}`,
    `visible=${drop.visible}`,
    `seen=${since(drop.visibilityAt)}`,
    `online=${drop.online}`,
    `drops=${drop.count}`
  ].join(" ");
}

// state: the connection's times so far; last: the drop kept before. A heartbeat timeout says why the connection
// went, so its close only adds the code; an error's close says how it ended. A drop before the connection opened
// belongs to an earlier one.
export function calculateDrop(state, last, event, now) {
  if (last && last.at >= state.openedAt && now - last.at < SAME_DROP_MS) {
    const how = last.how === "heartbeat_timeout" ? last.how : event.how;
    const closed = event.how === "closed" ? { code: event.code, clean: event.clean } : {};
    return { ...last, ...closed, how };
  }

  return {
    ...event,
    at: now,
    openedAt: state.openedAt,
    receivedAt: state.receivedAt,
    sentAt: state.sentAt,
    visible: state.visible,
    visibilityAt: state.visibilityAt,
    online: state.online,
    count: (last?.count ?? 0) + 1
  };
}

export function recordDrops(win, clock = () => Date.now()) {
  const doc = win.document;
  const state = {
    openedAt: clock(),
    receivedAt: clock(),
    sentAt: null,
    visible: doc.visibilityState === "visible",
    visibilityAt: clock(),
    online: win.navigator.onLine
  };
  let last = null;

  const note = (event) => {
    state.online = win.navigator.onLine;
    last = calculateDrop(state, last, event, clock());
  };

  doc.addEventListener("visibilitychange", () => {
    state.visible = doc.visibilityState === "visible";
    state.visibilityAt = clock();
  });

  return {
    // Phoenix's logger: the only place it says a heartbeat went unanswered, and when it last sent.
    logger(kind, message) {
      if (kind === "push") state.sentAt = clock();
      else if (kind === "transport" && message.startsWith("heartbeat timeout")) note({ how: "heartbeat_timeout" });
    },

    watch(socket) {
      socket.onOpen(() => {
        state.openedAt = clock();
        state.receivedAt = clock();
      });
      socket.onMessage(() => {
        state.receivedAt = clock();
      });
      socket.onClose((event) => note({ how: "closed", code: event?.code ?? "-", clean: event?.wasClean ?? "-" }));
      socket.onError(() => note({ how: "error" }));
    },

    params() {
      return last ? { _drop: describeDrop(last, clock()) } : {};
    }
  };
}
