defmodule Rail.Tools.Actions.GetUsageWaitTest do
  use Rail.DataCase, async: true

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Tools
  alias Rail.Tools.FollowerSupervisor
  alias Rail.Tools.Schemas.Backend
  alias Rail.Tools.Schemas.OsProcess

  setup %{project: project} do
    unique = System.unique_integer([:positive])
    dir = Path.join(System.tmp_dir!(), "usage_wait_test_#{unique}")
    File.mkdir_p!(Path.join(dir, "worktree"))
    on_exit(fn -> File.rm_rf(dir) end)

    model = "claude-wait-#{unique}"
    {:ok, seeded} = Roles.get_role(project_id: project.id, stage: :engineer)
    {:ok, role} = Roles.update_role(system_scope(), seeded, %{model: model})

    issue =
      %Issue{}
      |> Issue.changeset(%{
        project_id: project.id,
        external_id: "lin_wait_#{unique}",
        identifier: "WAIT#{unique}-1",
        title: "Wait Issue",
        state: :backlog
      })
      |> Repo.insert!()

    task =
      %Task{}
      |> Task.changeset(
        %{
          issue_id: issue.id,
          stage: :engineer,
          worktree_name: "wait-#{unique}",
          worktree_path: Path.join(dir, "worktree"),
          scratch_path: Path.join(dir, "scratch")
        },
        project.id
      )
      |> Repo.insert!()

    {:ok, run} =
      Pipeline.create_run(%{task_id: task.id, role_id: role.id, status: :starting, started_at: DateTime.utc_now()})

    at = fn hours -> DateTime.utc_now() |> DateTime.shift(hour: hours) |> DateTime.truncate(:second) end

    # A signed-in account offering the role's model, each window `{label, percent left, hours to its reset}`.
    ready_backend = fn windows, attrs ->
      usage =
        Enum.map(windows, fn {label, left, hours} ->
          %{
            name: label,
            details: %{
              "windows" => [
                %{"label" => label, "remaining_percent" => left, "resets_at" => DateTime.to_iso8601(at.(hours))}
              ]
            }
          }
        end)

      {:ok, backend} =
        Tools.create_backend(system_scope(), %{
          name: :claude,
          label: attrs[:label],
          executable_path: "/usr/bin/true",
          models: [%{id: model}]
        })

      Repo.update!(Backend.usage_changeset(backend, %{name: :claude, status: attrs[:status] || :ready, usage: usage}))
    end

    %{at: at, model: model, ready_backend: ready_backend, run: run}
  end

  test "lists each account offering the model, earliest reset first, and the signed-out ones last", %{
    ready_backend: ready_backend,
    at: at,
    model: model,
    run: run
  } do
    %{id: weekly_id} = ready_backend.([{"Weekly", 0.0, 30}], %{label: "work"})
    %{id: session_id} = ready_backend.([{"Session", 0.0, 2}, {"Weekly", 40.0, 50}], %{label: "max-2"})
    %{id: ops_id} = ready_backend.([], %{label: "ops", status: :signed_out})
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

  test "a resumed conversation waits on its own account alone", %{
    ready_backend: ready_backend,
    at: at,
    run: run
  } do
    %{id: home_id} = home = ready_backend.([], %{label: "home"})
    reset = at.(5)

    stub(Tools, :spawn_os_process, fn _executable, _args, _opts -> {:ok, nil, 4260} end)
    stub(FollowerSupervisor, :start_follower, fn _os_process, _opts -> {:ok, self()} end)
    assert {:ok, %OsProcess{id: first_id, backend_id: ^home_id}} = Tools.start_os_process(run, ["2"])

    OsProcess |> Repo.get!(first_id) |> OsProcess.changeset(%{status: :finished}) |> Repo.update!()
    {:ok, run} = Pipeline.update_run(run, %{conversation_id: "sess-home", status: :finished})
    _elsewhere = ready_backend.([{"Weekly", 0.0, 1}], %{label: "elsewhere"})

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

  test "an account that has room again shows no reset", %{ready_backend: ready_backend, run: run} do
    spent = ready_backend.([{"Weekly", 0.0, 3}], %{})
    assert {:ok, %OsProcess{status: :waiting_for_usage}} = Tools.start_os_process(run, ["2"])
    spent |> Backend.usage_changeset(%{name: :claude, status: :ready, usage: []}) |> Repo.update!()

    assert {:ok, %{resets_at: nil, accounts: [%{waited_on?: true, window: nil, resets_at: nil}]}} =
             Tools.get_usage_wait(run)
  end

  test "a run not waiting for usage has no wait", %{run: run} do
    assert {:error, :not_waiting} = Tools.get_usage_wait(run)
  end
end
