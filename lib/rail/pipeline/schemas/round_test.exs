defmodule Rail.Pipeline.Schemas.RoundTest do
  use Rail.DataCase, async: true

  alias Rail.Pipeline.Schemas.Round
  alias Rail.Pipeline.Schemas.Task

  describe "changeset/2" do
    test "builds the task's round by its number" do
      assert %Ecto.Changeset{valid?: true, data: %Round{task_id: "tsk_round", number: 2}} =
               Round.changeset(%Task{id: "tsk_round"}, 2)
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
