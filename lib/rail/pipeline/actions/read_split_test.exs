defmodule Rail.Pipeline.Actions.ReadSplitTest do
  use Rail.DataCase, async: true

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task

  setup do
    scratch = Path.join(System.tmp_dir!(), "read_split_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(scratch) end)

    %{
      task: %Task{scratch_path: scratch, issue: %Issue{identifier: "RSP-1"}},
      path: Path.join([scratch, "splits", "RSP-1.json"])
    }
  end

  test "no file is no split", %{task: task} do
    assert Pipeline.read_split(task) == nil
  end

  test "a saved split reads back numbered in order", %{task: task, path: path} do
    File.mkdir_p!(Path.dirname(path))

    File.write!(
      path,
      Jason.encode!(%{
        children: [
          %{title: "First", ticket: "One.", estimate: nil, plan: "## Implementation plan", builds_on: []},
          %{title: "Second", ticket: "Two.", estimate: 1, plan: "## Implementation plan", builds_on: [1]}
        ]
      })
    )

    assert %{
             children: [
               %{number: 1, title: "First", ticket: "One.", estimate: nil, builds_on: []},
               %{number: 2, title: "Second", estimate: 1, builds_on: [1]}
             ],
             saved_at: %DateTime{}
           } = Pipeline.read_split(task)
  end
end
