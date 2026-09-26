defmodule Rail.Triage.Actions.RetriageThreadTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  alias Rail.Scope
  alias Rail.Tools
  alias Rail.Triage
  alias Rail.Triage.Schemas.Message
  alias Rail.Triage.Schemas.Thread
  alias Rail.Triage.Workers.TriageThread

  setup do
    %{project: project} = triage_project()
    %{workspace: workspace, channel: channel} = connect_slack_channel(project)
    {:ok, thread} = Triage.handle_slack_event(workspace, slack_message_event(channel, %{"text" => "sync at 11:30?"}))

    no_response = %{
      "messages" => [%{"ts" => thread.external_id, "needs_response" => false, "reason" => "Scheduling"}],
      "items" => []
    }

    thread = triage_with(thread, no_response)
    Repo.delete_all(Oban.Job)

    %{thread: thread}
  end

  test "Triage anyway reads the thread again, telling the agent a person asked", %{thread: %{id: thread_id} = thread} do
    assert %Thread{status: :done} = thread

    assert {:ok, %Thread{status: :triaging, forced: true}} = Triage.retriage_thread(Scope.for_user(%{id: nil}), thread)

    assert [%Message{triaged_at: nil, no_response_reason: nil}] =
             Repo.all(from m in Message, where: m.thread_id == ^thread_id)

    assert_enqueued(worker: TriageThread, args: %{thread_id: thread_id})

    expect(Tools, :run_agent, fn _backend, argv, _opts ->
      assert Enum.any?(argv, &(&1 =~ "A person asked for this thread to be triaged"))

      thread
      |> Thread.scratch_path()
      |> Path.join("result.json")
      |> File.write!(Jason.encode!(%{"items" => [triage_bug()]}))

      {:ok, ""}
    end)

    assert :ok = Triage.triage_thread(thread)
    assert %Thread{status: :waiting, forced: false} = Repo.get!(Thread, thread_id)
  end

  test "Triage again after a failure clears the error and runs a pass", %{thread: %{id: thread_id} = thread} do
    Repo.update_all(from(t in Thread, where: t.id == ^thread_id), set: [error: "Triage exited with code 1."])

    assert {:ok, %Thread{status: :triaging, error: nil}} = Triage.retriage_thread(Scope.for_user(%{id: nil}), thread)
  end
end
