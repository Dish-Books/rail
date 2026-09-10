defmodule Rail.Artifacts.Schemas.DesignTest do
  use Rail.DataCase, async: true

  alias Rail.Artifacts.Schemas.Design
  alias Rail.Domain.Embeds.DesignDirection

  describe "changeset/2" do
    test "valid changeset succeeds" do
      attrs = %{
        task_id: "tsk_123",
        version: 1,
        canvas_url: "https://canvas.example.com/d/1",
        picked_key: "dir_a",
        directions: [
          %{
            key: "dir_a",
            title: "Direction A",
            notes: "Notes A",
            still_url: "https://example.com/still.png",
            linear_asset_id: "lin_ast_1"
          }
        ]
      }

      changeset = Design.changeset(%Design{}, attrs)
      assert changeset.valid?
      assert {:ok, %Design{version: 1}} = Repo.insert(changeset)
    end

    test "requires mandatory fields" do
      changeset = Design.changeset(%Design{}, %{version: nil})
      refute changeset.valid?
      assert %{task_id: [_task_err], version: [_ver_err], canvas_url: [_url_err]} = errors_on(changeset)
    end

    test "enforces version greater than or equal to 1" do
      changeset = Design.changeset(%Design{}, %{task_id: "tsk_1", canvas_url: "https://x.com", version: 0})
      refute changeset.valid?
      assert %{version: [_ver_err]} = errors_on(changeset)
    end

    test "enforces unique constraint on [:task_id, :version]" do
      attrs = %{
        task_id: "tsk_uniq_1",
        version: 1,
        canvas_url: "https://canvas.example.com/1"
      }

      {:ok, _design} = Repo.insert(Design.changeset(%Design{}, attrs))
      {:error, changeset} = Repo.insert(Design.changeset(%Design{}, attrs))
      assert %{task_id: [_task_err]} = errors_on(changeset)
    end
  end
end
