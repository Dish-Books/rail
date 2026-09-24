defmodule Rail.Tools.BrowserSession do
  @moduledoc """
  One Chrome, one tab, for one task.

  The browser has to outlive every call made against it - a QA pass is forty
  checks against the same session - so something has to own that lifetime. This
  does: it launches Chrome, connects to it, opens the tab everything is driven
  in, and on the way out kills the browser and removes the profile it wrote. A
  session that ends because the task ended, because the run failed, or because
  the application went down all take the same path, which is the point. An agent that
  forgets to stop cannot leave a browser behind.

  It owns no row. What it launched is written down by whoever started it, because
  a process that is not there cannot record its own death, and the record is
  exactly what a reaper needs. So this reports what it did and
  `Rail.Tools.reconcile_browser_sessions/1` settles anything that ended without
  being asked to.

  Chrome is detached from the BEAM the same way agent processes are, so the OS
  pid that was recorded is what stops it rather than a port this process holds.

  It also broadcasts what the tab is looking at, frame by frame, on
  `"browser:<task id>"`. Headless is the right default for a pass nobody is
  watching, but a human who opens the QA panel while one is running wants to see
  it happening rather than read about it afterwards - and Chrome only encodes a
  frame when the page actually changes, so a session nobody is watching costs
  almost nothing.
  """
  use GenServer, restart: :temporary

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Tools
  alias Rail.Tools.Browser
  alias Rail.Tools.BrowserRegistry

  require Logger

  @chrome_candidates [
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "/usr/bin/google-chrome",
    "/usr/bin/chromium",
    "/usr/bin/chromium-browser"
  ]

  @viewport %{width: 1920, height: 1080}

  @screencast %{format: "jpeg", quality: 80, maxWidth: 1920, maxHeight: 1080, everyNthFrame: 1}
  @ready_timeout_ms 15_000
  @poll_interval_ms 100

  defstruct [
    :session_id,
    :task_id,
    :browser,
    :target_id,
    :cdp_session_id,
    :os_pid,
    :debug_port,
    :profile_path,
    :frame,
    :url,
    problems: []
  ]

  @doc """
  Starts the session for `task` and returns its process.
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
  Returns what this session launched: the OS process, the port it is listening on,
  the profile it wrote, and the tab it is driving.
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

    # Launching here rather than in a continue, so that a caller holding the pid
    # holds a browser it can drive. A session still opening its tab is not a
    # session anyone can use, and `await_devtools/1` bounds how long this can take.
    case launch(state, opts) do
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
      os_pid: state.os_pid,
      debug_port: state.debug_port,
      profile_path: state.profile_path,
      target_id: state.target_id,
      cdp_session_id: state.cdp_session_id
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

  # Chrome stops sending frames until the last one is acknowledged, so the ack
  # goes out before anything else happens with it. The frame is broadcast whether
  # or not anybody is listening, which on a local PubSub with no subscribers is a
  # lookup and nothing else.
  def handle_info({:cdp_event, "Page.screencastFrame", %{"data" => data} = params}, %__MODULE__{} = state) do
    Browser.cast(state.browser, "Page.screencastFrameAck", %{
      session: state.cdp_session_id,
      sessionId: params["sessionId"]
    })

    Phoenix.PubSub.broadcast(Rail.PubSub, "browser:#{state.task_id}", {:browser_frame, state.task_id, data})

    {:noreply, %{state | frame: data}}
  end

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

  def handle_info(_message, %__MODULE__{} = state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %__MODULE__{} = state) do
    close(state)
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

  defp launch(%__MODULE__{} = state, opts) do
    with {:ok, executable} <- executable(),
         profile = profile_path(state.session_id),
         {:ok, _port, os_pid} <- spawn_chrome(executable, profile, opts),
         state = %{state | os_pid: os_pid, profile_path: profile},
         {:ok, port, url} <- await_devtools(profile),
         {:ok, browser} <- Browser.start_link(url: url, subscribe: [self() | List.wrap(opts[:subscribe])]),
         {:ok, %{"targetId" => target}} <- Browser.call(browser, "Target.createTarget", %{url: "about:blank"}),
         {:ok, %{"sessionId" => cdp}} <-
           Browser.call(browser, "Target.attachToTarget", %{targetId: target, flatten: true}) do
      prepare(%{state | browser: browser, target_id: target, cdp_session_id: cdp, debug_port: port})
    end
  end

  # A tab Rail drives is a fixed size so a narrow-viewport check means something,
  # and renders while it is in the background so animations and menus behave the
  # way they would in front of somebody.
  defp prepare(%__MODULE__{} = state) do
    metrics = Map.merge(@viewport, %{deviceScaleFactor: 1, mobile: false})

    with {:ok, _set} <- command(state, "Emulation.setDeviceMetricsOverride", metrics),
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

  defp spawn_chrome(executable, profile, opts) do
    File.rm_rf(profile)
    File.mkdir_p!(profile)
    logs = Path.join(profile, "chrome.log")

    Tools.spawn_os_process(executable, chrome_args(profile, opts), stdout_path: logs, stderr_path: logs)
  end

  # Headless unless somebody wants to watch. Every flag here is about making the
  # browser Rail's rather than the machine's: its own profile, no first-run
  # interruptions, and nothing shared with a Chrome the human has open.
  defp chrome_args(profile, opts) do
    headless = if Keyword.get(opts, :headless, true), do: ["--headless=new"], else: []

    headless ++
      [
        # Chrome picks the port and writes it into the profile, so two sessions
        # starting at once cannot pick the same one.
        "--remote-debugging-port=0",
        "--remote-allow-origins=*",
        "--user-data-dir=#{profile}",
        "--no-first-run",
        "--no-default-browser-check",
        "--disable-background-timer-throttling",
        "--disable-renderer-backgrounding",
        "--disable-backgrounding-occluded-windows",
        "--disable-gpu",
        # Rail's container has no user namespaces for Chrome's sandbox, and it only opens our own apps.
        "--no-sandbox",
        "about:blank"
      ]
  end

  # Chrome writes the port it took and the path to its own websocket into
  # `DevToolsActivePort` once it is listening, which is both how its address is
  # learned and how "up" is known. Reading a file beats asking over HTTP: there is
  # nothing to mock in a test, and nothing to race.
  defp await_devtools(profile), do: await_devtools(profile, System.monotonic_time(:millisecond) + @ready_timeout_ms)

  defp await_devtools(profile, deadline) do
    case File.read(Path.join(profile, "DevToolsActivePort")) do
      {:ok, contents} ->
        case String.split(String.trim(contents), "\n") do
          [port, path] ->
            {:ok, String.to_integer(port), "ws://127.0.0.1:#{port}#{path}"}

          # coveralls-ignore-start (the file caught between Chrome's two writes)
          _half_written ->
            retry(profile, deadline)
            # coveralls-ignore-stop
        end

      {:error, _not_yet} ->
        retry(profile, deadline)
    end
  end

  defp retry(profile, deadline) do
    if System.monotonic_time(:millisecond) < deadline do
      Process.sleep(@poll_interval_ms)
      await_devtools(profile, deadline)
    else
      {:error, :devtools_never_answered}
    end
  end

  # Whatever killed this session, the browser goes with it and so does the
  # profile: a Chrome nobody stopped holds a core for as long as the machine is
  # up, and a profile nobody removed is hundreds of megabytes per task.
  defp close(%__MODULE__{} = state) do
    if state.browser && Process.alive?(state.browser), do: GenServer.stop(state.browser, :normal, 1_000)
    if state.os_pid, do: Tools.terminate_os_process(state.os_pid, [])

    # A browser that came up and did its work leaves nothing behind. One that
    # never answered keeps its profile, because Chrome's own log is in there and
    # it is the only account of why - and the row still points at it.
    if state.profile_path && state.cdp_session_id, do: File.rm_rf(state.profile_path)

    :ok
  end

  # Per session rather than per task. A profile Chrome did not exit cleanly from
  # keeps its `SingletonLock`, and the next Chrome pointed at it refuses to start
  # rather than risk corrupting it - so a task's second pass would never get a
  # browser. Each launch gets its own directory and takes it with it.
  defp profile_path(session_id) do
    Path.join([System.tmp_dir!(), "rail", "browsers", session_id])
  end

  # coveralls-ignore-start (the branch for a machine with no Chrome, which is not
  # a machine these tests can run on)
  defp executable do
    case Enum.find(@chrome_candidates, &File.exists?/1) || System.find_executable("google-chrome") do
      executable when is_binary(executable) -> {:ok, executable}
      nil -> {:error, :no_chrome}
    end
  end

  # coveralls-ignore-stop
end
