defmodule Rail.Runs.PruneRunEventsTest do
  use Rail.DataCase, async: true

  alias Rail.Domain.TaskUsage
  alias Rail.Runs
  alias Rail.Runs.Schemas.RoleRun
  alias Rail.Runs.Schemas.RunEvent

  test "prunes run_events and marks role_runs older than retention days as pruned" do
    past_date = DateTime.shift(DateTime.utc_now(), week: -5)

    role_run =
      create_test_role_run(%{
        status: :finished,
        completed_at: past_date,
        inserted_at: past_date,
        exit_code: 0,
        output: "Finished old run",
        error: nil,
        usage: %TaskUsage{input_tokens: 200, output_tokens: 100},
        pruned: false
      })

    create_test_run_event(%{
      role_run_id: role_run.id,
      seq: 1,
      line: ~s({"type":"init"}),
      inserted_at: past_date
    })

    create_test_run_event(%{
      role_run_id: role_run.id,
      seq: 2,
      line: ~s({"type":"output","chunk":"hello"}),
      inserted_at: past_date
    })

    assert {:ok, %{pruned_events: 2, pruned_role_runs: 1}} = Runs.prune_run_events()

    # Verify events deleted
    assert [] = Repo.all(Ecto.Query.from(e in RunEvent, where: e.role_run_id == ^role_run.id))

    # Verify role_run marked pruned, but metadata preserved
    assert %RoleRun{
             pruned: true,
             exit_code: 0,
             output: "Finished old run",
             error: nil,
             usage: %TaskUsage{input_tokens: 200, output_tokens: 100}
           } = Repo.get!(RoleRun, role_run.id)
  end

  test "preserves recent run_events and leaves recent role_runs unpruned" do
    recent_date = DateTime.shift(DateTime.utc_now(), day: -5)

    role_run =
      create_test_role_run(%{
        status: :finished,
        completed_at: recent_date,
        inserted_at: recent_date,
        exit_code: 0,
        output: "Recent run output",
        pruned: false
      })

    %RunEvent{id: event_id} =
      create_test_run_event(%{
        role_run_id: role_run.id,
        seq: 1,
        line: ~s({"type":"recent_event"}),
        inserted_at: recent_date
      })

    assert {:ok, %{pruned_events: 0, pruned_role_runs: 0}} = Runs.prune_run_events()

    assert [%RunEvent{id: ^event_id}] = Repo.all(Ecto.Query.from(e in RunEvent, where: e.role_run_id == ^role_run.id))
    assert %RoleRun{pruned: false} = Repo.get!(RoleRun, role_run.id)
  end

  test "does not prune active in-flight runs even if started past cutoff" do
    past_date = DateTime.shift(DateTime.utc_now(), day: -40)

    running_role_run =
      create_test_role_run(%{
        status: :running,
        started_at: past_date,
        completed_at: nil,
        inserted_at: past_date,
        pruned: false
      })

    starting_role_run =
      create_test_role_run(%{
        status: :starting,
        started_at: past_date,
        completed_at: nil,
        inserted_at: past_date,
        pruned: false
      })

    create_test_run_event(%{
      role_run_id: running_role_run.id,
      seq: 1,
      line: ~s({"type":"running_event"}),
      inserted_at: past_date
    })

    create_test_run_event(%{
      role_run_id: starting_role_run.id,
      seq: 1,
      line: ~s({"type":"starting_event"}),
      inserted_at: past_date
    })

    assert {:ok, %{pruned_events: 0, pruned_role_runs: 0}} = Runs.prune_run_events()

    assert %RoleRun{pruned: false} = Repo.get!(RoleRun, running_role_run.id)
    assert %RoleRun{pruned: false} = Repo.get!(RoleRun, starting_role_run.id)
  end

  test "supports custom cutoff and retention_days options" do
    past_10_days = DateTime.shift(DateTime.utc_now(), day: -10)

    role_run =
      create_test_role_run(%{
        status: :finished,
        completed_at: past_10_days,
        inserted_at: past_10_days,
        pruned: false
      })

    create_test_run_event(%{
      role_run_id: role_run.id,
      seq: 1,
      inserted_at: past_10_days
    })

    # Default 30 days leaves 10-day-old run untouched
    assert {:ok, %{pruned_events: 0, pruned_role_runs: 0}} = Runs.prune_run_events()

    # Custom retention of 7 days prunes it
    assert {:ok, %{pruned_events: 1, pruned_role_runs: 1}} =
             Runs.prune_run_events(retention_days: 7)

    assert %RoleRun{pruned: true} = Repo.get!(RoleRun, role_run.id)
  end

  test "idempotent when runs are already pruned" do
    past_date = DateTime.shift(DateTime.utc_now(), day: -50)

    role_run =
      create_test_role_run(%{
        status: :finished,
        completed_at: past_date,
        inserted_at: past_date,
        pruned: true
      })

    assert {:ok, %{pruned_events: 0, pruned_role_runs: 0}} = Runs.prune_run_events()
    assert %RoleRun{pruned: true} = Repo.get!(RoleRun, role_run.id)
  end
end
