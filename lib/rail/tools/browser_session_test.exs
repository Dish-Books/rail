defmodule Rail.Tools.BrowserSessionTest do
  use Rail.DataCase, async: false

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Tools
  alias Rail.Tools.Browser
  alias Rail.Tools.BrowserSession
  alias Rail.Tools.Schemas.BrowserSession, as: Session

  # Serial, because each test drives a real Chrome and a machine running thirty at
  # once measures contention rather than the browser.
  @moduletag :browser

  setup %{project: project} do
    scope = system_scope()

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{
              "id" => "lin_brs_#{System.unique_integer([:positive])}",
              "identifier" => "BRS-1",
              "title" => "Browser Session"
            }
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(scope, project, %{description: "Browser Session"})
    {:ok, task} = Pipeline.create_task(issue, :qa)

    page = Path.join(task.scratch_path, "page.html")
    File.mkdir_p!(task.scratch_path)

    File.write!(page, """
    <!doctype html><title>Bill</title>
    <form>
      <label for="amount">Amount</label><input id="amount" type="text">
      <button type="button" id="save">Save</button>
    </form>
    """)

    # Killing the process rather than going through `stop_browser_session/1`: an
    # `on_exit` runs in a process of its own with no sandbox connection, and the
    # row it would settle is rolled back with the test anyway. What must not
    # survive is the Chrome.
    on_exit(fn ->
      case Tools.get_browser_session(task) do
        pid when is_pid(pid) -> GenServer.stop(pid, :normal, 10_000)
        nil -> :ok
      end

      File.rm_rf(task.scratch_path)
    end)

    %{task: task, page: "file://#{page}"}
  end

  test "drives a real browser and records what it launched", %{task: task, page: page} do
    assert {:ok, session} = Tools.start_browser_session(task)

    assert %Session{status: :running, os_pid: os_pid, debug_port: port, profile_path: profile} =
             Repo.get_by!(Session, task_id: task.id)

    assert is_integer(os_pid)
    assert is_integer(port)
    assert File.dir?(profile)

    assert {:ok, _navigated} = BrowserSession.call(session, "Page.navigate", %{url: page})

    eventually(fn ->
      assert {:ok, %{"result" => %{"value" => "Bill"}}} =
               BrowserSession.call(session, "Runtime.evaluate", %{expression: "document.title", returnByValue: true})
    end)
  end

  # The tab is a fixed size, so a check written for a narrow viewport means the
  # same thing on every machine.
  test "the tab is the size Rail asked for", %{task: task, page: page} do
    {:ok, session} = Tools.start_browser_session(task)
    {:ok, _navigated} = BrowserSession.call(session, "Page.navigate", %{url: page})

    assert {:ok, %{"result" => %{"value" => [1920, 1080]}}} =
             BrowserSession.call(session, "Runtime.evaluate", %{
               expression: "[innerWidth, innerHeight]",
               returnByValue: true
             })
  end

  test "asking twice gets the browser that is already open", %{task: task} do
    assert {:ok, session} = Tools.start_browser_session(task)
    assert {:ok, ^session} = Tools.start_browser_session(task)
  end

  # An agent that never reaches its last instruction still cannot leave a Chrome
  # holding a core, because stopping is not the agent's to remember.
  test "stopping takes the browser and its profile with it", %{task: task} do
    {:ok, _session} = Tools.start_browser_session(task)
    %Session{id: id, os_pid: os_pid, profile_path: profile} = Repo.get_by!(Session, task_id: task.id)

    assert :ok = Tools.stop_browser_session(task)

    eventually(fn ->
      refute Tools.os_process_alive?(os_pid)
      refute File.exists?(profile)
      assert %Session{status: :finished, finished_at: %DateTime{}} = Repo.get(Session, id)
    end)
  end

  # Where the tab is comes from Chrome rather than from the run's log: the log
  # says where a pass asked to go, which a redirect makes a different place.
  test "says where the tab went", %{task: task, page: page} do
    {:ok, session} = Tools.start_browser_session(task)
    {:ok, _navigated} = BrowserSession.call(session, "Page.navigate", %{url: page})

    eventually(fn ->
      assert BrowserSession.where(session) == page
      assert Tools.get_browser_url(task) == page
    end)
  end

  test "stopping a task that has no browser is fine", %{task: task} do
    assert :ok = Tools.stop_browser_session(task)
  end

  # A human who opens the QA panel mid-pass should see it happening rather than
  # read about it afterwards, and a browser that has already painted has a frame
  # to hand for the panel that has only just arrived.
  test "broadcasts what the tab is looking at", %{task: task, page: page} do
    Phoenix.PubSub.subscribe(Rail.PubSub, "browser:#{task.id}")

    {:ok, session} = Tools.start_browser_session(task)
    {:ok, _navigated} = BrowserSession.call(session, "Page.navigate", %{url: page})

    assert_receive {:browser_frame, task_id, data}, 10_000
    assert task_id == task.id
    assert {:ok, <<0xFF, 0xD8, _rest::binary>>} = Base.decode64(data)

    assert Tools.get_browser_frame(task)
  end

  # What a person doing QA would write down, and nothing else. Sent straight at
  # the session because a page cannot be asked to throw, log, 404 and crash on
  # command - and what matters here is which of those are kept and how they read.
  test "keeps what the browser complains about and drops the rest", %{task: task} do
    {:ok, session} = Tools.start_browser_session(task)

    events = [
      {"Runtime.exceptionThrown", %{"exceptionDetails" => %{"text" => "x is not a function", "url" => "/bills/new"}}},
      {"Runtime.exceptionThrown", %{"exceptionDetails" => %{}}},
      {"Runtime.consoleAPICalled",
       %{
         "type" => "error",
         "args" => [%{"value" => "total is"}, %{"description" => "Error: nope"}, %{"type" => "object"}]
       }},
      {"Runtime.consoleAPICalled", %{"type" => "log", "args" => [%{"value" => "just chatter"}]}},
      {"Log.entryAdded", %{"entry" => %{"level" => "error", "text" => "mixed content", "url" => "/bills"}}},
      {"Log.entryAdded", %{"entry" => %{"level" => "info", "text" => "hello"}}},
      {"Network.responseReceived", %{"response" => %{"status" => 500, "statusText" => "Server Error", "url" => "/api"}}},
      {"Network.responseReceived", %{"response" => %{"status" => 200, "statusText" => "OK", "url" => "/api"}}},
      {"Network.loadingFailed", %{"errorText" => "net::ERR_FAILED", "type" => "Image"}},
      {"Inspector.targetCrashed", %{}},
      {"Page.frameNavigated", %{}}
    ]

    for {method, params} <- events, do: send(session, {:cdp_event, method, params})

    # Not an event at all, which is most of what a long-lived process is sent.
    send(session, :tick)

    assert [exception, unnamed, console, log, response, failed, crash] = BrowserSession.drain_problems(session)

    assert %{kind: :exception, detail: "x is not a function", url: "/bills/new"} = exception
    assert %{kind: :exception, detail: "Uncaught exception"} = unnamed
    assert %{kind: :console, detail: ~s(total is Error: nope "object")} = console
    assert %{kind: :log, detail: "mixed content", url: "/bills"} = log
    assert %{kind: :response, detail: "500 Server Error", url: "/api"} = response
    assert %{kind: :response, detail: "net::ERR_FAILED", url: "Image"} = failed
    assert %{kind: :crash, detail: "The page crashed."} = crash

    assert BrowserSession.drain_problems(session) == []
  end

  # A session answering calls against a Chrome that is not there is worse than no
  # session, so the connection going down takes it with it. The connection is
  # found through the link rather than exposed, because nothing outside the
  # session has any business holding it.
  test "the session goes when its connection does", %{task: task} do
    {:ok, session} = Tools.start_browser_session(task)

    {:links, links} = Process.info(session, :links)

    connection =
      links
      |> Enum.filter(&is_pid/1)
      |> Enum.find(fn pid ->
        {:dictionary, dictionary} = Process.info(pid, :dictionary)

        dictionary[:"$initial_call"] == {Browser, :init, 1}
      end)

    reference = Process.monitor(session)
    GenServer.stop(connection, :shutdown)

    assert_receive {:DOWN, ^reference, :process, ^session, {:browser_gone, :shutdown}}, 10_000
  end

  # A browser that never started is a session nobody can drive, and the row it
  # wrote on the way in has to be settled or the task never gets another.
  test "a browser that will not start leaves nothing live behind", %{task: task} do
    set_mimic_global()
    stub(Tools, :spawn_os_process, fn _executable, _args, _opts -> {:error, :enoent} end)

    assert {:error, {:browser_unavailable, :enoent}} = Tools.start_browser_session(task)

    assert %Session{status: :finished, finished_at: %DateTime{}} = Repo.get_by!(Session, task_id: task.id)
    assert Tools.get_browser_session(task) == nil
  end

  # Chrome's log is the only account of why it never answered, and a CI runner
  # discards the profile it is written in.
  test "a browser that never answers says what Chrome logged", %{task: task} do
    set_mimic_global()
    stub(Tools, :terminate_os_process, fn _os_pid, _opts -> :ok end)

    stub(Tools, :spawn_os_process, fn _executable, _args, opts ->
      File.write!(opts[:stdout_path], "starting\nNo usable sandbox!\n")
      {:ok, nil, System.unique_integer([:positive])}
    end)

    assert {:error, {:browser_unavailable, {:devtools_never_answered, "starting\nNo usable sandbox!"}}} =
             Tools.start_browser_session(task, ready_timeout_ms: 200)
  end

  # Chrome now and then hangs before it listens, so a hung one is killed with its
  # children and started once more before the session gives up.
  test "a browser that hangs on its way up is killed and started again", %{task: task} do
    set_mimic_global()
    test_pid = self()

    stub(Tools, :spawn_os_process, fn _executable, _args, _opts ->
      os_pid = System.unique_integer([:positive])
      send(test_pid, {:spawned, os_pid})
      {:ok, nil, os_pid}
    end)

    stub(Tools, :terminate_os_process, fn os_pid, opts -> send(test_pid, {:terminated, os_pid, opts}) && :ok end)

    assert {:error, {:browser_unavailable, {:devtools_never_answered, _log}}} =
             Tools.start_browser_session(task, ready_timeout_ms: 200)

    assert_received {:spawned, first}
    assert_received {:terminated, ^first, [group: true]}
    assert_received {:spawned, second}
    assert_received {:terminated, ^second, [group: true]}
    refute_received {:spawned, _third}
  end

  test "a browser that never answers or logs says the log is missing", %{task: task} do
    set_mimic_global()
    stub(Tools, :terminate_os_process, fn _os_pid, _opts -> :ok end)
    stub(Tools, :spawn_os_process, fn _executable, _args, _opts -> {:ok, nil, System.unique_integer([:positive])} end)

    assert {:error, {:browser_unavailable, {:devtools_never_answered, "chrome.log unreadable: enoent"}}} =
             Tools.start_browser_session(task, ready_timeout_ms: 200)
  end

  # The snapshot is what every decision is made from, so it has to survive a real
  # page rather than only a fixture.
  test "reads the page into an indexed table of what can be done to it", %{task: task, page: page} do
    {:ok, session} = Tools.start_browser_session(task)
    {:ok, _navigated} = BrowserSession.call(session, "Page.navigate", %{url: page})

    snapshot = File.read!(Application.app_dir(:rail, "priv/browser/snapshot.js"))

    # A document still navigating reads as nothing, so the snapshot is asked for
    # until the page it is a snapshot of is there.
    state =
      eventually(fn ->
        assert {:ok, %{"result" => %{"value" => %{"actions" => [_first | _rest]} = state}}} =
                 BrowserSession.call(session, "Runtime.evaluate", %{expression: snapshot, returnByValue: true})

        state
      end)

    labels = Enum.map(state["actions"], & &1["label"])

    assert "Amount" in labels
    assert "Save" in labels
    assert state["title"] == "Bill"
  end
end
