defmodule Rail.Artifacts.Actions.MarkDemoStaleTest do
  use Rail.DataCase, async: true

  alias Rail.Artifacts
  alias Rail.Artifacts.Schemas.Demo
  alias Rail.Scope

  describe "mark_demo_stale/3" do
    test "rejects unauthorized scope" do
      scope = %Scope{user: nil, system: false}
      assert {:error, :not_authorized} = Artifacts.mark_demo_stale(scope, "tsk_1")
      assert {:error, :not_authorized} = Artifacts.mark_demo_stale(:bad_scope, "tsk_1")
    end

    test "returns :not_found when task has no demos" do
      scope = Scope.for_system()
      assert {:error, :not_found} = Artifacts.mark_demo_stale(scope, "tsk_nonexistent")
    end

    test "marks the latest demo version as stale" do
      scope = Scope.user_scope()

      {:ok, _d1} =
        %Demo{}
        |> Demo.changeset(%{
          task_id: "tsk_stale_1",
          version: 1,
          recorded_at: DateTime.utc_now(),
          outcome: "recorded",
          stale: false
        })
        |> Repo.insert()

      {:ok, %Demo{id: expected_id}} =
        %Demo{}
        |> Demo.changeset(%{
          task_id: "tsk_stale_1",
          version: 2,
          recorded_at: DateTime.utc_now(),
          outcome: "recorded",
          stale: false
        })
        |> Repo.insert()

      assert {:ok, %Demo{id: ^expected_id, stale: true}} = Artifacts.mark_demo_stale(scope, "tsk_stale_1")

      # Also test struct target and other target
      assert {:ok, %Demo{}} = Artifacts.mark_demo_stale(scope, %{id: "tsk_stale_1"})
      assert {:ok, %Demo{}} = Artifacts.mark_demo_stale(scope, :tsk_stale_1)
    end
  end
end
