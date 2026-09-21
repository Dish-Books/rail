defmodule Rail.Tools.Actions.DriveBrowserTest do
  use Rail.DataCase, async: false

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Projects
  alias Rail.Tools
  alias Rail.Tools.BrowserSession

  # Serial, because each test drives a real Chrome and a machine running thirty at
  # once measures contention rather than the browser.
  @moduletag :browser

  setup do
    scope = system_scope()

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{"data" => %{"teams" => %{"nodes" => [%{"id" => "lin_team_id"}]}}})
    end)

    {:ok, project} =
      Projects.create_project(scope, %{
        name: "Drive Browser Project",
        github_repo: "org/drive-browser",
        github_installation_id: 47_042,
        linear_workspace: %{
          name: "Drive Browser Workspace",
          external_id: "lin_ws_drive_browser",
          token: "lin_api_token_drive_browser",
          webhook_secret: "whsec_drive_browser"
        },
        linear_team_key: "DRB",
        default_branch: "main",
        clone_path: "/tmp/repos/drive-browser",
        linear_state_ids: %{"triage" => "st_triage"}
      })

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_drb_1", "identifier" => "DRB-1", "title" => "Drive Browser"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(scope, project, %{description: "Drive Browser"})
    {:ok, task} = Pipeline.create_task(issue, :qa)
    File.mkdir_p!(task.scratch_path)

    page = Path.join(task.scratch_path, "bill.html")

    File.write!(page, """
    <!doctype html><title>New bill</title>
    <label for="amount">Amount</label><input id="amount" type="text">
    <button type="button" id="save" onclick="document.title = 'Saved ' + amount.value">Save</button>
    """)

    {:ok, session} = Tools.start_browser_session(task)
    {:ok, _navigated} = BrowserSession.call(session, "Page.navigate", %{url: "file://#{page}"})

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

    # The choice is checked against what was actually offered, so a test builds
    # its answers from the question rather than from numbers it guessed.
    choosing = fn questions, name, choice ->
      true = choice in Map.keys(questions[name]["criteria"])

      %{"choice" => choice, "confidence" => 1.0}
    end

    # TypeSafe is asked what to do; every test says what it answers. Answering is
    # a function of the question so a test does not have to know the element
    # numbering in advance.
    answering = fn answers ->
      Req.Test.stub(Rail.TypeSafe, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        %{"questions" => questions, "state" => state} = Jason.decode!(body)

        Req.Test.json(conn, %{"answers" => answers.(questions, state)})
      end)
    end

    %{task: task, session: session, answering: answering, choosing: choosing}
  end

  test "carries out an instruction and says what it did", %{session: session, answering: answering, choosing: choosing} do
    answering.(fn questions, state ->
      save = Enum.find(state["elements"], &(&1["label"] == "Save"))

      %{
        "operation" => choosing.(questions, "operation", "CLICK"),
        "click_target" => choosing.(questions, "click_target", save["index"]),
        "type_text_target" => choosing.(questions, "type_text_target", "1")
      }
    end)

    assert {:ok, receipt} = Tools.drive_browser(session, "click Save")
    assert [%{operation: "CLICK", action: "Save"} | _rest] = receipt.executed
  end

  test "types only what the caller supplied", %{session: session, answering: answering, choosing: choosing} do
    answering.(fn questions, state ->
      amount = Enum.find(state["elements"], &(&1["label"] == "Amount"))

      %{
        "operation" => choosing.(questions, "operation", "TYPE_TEXT"),
        "type_text_target" => choosing.(questions, "type_text_target", amount["index"]),
        "click_target" => choosing.(questions, "click_target", "1")
      }
    end)

    assert {:ok, _receipt} = Tools.drive_browser(session, "fill in the amount", text: "1234.50")

    assert {:ok, %{"result" => %{"value" => "1234.50"}}} =
             BrowserSession.call(session, "Runtime.evaluate", %{
               expression: "document.getElementById('amount').value",
               returnByValue: true
             })
  end

  # The one thing a decision cannot supply. Rather than inventing a value, the
  # step stops and hands the question back.
  test "stops and asks when a field needs a value nobody gave it", %{
    session: session,
    answering: answering,
    choosing: choosing
  } do
    answering.(fn questions, state ->
      amount = Enum.find(state["elements"], &(&1["label"] == "Amount"))

      %{
        "operation" => choosing.(questions, "operation", "TYPE_TEXT"),
        "type_text_target" => choosing.(questions, "type_text_target", amount["index"]),
        "click_target" => choosing.(questions, "click_target", "1")
      }
    end)

    assert {:ok, %{outcome: {:needs_text, "Amount"}, executed: []}} =
             Tools.drive_browser(session, "fill in the amount")
  end

  test "several actions for one instruction", %{session: session, answering: answering, choosing: choosing} do
    answering.(fn questions, state ->
      amount = Enum.find(state["elements"], &(&1["label"] == "Amount"))
      save = Enum.find(state["elements"], &(&1["label"] == "Save"))
      done = state["already_done"]

      operation =
        cond do
          "Save" in done -> "DONE"
          "Amount" in done -> "CLICK"
          true -> "TYPE_TEXT"
        end

      %{
        "operation" => choosing.(questions, "operation", operation),
        "type_text_target" => choosing.(questions, "type_text_target", amount["index"]),
        "click_target" => choosing.(questions, "click_target", save["index"])
      }
    end)

    assert {:ok, %{title: "Saved 99.00", executed: executed}} =
             Tools.drive_browser(session, "enter the amount and save", text: "99.00")

    assert [%{operation: "TYPE_TEXT"}, %{operation: "CLICK", action: "Save"}] = executed
  end

  test "reports what the page cannot do", %{session: session, answering: answering, choosing: choosing} do
    answering.(fn questions, _state ->
      %{
        "operation" => choosing.(questions, "operation", "BLOCKED"),
        "click_target" => choosing.(questions, "click_target", "1"),
        "type_text_target" => choosing.(questions, "type_text_target", "1")
      }
    end)

    assert {:ok, %{outcome: :blocked, executed: []}} = Tools.drive_browser(session, "delete the invoice")
  end

  test "a pass is told about each action as it happens", %{session: session, answering: answering, choosing: choosing} do
    answering.(fn questions, state ->
      save = Enum.find(state["elements"], &(&1["label"] == "Save"))

      %{
        "operation" => choosing.(questions, "operation", "CLICK"),
        "click_target" => choosing.(questions, "click_target", save["index"]),
        "type_text_target" => choosing.(questions, "type_text_target", "1")
      }
    end)

    watcher = self()

    assert {:ok, _receipt} =
             Tools.drive_browser(session, "click Save", on_action: &send(watcher, {:acted, &1}))

    assert_received {:acted, %{operation: "CLICK", action: "Save"}}
  end

  # The gap between reading a page and acting on it is real. Nothing was done, so
  # the recovery is the whole of it: read the page again and decide afresh.
  test "a page that moved under the decision is read again rather than given up on", %{
    session: session,
    answering: answering,
    choosing: choosing
  } do
    answering.(fn questions, state ->
      save = Enum.find(state["elements"], &(&1["label"] == "Save"))
      operation = if state["already_done"] == [], do: "CLICK", else: "DONE"

      %{
        "operation" => choosing.(questions, "operation", operation),
        "click_target" => choosing.(questions, "click_target", save["index"]),
        "type_text_target" => choosing.(questions, "type_text_target", "1")
      }
    end)

    expect(Tools, :execute_browser_action, fn _session, _action, _text -> {:error, {:refused, "gone", nil}} end)
    stub(Tools, :execute_browser_action, fn _session, _action, _text -> {:ok, "save"} end)

    assert {:ok, %{outcome: :done, executed: [%{operation: "CLICK", action: "Save"}]}} =
             Tools.drive_browser(session, "click Save")
  end

  test "an action the browser refuses stops the instruction", %{
    session: session,
    answering: answering,
    choosing: choosing
  } do
    answering.(fn questions, state ->
      save = Enum.find(state["elements"], &(&1["label"] == "Save"))

      %{
        "operation" => choosing.(questions, "operation", "CLICK"),
        "click_target" => choosing.(questions, "click_target", save["index"]),
        "type_text_target" => choosing.(questions, "type_text_target", "1")
      }
    end)

    stub(Tools, :execute_browser_action, fn _session, _action, _text -> {:error, :no_text_to_type} end)

    assert {:error, :no_text_to_type} = Tools.drive_browser(session, "click Save")
  end

  # A page navigating when it is read again has nothing to read, and the step
  # that already landed is still worth reporting.
  test "a page that cannot be read again still reports what was done", %{
    session: session,
    answering: answering,
    choosing: choosing
  } do
    answering.(fn questions, state ->
      save = Enum.find(state["elements"], &(&1["label"] == "Save"))

      %{
        "operation" => choosing.(questions, "operation", "CLICK"),
        "click_target" => choosing.(questions, "click_target", save["index"]),
        "type_text_target" => choosing.(questions, "type_text_target", "1")
      }
    end)

    {:ok, page} = Tools.observe_browser(session)

    expect(Tools, :observe_browser, fn _session -> {:ok, page} end)
    expect(Tools, :observe_browser, fn _session -> {:error, :navigating} end)
    stub(Tools, :execute_browser_action, fn _session, _action, _text -> {:ok, "save"} end)

    assert {:ok, %{outcome: :done, error: :navigating, executed: [%{action: "Save"}]}} =
             Tools.drive_browser(session, "click Save")
  end

  # A control that refuses twice over a page that has not moved is not a race
  # being lost, it is the page's answer - and what refused it is the finding.
  test "a control that keeps refusing stops the instruction and says why", %{
    session: session,
    answering: answering,
    choosing: choosing
  } do
    answering.(fn questions, state ->
      save = Enum.find(state["elements"], &(&1["label"] == "Save"))

      %{
        "operation" => choosing.(questions, "operation", "CLICK"),
        "click_target" => choosing.(questions, "click_target", save["index"]),
        "type_text_target" => choosing.(questions, "type_text_target", "1")
      }
    end)

    stub(Tools, :execute_browser_action, fn _session, _action, _text ->
      {:error, {:refused, "covered", ~s(div "Saving")}}
    end)

    assert {:ok, receipt} = Tools.drive_browser(session, "click Save")
    assert receipt.outcome == {:refused, %{label: "Save", why: "covered", by: ~s(div "Saving")}}
    assert receipt.executed == []
  end

  # A step that leaves the page as it found it, chosen again, is a step doing
  # something other than what was asked.
  test "the same step over a page that did not move stops after the second", %{
    session: session,
    answering: answering,
    choosing: choosing
  } do
    answering.(fn questions, state ->
      save = Enum.find(state["elements"], &(&1["label"] == "Save"))

      %{
        "operation" => choosing.(questions, "operation", "CLICK"),
        "click_target" => choosing.(questions, "click_target", save["index"]),
        "type_text_target" => choosing.(questions, "type_text_target", "1")
      }
    end)

    stub(Tools, :execute_browser_action, fn _session, _action, _text -> {:ok, "save"} end)

    assert {:ok, %{outcome: :not_moving, executed: executed}} = Tools.drive_browser(session, "click Save")
    assert length(executed) == 1
  end

  # An instruction that keeps finding something else to do is stopped by the
  # budget rather than by a page that stopped changing.
  test "an instruction that never finishes is stopped by its budget", %{
    session: session,
    answering: answering,
    choosing: choosing
  } do
    # Alternating, so no step is ever the one just taken and only the budget can
    # end this. The count is its own because what the decider is told about what
    # has been done stops growing after ten.
    taken = :counters.new(1, [])

    answering.(fn questions, state ->
      :counters.add(taken, 1, 1)
      wanted = if rem(:counters.get(taken, 1), 2) == 0, do: "Save", else: "Amount"
      target = Enum.find(state["elements"], &(&1["label"] == wanted))

      %{
        "operation" => choosing.(questions, "operation", "CLICK"),
        "click_target" => choosing.(questions, "click_target", target["index"]),
        "type_text_target" => choosing.(questions, "type_text_target", "1")
      }
    end)

    stub(Tools, :execute_browser_action, fn _session, _action, _text -> {:ok, "acted"} end)

    assert {:ok, %{outcome: :too_many_actions, executed: executed}} = Tools.drive_browser(session, "click about")
    assert length(executed) == 30
  end

  # The caller keys its values by the field as the page labels it, so one call
  # fills a form - and a label the page writes differently still matches.
  test "values are matched to the field they were keyed for", %{
    session: session,
    answering: answering,
    choosing: choosing
  } do
    answering.(fn questions, state ->
      amount = Enum.find(state["elements"], &(&1["label"] == "Amount"))
      done? = state["already_done"] != []

      %{
        "operation" => choosing.(questions, "operation", if(done?, do: "DONE", else: "TYPE_TEXT")),
        "click_target" => choosing.(questions, "click_target", "1"),
        "type_text_target" => choosing.(questions, "type_text_target", amount["index"])
      }
    end)

    assert {:ok, %{executed: [%{text: "12.50"}]}} =
             Tools.drive_browser(session, "the amount is 12.50", values: %{"Amount" => "12.50"})

    assert {:ok, %{executed: [%{text: "13.50"}]}} =
             Tools.drive_browser(session, "the amount is 13.50", values: %{"amount field" => "13.50"})
  end

  # An answer Rail did not offer never reaches the page.
  test "refuses a decision that names something that was not offered", %{session: session} do
    Req.Test.stub(Rail.TypeSafe, fn conn ->
      Req.Test.json(conn, %{
        "answers" => %{
          "operation" => %{"choice" => "FLY", "confidence" => 1.0}
        }
      })
    end)

    assert {:error, {:type_safe_unusable_answer, :operation, :choice_not_offered}} =
             Tools.drive_browser(session, "click Save")
  end
end
