defmodule Rail.Pipeline.Actions.SaveReportTest do
  use Rail.DataCase, async: true

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task

  setup do
    scratch = Path.join(System.tmp_dir!(), "save_report_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(scratch) end)

    %{task: %Task{id: "tsk_save_report", scratch_path: scratch}}
  end

  test "a report saves trimmed in place of the role's last, and is broadcast", %{task: task} do
    Phoenix.PubSub.subscribe(Rail.PubSub, "outputs:#{task.id}")

    assert {:ok, "Saving twice shows two rows."} = Pipeline.save_report(task, :qa, "  Saving twice shows two rows.\n")
    assert_received {:output_saved, "tsk_save_report"}

    assert {:ok, "One row now."} = Pipeline.save_report(task, :qa, "One row now.")
    assert [qa: "One row now."] = Pipeline.read_reports(task)
  end

  test "an empty report is refused and nothing is saved", %{task: task} do
    assert {:error, :empty_report} = Pipeline.save_report(task, :review, " \n ")
    assert [] = Pipeline.read_reports(task)
  end
end
