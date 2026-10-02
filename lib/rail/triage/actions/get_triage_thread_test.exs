defmodule Rail.Triage.Actions.GetTriageThreadTest do
  use Rail.DataCase, async: true

  alias Rail.Triage
  alias Rail.Triage.Schemas.Thread

  setup do
    %{project: project} = triage_project()
    %{workspace: workspace, channel: channel} = connect_slack_channel(project)
    {:ok, %Thread{id: thread_id}} = Triage.handle_slack_event(workspace, slack_message_event(channel, %{}))

    %{project: project, thread_id: thread_id}
  end

  test "loads a thread in a project the scope can see", %{project: project, thread_id: thread_id} do
    assert {:ok, %Thread{id: ^thread_id}} = Triage.get_triage_thread(system_scope(), thread_id)
    assert {:ok, %Thread{id: ^thread_id}} = Triage.get_triage_thread(user_scope(admin: true), thread_id)
    assert {:ok, %Thread{id: ^thread_id}} = Triage.get_triage_thread(user_scope(project_ids: [project.id]), thread_id)
  end

  test "a thread in a project the user cannot see is not found", %{thread_id: thread_id} do
    assert {:error, :not_found} = Triage.get_triage_thread(user_scope(project_ids: ["prj_other"]), thread_id)
    assert {:error, :not_found} = Triage.get_triage_thread(user_scope(), thread_id)
  end
end
