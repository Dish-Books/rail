defmodule Rail.Artifacts.Schemas.DemoTest do
  use Rail.DataCase, async: true

  alias Rail.Artifacts.Schemas.Demo

  describe "changeset/2" do
    test "valid changeset succeeds" do
      attrs = %{
        task_id: "tsk_demo_1",
        version: 1,
        recorded_at: DateTime.utc_now(),
        outcome: "recorded",
        segments: [
          %{
            criterion_index: 1,
            criterion: "Passes check",
            outcome: :recorded,
            frames: [
              %{
                url: "https://linear.app/asset/1.png",
                linear_asset_id: "ast_1",
                hold_ms: 1000
              }
            ]
          }
        ]
      }

      changeset = Demo.changeset(%Demo{}, attrs)
      assert changeset.valid?
      assert {:ok, %Demo{version: 1, outcome: "recorded"}} = Repo.insert(changeset)
    end

    test "requires mandatory fields" do
      changeset = Demo.changeset(%Demo{}, %{version: nil})
      refute changeset.valid?

      assert %{task_id: [_task_err], version: [_ver_err], recorded_at: [_rec_err], outcome: [_out_err]} =
               errors_on(changeset)
    end

    test "validates outcome inclusion" do
      changeset =
        Demo.changeset(%Demo{}, %{
          task_id: "tsk_1",
          version: 1,
          recorded_at: DateTime.utc_now(),
          outcome: "invalid_outcome"
        })

      refute changeset.valid?
      assert %{outcome: [_out_err]} = errors_on(changeset)
    end

    test "enforces unique constraint on [:task_id, :version]" do
      attrs = %{
        task_id: "tsk_uniq_demo",
        version: 1,
        recorded_at: DateTime.utc_now(),
        outcome: "recorded"
      }

      {:ok, _demo} = Repo.insert(Demo.changeset(%Demo{}, attrs))
      {:error, changeset} = Repo.insert(Demo.changeset(%Demo{}, attrs))
      assert %{task_id: [_task_err]} = errors_on(changeset)
    end
  end
end
