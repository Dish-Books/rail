defmodule Rail.Triage.Workers.TriageThreadTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  alias Rail.Triage.Schemas.Thread
  alias Rail.Triage.Workers.TriageThread

  setup do
    %{project: project} = triage_project()
    %{workspace: workspace, channel: channel} = connect_slack_channel(project)
    {:ok, thread} = Rail.Triage.handle_slack_event(workspace, slack_message_event(channel, %{}))
    %{thread: thread}
  end

  test "runs a pass on the thread, and passes a snooze through", %{thread: %{id: thread_id} = thread} do
    expect(Rail.Tools, :run_agent, fn _backend, _argv, _opts ->
      assert {:snooze, 30} = perform_job(TriageThread, %{thread_id: thread_id})
      thread |> Thread.scratch_path() |> Path.join("result.json") |> File.write!(Jason.encode!(%{"items" => []}))
      {:ok, ""}
    end)

    assert :ok = perform_job(TriageThread, %{thread_id: thread_id})
    assert %Thread{triage_started_at: nil} = Repo.get!(Thread, thread_id)
  end

  test "a thread that is gone is nothing to do" do
    assert :ok = perform_job(TriageThread, %{thread_id: "tth_gone"})
  end

  test "gives a pass forty minutes" do
    assert to_timeout(minute: 40) == TriageThread.timeout(%Oban.Job{})
  end
end
