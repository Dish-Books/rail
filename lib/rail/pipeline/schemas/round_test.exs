defmodule Rail.Pipeline.Schemas.RoundTest do
  use Rail.DataCase, async: true

  alias Rail.Pipeline.Schemas.Round
  alias Rail.Pipeline.Schemas.Task

  describe "changeset/2" do
    test "a task's first round is round 1, with nothing on it" do
      assert %Ecto.Changeset{valid?: true, data: %Round{task_id: "tsk_round", number: 1, ticket: nil, design: nil}} =
               Round.changeset(%Task{id: "tsk_round"}, nil)
    end

    test "a later round is numbered one past the last and starts from its ticket and design, not its plan" do
      previous = %Round{
        number: 2,
        plan: "Guard nil.",
        approved_at: DateTime.utc_now(),
        ticket: %Round.Ticket{title: "A ticket", description: "The body."},
        design: %Round.Design{key: "rows", title: "Charts in the row"}
      }

      assert %Ecto.Changeset{
               valid?: true,
               data: %Round{
                 task_id: "tsk_round",
                 number: 3,
                 plan: nil,
                 approved_at: nil,
                 ticket: %Round.Ticket{title: "A ticket"},
                 design: %Round.Design{key: "rows"}
               }
             } = Round.changeset(%Task{id: "tsk_round"}, previous)
    end
  end

  describe "plan_changeset/2" do
    test "takes the trimmed plan as the next version" do
      changeset = Round.plan_changeset(%Round{plan_version: 3}, %{plan: "\nGuard nil.  ", record_demo: true})

      assert %Round{plan: "Guard nil.", plan_version: 4, plan_saved_at: %DateTime{}, record_demo: true} =
               Ecto.Changeset.apply_changes(changeset)
    end

    test "a plan is required" do
      assert %{plan: ["can't be blank"]} = errors_on(Round.plan_changeset(%Round{}, %{}))
    end
  end

  describe "state/1" do
    test "follows the round from planning to finished" do
      now = DateTime.utc_now()

      assert :planning = Round.state(%Round{})
      assert :waiting = Round.state(%Round{plan: "Guard nil."})
      assert :working = Round.state(%Round{plan: "Guard nil.", approved_at: now})
      assert :reviewed = Round.state(%Round{plan: "Guard nil.", approved_at: now, reviewed_at: now})
      assert :finished = Round.state(%Round{plan: "Guard nil.", approved_at: now, reviewed_at: now, finished_at: now})
    end
  end
end
