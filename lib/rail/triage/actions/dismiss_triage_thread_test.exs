defmodule Rail.Triage.Actions.DismissTriageThreadTest do
  use Rail.DataCase, async: true

  alias Rail.Scope
  alias Rail.Triage
  alias Rail.Triage.Schemas.Thread

  test "a dismissed thread is Done without accepting anything" do
    %{project: project} = triage_project()
    %{workspace: workspace, channel: channel} = connect_slack_channel(project)
    {:ok, thread} = Triage.handle_slack_event(workspace, slack_message_event(channel, %{}))
    thread = triage_with(thread, %{"items" => [triage_bug()]})
    %{id: user_id} = user = slack_user(workspace.external_id, "Jordan Ellis")

    assert %Thread{status: :waiting} = thread

    assert {:ok, %Thread{status: :done, dismissed_by_id: ^user_id, dismissed_at: %DateTime{}}} =
             Triage.dismiss_triage_thread(Scope.for_user(user), thread)

    assert {:ok, %Thread{items: [_item]} = dismissed} = Triage.get_triage_thread(Scope.for_user(user), thread.id)
    assert "Dismissed by Jordan Ellis" = Thread.outcome_label(dismissed)
  end
end
