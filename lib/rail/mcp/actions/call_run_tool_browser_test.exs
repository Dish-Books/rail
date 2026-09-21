defmodule Rail.Mcp.Actions.CallRunToolBrowserTest do
  use Rail.DataCase, async: false

  alias Rail.Issues
  alias Rail.Mcp
  alias Rail.Mcp.RunContext
  alias Rail.Pipeline
  alias Rail.Projects
  alias Rail.Roles
  alias Rail.Tools
  alias Rail.Tools.Schemas.OsProcess

  # The half of `call_run_tool/3` that Rail answers itself, which is a file of its
  # own because it drives a real Chrome: serial, and only when asked for. The
  # proxied half is in `call_run_tool_test.exs` and runs with everything else.
  @moduletag :browser

  setup do
    scope = system_scope()

    {:ok, backend} = Tools.create_backend(scope, %{name: :claude, executable_path: "/usr/bin/true"})

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{"data" => %{"teams" => %{"nodes" => [%{"id" => "lin_team_id"}]}}})
    end)

    {:ok, project} =
      Projects.create_project(scope, %{
        name: "Qa Tools Project",
        github_repo: "org/qa-tools",
        github_installation_id: 47_043,
        linear_workspace: %{
          name: "Qa Tools Workspace",
          external_id: "lin_ws_qa_tools",
          token: "lin_api_token_qa_tools",
          webhook_secret: "whsec_qa_tools"
        },
        linear_team_key: "QAT",
        default_branch: "main",
        clone_path: "/tmp/repos/qa-tools",
        linear_state_ids: %{"triage" => "st_triage"}
      })

    roles =
      Map.new([:qa, :review], fn stage ->
        {:ok, role} =
          Roles.create_role(scope, project, %{
            backend_id: backend.id,
            stage: stage,
            name: "#{stage} role",
            model: "claude-3-7-sonnet",
            system_prompt: "You are the #{stage} agent."
          })

        {stage, role}
      end)

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_qat_1", "identifier" => "QAT-1", "title" => "Qa Tools"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(scope, project, %{description: "Qa Tools"})
    {:ok, task} = Pipeline.create_task(issue, :qa)
    File.mkdir_p!(task.scratch_path)

    page = Path.join(task.scratch_path, "bill.html")

    File.write!(page, """
    <!doctype html><title>New bill</title>
    <h1>New bill</h1>
    <label for="amount">Amount</label><input id="amount" type="text" value="1234.50">
    <img src="nowhere-at-all.png" alt="">
    <button type="button" id="save" onclick="console.error('total is unrounded')">Save</button>
    """)

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

    # TypeSafe decides what to do; here it clicks whatever the instruction names
    # and stops. Every answer is built from what was actually offered, because
    # anything else is refused before it reaches the page.
    Req.Test.stub(Rail.TypeSafe, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      %{"questions" => questions, "state" => state} = Jason.decode!(body)

      choosing = fn name, choice ->
        true = choice in Map.keys(questions[name]["criteria"])

        %{"choice" => choice, "confidence" => 1.0}
      end

      wanted = Enum.find(state["elements"], &String.contains?(state["instruction"], &1["label"]))
      operation = if state["already_done"] == [] and wanted, do: "CLICK", else: "DONE"

      answers =
        questions
        |> Map.keys()
        |> Enum.reject(&(&1 == "operation"))
        |> Map.new(fn name -> {name, choosing.(name, questions[name]["criteria"] |> Map.keys() |> hd())} end)
        |> Map.put("operation", choosing.("operation", operation))

      answers =
        if operation == "CLICK" and Map.has_key?(questions, "click_target") do
          Map.put(answers, "click_target", choosing.("click_target", wanted["index"]))
        else
          answers
        end

      Req.Test.json(conn, %{"answers" => answers})
    end)

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

    %{task: task, run: run, context: context, roles: roles, page: "file://#{page}"}
  end

  # Knowing the name is not the same as being allowed to call it.
  test "another stage cannot call one by knowing its name", %{context: context, roles: roles} do
    reviewing = %{context | role: roles[:review]}

    assert {:error, :unknown_tool} = Mcp.call_run_tool(reviewing, "qa_goto", %{"url" => "about:blank"})
  end

  # The checklist is written before anything is opened, so neither of these costs
  # a browser.
  test "planning and marking off happen without a browser", %{context: context, task: task, run: run} do
    assert {:ok, %{"content" => [%{"text" => planned}]}} =
             Mcp.call_run_tool(context, "qa_plan", %{
               "checks" => [
                 %{"key" => "bill-saves", "title" => "A bill saves", "outcome" => "pass"},
                 %{"key" => "totals", "title" => "The totals agree"}
               ]
             })

    assert planned =~ "2 checks"
    assert Tools.get_browser_session(task) == nil

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

  # Nothing here is worth failing the call over: the agent can read the answer and
  # put it right on the next one.
  test "a plan or a mark Rail cannot use comes back as words rather than an error", %{context: context} do
    assert {:ok, %{"content" => [%{"text" => marked}]}} =
             Mcp.call_run_tool(context, "qa_check", %{"key" => "totals", "outcome" => "pass"})

    assert marked =~ "no checklist yet"

    assert {:ok, %{"content" => [%{"text" => refused}]}} =
             Mcp.call_run_tool(context, "qa_plan", %{"checks" => [%{"title" => "no key on this one"}]})

    assert refused =~ "not usable"

    assert {:ok, %{"content" => [%{"text" => "qa_plan needs a `checks` list. Nothing was written."}]}} =
             Mcp.call_run_tool(context, "qa_plan", %{})

    {:ok, _planned} = Mcp.call_run_tool(context, "qa_plan", %{"checks" => [%{"key" => "one", "title" => "A bill saves"}]})

    assert {:ok, %{"content" => [%{"text" => unknown}]}} =
             Mcp.call_run_tool(context, "qa_check", %{"key" => "two", "outcome" => "pass"})

    assert unknown =~ ~s(No check called "two")

    assert {:ok, %{"content" => [%{"text" => outcome}]}} =
             Mcp.call_run_tool(context, "qa_check", %{"key" => "one", "outcome" => "probably"})

    assert outcome =~ "`pass`, `fail` or `skipped`"

    assert {:ok, %{"content" => [%{"text" => "qa_check needs a `key` and an `outcome`. Nothing was recorded."}]}} =
             Mcp.call_run_tool(context, "qa_check", %{"key" => "one"})
  end

  test "opening a page starts the browser without being asked", %{context: context, task: task, page: page} do
    assert {:ok, %{"content" => [%{"text" => text}]}} = Mcp.call_run_tool(context, "qa_goto", %{"url" => page})

    assert text =~ "New bill"
    assert Tools.start_browser_session(task) == {:ok, Tools.get_browser_session(task)}
  end

  test "reading the page names what can be acted on", %{context: context, page: page} do
    {:ok, _opened} = Mcp.call_run_tool(context, "qa_goto", %{"url" => page})

    assert {:ok, %{"content" => [%{"text" => text}]}} = Mcp.call_run_tool(context, "qa_look", %{})

    assert text =~ "New bill"
    assert text =~ ~s(textbox "Amount")
    assert text =~ ~s(button "Save")
  end

  # Rail names the file, so nothing arriving from a model becomes a path.
  test "a screenshot is described rather than located", %{context: context, task: task, page: page} do
    {:ok, _opened} = Mcp.call_run_tool(context, "qa_goto", %{"url" => page})

    assert {:ok, %{"content" => [%{"text" => text}]}} =
             Mcp.call_run_tool(context, "qa_shot", %{"name" => "The bill total as rendered"})

    assert text =~ "evidence/the-bill-total-as-rendered.jpg"
    # The name comes back, never the picture, so reading it is the agent's own
    # decision to make and its own context to spend.
    assert text =~ "read it only when a check turns on that"
    assert File.exists?(Path.join([task.scratch_path, "qa", "evidence", "the-bill-total-as-rendered.jpg"]))
  end

  test "the browser's own complaints are drained, not accumulated", %{context: context, page: page} do
    {:ok, _opened} = Mcp.call_run_tool(context, "qa_goto", %{"url" => page})

    {:ok, _clicked} =
      Mcp.call_run_tool(context, "qa_do", %{"intent" => "click Save"})

    eventually(fn ->
      assert {:ok, %{"content" => [%{"text" => text}]}} = Mcp.call_run_tool(context, "qa_problems", %{})
      assert text =~ "total is unrounded"
    end)

    assert {:ok, %{"content" => [%{"text" => "Nothing since the last check."}]}} =
             Mcp.call_run_tool(context, "qa_problems", %{})
  end

  # What is logged is what Rail executed, not what the agent asked for, so a step
  # that went to the wrong element is visible while the pass is still running.
  test "every browser action reaches the run's log as it happens", %{context: context, run: run, page: page} do
    {:ok, _opened} = Mcp.call_run_tool(context, "qa_goto", %{"url" => page})
    {:ok, _clicked} = Mcp.call_run_tool(context, "qa_do", %{"intent" => "click Save"})

    log = run |> Pipeline.list_run_events() |> Enum.map_join("\n", & &1.line)

    assert log =~ "[qa] goto file://"
    assert log =~ ~s([qa] do "click Save")
    assert log =~ ~s([qa]   CLICK "Save")
  end

  # What comes back is a receipt rather than a page, and each way an instruction
  # can end has to read as itself or the agent's next move is a guess.
  test "an instruction that cannot be carried out says so rather than failing", %{context: context, page: page} do
    {:ok, _opened} = Mcp.call_run_tool(context, "qa_goto", %{"url" => page})

    Req.Test.stub(Rail.TypeSafe, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      %{"questions" => questions} = Jason.decode!(body)

      answers =
        Map.new(questions, fn {name, question} ->
          choice = if name == "operation", do: "BLOCKED", else: question["criteria"] |> Map.keys() |> hd()

          {name, %{"choice" => choice, "confidence" => 1.0}}
        end)

      Req.Test.json(conn, %{"answers" => answers})
    end)

    assert {:ok, %{"content" => [%{"text" => text}]}} =
             Mcp.call_run_tool(context, "qa_do", %{"intent" => "delete the invoice"})

    assert text =~ "Did nothing."
    assert text =~ "Nothing on this page can carry that out."
  end

  # The one thing a decision cannot supply. Rather than inventing a value, the
  # instruction stops and hands the question back.
  test "an instruction that reaches a field asks for the value", %{context: context, page: page} do
    {:ok, _opened} = Mcp.call_run_tool(context, "qa_goto", %{"url" => page})

    stub(Tools, :drive_browser, fn _session, _intent, _opts ->
      {:ok, %{outcome: {:needs_text, "Amount"}, url: "file:///bill.html", title: "New bill", executed: []}}
    end)

    assert {:ok, %{"content" => [%{"text" => asked}]}} =
             Mcp.call_run_tool(context, "qa_do", %{"intent" => "fill in the amount"})

    assert asked =~ ~s(Stopped at "Amount", which needs a value.)
  end

  test "an instruction that never finishes says how far it got", %{context: context, page: page} do
    {:ok, _opened} = Mcp.call_run_tool(context, "qa_goto", %{"url" => page})

    stub(Tools, :drive_browser, fn _session, _intent, _opts ->
      {:ok,
       %{
         outcome: :too_many_actions,
         url: "file:///bill.html",
         title: "New bill",
         executed: [%{operation: "TYPE_TEXT", action: "Amount", text: "12"}]
       }}
    end)

    assert {:ok, %{"content" => [%{"text" => text}]}} =
             Mcp.call_run_tool(context, "qa_do", %{"intent" => "fill in every field"})

    assert text =~ ~s(TYPE_TEXT "Amount" ← "12")
    assert text =~ "Stopped after too many actions"
  end

  # The value supplied is written down as well as typed, so a check that entered
  # the wrong thing is visible in the log rather than only in the outcome.
  test "the value a step typed reaches the log", %{context: context, run: run, page: page} do
    {:ok, _opened} = Mcp.call_run_tool(context, "qa_goto", %{"url" => page})

    stub(Tools, :drive_browser, fn _session, _intent, opts ->
      opts[:on_action].(%{operation: "TYPE_TEXT", action: "Amount", text: "1234.50"})

      {:ok, %{outcome: :done, url: "file:///bill.html", title: "New bill", executed: []}}
    end)

    {:ok, _typed} = Mcp.call_run_tool(context, "qa_do", %{"intent" => "fill in the amount", "text" => "1234.50"})

    log = run |> Pipeline.list_run_events() |> Enum.map_join("\n", & &1.line)

    assert log =~ ~s([qa] do "fill in the amount" ← "1234.50")
    assert log =~ ~s([qa]   TYPE_TEXT "Amount" ← "1234.50")
  end

  # Reading the page is how a check asserts a value, so what a field is holding
  # is part of what comes back rather than something to photograph.
  test "what a field is holding is read off the page", %{context: context, page: page} do
    {:ok, _opened} = Mcp.call_run_tool(context, "qa_goto", %{"url" => page})

    assert {:ok, %{"content" => [%{"text" => text}]}} = Mcp.call_run_tool(context, "qa_look", %{})

    assert text =~ ~s(textbox "Amount" holding "1234.50")
  end

  # A request that failed says which one, because "something 404'd" is not a
  # finding anybody can act on.
  test "a problem that happened somewhere says where", %{context: context, page: page} do
    {:ok, _opened} = Mcp.call_run_tool(context, "qa_goto", %{"url" => page})

    eventually(fn ->
      assert {:ok, %{"content" => [%{"text" => text}]}} = Mcp.call_run_tool(context, "qa_problems", %{})
      assert text =~ "nowhere-at-all.png" or text =~ "(Image)"
    end)
  end

  # Called outside a pass - which is every call made while testing this - there
  # is no run to write to and nothing to write about.
  test "a call with no run behind it writes nothing and still answers", %{roles: roles, task: task} do
    context = %RunContext{os_process: %OsProcess{task_id: task.id}, role: roles[:qa], user: nil}

    assert {:ok, %{"content" => [%{"text" => text}]}} =
             Mcp.call_run_tool(context, "qa_plan", %{"checks" => [%{"key" => "one", "title" => "A bill saves"}]})

    assert text =~ "1 checks"
  end

  test "a call with no task behind it is refused", %{roles: roles} do
    assert {:error, :no_task} =
             Mcp.call_run_tool(%RunContext{os_process: %OsProcess{}, role: roles[:qa], user: nil}, "qa_look", %{})

    assert {:error, :no_task} =
             Mcp.call_run_tool(
               %RunContext{os_process: %OsProcess{task_id: "tsk_gone"}, role: roles[:qa], user: nil},
               "qa_look",
               %{}
             )
  end

  # A name Rail does not serve is forwarded, and there is no server by that name
  # either.
  test "a name Rail does not serve is refused", %{context: context} do
    assert {:error, :unknown_tool} = Mcp.call_run_tool(context, "qa_invented", %{})
  end

  # Whatever went wrong down there reaches the agent as an error rather than as
  # a sentence, because it is not something a different instruction would fix.
  test "a browser that will not answer is an error, not advice", %{context: context, page: page} do
    {:ok, _opened} = Mcp.call_run_tool(context, "qa_goto", %{"url" => page})

    stub(Tools, :drive_browser, fn _session, _intent, _opts -> {:error, :no_text_to_type} end)

    assert {:error, :no_text_to_type} = Mcp.call_run_tool(context, "qa_do", %{"intent" => "click Save"})
  end

  test "stopping closes the browser", %{context: context, task: task, page: page} do
    {:ok, _opened} = Mcp.call_run_tool(context, "qa_goto", %{"url" => page})

    assert {:ok, %{"content" => [%{"text" => "The browser is closed."}]}} =
             Mcp.call_run_tool(context, "qa_stop", %{})

    assert Tools.get_browser_session(task) == nil
  end
end
