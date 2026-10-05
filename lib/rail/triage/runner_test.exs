defmodule Rail.Triage.RunnerTest do
  # The runner acts on every "triage" broadcast from processes no test owns, so its
  # stubs and sandbox are shared and nothing may run beside it.
  use Rail.DataCase, async: false

  alias Rail.Tools
  alias Rail.Triage
  alias Rail.Triage.Runner
  alias Rail.Triage.Schemas.Thread

  setup :set_mimic_global

  setup do
    Req.Test.set_req_test_to_shared()
    on_exit(fn -> Req.Test.set_req_test_to_private() end)

    %{project: project} = triage_project()
    %{workspace: workspace, channel: channel} = connect_slack_channel(project)
    {:ok, thread} = Triage.handle_slack_event(workspace, slack_message_event(channel, %{}))

    %{
      workspace: workspace,
      channel: channel,
      thread: thread,
      result_path: Path.join(Thread.scratch_path(thread), "result.json")
    }
  end

  test "on start it frees the locks a dead pass left and runs every thread still Triaging", %{
    thread: %{id: thread_id},
    result_path: result_path
  } do
    Repo.update_all(from(t in Thread, where: t.id == ^thread_id), set: [triage_started_at: DateTime.utc_now()])
    test = self()

    expect(Tools, :run_agent, fn _role, _argv, _opts ->
      send(test, :agent_ran)
      File.write!(result_path, Jason.encode!(%{"items" => [triage_bug()]}))
      {:ok, ""}
    end)

    start_supervised!({Runner, enabled: true})

    assert_receive :agent_ran, 5_000
    eventually(fn -> assert %Thread{status: :waiting, triage_started_at: nil} = Repo.get!(Thread, thread_id) end, 5_000)
  end

  test "reads a burst once, and gives a message that lands mid-pass a pass of its own", %{
    workspace: workspace,
    channel: channel,
    thread: %{id: thread_id} = thread,
    result_path: result_path
  } do
    Repo.update_all(from(t in Thread, where: t.id == ^thread_id), set: [status: :waiting])
    start_supervised!({Runner, enabled: true})
    test = self()

    Tools
    |> expect(:run_agent, fn _role, _argv, _opts ->
      send(test, :first_pass)

      Triage.handle_slack_event(
        workspace,
        slack_message_event(channel, %{"ts" => "1790000900.000100", "thread_ts" => thread.external_id})
      )

      File.write!(result_path, Jason.encode!(%{"items" => []}))
      {:ok, ""}
    end)
    |> expect(:run_agent, fn _role, _argv, _opts ->
      send(test, :second_pass)
      File.write!(result_path, Jason.encode!(%{"items" => []}))
      {:ok, ""}
    end)

    Phoenix.PubSub.broadcast(Rail.PubSub, "triage", {:triage_scheduled, thread_id, 20})
    Phoenix.PubSub.broadcast(Rail.PubSub, "triage", {:triage_scheduled, thread_id, 20})

    assert_receive :first_pass, 5_000
    assert_receive :second_pass, 5_000
    eventually(fn -> assert %Thread{status: :waiting, triage_started_at: nil} = Repo.get!(Thread, thread_id) end, 5_000)
  end

  test "a pass that finds its thread locked tries again", %{thread: %{id: thread_id}, result_path: result_path} do
    # Starting frees every lock and runs every thread still Triaging, so the lock is only
    # taken once that is over, on a thread it did not pick up.
    Repo.update_all(from(t in Thread, where: t.id == ^thread_id), set: [status: :waiting])
    runner = start_supervised!({Runner, enabled: true, retry_after: 20})
    _recovered = :sys.get_state(runner)
    Repo.update_all(from(t in Thread, where: t.id == ^thread_id), set: [triage_started_at: DateTime.utc_now()])
    test = self()

    expect(Tools, :run_agent, fn _role, _argv, _opts ->
      send(test, :agent_ran)
      File.write!(result_path, Jason.encode!(%{"items" => []}))
      {:ok, ""}
    end)

    Phoenix.PubSub.broadcast(Rail.PubSub, "triage", {:triage_scheduled, thread_id, 0})
    refute_receive :agent_ran, 100

    Repo.update_all(from(t in Thread, where: t.id == ^thread_id), set: [triage_started_at: nil])
    assert_receive :agent_ran, 5_000
  end

  test "a pass that waited for usage runs again at the reset", %{thread: %{id: thread_id}, result_path: result_path} do
    Repo.update_all(from(t in Thread, where: t.id == ^thread_id), set: [status: :waiting])
    runner = start_supervised!({Runner, enabled: true, retry_after: 60_000})
    _recovered = :sys.get_state(runner)
    test = self()

    Tools
    |> expect(:run_agent, fn _role, _argv, _opts ->
      send(test, :waited)
      {:error, {:waiting_for_usage, DateTime.add(DateTime.utc_now(), 300, :millisecond)}}
    end)
    |> expect(:run_agent, fn _role, _argv, _opts ->
      send(test, :ran_after_reset)
      File.write!(result_path, Jason.encode!(%{"items" => []}))
      {:ok, ""}
    end)

    Phoenix.PubSub.broadcast(Rail.PubSub, "triage", {:triage_scheduled, thread_id, 0})

    assert_receive :waited, 5_000
    refute_receive :ran_after_reset, 100
    assert_receive :ran_after_reset, 5_000
  end

  test "a pass that crashes says so on its thread and lets go of it", %{thread: %{id: thread_id}} do
    stub(Tools, :run_agent, fn _role, _argv, _opts -> raise "agent exploded" end)

    start_supervised!({Runner, enabled: true})

    eventually(
      fn ->
        assert %Thread{status: :waiting, triage_started_at: nil, error: "Triage crashed: " <> _reason} =
                 Repo.get!(Thread, thread_id)
      end,
      5_000
    )
  end

  test "a thread that is gone is nothing to run, and a switched-off runner never starts", %{thread: %{id: thread_id}} do
    Repo.update_all(from(t in Thread, where: t.id == ^thread_id), set: [status: :waiting])
    pid = start_supervised!({Runner, enabled: true})
    Phoenix.PubSub.broadcast(Rail.PubSub, "triage", {:triage_scheduled, "tth_gone", 0})

    eventually(fn ->
      assert %{running: running, timers: timers} = :sys.get_state(pid)
      assert {0, 0} == {map_size(running), map_size(timers)}
    end)

    assert :ignore = Runner.start_link([])
  end
end
