defmodule Rail.Tools.Workers.StartAfterUsageResetTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  alias Rail.Repo
  alias Rail.Tools
  alias Rail.Tools.FollowerSupervisor
  alias Rail.Tools.Schemas.Backend
  alias Rail.Tools.Schemas.OsProcess
  alias Rail.Tools.Workers.StartAfterUsageReset

  # A turn waiting for its account's weekly window, the job for which is what is under test.
  setup %{project: project} do
    reset = DateTime.truncate(DateTime.shift(DateTime.utc_now(), hour: 3), :second)
    %{role: role} = run = project |> agent_run("claude-job-#{System.unique_integer([:positive])}") |> Repo.preload(:role)
    account = ready_backend(role.model, [{"Weekly", 0.0, reset}])
    {:ok, waiting} = Tools.start_os_process(run, ["2"])

    %{account: account, reset: reset, waiting: waiting}
  end

  test "snoozes until the next reset while the turn still waits", %{reset: reset, waiting: waiting} do
    reject(Tools, :spawn_os_process, 3)
    assert_enqueued(worker: StartAfterUsageReset, args: %{os_process_id: waiting.id}, scheduled_at: reset)

    assert {:snooze, seconds} = perform_job(StartAfterUsageReset, %{os_process_id: waiting.id})
    assert_in_delta seconds, DateTime.diff(reset, DateTime.utc_now()), 5
  end

  test "is done once the turn was stopped", %{waiting: waiting} do
    {:ok, _stopped} = Tools.stop_os_process(system_scope(), waiting)
    assert :ok = perform_job(StartAfterUsageReset, %{os_process_id: waiting.id})
  end

  test "is done once the turn has started", %{account: account, waiting: waiting} do
    account |> Backend.usage_changeset(%{name: :claude, status: :ready, usage: []}) |> Repo.update!()
    expect(Tools, :spawn_os_process, fn _executable, _args, _opts -> {:ok, nil, 4251} end)
    expect(FollowerSupervisor, :start_follower, fn _os_process, _opts -> {:ok, self()} end)

    assert :ok = perform_job(StartAfterUsageReset, %{os_process_id: waiting.id})
    assert %OsProcess{status: :running} = Repo.get!(OsProcess, waiting.id)
  end
end
