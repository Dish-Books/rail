defmodule Rail.Triage.Actions.ListTriageThreadsTest do
  use Rail.DataCase, async: true

  alias Rail.Scope
  alias Rail.Triage
  alias Rail.Triage.Schemas.Message
  alias Rail.Triage.Schemas.Thread

  setup do
    %{project: project} = triage_project()
    %{workspace: workspace, channel: channel} = connect_slack_channel(project)

    {:ok, older} =
      Triage.handle_slack_event(
        workspace,
        slack_message_event(channel, %{"ts" => "1790000000.000100", "text" => "older"})
      )

    {:ok, newer} =
      Triage.handle_slack_event(
        workspace,
        slack_message_event(channel, %{"ts" => "1790000500.000100", "text" => "newer"})
      )

    older = triage_with(older, %{"title" => "Older", "items" => [triage_bug()]})
    newer = triage_with(newer, %{"title" => "Newer", "items" => [triage_bug()]})

    %{project: project, workspace: workspace, channel: channel, older: older, newer: newer}
  end

  test "lists a status's threads, Waiting by the latest message and Done by when it finished", %{
    project: project,
    older: %{id: older_id} = older,
    newer: %{id: newer_id}
  } do
    assert [%Thread{id: ^newer_id}, %Thread{id: ^older_id, items: [_item], messages: [_message]}] =
             Enum.filter(Triage.list_triage_threads(project_id: project.id), &(&1.id in [older_id, newer_id]))

    {:ok, _done} = Triage.dismiss_triage_thread(Scope.for_user(%{id: nil}), older)

    assert [%Thread{id: ^older_id}] = Triage.list_triage_threads(project_id: project.id, status: :done)
    assert [%Thread{id: ^newer_id}] = Triage.list_triage_threads(project_id: project.id, status: :waiting)
    assert [] = Triage.list_triage_threads(project_id: project.id, status: :triaging)
    assert [] = Triage.list_triage_threads(project_id: "prj_other", status: :waiting)
    assert [%Thread{id: ^newer_id}] = Triage.list_triage_threads(project_id: [project.id, "prj_other"])
    assert [] = Triage.list_triage_threads(project_id: ["prj_other"])
    assert [] = Triage.list_triage_threads(project_id: [])
    assert Enum.any?(Triage.list_triage_threads(status: :waiting), &(&1.id == newer_id))
  end

  test "keeps to a limit, the most recent first, and loads only the message each row shows", %{
    project: project,
    workspace: workspace,
    channel: channel,
    older: %{id: older_id} = older,
    newer: %{id: newer_id} = newer
  } do
    {:ok, _reply} =
      Triage.handle_slack_event(
        workspace,
        slack_message_event(channel, %{"ts" => "1790000900.000100", "thread_ts" => older.external_id, "text" => "later"})
      )

    {:ok, _done} = Triage.dismiss_triage_thread(Scope.for_user(%{id: nil}), older)
    {:ok, _done} = Triage.dismiss_triage_thread(Scope.for_user(%{id: nil}), newer)

    assert [%Thread{id: ^newer_id}] = Triage.list_triage_threads(project_id: project.id, status: :done, limit: 1)

    assert [%Thread{id: ^newer_id}, %Thread{id: ^older_id, messages: [%Message{text: "older"}]}] =
             Triage.list_triage_threads(project_id: project.id, status: :done)
  end

  test "counts each status in one query", %{project: project, older: older} do
    {:ok, _done} = Triage.dismiss_triage_thread(Scope.for_user(%{id: nil}), older)

    assert %{waiting: 1, triaging: 0, done: 1} = Triage.count_triage_threads(project_id: project.id)
    assert %{waiting: 1, done: 1} = Triage.count_triage_threads(project_id: [project.id])
    assert %{waiting: 0, done: 0} = Triage.count_triage_threads(project_id: ["prj_other"])
    assert %{waiting: 0, done: 0} = Triage.count_triage_threads(project_id: [])
    assert %{waiting: 1, done: 1} = Triage.count_triage_threads(slack_channel_id: [older.slack_channel_id])
    assert %{waiting: 0, done: 0} = Triage.count_triage_threads(slack_channel_id: ["sch_other"])
    assert %{waiting: waiting} = Triage.count_triage_threads([])
    assert waiting >= 1
  end

  test "counts each channel's threads in one query when asked by channel", %{channel: channel} do
    %{project: other_project} = triage_project()
    %{workspace: other_workspace, channel: other_channel} = connect_slack_channel(other_project)

    {:ok, _thread} =
      Triage.handle_slack_event(other_workspace, slack_message_event(other_channel, %{"ts" => "1790000900.000100"}))

    counts =
      Triage.count_triage_threads(
        slack_channel_id: [channel.id, other_channel.id, "sch_none"],
        group_by: :slack_channel_id
      )

    assert counts == %{channel.id => 2, other_channel.id => 1}
  end

  test "a thread that is not there is not found" do
    assert {:error, :not_found} = Triage.get_triage_thread(Scope.for_user(%{id: nil}), "tth_missing")
  end
end
