defmodule Rail.Pipeline.Actions.ReconcileViewedDiffFilesTest do
  use Rail.DataCase, async: true

  alias Rail.Domain.Diff.FileDiff
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task

  test "returns unchanged task if all viewed files match parsed files" do
    expected = %{"lib/foo.ex" => "hash1", "lib/bar.ex" => "hash2"}

    task =
      create_test_task(%{
        viewed_diff_files: expected
      })

    files = [
      FileDiff.new(%{status: :modified, digest: "hash1", new_path: "lib/foo.ex"}),
      FileDiff.new(%{status: :modified, digest: "hash2", new_path: "lib/bar.ex"})
    ]

    assert {:ok, %Task{viewed_diff_files: ^expected}} =
             Pipeline.reconcile_viewed_diff_files(task, files)
  end

  test "drops viewed entries when file path is missing or digest changed, and updates database" do
    task =
      create_test_task(%{
        viewed_diff_files: %{
          "lib/keep.ex" => "hash_keep",
          "lib/changed.ex" => "old_hash",
          "lib/deleted.ex" => "deleted_hash"
        }
      })

    files = [
      FileDiff.new(%{status: :modified, digest: "hash_keep", new_path: "lib/keep.ex"}),
      FileDiff.new(%{status: :modified, digest: "new_hash", new_path: "lib/changed.ex"})
    ]

    expected = %{"lib/keep.ex" => "hash_keep"}

    assert {:ok, %Task{viewed_diff_files: ^expected}} =
             Pipeline.reconcile_viewed_diff_files(task, files)
  end

  test "handles empty or nil viewed_diff_files gracefully" do
    task = create_test_task(%{viewed_diff_files: %{}})
    files = [FileDiff.new(%{status: :modified, digest: "hash1", new_path: "lib/foo.ex"})]

    assert {:ok, %Task{viewed_diff_files: %{}}} =
             Pipeline.reconcile_viewed_diff_files(task, files)
  end
end
