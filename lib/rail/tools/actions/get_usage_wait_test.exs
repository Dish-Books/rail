defmodule Rail.Tools.Actions.GetUsageWaitTest do
  use Rail.DataCase, async: true

  alias Rail.Pipeline
  alias Rail.Repo
  alias Rail.Tools
  alias Rail.Tools.FollowerSupervisor
  alias Rail.Tools.Schemas.Backend
  alias Rail.Tools.Schemas.OsProcess

  setup %{project: project} do
    model = "claude-wait-#{System.unique_integer([:positive])}"
    run = agent_run(project, model)
    at = fn hours -> DateTime.utc_now() |> DateTime.shift(hour: hours) |> DateTime.truncate(:second) end

    %{at: at, model: model, run: run}
  end

  test "lists each account offering the model, earliest reset first, and the signed-out ones last", %{
    at: at,
    model: model,
    run: run
  } do
    %{id: weekly_id} = ready_backend(model, [{"Weekly", 0.0, at.(30)}], %{label: "work"})
    %{id: session_id} = ready_backend(model, [{"Session", 0.0, at.(2)}, {"Weekly", 40.0, at.(50)}], %{label: "max-2"})
    %{id: ops_id} = ready_backend(model, [], %{label: "ops", status: :signed_out})
    soonest = at.(2)

    assert {:ok, %OsProcess{id: waiting_id}} = Tools.start_os_process(run, ["2"])

    assert {:ok,
            %{
              os_process: %OsProcess{id: ^waiting_id},
              pinned: nil,
              model: ^model,
              resets_at: ^soonest,
              accounts: [
                %{
                  backend: %Backend{id: ^session_id},
                  waited_on?: true,
                  window: %{label: "5-hour", remaining_percent: +0.0}
                },
                %{backend: %Backend{id: ^weekly_id}, waited_on?: true, window: %{label: "Weekly"}},
                %{backend: %Backend{id: ^ops_id}, waited_on?: false, window: nil, resets_at: nil}
              ]
            }} = Tools.get_usage_wait(run)
  end

  test "a resumed conversation waits on its own account alone", %{at: at, model: model, run: run} do
    %{id: home_id} = home = ready_backend(model, [], %{label: "home"})
    reset = at.(5)

    stub(Tools, :spawn_os_process, fn _executable, _args, _opts -> {:ok, nil, 4260} end)
    stub(FollowerSupervisor, :start_follower, fn _os_process, _opts -> {:ok, self()} end)
    assert {:ok, %OsProcess{id: first_id, backend_id: ^home_id}} = Tools.start_os_process(run, ["2"])

    OsProcess |> Repo.get!(first_id) |> OsProcess.changeset(%{status: :finished}) |> Repo.update!()
    {:ok, run} = Pipeline.update_run(run, %{conversation_id: "sess-home", status: :finished})
    _elsewhere = ready_backend(model, [{"Weekly", 0.0, at.(1)}], %{label: "elsewhere"})

    home
    |> Backend.usage_changeset(%{
      name: :claude,
      status: :ready,
      usage: [
        %{
          name: "Weekly",
          details: %{
            "windows" => [%{"label" => "Weekly", "remaining_percent" => 0.0, "resets_at" => DateTime.to_iso8601(reset)}]
          }
        }
      ]
    })
    |> Repo.update!()

    assert {:ok, %OsProcess{status: :waiting_for_usage}} = Tools.start_os_process(run, ["2"])

    assert {:ok, %{pinned: %Backend{id: ^home_id}, resets_at: ^reset, accounts: [%{backend: %Backend{id: ^home_id}}]}} =
             Tools.get_usage_wait(run)
  end

  test "an account that has room again shows no reset", %{at: at, model: model, run: run} do
    spent = ready_backend(model, [{"Weekly", 0.0, at.(3)}])
    assert {:ok, %OsProcess{status: :waiting_for_usage}} = Tools.start_os_process(run, ["2"])
    spent |> Backend.usage_changeset(%{name: :claude, status: :ready, usage: []}) |> Repo.update!()

    assert {:ok, %{resets_at: nil, accounts: [%{waited_on?: true, window: nil, resets_at: nil}]}} =
             Tools.get_usage_wait(run)
  end

  test "a run not waiting for usage has no wait", %{run: run} do
    assert {:error, :not_waiting} = Tools.get_usage_wait(run)
  end
end
