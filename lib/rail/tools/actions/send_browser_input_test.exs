defmodule Rail.Tools.Actions.SendBrowserInputTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Roles
  alias Rail.Scope
  alias Rail.Tools
  alias Rail.Tools.BrowserRegistry
  alias Rail.Tools.BrowserSession

  setup %{project: project} do
    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_sbi_1", "identifier" => "SBI-1", "title" => "Send Browser Input"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{description: "Send Browser Input"})
    {:ok, task} = Pipeline.create_task(issue, :review)
    on_exit(fn -> File.rm_rf(task.scratch_path) end)
    {:ok, lead} = Roles.get_role(project_id: project.id, stage: :review_lead)

    {:ok, run} =
      Pipeline.create_run(%{task_id: task.id, role_id: lead.id, status: :finished, started_at: DateTime.utc_now()})

    # This process stands in for the session the registry names, and the stub hears what it is sent.
    {:ok, _registered} = Registry.register(BrowserRegistry, {task.id, "qa-1"}, nil)
    test_pid = self()

    stub(BrowserSession, :call, fn session, method, params ->
      send(test_pid, {:cdp, session, method, params})
      {:ok, %{}}
    end)

    %{task: task, run: run, scope: Scope.for_user(%{admin: false, project_ids: [project.id]})}
  end

  test "a click is a press and a release at the page point", %{task: task, scope: scope} do
    test_pid = self()

    assert :ok = Tools.send_browser_input(scope, task, "qa-1", %{"type" => "click", "x" => 640.5, "y" => 360})

    assert_received {:cdp, ^test_pid, "Input.dispatchMouseEvent",
                     %{type: "mousePressed", x: 640.5, y: 360, button: "left", clickCount: 1}}

    assert_received {:cdp, ^test_pid, "Input.dispatchMouseEvent", %{type: "mouseReleased", x: 640.5, y: 360}}
  end

  test "a point off the page lands on its edge", %{task: task, scope: scope} do
    assert :ok = Tools.send_browser_input(scope, task, "qa-1", %{"type" => "click", "x" => -4, "y" => 5000})
    assert_received {:cdp, _session, "Input.dispatchMouseEvent", %{type: "mousePressed", x: 0, y: 1080}}
  end

  test "a typed key reaches the tab as text, and a key with none by its code", %{task: task, scope: scope} do
    assert :ok = Tools.send_browser_input(scope, task, "qa-1", %{"type" => "key", "key" => "e", "code" => "KeyE"})
    assert_received {:cdp, _session, "Input.dispatchKeyEvent", %{type: "keyDown", key: "e", text: "e", modifiers: 0}}
    assert_received {:cdp, _session, "Input.dispatchKeyEvent", %{type: "keyUp", key: "e", code: "KeyE"}}

    assert :ok = Tools.send_browser_input(scope, task, "qa-1", %{"type" => "key", "key" => "Enter", "code" => "Enter"})
    assert_received {:cdp, _session, "Input.dispatchKeyEvent", %{type: "keyDown", text: "\r", windowsVirtualKeyCode: 13}}

    backspace = %{"type" => "key", "key" => "Backspace", "code" => "Backspace", "modifiers" => 0}
    assert :ok = Tools.send_browser_input(scope, task, "qa-1", backspace)
    assert_received {:cdp, _session, "Input.dispatchKeyEvent", %{type: "rawKeyDown", windowsVirtualKeyCode: 8} = down}
    refute Map.has_key?(down, :text)

    # Ctrl+A selects rather than typing an a.
    select_all = %{"type" => "key", "key" => "a", "code" => "KeyA", "modifiers" => 2}
    assert :ok = Tools.send_browser_input(scope, task, "qa-1", select_all)
    assert_received {:cdp, _session, "Input.dispatchKeyEvent", %{type: "rawKeyDown", key: "a", modifiers: 2}}
  end

  test "a scroll is one wheel event with its deltas", %{task: task, scope: scope} do
    wheel = %{"type" => "wheel", "x" => 900, "y" => 500, "dx" => 0, "dy" => 240}
    assert :ok = Tools.send_browser_input(scope, task, "qa-1", wheel)
    assert_received {:cdp, _session, "Input.dispatchMouseEvent", %{type: "mouseWheel", deltaX: 0, deltaY: 240}}
  end

  test "input is refused while any run on the task is in flight, one waiting for a sandbox included", %{
    task: task,
    run: run,
    scope: scope
  } do
    click = %{"type" => "click", "x" => 1, "y" => 1}

    for status <- [:running, :waiting_for_resources, :starting, :waiting_for_usage] do
      {:ok, _moving} = Pipeline.update_run(run, %{status: status})
      assert {:error, :run_in_flight} = Tools.send_browser_input(scope, task, "qa-1", click)
    end

    refute_received {:cdp, _session, _method, _params}
  end

  # A comment resumes the lead after Review finished, and that run drives the browser just the same.
  test "input is refused while a run resumed after Review finished is in flight", %{
    task: task,
    run: run,
    scope: scope
  } do
    {:ok, task} = Pipeline.update_task(task, %{stage: :merged, merged_at: DateTime.utc_now()})
    {:ok, _resumed} = Pipeline.update_run(run, %{status: :running})

    assert {:error, :run_in_flight} =
             Tools.send_browser_input(scope, task, "qa-1", %{"type" => "click", "x" => 1, "y" => 1})
  end

  test "a session gone since a restart is attached to its tab again, and none is opened", %{task: task, scope: scope} do
    test_pid = self()
    tab = spawn(fn -> Process.sleep(:infinity) end)

    expect(Tools, :start_browser_session, fn _task, "demo", [existing: true] -> {:ok, tab} end)
    assert :ok = Tools.send_browser_input(scope, task, "demo", %{"type" => "click", "x" => 1, "y" => 1})
    assert_received {:cdp, ^tab, "Input.dispatchMouseEvent", %{type: "mousePressed"}}

    expect(Tools, :start_browser_session, fn _task, "gone", [existing: true] -> {:error, :no_browser} end)

    assert {:error, :no_browser} =
             Tools.send_browser_input(scope, task, "gone", %{"type" => "click", "x" => 1, "y" => 1})

    refute_received {:cdp, ^test_pid, _method, _params}
  end

  test "another project's task and an event it does not know are refused", %{task: task} do
    outsider = Scope.for_user(%{admin: false, project_ids: []})
    click = %{"type" => "click", "x" => 1, "y" => 1}

    assert {:error, :not_found} = Tools.send_browser_input(outsider, task, "qa-1", click)

    for event <- [%{"type" => "drag"}, %{"type" => "click", "x" => "1", "y" => 1}, %{}] do
      assert {:error, :unknown_event} = Tools.send_browser_input(system_scope(), task, "qa-1", event)
    end

    refute_received {:cdp, _session, _method, _params}
  end

  test "a tab that turns an event away says why", %{task: task, scope: scope} do
    stub(BrowserSession, :call, fn _session, _method, _params -> {:error, "Not attached to an active page"} end)

    assert {:error, "Not attached to an active page"} =
             Tools.send_browser_input(scope, task, "qa-1", %{"type" => "click", "x" => 1, "y" => 1})
  end
end
