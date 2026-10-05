defmodule Rail.Tools.Workers.StartAfterUsageResetTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Tools
  alias Rail.Tools.FollowerSupervisor
  alias Rail.Tools.Schemas.Backend
  alias Rail.Tools.Schemas.OsProcess
  alias Rail.Tools.Workers.StartAfterUsageReset

  # A QA turn waiting on its account's weekly window; the job at that reset is what is under test.
  setup %{project: project} do
    n = System.unique_integer([:positive])
    root = Path.join(System.tmp_dir!(), "usage_job_#{n}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    weekly_reset = DateTime.truncate(DateTime.shift(DateTime.utc_now(), hour: 3), :second)
    {:ok, qa} = Roles.get_role(project_id: project.id, stage: :qa)
    {:ok, qa} = Roles.update_role(system_scope(), qa, %{model: "claude-job-#{n}"})

    {:ok, backend} =
      Tools.create_backend(system_scope(), %{name: :claude, executable_path: "/usr/bin/true", models: [%{id: qa.model}]})

    spent = %{"label" => "Weekly", "remaining_percent" => 0, "resets_at" => DateTime.to_iso8601(weekly_reset)}

    account =
      Repo.update!(
        Backend.usage_changeset(backend, %{
          name: :claude,
          status: :ready,
          usage: [%{name: "Weekly", details: %{"windows" => [spent]}}]
        })
      )

    issue =
      Repo.insert!(
        Issue.changeset(%Issue{}, %{
          project_id: project.id,
          external_id: "lin_job_#{n}",
          identifier: "JOB#{n}-1",
          title: "Job",
          state: :backlog
        })
      )

    task =
      Repo.insert!(
        Task.changeset(
          %Task{},
          %{
            issue_id: issue.id,
            stage: :qa,
            worktree_name: "job-#{n}",
            worktree_path: root,
            scratch_path: Path.join(root, "scratch")
          },
          project.id
        )
      )

    {:ok, run} =
      Pipeline.create_run(%{task_id: task.id, role_id: qa.id, status: :starting, started_at: DateTime.utc_now()})

    {:ok, waiting} = Tools.start_os_process(run, ["2"])

    %{account: account, reset: weekly_reset, waiting: waiting}
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
