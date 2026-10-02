defmodule Rail.Tools.BrowserSession do
  @moduledoc """
  One task's tab in the shared Chrome, and Rail's connection to it.

  The Chrome is `Rail.Tools.Utils.EnsureBrowserHost`'s: one for every task, in a
  sandbox of its own, outliving Rail. What a session owns is a browser context -
  cookies and storage nobody else's pass can see - and one tab in it, which the
  agent drives directly over its own DevTools connection and Rail watches over
  this one.

  The tab outlives this process. Rail stopping takes the connection and leaves
  the tab, so a deploy in the middle of a pass comes back to the same page,
  signed in: the row keeps the context and target, and the next session for the
  task attaches to them rather than opening another. Only a stop that means it -
  `Rail.Tools.stop_browser_session/1`, the task moving on - closes the context.

  It also broadcasts what the tab is looking at, frame by frame, on
  `"browser:<task id>"`. Headless is the right default for a pass nobody is
  watching, but a human who opens the QA panel while one is running wants to see
  it happening rather than read about it afterwards - and Chrome only encodes a
  frame when the page actually changes, so a session nobody is watching costs
  almost nothing.
  """
  use GenServer, restart: :temporary

  import Rail.Tools.Utils.EnsureBrowserHost

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Tools.Browser
  alias Rail.Tools.BrowserRegistry

  require Logger

  @viewport %{width: 1920, height: 1080}

  @screencast %{format: "jpeg", quality: 80, maxWidth: 1920, maxHeight: 1080, everyNthFrame: 1}

  # Encoding frames is most of what Chrome spends on a busy tab, and the panel
  # shows four a second. Chrome keeps two frames in flight, so holding each ack
  # this long keeps a busy tab to about eighteen a second and half the CPU.
  @ack_after_ms 133
  @settled_after_ms 250

  defstruct [
    :session_id,
    :task_id,
    :browser,
    :browser_context_id,
    :target_id,
    :cdp_session_id,
    :debug_port,
    :frame,
    :url,
    :capture,
    frame_seq: 0,
    screenshot_echo?: false,
    problems: []
  ]

  @doc """
  Starts the session for `task` and returns its process.

  `opts` takes `:resume`, a map with the `:browser_context_id` and `:target_id`
  of a tab an earlier session opened, to attach to that tab rather than open one.
  """
  def start_link(opts) do
    task = Keyword.fetch!(opts, :task)

    GenServer.start_link(__MODULE__, opts, name: {:via, Registry, {BrowserRegistry, task.id}})
  end

  @doc """
  Sends `method` to this task's tab and returns what Chrome answers.

  The tab is addressed for the caller, so nothing outside here needs to know the
  session id Chrome gave it.
  """
  def call(pid, method, params \\ %{}) do
    GenServer.call(pid, {:call, method, params}, 40_000)
  end

  @doc """
  Returns what this session is holding: the context and tab in the shared
  Chrome, the port Chrome is listening on, and `page_url`, the tab's own DevTools
  websocket - which is what an agent drives it through.
  """
  def details(pid), do: GenServer.call(pid, :details)

  @doc """
  Returns everything the browser complained about since it was last asked, and
  forgets it.

  Draining rather than accumulating, so a problem belongs to the check that was
  running when it happened. A console error found after step 40 that was actually
  thrown on step 2 is worse than no console error at all.
  """
  def drain_problems(pid), do: GenServer.call(pid, :drain_problems)

  @doc """
  The last frame the tab painted, as base64 JPEG, or `nil` before it has painted
  one.

  A panel opened part way through a pass has missed every frame broadcast so far,
  and a browser sitting on a form nobody is touching will not paint another until
  something happens. So the newest one is kept to hand.
  """
  def last_frame(pid), do: GenServer.call(pid, :last_frame)

  @doc """
  The URL the tab is on, or nil before it has gone anywhere.
  """
  def where(pid), do: GenServer.call(pid, :where)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    %Task{} = task = Keyword.fetch!(opts, :task)
    state = %__MODULE__{session_id: Keyword.fetch!(opts, :session_id), task_id: task.id}

    # Opening here rather than in a continue, so that a caller holding the pid
    # holds a tab it can drive. A session still opening its tab is not a session
    # anyone can use, and the host's own ready timeout bounds how long this takes.
    case open(state, opts) do
      {:ok, state} -> {:ok, state}
      {:error, reason} -> {:stop, {:browser_unavailable, reason}}
    end
  end

  @impl true
  def handle_call({:call, method, params}, _from, %__MODULE__{} = state) do
    {:reply, command(state, method, params), state}
  end

  def handle_call(:details, _from, %__MODULE__{} = state) do
    details = %{
      debug_port: state.debug_port,
      browser_context_id: state.browser_context_id,
      target_id: state.target_id,
      cdp_session_id: state.cdp_session_id,
      page_url: "ws://127.0.0.1:#{state.debug_port}/devtools/page/#{state.target_id}"
    }

    {:reply, details, state}
  end

  def handle_call(:drain_problems, _from, %__MODULE__{problems: problems} = state) do
    {:reply, Enum.reverse(problems), %{state | problems: []}}
  end

  def handle_call(:last_frame, _from, %__MODULE__{} = state) do
    {:reply, state.frame, state}
  end

  def handle_call(:where, _from, %__MODULE__{} = state) do
    {:reply, state.url, state}
  end

  # The connection going down means the browser did, so the session goes with it
  # rather than answering calls against a Chrome that is not there.
  @impl true
  def handle_info({:EXIT, browser, reason}, %__MODULE__{browser: browser} = state) do
    {:stop, {:browser_gone, reason}, state}
  end

  # Chrome sends no frame until the last one is acknowledged, so holding the ack
  # is what sets the frame rate. The frame is broadcast whether or not anybody is
  # listening, which on a local PubSub with no subscribers is a lookup and
  # nothing else.
  #
  # The frame a screenshot of our own paints is let straight through, or every
  # screenshot would be followed by another.
  def handle_info(
        {:cdp_event, "Page.screencastFrame", %{"data" => data, "sessionId" => ack}},
        %__MODULE__{screenshot_echo?: true} = state
      ) do
    ack(state, ack)

    {:noreply, %{show(state, data) | screenshot_echo?: false}}
  end

  def handle_info({:cdp_event, "Page.screencastFrame", %{"data" => data, "sessionId" => ack}}, %__MODULE__{} = state) do
    seq = state.frame_seq + 1
    Process.send_after(self(), {:ack_frame, ack, seq}, @ack_after_ms)

    {:noreply, %{show(state, data) | frame_seq: seq}}
  end

  def handle_info({:ack_frame, ack, seq}, %__MODULE__{} = state) do
    ack(state, ack)
    Process.send_after(self(), {:settled, seq}, @settled_after_ms)

    {:noreply, state}
  end

  # Whatever the page painted while an ack was held was never sent, and a page
  # that has since gone still will not paint again. So once the frames stop, the
  # page is photographed as it is, and that is the frame everyone ends on.
  #
  # Asked for rather than waited on: a busy Chrome can take half a minute over
  # a screenshot, and everyone else calling this session - the agent's tools, a
  # panel wanting the last frame - would wait that long behind it. The frame it
  # paints doing so is the echo, whichever of the two arrives first.
  def handle_info({:settled, seq}, %__MODULE__{frame_seq: seq} = state) do
    params = %{format: "jpeg", quality: @screencast.quality, session: state.cdp_session_id}
    request = Browser.send_request(state.browser, "Page.captureScreenshot", params)

    {:noreply, %{state | capture: {request, seq}, screenshot_echo?: true}}
  end

  def handle_info({:settled, _since_moved}, %__MODULE__{} = state), do: {:noreply, state}

  # The tab said it navigated. Only the main frame counts: an iframe going
  # somewhere is not the page going somewhere.
  def handle_info({:cdp_event, "Page.frameNavigated", %{"frame" => %{"url" => url} = frame}}, %__MODULE__{} = state)
      when not is_map_key(frame, "parentId") do
    {:noreply, %{state | url: url}}
  end

  # What the browser says without being asked. Most of it is noise; what is kept
  # is what a person doing QA would write down - an exception, an error in the
  # console, a request that failed, a renderer that died.
  def handle_info({:cdp_event, method, params}, %__MODULE__{} = state) do
    case problem(method, params) do
      %{} = problem -> {:noreply, %{state | problems: [problem | state.problems]}}
      nil -> {:noreply, state}
    end
  end

  # The screenshot asked for once the frames stopped. A page that has moved since
  # has newer frames than the photograph, which is then thrown away.
  def handle_info(message, %__MODULE__{capture: {request, seq}} = state) do
    case :gen_server.check_response(message, request) do
      {:reply, {:ok, %{"data" => data}}} when seq == state.frame_seq ->
        {:noreply, %{show(state, data) | capture: nil}}

      :no_reply ->
        {:noreply, state}

      _stale_refused_or_down ->
        {:noreply, %{state | capture: nil, screenshot_echo?: false}}
    end
  end

  def handle_info(_message, %__MODULE__{} = state), do: {:noreply, state}

  # Only a stop that was asked for closes the tab. Rail shutting down is
  # `:shutdown`, and the tab is left for the next session to attach to; a crash
  # leaves it for reconcile, which knows whether the task still wants it.
  @impl true
  def terminate(reason, %__MODULE__{} = state) do
    if reason == :normal and state.browser_context_id, do: dispose(state)
    if state.browser && Process.alive?(state.browser), do: GenServer.stop(state.browser, :normal, 1_000)

    :ok
  end

  defp show(%__MODULE__{} = state, data) do
    Phoenix.PubSub.broadcast(Rail.PubSub, "browser:#{state.task_id}", {:browser_frame, state.task_id, data})

    %{state | frame: data}
  end

  defp ack(%__MODULE__{} = state, ack) do
    Browser.cast(state.browser, "Page.screencastFrameAck", %{session: state.cdp_session_id, sessionId: ack})
  end

  defp problem("Runtime.exceptionThrown", %{"exceptionDetails" => details}) do
    %{kind: :exception, detail: details["text"] || "Uncaught exception", url: details["url"]}
  end

  defp problem("Runtime.consoleAPICalled", %{"type" => type, "args" => args}) when type in ["error", "assert"] do
    %{kind: :console, detail: Enum.map_join(args, " ", &console_argument/1)}
  end

  defp problem("Log.entryAdded", %{"entry" => %{"level" => "error"} = entry}) do
    %{kind: :log, detail: entry["text"], url: entry["url"]}
  end

  defp problem("Network.responseReceived", %{"response" => %{"status" => status} = response}) when status >= 400 do
    %{kind: :response, detail: "#{status} #{response["statusText"]}", url: response["url"]}
  end

  defp problem("Network.loadingFailed", %{"errorText" => error} = params) do
    %{kind: :response, detail: error, url: params["type"]}
  end

  defp problem("Inspector.targetCrashed", _params) do
    %{kind: :crash, detail: "The page crashed."}
  end

  defp problem(_uninteresting, _params), do: nil

  defp console_argument(%{"value" => value}) when is_binary(value), do: value
  defp console_argument(%{"description" => description}) when is_binary(description), do: description
  defp console_argument(argument), do: inspect(argument["value"] || argument["type"])

  defp open(%__MODULE__{} = state, opts) do
    with {:ok, %{url: url, port: port}} <- ensure_browser_host(opts),
         {:ok, browser} <- Browser.start_link(url: url, subscribe: [self() | List.wrap(opts[:subscribe])]),
         state = %{state | browser: browser, debug_port: port},
         {:ok, state} <- tab(state, opts[:resume]) do
      prepare(state)
    end
  end

  # A tab an earlier session opened is attached to where it is. One that is not
  # there any more - Chrome restarted, the context was closed - is an error rather
  # than a quiet new tab, because the caller is the one who settles the row that
  # pointed at it.
  defp tab(%__MODULE__{} = state, %{browser_context_id: context, target_id: target})
       when is_binary(context) and is_binary(target) do
    state = %{state | browser_context_id: context, target_id: target}

    with {:ok, %{"sessionId" => cdp}} <-
           Browser.call(state.browser, "Target.attachToTarget", %{targetId: target, flatten: true}),
         {:ok, %{"targetInfo" => %{"url" => url}}} <-
           Browser.call(state.browser, "Target.getTargetInfo", %{targetId: target}) do
      {:ok, %{state | cdp_session_id: cdp, url: url}}
    else
      {:error, _gone} ->
        dispose(state)
        {:error, :tab_gone}
    end
  end

  defp tab(%__MODULE__{} = state, _fresh) do
    with {:ok, %{"browserContextId" => context}} <- Browser.call(state.browser, "Target.createBrowserContext", %{}),
         {:ok, %{"targetId" => target}} <-
           Browser.call(state.browser, "Target.createTarget", %{url: "about:blank", browserContextId: context}),
         {:ok, %{"sessionId" => cdp}} <-
           Browser.call(state.browser, "Target.attachToTarget", %{targetId: target, flatten: true}) do
      {:ok, %{state | browser_context_id: context, target_id: target, cdp_session_id: cdp}}
    end
  end

  # Closing the context closes its tab and forgets everything signed into it.
  # Chrome refusing because it is already gone is the same outcome.
  defp dispose(%__MODULE__{} = state) do
    _disposed = Browser.call(state.browser, "Target.disposeBrowserContext", %{browserContextId: state.browser_context_id})

    :ok
  end

  # A tab Rail drives is a fixed size so a narrow-viewport check means something,
  # and renders while it is in the background so animations and menus behave the
  # way they would in front of somebody.
  #
  # The size is the window's own, not only an override: Chrome drops every
  # override when a connection that set one goes, and the agent's driver resizes
  # over a connection of its own. A headless window is 756x469 inside, so without
  # this the page stays laid out at 1920 while the screencast shows its corner.
  defp prepare(%__MODULE__{} = state) do
    metrics = Map.merge(@viewport, %{deviceScaleFactor: 1, mobile: false})

    with {:ok, %{"windowId" => window}} <-
           Browser.call(state.browser, "Browser.getWindowForTarget", %{targetId: state.target_id}),
         {:ok, _sized} <- Browser.call(state.browser, "Browser.setContentsSize", Map.put(@viewport, :windowId, window)),
         {:ok, _set} <- command(state, "Emulation.setDeviceMetricsOverride", metrics),
         {:ok, _focus} <- command(state, "Emulation.setFocusEmulationEnabled", %{enabled: true}),
         :ok <- listen(state),
         {:ok, _casting} <- command(state, "Page.startScreencast", @screencast) do
      {:ok, state}
    end
  end

  # Nothing is reported until it is asked for. These are what turn an ordinary
  # browser into one that says when the page threw, logged an error, or asked for
  # something the server refused.
  defp listen(%__MODULE__{} = state) do
    Enum.reduce_while(["Runtime.enable", "Log.enable", "Network.enable", "Page.enable"], :ok, fn domain, :ok ->
      case command(state, domain, %{}) do
        {:ok, _enabled} ->
          {:cont, :ok}

        # coveralls-ignore-start (a Chrome that accepted the connection and then
        # refused one of its own standard domains; no test can ask for it)
        {:error, reason} ->
          {:halt, {:error, reason}}
          # coveralls-ignore-stop
      end
    end)
  end

  # Addressed to this session's own tab. Setup runs inside `handle_continue`,
  # where the process cannot call itself, so it goes straight to the connection.
  defp command(%__MODULE__{} = state, method, params) do
    Browser.call(state.browser, method, Map.put(Map.new(params), :session, state.cdp_session_id))
  end
end
