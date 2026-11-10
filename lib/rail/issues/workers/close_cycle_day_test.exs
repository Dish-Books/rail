defmodule Rail.Issues.Workers.CloseCycleDayTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  alias Rail.Issues.Schemas.Cycle
  alias Rail.Issues.Workers.CloseCycleDay
  alias Rail.Projects

  test "runs the day for today's UTC date" do
    local_key = "WCD#{System.unique_integer([:positive])}"

    {:ok, %{id: local_id}} =
      Projects.create_project(system_scope(), %{
        name: "Nightly worker",
        github_repo: "example/#{local_key}",
        github_installation_id: 1,
        tracker: :local,
        key: local_key,
        default_branch: "main",
        clone_path: "/tmp/#{local_key}"
      })

    stub(Date, :utc_today, fn -> ~D[2026-11-10] end)

    assert :ok = perform_job(CloseCycleDay, %{})

    assert [%Cycle{number: 1, starts_on: ~D[2026-11-10]} | _later] =
             Repo.all(from(c in Cycle, where: c.project_id == ^local_id, order_by: c.number))
  end
end
