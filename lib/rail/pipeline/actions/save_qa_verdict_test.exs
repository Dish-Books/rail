defmodule Rail.Pipeline.Actions.SaveQaVerdictTest do
  use Rail.DataCase, async: true

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.QaReport
  alias Rail.Pipeline.Schemas.Task

  setup do
    scratch = Path.join(System.tmp_dir!(), "save_qa_verdict_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(scratch) end)

    task = %Task{
      id: "tsk_save_verdict_#{System.unique_integer([:positive])}",
      scratch_path: scratch,
      issue: %Issue{identifier: "SQV-1"}
    }

    Phoenix.PubSub.subscribe(Rail.PubSub, "outputs:#{task.id}")

    %{task: task}
  end

  test "a verdict Rail knows is written where read_qa_report reads it, and broadcast", %{task: %{id: task_id} = task} do
    assert {:ok, %QaReport{verdict: :concerns}} =
             Pipeline.save_qa_verdict(task, %{
               "verdict" => "concerns",
               "summary" => "Mostly works.",
               "not_checked" => "Mobile."
             })

    assert %QaReport{verdict: :concerns, summary: "Mostly works.", not_checked: "Mobile."} = Pipeline.read_qa_report(task)
    assert_received {:output_saved, ^task_id}
  end

  test "an unknown verdict or a blank summary is refused, and nothing is written", %{task: task} do
    assert {:error, changeset} = Pipeline.save_qa_verdict(task, %{"verdict" => "great", "summary" => ""})
    assert %{verdict: ["is invalid"], summary: ["can't be blank"]} = errors_on(changeset)
    assert Pipeline.read_qa_report(task) == nil
  end
end
