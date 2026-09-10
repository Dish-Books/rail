defmodule Rail.Pipeline.Actions.SetDiffFileViewedTest do
  use Rail.DataCase, async: true

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task

  test "sets viewed status and digest for a file" do
    task = create_test_task(%{viewed_diff_files: %{}})
    expected = %{"lib/example.ex" => "sha256_abc"}

    assert {:ok, %Task{viewed_diff_files: ^expected}} =
             Pipeline.set_diff_file_viewed(task, "lib/example.ex", "sha256_abc", true)
  end

  test "supports scope as first argument and unsets viewed status when viewed is false" do
    scope = Rail.Scope.for_system()

    task =
      create_test_task(%{
        viewed_diff_files: %{"lib/example.ex" => "sha256_abc", "lib/other.ex" => "sha256_def"}
      })

    expected = %{"lib/other.ex" => "sha256_def"}

    assert {:ok, %Task{viewed_diff_files: ^expected}} =
             Pipeline.set_diff_file_viewed(scope, task, "lib/example.ex", "sha256_abc", false)
  end
end
