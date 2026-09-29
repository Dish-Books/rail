defmodule Rail.Triage.Actions.AddTriageNoteTest do
  use Rail.DataCase, async: true

  alias Rail.Scope
  alias Rail.Tools
  alias Rail.Triage
  alias Rail.Triage.Schemas.Item
  alias Rail.Triage.Schemas.Note
  alias Rail.Triage.Schemas.Thread

  setup do
    %{project: project} = triage_project()
    %{workspace: workspace, channel: channel} = connect_slack_channel(project)
    {:ok, thread} = Triage.handle_slack_event(workspace, slack_message_event(channel, %{}))

    request = %{
      "key" => "wait-times",
      "kind" => "feature_request",
      "title" => "Wait times",
      "verdict" => "not_built",
      "summary" => "Nothing shows a wait."
    }

    bug = triage_bug(%{"verdict" => "not_reproduced", "assumptions" => [%{"text" => "Billing has a Design role."}]})
    thread = triage_with(thread, %{"items" => [bug, request]})
    Phoenix.PubSub.subscribe(Rail.PubSub, "triage")

    %{thread: thread, bug: bug, request: request, scope: Scope.for_user(%{id: nil})}
  end

  test "a note triages only its item again, with the note in the brief, and records what it overturned", %{
    thread: %Thread{id: thread_id, items: [bug_item, request_item]} = thread,
    bug: bug,
    request: request,
    scope: scope
  } do
    assert {:ok, %Note{text: "Billing has its Design role turned off.", assumption: "Billing has a Design role."}} =
             Triage.add_triage_note(scope, bug_item, %{
               "text" => "  Billing has its Design role turned off.  ",
               "assumption" => "Billing has a Design role."
             })

    assert %Item{retriaging: true} = Repo.get!(Item, bug_item.id)
    assert %Item{retriaging: false} = Repo.get!(Item, request_item.id)
    assert %Thread{status: :triaging} = Repo.get!(Thread, thread_id)
    assert_receive {:triage_scheduled, ^thread_id, 0}

    expect(Tools, :run_agent, fn _backend, argv, _opts ->
      brief = Enum.find(argv, &(&1 =~ "People left notes on these items"))
      assert brief =~ ~s(On `stuck-at-design`, a person noted: "Billing has its Design role turned off.")
      assert brief =~ ~s(It answers your assumption: "Billing has a Design role.")
      refute brief =~ "On `wait-times`"

      corrected =
        Map.merge(bug, %{
          "verdict" => "confirmed",
          "assumptions" => [%{"text" => "Billing's Design role is off.", "corrected" => true}]
        })

      untouchable = Map.put(request, "summary", "This pass may not touch it.")

      thread
      |> Thread.scratch_path()
      |> Path.join("result.json")
      |> File.write!(Jason.encode!(%{"items" => [corrected, untouchable]}))

      {:ok, ""}
    end)

    assert :ok = Triage.triage_thread(Repo.get!(Thread, thread_id))

    assert %Item{
             verdict: :confirmed,
             previous_verdict: :not_reproduced,
             retriaging: false,
             retriaged_at: %DateTime{},
             assumptions: [%Item.Assumption{corrected: true}]
           } = Repo.get!(Item, bug_item.id)

    assert %Item{summary: "Nothing shows a wait."} = Repo.get!(Item, request_item.id)
    assert %Thread{status: :waiting} = Repo.get!(Thread, thread_id)
  end

  test "a note needs words", %{thread: %Thread{items: [bug_item, _request]}, scope: scope} do
    assert {:error, changeset} = Triage.add_triage_note(scope, bug_item, %{"text" => "  "})
    assert %{text: ["can't be blank"]} = errors_on(changeset)
    assert %Item{retriaging: false} = Repo.get!(Item, bug_item.id)
  end

  test "a settled item takes no more notes", %{thread: %Thread{items: [bug_item, _request]} = thread, scope: scope} do
    {:ok, _dismissed} = Triage.dismiss_triage_thread(scope, thread)

    assert {:error, :settled} = Triage.add_triage_note(scope, bug_item, %{"text" => "Too late."})
  end
end
