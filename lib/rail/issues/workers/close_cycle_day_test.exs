defmodule Rail.Issues.Workers.CloseCycleDayTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  alias Rail.Issues.Schemas.Cycle
  alias Rail.Issues.Workers.CloseCycleDay

  test "runs the day for today's UTC date" do
    %{id: local_id} = local_project()

    stub(Date, :utc_today, fn -> ~D[2026-11-10] end)

    assert :ok = perform_job(CloseCycleDay, %{})

    assert [%Cycle{number: 1, starts_on: ~D[2026-11-10]} | _later] =
             Repo.all(from(c in Cycle, where: c.project_id == ^local_id, order_by: c.number))
  end
end
