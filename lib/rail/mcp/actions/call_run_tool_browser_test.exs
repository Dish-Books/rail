defmodule Rail.Mcp.Actions.CallRunToolBrowserTest do
  use Rail.DataCase, async: false

  alias Rail.Issues
  alias Rail.Mcp
  alias Rail.Mcp.RunContext
  alias Rail.Pipeline
  alias Rail.Roles
  alias Rail.Tools
  alias Rail.Tools.BrowserSession
  alias Rail.Tools.Schemas.OsProcess

  # The half of `call_run_tool/3` that Rail answers itself; the proxied half is in
  # `call_run_tool_test.exs`. The browser is stubbed at the session: Chrome itself
  # is `BrowserSessionTest`'s.

  setup %{project: project} do
    scope = system_scope()

    roles =
      Map.new([:qa, :demo, :review], fn stage ->
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
    {:ok, task} = Pipeline.create_task(issue, :qa)
    File.mkdir_p!(task.scratch_path)

    stub(Tools, :start_browser_session, fn _task, _opts -> {:ok, self()} end)

    stub(BrowserSession, :details, fn _session ->
      %{page_url: "ws://127.0.0.1:9333/devtools/page/TAB1", target_id: "TAB1", browser_context_id: "CTX1"}
    end)

    stub(BrowserSession, :drain_problems, fn _session -> [] end)

    stub(BrowserSession, :call, fn
      _session, "Page.navigate", _params -> {:ok, %{"frameId" => "main"}}
      _session, "Page.captureScreenshot", _params -> {:ok, %{"data" => Base.encode64("jpeg bytes")}}
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

  # Knowing the name is not the same as being allowed to call it.
  test "another stage cannot call one by knowing its name", %{context: context, roles: roles} do
    reviewing = %{context | role: roles[:review]}

    assert {:error, :unknown_tool} = Mcp.call_run_tool(reviewing, "browser_connect", %{})
  end

  # Rehearsing is driving the application without filming it, which is the whole
  # of what `demo_start` buys: the camera is off until the agent says otherwise.
  test "a demo run is not filmed until it starts a take", %{context: context, task: task, roles: roles} do
    filming = %{context | role: roles[:demo]}

    assert {:ok, _rehearsed} = Mcp.call_run_tool(filming, "browser_connect", %{})
    refute Tools.get_browser_recording(task)

    assert {:ok, %{"content" => [%{"text" => rolling}]}} = Mcp.call_run_tool(filming, "demo_start", %{})
    assert rolling =~ "Recording."

    assert is_pid(Tools.get_browser_recording(task))
  end

  # A walkthrough that went wrong costs a retake rather than a bad video, so the
  # beats of the take being replaced go with its frames.
  test "another take discards the one before it", %{context: context, task: task, roles: roles} do
    filming = %{context | role: roles[:demo]}
    captions = Path.join([task.scratch_path, "demo", "captions.jsonl"])

    {:ok, _rolling} = Mcp.call_run_tool(filming, "demo_start", %{})
    {:ok, _said} = Mcp.call_run_tool(filming, "demo_say", %{"text" => "A take that went wrong"})
    assert File.exists?(captions)

    {:ok, _again} = Mcp.call_run_tool(filming, "demo_start", %{})

    refute File.exists?(captions)
  end

  test "a caption is filed under the demo and says when it landed", %{context: context, task: task, roles: roles} do
    filming = %{context | role: roles[:demo]}

    {:ok, _rolling} = Mcp.call_run_tool(filming, "demo_start", %{})

    assert {:ok, %{"content" => [%{"text" => said}]}} =
             Mcp.call_run_tool(filming, "demo_say", %{"text" => "Entering a bill for Sysco"})

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
  test "the log carries the caption and the moment it landed", %{context: context, roles: roles, run: run} do
    filming = %{context | role: roles[:demo]}

    {:ok, _rolling} = Mcp.call_run_tool(filming, "demo_start", %{})
    {:ok, _said} = Mcp.call_run_tool(filming, "demo_say", %{"text" => "Entering a bill for Sysco"})

    # A caption with no words is still a call somebody has to see having happened.
    {:error, {:refused, _nothing}} = Mcp.call_run_tool(filming, "demo_say", %{})

    log = run |> Pipeline.list_run_events() |> Enum.map_join("\n", & &1.line)

    assert log =~ ~s([demo] 0:00 say "Entering a bill for Sysco")
    assert log =~ "[demo] say · refused"
  end

  # The checklist is written before anything is opened, so neither of these costs
  # a browser.
  test "planning and marking off happen without a browser", %{context: context, task: task, run: run} do
    reject(Tools, :start_browser_session, 2)

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

  test "a shot with no name is refused rather than raised", %{context: context} do
    reject(Tools, :start_browser_session, 2)

    assert {:error, {:refused, "qa_shot needs a `name`" <> _rest}} =
             Mcp.call_run_tool(context, "qa_shot", %{"check" => "totals"})
  end

  # The agent drives the tab itself, so what it is handed is the tab's address
  # and a driver at a path its sandbox can see.
  test "connecting opens the tab without being asked and hands over the driver", %{context: context, task: task, run: run} do
    expect(Tools, :start_browser_session, fn started, _opts ->
      assert started.id == task.id
      {:ok, self()}
    end)

    assert {:ok, %{"content" => [%{"text" => text}]}} = Mcp.call_run_tool(context, "browser_connect", %{})

    driver = Path.join([task.scratch_path, "browser", "driver.mjs"])

    assert text =~ "Your tab: ws://127.0.0.1:9333/devtools/page/TAB1"
    assert text =~ "Driver: #{driver}"
    assert text =~ "openBrowser('ws://127.0.0.1:9333/devtools/page/TAB1')"
    assert File.read!(driver) =~ "export async function openBrowser"

    assert run |> Pipeline.list_run_events() |> Enum.map_join("\n", & &1.line) =~ "[browser] connect"
  end

  # Rail names the file, so nothing arriving from a model becomes a path.
  test "a screenshot is described rather than located", %{context: context, task: task} do
    assert {:ok, %{"content" => [%{"text" => text}]}} =
             Mcp.call_run_tool(context, "qa_shot", %{"name" => "The bill total as rendered"})

    assert text =~ "evidence/the-bill-total-as-rendered.jpg"
    # The name comes back, never the picture, so reading it is the agent's own
    # decision to make and its own context to spend.
    assert text =~ "read it only when a check turns on that"
    assert File.exists?(Path.join([task.scratch_path, "qa", "evidence", "the-bill-total-as-rendered.jpg"]))
  end

  # A change with nothing on screen is proved by what it writes, so filing that
  # costs no browser, and the line lands once there is a file for the panel to read.
  test "a file is filed against its check without a browser", %{context: context, task: task, run: run} do
    reject(Tools, :start_browser_session, 2)
    {:ok, _checklist} = Pipeline.write_qa_checklist(task, [%{"key" => "script-runs", "title" => "The script runs"}])
    File.mkdir_p!(Path.join([task.scratch_path, "qa", "evidence"]))
    File.write!(Path.join([task.scratch_path, "qa", "evidence", "run.log"]), "wrote 3 rows")

    assert {:ok, %{"content" => [%{"text" => text}]}} =
             Mcp.call_run_tool(context, "qa_file", %{
               "check" => "script-runs",
               "name" => "The script's log",
               "path" => "evidence/run.log"
             })

    assert text =~ "evidence/script-runs~the-script-s-log.log"
    assert File.exists?(Path.join([task.scratch_path, "qa", "evidence", "script-runs~the-script-s-log.log"]))

    # A refusal reads as one in the log, rather than as one more file filed.
    {:error, {:refused, _refused}} =
      Mcp.call_run_tool(context, "qa_file", %{"check" => "script-runs", "name" => "Stolen", "path" => "/etc/passwd"})

    {:error, {:refused, _usage}} = Mcp.call_run_tool(context, "qa_file", %{"check" => "script-runs", "name" => "No path"})

    log = run |> Pipeline.list_run_events() |> Enum.map_join("\n", & &1.line)

    assert log =~ ~s([qa] file "The script's log"\n)
    refute log =~ ~s([qa] file "The script's log" · nothing filed)
    assert log =~ ~s([qa] file "Stolen" · nothing filed)
    assert log =~ ~s([qa] file "No path" · nothing filed)
  end

  test "the browser's own complaints are drained, not accumulated", %{context: context} do
    expect(BrowserSession, :drain_problems, fn _session -> [%{kind: :console, detail: "total is unrounded"}] end)

    assert {:ok, %{"content" => [%{"text" => "[console] total is unrounded"}]}} =
             Mcp.call_run_tool(context, "browser_problems", %{})

    assert {:ok, %{"content" => [%{"text" => "Nothing since the last check."}]}} =
             Mcp.call_run_tool(context, "browser_problems", %{})
  end

  # A request that failed says which one, because "something 404'd" is not a
  # finding anybody can act on.
  test "a problem that happened somewhere says where", %{context: context} do
    expect(BrowserSession, :drain_problems, fn _session ->
      [%{kind: :response, detail: "404 Not Found", url: "file:///nowhere-at-all.png"}]
    end)

    assert {:ok, %{"content" => [%{"text" => "[response] 404 Not Found (file:///nowhere-at-all.png)"}]}} =
             Mcp.call_run_tool(context, "browser_problems", %{})
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
             Mcp.call_run_tool(%RunContext{os_process: %OsProcess{}, role: roles[:qa], user: nil}, "browser_connect", %{})

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
    stub(Tools, :start_browser_session, fn _task, _opts -> {:error, {:browser_unavailable, :chrome_not_found}} end)

    assert {:error, {:rail_failed, {:browser_unavailable, :chrome_not_found}}} =
             Mcp.call_run_tool(context, "browser_connect", %{})
  end
end
