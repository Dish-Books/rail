defmodule Rail.Tools.BrowserSessionTest do
  use Rail.DataCase, async: false

  import Ecto.Query
  import Rail.Tools.Utils.EnsureBrowserHost

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Tools
  alias Rail.Tools.Browser
  alias Rail.Tools.BrowserSession
  alias Rail.Tools.Schemas.BrowserSession, as: Session

  # Serial, because each test drives a real Chrome and a machine running thirty at
  # once measures contention rather than the browser.
  @moduletag :browser

  # A fresh machine's first Chrome builds its font cache and profile, which can outlast what a
  # session waits for one to answer. Started here once, so no test pays for it.
  setup_all do
    {:ok, _host} = ensure_browser_host(ready_timeout_ms: 60_000)
    :ok
  end

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
      case Tools.get_browser_session(task, "qa") do
        pid when is_pid(pid) -> GenServer.stop(pid, :normal, 10_000)
        nil -> :ok
      end

      File.rm_rf(task.scratch_path)
    end)

    %{task: task, page: "file://#{page}", project: project}
  end

  test "drives a tab in the shared Chrome and records where it is", %{task: task, page: page} do
    assert {:ok, session} = Tools.start_browser_session(task, "qa")

    assert %Session{status: :running, debug_port: port, browser_context_id: context, target_id: target} =
             Repo.get_by!(Session, task_id: task.id)

    assert is_integer(port)
    assert context =~ ~r/^[0-9A-F]{32}$/
    page_url = "ws://127.0.0.1:#{port}/devtools/page/#{target}"
    assert %{page_url: ^page_url, browser_context_id: ^context} = BrowserSession.details(session)

    assert {:ok, _navigated} = BrowserSession.call(session, "Page.navigate", %{url: page})

    eventually(fn ->
      assert {:ok, %{"result" => %{"value" => "Bill"}}} =
               BrowserSession.call(session, "Runtime.evaluate", %{expression: "document.title", returnByValue: true})
    end)
  end

  # The tab is a fixed size, so a check written for a narrow viewport means the
  # same thing on every machine.
  test "the tab is the size Rail asked for", %{task: task, page: page} do
    {:ok, session} = Tools.start_browser_session(task, "qa")
    {:ok, _navigated} = BrowserSession.call(session, "Page.navigate", %{url: page})

    assert {:ok, %{"result" => %{"value" => [1920, 1080]}}} =
             BrowserSession.call(session, "Runtime.evaluate", %{
               expression: "[innerWidth, innerHeight]",
               returnByValue: true
             })
  end

  # The agent drives the tab over a connection of its own, and Chrome forgets the
  # viewport a connection set when that connection goes. What is left has to be
  # the tab's own size, or the panel shows the corner of a page laid out wider.
  test "the tab stays the size Rail asked for after the agent's connection resizes it and goes", %{
    task: task,
    page: page
  } do
    {:ok, session} = Tools.start_browser_session(task, "qa")
    {:ok, _navigated} = BrowserSession.call(session, "Page.navigate", %{url: page})
    %{page_url: page_url} = BrowserSession.details(session)

    {:ok, agent} = Browser.start_link(url: page_url)
    narrow = %{width: 390, height: 844, deviceScaleFactor: 1, mobile: true}
    {:ok, _narrow} = Browser.call(agent, "Emulation.setDeviceMetricsOverride", narrow)
    wide = %{width: 1920, height: 1080, deviceScaleFactor: 1, mobile: false}
    {:ok, _wide} = Browser.call(agent, "Emulation.setDeviceMetricsOverride", wide)
    :ok = GenServer.stop(agent, :normal)

    eventually(fn ->
      assert {:ok, %{"cssVisualViewport" => %{"clientWidth" => 1920, "clientHeight" => 1080}}} =
               BrowserSession.call(session, "Page.getLayoutMetrics")
    end)
  end

  test "asking twice gets the tab that is already open", %{task: task} do
    assert {:ok, session} = Tools.start_browser_session(task, "qa")
    assert {:ok, ^session} = Tools.start_browser_session(task, "qa")
  end

  # One Chrome between them, and nothing signed into one task's app is visible
  # to another's.
  test "two tasks share one Chrome and nothing else", %{task: task, project: project} do
    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_brs_other", "identifier" => "BRS-2", "title" => "Other"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{description: "Other"})
    {:ok, other} = Pipeline.create_task(issue, :qa)

    on_exit(fn ->
      case Tools.get_browser_session(other, "qa") do
        pid when is_pid(pid) -> GenServer.stop(pid, :normal, 10_000)
        nil -> :ok
      end
    end)

    {:ok, _mine} = Tools.start_browser_session(task, "qa")
    {:ok, _theirs} = Tools.start_browser_session(other, "qa")

    mine = Repo.get_by!(Session, task_id: task.id)
    theirs = Repo.get_by!(Session, task_id: other.id)

    assert mine.debug_port == theirs.debug_port
    assert mine.browser_context_id != theirs.browser_context_id
  end

  # Two agents on one task each drive a context of their own, signed into its own
  # account, and each browser's frames go only to whoever watches that name.
  test "two names on one task get two contexts and two frame streams", %{task: task, page: page} do
    on_exit(fn ->
      case Tools.get_browser_session(task, "explorer 2") do
        pid when is_pid(pid) -> GenServer.stop(pid, :normal, 10_000)
        nil -> :ok
      end
    end)

    Phoenix.PubSub.subscribe(Rail.PubSub, "browser:#{task.id}:explorer 2")

    {:ok, qa} = Tools.start_browser_session(task, "qa")
    {:ok, explorer} = Tools.start_browser_session(task, "explorer 2")

    assert qa != explorer
    assert Tools.get_browser_session(task, "explorer 2") == explorer

    assert [%Session{name: "explorer 2", browser_context_id: theirs}, %Session{name: "qa", browser_context_id: mine}] =
             Repo.all(from s in Session, where: s.task_id == ^task.id, order_by: s.name)

    assert mine != theirs

    {:ok, _navigated} = BrowserSession.call(explorer, "Page.navigate", %{url: page})
    assert_receive {:browser_frame, _task_id, _data}, 10_000

    eventually(fn -> assert Tools.get_browser_url(task, "explorer 2") == page end)
    assert Tools.get_browser_url(task, "qa") in [nil, "about:blank"]
  end

  # Who a tab was signed in as belongs to the tab, so a deploy in the middle of a
  # pass comes back to the same account rather than signing in another.
  test "a tab signed in keeps its account when Rail restarts", %{task: task, page: page} do
    {:ok, session} = Tools.start_browser_session(task, "qa")
    assert %{signed_in?: false, account: nil} = BrowserSession.details(session)

    assert :ok = BrowserSession.sign_in(session, page, "explorer-1@rail.test")
    eventually(fn -> assert BrowserSession.where(session) == page end)
    assert %Session{account: "explorer-1@rail.test"} = Repo.get_by!(Session, task_id: task.id)

    :ok = GenServer.stop(session, :shutdown, 10_000)

    {:ok, again} = Tools.start_browser_session(task, "qa")
    assert %{signed_in?: true, account: "explorer-1@rail.test"} = BrowserSession.details(again)
  end

  # A bare browser is signed in as nobody on purpose, and is not signed in again.
  test "a tab left bare is settled with nobody signed in", %{task: task} do
    {:ok, session} = Tools.start_browser_session(task, "qa")

    assert :ok = BrowserSession.sign_in(session, nil, nil)
    assert %{signed_in?: true, account: nil} = BrowserSession.details(session)
    assert Tools.get_browser_url(task, "qa") in [nil, "about:blank"]
  end

  test "a link Chrome will not open leaves the tab to sign in again", %{task: task} do
    {:ok, session} = Tools.start_browser_session(task, "qa")

    assert {:error, _refused} = BrowserSession.sign_in(session, "not a url", "a@rail.test")
    assert %{signed_in?: false} = BrowserSession.details(session)
  end

  # A tool naming a browser acts on one browser_connect opened. A slip in the name
  # opens nothing, and a tab Rail lost hold of across a restart is still found.
  test "asking only for a browser the task has opens nothing for a name it has none under", %{task: task} do
    assert {:error, :no_browser} = Tools.start_browser_session(task, "Explorer 1", existing: true)
    assert Repo.all(from s in Session, where: s.task_id == ^task.id) == []

    {:ok, session} = Tools.start_browser_session(task, "explorer 1")
    :ok = GenServer.stop(session, :shutdown, 10_000)

    assert {:ok, again} = Tools.start_browser_session(task, "explorer 1", existing: true)
    assert again != session
    assert [%Session{name: "explorer 1", status: :running}] = Repo.all(from s in Session, where: s.task_id == ^task.id)
  end

  # Two tool calls for a name nobody has opened yet both find nothing and both
  # insert. The one the index refuses finds the other's browser rather than crashing.
  test "callers starting one new name at once all get the same browser", %{task: task} do
    test = self()

    started =
      1..8
      |> Enum.map(fn _caller ->
        Task.async(fn ->
          Ecto.Adapters.SQL.Sandbox.allow(Repo, test, self())
          Tools.start_browser_session(task, "qa")
        end)
      end)
      |> Task.await_many(60_000)

    assert [{:ok, session}] = Enum.uniq(started)
    assert is_pid(session)
    assert [%Session{status: :running}] = Repo.all(from s in Session, where: s.task_id == ^task.id)
  end

  # Only the race on the live name is retried. A task deleted under a tool call
  # fails its foreign key every time, so it raises rather than looping.
  test "a task deleted under the call raises rather than retrying", %{task: task} do
    Repo.delete!(task)

    assert_raise CaseClauseError, fn -> Tools.start_browser_session(task, "qa") end
  end

  # Rail stopping is not the task being done with its browser: a deploy in the
  # middle of a pass comes back to the page the pass was on.
  test "a session that ends with Rail leaves its tab, and the next one attaches to it", %{task: task, page: page} do
    {:ok, session} = Tools.start_browser_session(task, "qa")
    {:ok, _navigated} = BrowserSession.call(session, "Page.navigate", %{url: page})
    eventually(fn -> assert BrowserSession.where(session) == page end)
    %Session{id: id, target_id: target} = Repo.get_by!(Session, task_id: task.id)

    :ok = GenServer.stop(session, :shutdown, 10_000)

    assert {:ok, again} = Tools.start_browser_session(task, "qa")
    assert again != session
    assert %Session{id: ^id, status: :running, target_id: ^target} = Repo.get_by!(Session, task_id: task.id)
    assert BrowserSession.where(again) == page
  end

  # Chrome restarted, or the context was closed from under the row. The row is
  # settled and the task gets a new tab rather than an error.
  test "a tab that is not there any more is replaced", %{task: task} do
    {:ok, session} = Tools.start_browser_session(task, "qa")
    %Session{id: id, browser_context_id: context, target_id: target} = Repo.get_by!(Session, task_id: task.id)
    :ok = GenServer.stop(session, :shutdown, 10_000)

    {:ok, %{url: url}} = ensure_browser_host(start: false)
    {:ok, connection} = Browser.start_link(url: url)
    {:ok, _closed} = Browser.call(connection, "Target.disposeBrowserContext", %{browserContextId: context})
    GenServer.stop(connection)

    assert {:ok, _fresh} = Tools.start_browser_session(task, "qa")

    assert %Session{status: :finished} = Repo.get!(Session, id)

    assert %Session{target_id: fresh} =
             Repo.one!(from s in Session, where: s.task_id == ^task.id and s.status == :running)

    assert fresh != target
  end

  # A row left `starting` never got as far as a tab, so there is nothing to
  # attach to - and it is still the one live row the task is allowed.
  test "a row that never got a tab is settled and a tab opened", %{task: task} do
    {:ok, %Session{id: stuck}} =
      %Session{}
      |> Session.changeset(%{task_id: task.id, name: "qa", status: :starting, started_at: DateTime.utc_now()})
      |> Repo.insert()

    assert {:ok, _session} = Tools.start_browser_session(task, "qa")

    assert %Session{status: :finished} = Repo.get!(Session, stuck)

    assert %Session{target_id: target} =
             Repo.one!(from s in Session, where: s.task_id == ^task.id and s.status == :running)

    assert byte_size(target) > 0
  end

  # A Chrome that cannot be started is no answer about whether the tab is still
  # there, so the row pointing at it is left for when it can be.
  test "a tab that cannot be reached for want of a browser keeps its row", %{task: task} do
    {:ok, %Session{id: id}} =
      %Session{}
      |> Session.changeset(%{task_id: task.id, name: "qa", status: :running, browser_context_id: "CTX", target_id: "TGT"})
      |> Repo.insert()

    set_mimic_global()
    root = Path.join(System.tmp_dir!(), "rail-no-browser-#{System.unique_integer([:positive])}")
    stub(Rail, :browser_root, fn -> root end)
    stub(Tools, :spawn_os_process, fn _executable, _args, _opts -> {:error, :enoent} end)

    assert {:error, {:browser_unavailable, :enoent}} = Tools.start_browser_session(task, "qa")
    assert %Session{status: :running} = Repo.get!(Session, id)
  end

  # An agent that never reaches its last instruction still cannot leave a tab
  # open, because stopping is not the agent's to remember.
  test "stopping closes the tab and its context", %{task: task} do
    {:ok, _session} = Tools.start_browser_session(task, "qa")
    %Session{id: id, target_id: target} = Repo.get_by!(Session, task_id: task.id)

    assert :ok = Tools.stop_browser_session(task)

    assert %Session{status: :finished, finished_at: %DateTime{}} = Repo.get(Session, id)
    assert Tools.get_browser_session(task, "qa") == nil

    {:ok, %{url: url}} = ensure_browser_host(start: false)
    {:ok, connection} = Browser.start_link(url: url)
    {:ok, %{"targetInfos" => targets}} = Browser.call(connection, "Target.getTargets", %{})
    GenServer.stop(connection)

    refute Enum.any?(targets, &(&1["targetId"] == target))
  end

  test "stopping closes every browser the task has, whatever its name", %{task: task} do
    {:ok, _qa} = Tools.start_browser_session(task, "qa")
    {:ok, explorer} = Tools.start_browser_session(task, "explorer 2")
    :ok = GenServer.stop(explorer, :shutdown, 10_000)

    assert :ok = Tools.stop_browser_session(task)

    assert [%Session{status: :finished}, %Session{status: :finished}] =
             Repo.all(from s in Session, where: s.task_id == ^task.id)

    assert Tools.get_browser_session(task, "qa") == nil
  end

  # Rail restarted since the tab was opened, so nothing holds it - and it is
  # still a tab to close.
  test "stopping closes a tab nothing is connected to", %{task: task} do
    {:ok, session} = Tools.start_browser_session(task, "qa")
    %Session{target_id: target} = Repo.get_by!(Session, task_id: task.id)
    :ok = GenServer.stop(session, :shutdown, 10_000)

    assert :ok = Tools.stop_browser_session(task)

    {:ok, %{url: url}} = ensure_browser_host(start: false)
    {:ok, connection} = Browser.start_link(url: url)
    {:ok, %{"targetInfos" => targets}} = Browser.call(connection, "Target.getTargets", %{})
    GenServer.stop(connection)

    refute Enum.any?(targets, &(&1["targetId"] == target))
  end

  # Where the tab is comes from Chrome rather than from the run's log: the log
  # says where a pass asked to go, which a redirect makes a different place.
  test "says where the tab went", %{task: task, page: page} do
    {:ok, session} = Tools.start_browser_session(task, "qa")
    {:ok, _navigated} = BrowserSession.call(session, "Page.navigate", %{url: page})

    eventually(fn ->
      assert BrowserSession.where(session) == page
      assert Tools.get_browser_url(task, "qa") == page
    end)
  end

  test "stopping a task that has no browser is fine", %{task: task} do
    assert :ok = Tools.stop_browser_session(task)
  end

  # A human who opens the QA panel mid-pass should see it happening rather than
  # read about it afterwards, and a browser that has already painted has a frame
  # to hand for the panel that has only just arrived.
  test "broadcasts what the tab is looking at", %{task: task, page: page} do
    Phoenix.PubSub.subscribe(Rail.PubSub, "browser:#{task.id}:qa")

    {:ok, session} = Tools.start_browser_session(task, "qa")
    {:ok, _navigated} = BrowserSession.call(session, "Page.navigate", %{url: page})

    assert_receive {:browser_frame, task_id, data}, 10_000
    assert task_id == task.id
    assert {:ok, <<0xFF, 0xD8, _rest::binary>>} = Base.decode64(data)

    assert Tools.get_browser_frame(task, "qa")
  end

  # Frames are taken at most about fifteen a second, so a paint that lands while
  # one is still being held back is never sent. A page that then holds still is
  # still the page the panel and the demo end on. Read back in the tab itself,
  # because Chrome is what can decode a JPEG.
  test "the last frame is the page as it settled, however quickly it got there", %{task: task} do
    page = Path.join(task.scratch_path, "settles.html")

    File.write!(page, """
    <!doctype html><body style="margin:0;background:rgb(255,0,0)"><script>
      setTimeout(() => {
        let shade = 0
        const flicker = setInterval(() => { document.body.style.background = `rgb(0,0,${++shade * 40})` }, 10)
        setTimeout(() => {
          clearInterval(flicker)
          document.body.style.background = 'rgb(0,160,0)'
          document.title = 'settled'
        }, 55)
      }, 1000)
    </script>
    """)

    Phoenix.PubSub.subscribe(Rail.PubSub, "browser:#{task.id}:qa")
    {:ok, session} = Tools.start_browser_session(task, "qa")
    {:ok, _navigated} = BrowserSession.call(session, "Page.navigate", %{url: "file://#{page}"})

    eventually(
      fn ->
        assert {:ok, %{"result" => %{"value" => "settled"}}} =
                 BrowserSession.call(session, "Runtime.evaluate", %{expression: "document.title", returnByValue: true})
      end,
      5_000
    )

    eventually(
      fn ->
        decode = """
        new Promise(resolve => {
          const image = new Image()
          image.onload = () => {
            const canvas = document.createElement('canvas')
            canvas.width = image.width
            canvas.height = image.height
            const context = canvas.getContext('2d')
            context.drawImage(image, 0, 0)
            resolve(Array.from(context.getImageData(image.width / 2, image.height / 2, 1, 1).data.slice(0, 3)))
          }
          image.src = 'data:image/jpeg;base64,#{Tools.get_browser_frame(task, "qa")}'
        })
        """

        assert {:ok, %{"result" => %{"value" => [red, green, blue]}}} =
                 BrowserSession.call(session, "Runtime.evaluate", %{
                   expression: decode,
                   awaitPromise: true,
                   returnByValue: true
                 })

        assert red < 40 and green > 120 and blue < 40
      end,
      3_000
    )
  end

  # A busy Chrome can sit on a screenshot for half a minute. The session asks for
  # one once the frames stop, and goes on answering everyone else while it waits -
  # a demo starting wants the frame it already has, not the one Chrome is taking.
  test "a screenshot Chrome is slow over holds nobody up", %{task: task, page: page} do
    set_mimic_global()
    test = self()

    Mimic.stub(Browser, :send_request, fn _connection, "Page.captureScreenshot", _params ->
      send(test, :photographing)
      make_ref()
    end)

    Phoenix.PubSub.subscribe(Rail.PubSub, "browser:#{task.id}:qa")
    {:ok, session} = Tools.start_browser_session(task, "qa")
    {:ok, _navigated} = BrowserSession.call(session, "Page.navigate", %{url: page})
    assert_receive :photographing, 10_000

    # Not the answer it is waiting for, which is most of what a session is sent.
    send(session, :tick)

    assert "" <> _frame = BrowserSession.last_frame(session)
    assert {:ok, _evaluated} = BrowserSession.call(session, "Runtime.evaluate", %{expression: "1"})
  end

  # A tab left open between passes is encoded for nobody: with nobody listening
  # Chrome's ack is held, so it stops, and no frame the page may since have moved
  # on from is offered. Somebody arriving gets the page as it is.
  test "a tab nobody is watching sends nothing until somebody is", %{task: task, page: page} do
    {:ok, session} = Tools.start_browser_session(task, "qa")
    {:ok, _navigated} = BrowserSession.call(session, "Page.navigate", %{url: page})

    eventually(fn -> assert %BrowserSession{holding?: true} = :sys.get_state(session) end, 10_000)
    assert BrowserSession.last_frame(session) == nil

    Phoenix.PubSub.subscribe(Rail.PubSub, "browser:#{task.id}:qa")
    assert_receive {:browser_frame, _task_id, _data}, 10_000

    # Chrome keeps two frames in flight, so the one received can be the second,
    # sent while the first ack was still held and before its next look found us.
    eventually(fn -> assert "" <> _frame = BrowserSession.last_frame(session) end)
  end

  # The tab closed from under the session between its last frame and the
  # photograph of how it settled. The frame it had is the frame it keeps.
  test "a tab that goes before it can be photographed keeps its last frame", %{task: task, page: page} do
    Phoenix.PubSub.subscribe(Rail.PubSub, "browser:#{task.id}:qa")
    {:ok, session} = Tools.start_browser_session(task, "qa")
    %Session{browser_context_id: context} = Repo.get_by!(Session, task_id: task.id)
    {:ok, _navigated} = BrowserSession.call(session, "Page.navigate", %{url: page})
    assert_receive {:browser_frame, _task_id, _data}, 10_000

    {:ok, %{url: url}} = ensure_browser_host(start: false)
    {:ok, connection} = Browser.start_link(url: url)
    {:ok, _closed} = Browser.call(connection, "Target.disposeBrowserContext", %{browserContextId: context})
    GenServer.stop(connection)

    Process.sleep(500)
    assert Process.alive?(session)
    assert Tools.get_browser_frame(task, "qa")
  end

  # What a person doing QA would write down, and nothing else. Sent straight at
  # the session because a page cannot be asked to throw, log, 404 and crash on
  # command - and what matters here is which of those are kept and how they read.
  test "keeps what the browser complains about and drops the rest", %{task: task} do
    {:ok, session} = Tools.start_browser_session(task, "qa")

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
    {:ok, session} = Tools.start_browser_session(task, "qa")

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
    root = Path.join(System.tmp_dir!(), "rail-no-browser-#{System.unique_integer([:positive])}")
    stub(Rail, :browser_root, fn -> root end)
    stub(Tools, :spawn_os_process, fn _executable, _args, _opts -> {:error, :enoent} end)

    assert {:error, {:browser_unavailable, :enoent}} = Tools.start_browser_session(task, "qa")

    assert %Session{status: :finished, finished_at: %DateTime{}} = Repo.get_by!(Session, task_id: task.id)
    assert Tools.get_browser_session(task, "qa") == nil
  end
end
