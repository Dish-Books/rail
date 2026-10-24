defmodule Rail.Mcp.Actions.CallRunToolBrowserTest do
  use Rail.DataCase, async: false

  alias Rail.Issues
  alias Rail.Mcp
  alias Rail.Mcp.RunContext
  alias Rail.Pipeline
  alias Rail.Roles
  alias Rail.Roles.Schemas.Role
  alias Rail.Tools
  alias Rail.Tools.BrowserSession
  alias Rail.Tools.Schemas.OsProcess

  # The half of `call_run_tool/3` that Rail answers itself; the proxied half is in
  # `call_run_tool_test.exs`. The browser is stubbed at the session: Chrome itself
  # is `BrowserSessionTest`'s.

  setup %{project: project} do
    scope = system_scope()

    roles =
      Map.new([:qa, :review], fn stage ->
        {:ok, role} = Roles.get_role(project_id: project.id, stage: stage)

        {stage, role}
      end)

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{
              "id" => "lin_qat_#{System.unique_integer([:positive])}",
              "identifier" => "QAT-1",
              "title" => "Qa Tools"
            }
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(scope, project, %{description: "Qa Tools"})
    {:ok, task} = Pipeline.create_task(issue, :review)
    File.mkdir_p!(task.scratch_path)

    stub(Tools, :start_browser_session, fn _task, _name, _opts -> {:ok, self()} end)

    stub(BrowserSession, :details, fn _session ->
      %{
        page_url: "ws://127.0.0.1:9333/devtools/page/TAB1",
        target_id: "TAB1",
        browser_context_id: "CTX1",
        signed_in?: true,
        account: nil
      }
    end)

    stub(BrowserSession, :drain_problems, fn _session -> [] end)

    # Rail's Learnings with nothing to review, as headless Chrome photographs it: sparse but not blank.
    empty_list = File.read!("test/support/fixtures/empty_list_page.png")
    viewport = %{"pageX" => 0, "pageY" => 0, "clientWidth" => 1920, "clientHeight" => 1080, "scale" => 1}

    stub(BrowserSession, :call, fn
      _session, "Page.getLayoutMetrics", _params -> {:ok, %{"cssVisualViewport" => viewport}}
      _session, "Page.captureScreenshot", %{format: "png"} -> {:ok, %{"data" => Base.encode64(empty_list)}}
      _session, _method, _params -> {:ok, %{"data" => Base.encode64("jpeg bytes")}}
    end)

    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: roles[:qa].id,
        status: :running,
        started_at: DateTime.utc_now()
      })

    {:ok, os_process} =
      %OsProcess{}
      |> OsProcess.changeset(%{
        run_id: run.id,
        task_id: task.id,
        role_id: roles[:qa].id,
        os_pid: 1234,
        stream_path: Path.join(task.scratch_path, "stream.ndjson"),
        status: :running,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert()

    context = %RunContext{os_process: os_process, role: roles[:qa], user: nil}

    on_exit(fn ->
      Tools.stop_browser_recording(task)
      File.rm_rf(task.scratch_path)
    end)

    %{task: task, run: run, context: context, roles: roles}
  end

  # Knowing the name is not the same as being allowed to call it: a code reviewer has no browser.
  test "another role cannot call one by knowing its name", %{context: context, roles: roles} do
    reviewing = %{context | role: roles[:review]}

    assert {:error, :unknown_tool} = Mcp.call_run_tool(reviewing, "browser_connect", %{})
  end

  # Rehearsing is driving the application without filming it, which is the whole
  # of what `demo_start` buys: the camera is off until the agent says otherwise.
  test "a run is not filmed until it starts a take", %{context: context, task: task} do
    assert {:ok, _rehearsed} = Mcp.call_run_tool(context, "browser_connect", %{"browser" => "demo"})
    refute Tools.get_browser_recording(task)

    assert {:ok, %{"content" => [%{"text" => rolling}]}} =
             Mcp.call_run_tool(%{context | role: %Role{stage: :demo}}, "demo_start", %{"browser" => "demo"})

    assert rolling =~ "Recording."

    assert is_pid(Tools.get_browser_recording(task))
  end

  # A walkthrough that went wrong costs a retake rather than a bad video, so the
  # beats of the take being replaced go with its frames.
  test "another take discards the one before it", %{context: context, task: task} do
    captions = Path.join([task.scratch_path, "demo", "captions.jsonl"])

    {:ok, _rolling} = Mcp.call_run_tool(%{context | role: %Role{stage: :demo}}, "demo_start", %{"browser" => "demo"})

    {:ok, _said} =
      Mcp.call_run_tool(%{context | role: %Role{stage: :demo}}, "demo_say", %{"text" => "A take that went wrong"})

    assert File.exists?(captions)

    {:ok, _again} = Mcp.call_run_tool(%{context | role: %Role{stage: :demo}}, "demo_start", %{"browser" => "demo"})

    refute File.exists?(captions)
  end

  test "a caption is filed under the demo and says when it landed", %{context: context, task: task} do
    {:ok, _rolling} = Mcp.call_run_tool(%{context | role: %Role{stage: :demo}}, "demo_start", %{"browser" => "demo"})

    assert {:ok, %{"content" => [%{"text" => said}]}} =
             Mcp.call_run_tool(%{context | role: %Role{stage: :demo}}, "demo_say", %{
               "text" => "Entering a bill for Sysco"
             })

    assert said =~ "Said at 0:00"

    assert [%{"text" => "Entering a bill for Sysco"}] =
             [task.scratch_path, "demo", "captions.jsonl"]
             |> Path.join()
             |> File.read!()
             |> String.split("\n", trim: true)
             |> Enum.map(&Jason.decode!/1)
  end

  # What a caption said and when it landed is what a person reading the log back
  # wants; the receipt the agent read is not.
  test "the log carries the caption and the moment it landed", %{context: context, run: run} do
    {:ok, _rolling} = Mcp.call_run_tool(%{context | role: %Role{stage: :demo}}, "demo_start", %{"browser" => "demo"})

    {:ok, _said} =
      Mcp.call_run_tool(%{context | role: %Role{stage: :demo}}, "demo_say", %{"text" => "Entering a bill for Sysco"})

    # A caption with no words is still a call somebody has to see having happened.
    {:error, {:refused, _nothing}} = Mcp.call_run_tool(%{context | role: %Role{stage: :demo}}, "demo_say", %{})

    log = run |> Pipeline.list_run_events() |> Enum.map_join("\n", & &1.line)

    assert log =~ ~s([demo] 0:00 say "Entering a bill for Sysco")
    assert log =~ "[demo] say · refused"
  end

  test "a cut is written to the take and the log says when it landed", %{context: context, task: task, run: run} do
    {:error, {:refused, _not_recording}} = Mcp.call_run_tool(%{context | role: %Role{stage: :demo}}, "demo_cut", %{})
    {:ok, _rolling} = Mcp.call_run_tool(%{context | role: %Role{stage: :demo}}, "demo_start", %{"browser" => "demo"})

    assert {:ok, %{"content" => [%{"text" => "Cut at 0:00." <> _left_out}]}} =
             Mcp.call_run_tool(%{context | role: %Role{stage: :demo}}, "demo_cut", %{})

    assert File.exists?(Path.join([task.scratch_path, "demo", "cuts.jsonl"]))

    log = run |> Pipeline.list_run_events() |> Enum.map_join("\n", & &1.line)

    assert log =~ "[demo] cut · refused"
    assert log =~ "[demo] cut at 0:00"
  end

  # The checklist is written before anything is opened, so neither of these costs
  # a browser.
  test "planning and marking off happen without a browser", %{context: context, task: task, run: run} do
    reject(Tools, :start_browser_session, 3)

    assert {:ok, %{"content" => [%{"text" => planned}]}} =
             Mcp.call_run_tool(context, "qa_plan", %{
               "checks" => [
                 %{"key" => "bill-saves", "title" => "A bill saves", "outcome" => "pass"},
                 %{"key" => "totals", "title" => "The totals agree"}
               ]
             })

    assert planned =~ "2 checks"

    # An outcome smuggled into the plan is not a check anybody ran.
    assert {:ok, %{checks: [%{outcome: :pending}, %{outcome: :pending}]}} = Pipeline.read_qa_checklist(task)

    assert {:ok, %{"content" => [%{"text" => "totals: Passed."}]}} =
             Mcp.call_run_tool(context, "qa_check", %{"key" => "totals", "outcome" => "pass", "note" => "to the cent"})

    assert {:ok, %{checks: [_bill, %{key: "totals", outcome: :pass, note: "to the cent"}]}} =
             Pipeline.read_qa_checklist(task)

    log = run |> Pipeline.list_run_events() |> Enum.map_join("\n", & &1.line)

    assert log =~ "[qa] plan 2 checks"
    assert log =~ ~s([qa] check "totals" pass)
  end

  # Each is the agent's to put right on the next call, so each comes back refused
  # with the reason, the plan's naming the row that was wrong.
  test "a plan or a mark Rail cannot use is refused with the reason", %{context: context} do
    assert {:error, {:refused, marked}} =
             Mcp.call_run_tool(context, "qa_check", %{"key" => "totals", "outcome" => "pass"})

    assert marked =~ "no checklist yet"

    assert {:error, {:refused, "Refused, nothing saved. checks 2 key: is required."}} =
             Mcp.call_run_tool(context, "qa_plan", %{
               "checks" => [%{"key" => "one", "title" => "A bill saves"}, %{"title" => "no key on this one"}]
             })

    assert {:error, {:refused, "qa_plan needs a `checks` list. Nothing was written."}} =
             Mcp.call_run_tool(context, "qa_plan", %{})

    {:ok, _planned} = Mcp.call_run_tool(context, "qa_plan", %{"checks" => [%{"key" => "one", "title" => "A bill saves"}]})

    assert {:error, {:refused, unknown}} = Mcp.call_run_tool(context, "qa_check", %{"key" => "two", "outcome" => "pass"})
    assert unknown =~ ~s(No check called "two")

    assert {:error, {:refused, outcome}} =
             Mcp.call_run_tool(context, "qa_check", %{"key" => "one", "outcome" => "probably"})

    assert outcome =~ "`pass`, `fail` or `skipped`"
  end

  # Logged once it has answered, so a refused shot never reads as a picture taken.
  test "a shot with no name is refused rather than raised, and logged as refused", %{context: context, run: run} do
    reject(Tools, :start_browser_session, 3)

    assert {:error, {:refused, "qa_shot needs a `name`" <> _rest}} =
             Mcp.call_run_tool(context, "qa_shot", %{"check" => "totals"})

    assert {:error, {:refused, _numbered}} = Mcp.call_run_tool(context, "qa_shot", %{"name" => 42})

    assert ["[qa] shot · refused", "[qa] shot · refused"] = Enum.map(Pipeline.list_run_events(run), & &1.line)
  end

  # The agent drives the tab itself, so what it is handed is the tab's address
  # and a driver at a path its sandbox can see.
  test "connecting opens the tab without being asked and hands over the driver", %{context: context, task: task, run: run} do
    expect(Tools, :start_browser_session, fn started, "explorer-1", _opts ->
      assert started.id == task.id
      {:ok, self()}
    end)

    assert {:ok, %{"content" => [%{"text" => text}]}} =
             Mcp.call_run_tool(context, "browser_connect", %{"browser" => "explorer-1"})

    driver = Path.join([task.scratch_path, "browser", "driver.mjs"])

    assert text =~ "Your tab: ws://127.0.0.1:9333/devtools/page/TAB1"
    assert text =~ "Driver: #{driver}"
    assert text =~ "openBrowser('ws://127.0.0.1:9333/devtools/page/TAB1')"
    assert File.read!(driver) =~ "export async function openBrowser"

    assert run |> Pipeline.list_run_events() |> Enum.map_join("\n", & &1.line) =~ "[browser] connect"
  end

  # An agent driving two browsers asks about the one it names.
  test "a browser tool acts on the browser it names", %{context: context} do
    expect(Tools, :start_browser_session, 2, fn _task, "explorer 2", opts ->
      assert opts[:existing]
      {:ok, self()}
    end)

    assert {:ok, _drained} = Mcp.call_run_tool(context, "browser_problems", %{"browser" => "explorer 2"})
    assert {:ok, _filed} = Mcp.call_run_tool(context, "qa_shot", %{"name" => "Signed in", "browser" => "explorer 2"})

    assert {:error, {:refused, "`browser` is a name" <> _rest}} =
             Mcp.call_run_tool(context, "qa_shot", %{"name" => "Signed in", "browser" => "../x"})
  end

  # Each agent that drives the app has a browser and an account of its own, so a name Rail will not key a
  # browser by opens none.
  test "a browser name Rail will not take is refused and opens none", %{context: context, task: task} do
    reject(Tools, :start_browser_session, 3)

    assert {:error, {:refused, "`browser` is a name" <> _rest}} =
             Mcp.call_run_tool(context, "browser_connect", %{"browser" => "a/b"})

    refute Tools.get_browser_recording(task)
  end

  # A name nobody connected is a slip, and a blank picture or a clean drain from a
  # browser nobody drove would read as evidence.
  test "a browser tool refuses a name browser_connect never opened", %{context: context, task: task} do
    stub(Tools, :start_browser_session, fn _task, _name, [{:existing, true} | _opts] -> {:error, :no_browser} end)

    assert {:error, {:refused, "No browser named `Explorer 1` on this task. Call browser_connect with that name first."}} =
             Mcp.call_run_tool(context, "qa_shot", %{
               "check" => "invoice-list",
               "name" => "Invoice list",
               "browser" => "Explorer 1"
             })

    assert {:error, {:refused, "No browser named `typo` on this task." <> _rest}} =
             Mcp.call_run_tool(context, "browser_problems", %{"browser" => "typo"})

    refute File.exists?(Path.join([task.scratch_path, "qa", "shots"]))

    assert {:error, {:refused, "No browser named `Demo` on this task." <> _rest}} =
             Mcp.call_run_tool(%{context | role: %Role{stage: :demo}}, "demo_start", %{"browser" => "Demo"})

    refute Tools.get_browser_recording(task)
  end

  # Chrome restarted under a running pass. A blank tab would read as the app having signed the
  # explorer out, so the tool says what happened and what to do about it.
  test "a browser tool says when Chrome restarted under the browser it names", %{context: context} do
    stub(Tools, :start_browser_session, fn _task, _name, [{:existing, true} | _opts] -> {:error, :browser_restarted} end)

    assert {:error, {:refused, said}} = Mcp.call_run_tool(context, "browser_problems", %{"browser" => "explorer-1"})

    assert said =~ "Chrome restarted and the browser `explorer-1` went with it"
    assert said =~ "Call browser_connect with that name"
  end

  test "a take of a browser the agent named and connected films it", %{context: context, task: task} do
    expect(Tools, :start_browser_session, fn _task, "signup", [{:existing, true} | _opts] -> {:ok, self()} end)

    assert {:ok, %{"content" => [%{"text" => "Recording." <> _rest}]}} =
             Mcp.call_run_tool(%{context | role: %Role{stage: :demo}}, "demo_start", %{"browser" => "signup"})

    assert is_pid(Tools.get_browser_recording(task))
  end

  # Rail names the file, so nothing arriving from a model becomes a path, and the picture comes back with
  # the reply, so the agent checks it without a second call to read the file.
  test "a screenshot is described rather than located, and attached", %{context: context, task: task} do
    assert {:ok,
            %{
              "content" => [
                %{"type" => "text", "text" => "Saved as shots/the-bill-total-as-rendered-" <> _rest},
                %{"type" => "image", "mimeType" => "image/jpeg", "data" => data}
              ]
            }} =
             Mcp.call_run_tool(context, "qa_shot", %{"name" => "The bill total as rendered", "browser" => "explorer-1"})

    assert {:ok, _jpeg} = Base.decode64(data)
    assert [_saved] = Path.wildcard(Path.join([task.scratch_path, "qa", "shots", "the-bill-total-as-rendered-*.jpg"]))
  end

  test "the browser's own complaints are drained, not accumulated", %{context: context} do
    expect(BrowserSession, :drain_problems, fn _session -> [%{kind: :console, detail: "total is unrounded"}] end)

    assert {:ok, %{"content" => [%{"text" => "[console] total is unrounded"}]}} =
             Mcp.call_run_tool(context, "browser_problems", %{"browser" => "explorer-1"})

    assert {:ok, %{"content" => [%{"text" => "Nothing since the last check."}]}} =
             Mcp.call_run_tool(context, "browser_problems", %{"browser" => "explorer-1"})
  end

  # An explorer done with its browser gives its place to the next one waiting, and the log says so.
  test "an agent closes the browser it is done with", %{context: context, task: task} do
    expect(Tools, :list_browser_sessions, fn %{id: id} when id == task.id ->
      [%Tools.Schemas.BrowserSession{name: "explorer-1"}]
    end)

    expect(Tools, :stop_browser_session, fn %{id: id}, "explorer-1" when id == task.id -> :ok end)

    assert {:ok, %{"content" => [%{"text" => "Closed `explorer-1`." <> _rest}]}} =
             Mcp.call_run_tool(context, "browser_close", %{"browser" => "explorer-1"})
  end

  # A request that failed says which one, because "something 404'd" is not a
  # finding anybody can act on.
  test "a problem that happened somewhere says where", %{context: context} do
    expect(BrowserSession, :drain_problems, fn _session ->
      [%{kind: :response, detail: "404 Not Found", url: "file:///nowhere-at-all.png"}]
    end)

    assert {:ok, %{"content" => [%{"text" => "[response] 404 Not Found (file:///nowhere-at-all.png)"}]}} =
             Mcp.call_run_tool(context, "browser_problems", %{"browser" => "explorer-1"})
  end

  # Called outside a pass - which is every call made while testing this - there
  # is no run to write to and nothing to write about.
  test "a call with no run behind it writes nothing and still answers", %{roles: roles, task: task} do
    context = %RunContext{os_process: %OsProcess{task_id: task.id}, role: roles[:qa], user: nil}

    assert {:ok, %{"content" => [%{"text" => text}]}} =
             Mcp.call_run_tool(context, "qa_plan", %{"checks" => [%{"key" => "one", "title" => "A bill saves"}]})

    assert text =~ "1 checks"
  end

  test "a call with no task behind it is Rail's failure", %{roles: roles} do
    assert {:error, {:rail_failed, :no_task}} =
             Mcp.call_run_tool(
               %RunContext{os_process: %OsProcess{}, role: roles[:qa], user: nil},
               "browser_connect",
               %{}
             )

    assert {:error, {:rail_failed, :no_task}} =
             Mcp.call_run_tool(
               %RunContext{os_process: %OsProcess{task_id: "tsk_gone"}, role: roles[:qa], user: nil},
               "browser_connect",
               %{}
             )
  end

  # A name Rail does not serve is forwarded, and there is no server by that name
  # either.
  test "a name Rail does not serve is refused", %{context: context} do
    assert {:error, :unknown_tool} = Mcp.call_run_tool(context, "qa_invented", %{})
  end

  # Whatever went wrong down there is Rail's, not something a different
  # instruction would fix, and it says so rather than reading as a refusal.
  test "a browser that will not open is Rail's failure, not advice", %{context: context} do
    stub(Tools, :start_browser_session, fn _task, _name, _opts -> {:error, {:browser_unavailable, :chrome_not_found}} end)

    assert {:error, {:rail_failed, {:browser_unavailable, :chrome_not_found}}} =
             Mcp.call_run_tool(context, "browser_connect", %{"browser" => "explorer-1"})

    assert {:error, {:rail_failed, {:browser_unavailable, :chrome_not_found}}} =
             Mcp.call_run_tool(context, "browser_problems", %{"browser" => "explorer-1"})
  end
end
