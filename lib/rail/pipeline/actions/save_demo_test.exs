defmodule Rail.Pipeline.Actions.SaveDemoTest do
  use Rail.DataCase, async: true

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Demo
  alias Rail.Pipeline.Schemas.Task

  setup do
    scratch = Path.join(System.tmp_dir!(), "save_demo_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(scratch) end)

    task = %Task{
      id: "tsk_save_demo_#{System.unique_integer([:positive])}",
      scratch_path: scratch,
      issue: %Issue{identifier: "SVD-1"}
    }

    Phoenix.PubSub.subscribe(Rail.PubSub, "outputs:#{task.id}")

    %{task: task}
  end

  test "a write-up is written where read_demo reads it, and broadcast", %{task: %{id: task_id} = task} do
    assert {:ok, %Demo{title: "Rounds of comments"}} =
             Pipeline.save_demo(task, %{"title" => "Rounds of comments", "summary" => "Comments go as one round."})

    assert %Demo{title: "Rounds of comments", summary: "Comments go as one round.", not_shown: nil} =
             Pipeline.read_demo(task)

    assert_received {:output_saved, ^task_id}
  end

  test "a write-up with no summary is refused", %{task: task} do
    assert {:error, changeset} = Pipeline.save_demo(task, %{"title" => "Rounds of comments"})
    assert %{summary: ["can't be blank"]} = errors_on(changeset)
    assert Pipeline.read_demo(task) == nil
  end
end
