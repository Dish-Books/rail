defmodule Rail.Learnings.Workers.ScheduleCuratorsTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  alias Rail.Learnings.Workers.CurateLearnings
  alias Rail.Learnings.Workers.ScheduleCurators
  alias Rail.Projects

  test "queues one pass per active project, and scheduling again the same day adds none", %{project: project} do
    {:ok, inactive} =
      Projects.create_project(system_scope(), %{
        name: "Inactive #{System.unique_integer([:positive])}",
        github_repo: "example/inactive",
        github_installation_id: 1,
        default_branch: "main",
        key: "INA",
        clone_path: "/tmp/repos/inactive",
        active: false
      })

    assert :ok = perform_job(ScheduleCurators, %{})
    assert :ok = perform_job(ScheduleCurators, %{})

    assert [_one] = all_enqueued(worker: CurateLearnings, args: %{project_id: project.id})
    refute_enqueued(worker: CurateLearnings, args: %{project_id: inactive.id})
  end
end
