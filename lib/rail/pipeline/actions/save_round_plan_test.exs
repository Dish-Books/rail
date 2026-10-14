defmodule Rail.Pipeline.Actions.SaveRoundPlanTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Round
  alias Rail.Pipeline.Schemas.Task

  setup %{project: project} do
    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_save_round_plan_1", "identifier" => "SRP-1", "title" => "Rounds"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{description: "Rounds"})
    {:ok, task} = Pipeline.create_task(issue, :plan)
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    %{task: task}
  end

  test "a later round's plan saves as the next version, and a second save replaces it, each broadcast",
       %{task: %Task{id: task_id} = task} do
    {:ok, _first} = Pipeline.create_round(task)
    {:ok, round} = Pipeline.create_round(task)
    Phoenix.PubSub.subscribe(Rail.PubSub, "outputs:#{task_id}")

    assert {:ok, %Round{plan: "Guard nil.", plan_version: 1, plan_saved_at: %DateTime{}, record_demo: false}} =
             Pipeline.save_round_plan(round, %{"plan" => "  Guard nil.\n"})

    # The round as first read, so the version comes from the row and not the caller's copy.
    assert {:ok, %Round{plan: "Guard nil everywhere.", plan_version: 2, record_demo: true}} =
             Pipeline.save_round_plan(round, %{"plan" => "Guard nil everywhere.", "record_demo" => true})

    assert_received {:output_saved, ^task_id}
    assert_received {:output_saved, ^task_id}
  end

  test "an empty plan is refused and nothing is saved", %{task: task} do
    {:ok, _first} = Pipeline.create_round(task)
    {:ok, round} = Pipeline.create_round(task)

    assert {:error, changeset} = Pipeline.save_round_plan(round, %{"plan" => "  "})
    assert %{plan: ["can't be blank"]} = errors_on(changeset)
    assert %Round{plan: nil, plan_version: 0} = Pipeline.read_plan(task)
  end

  test "an approved round's plan no longer changes", %{task: task} do
    {:ok, _first} = Pipeline.create_round(task)
    {:ok, round} = Pipeline.create_round(task)
    {:ok, saved} = Pipeline.save_round_plan(round, %{"plan" => "Guard nil."})
    saved |> Ecto.Changeset.change(approved_at: DateTime.utc_now()) |> Repo.update!()

    assert {:error, :round_approved} = Pipeline.save_round_plan(round, %{"plan" => "Something else."})
    assert %Round{plan: "Guard nil.", plan_version: 1} = Pipeline.read_plan(task)
  end
end
