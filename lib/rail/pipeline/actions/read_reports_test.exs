defmodule Rail.Pipeline.Actions.ReadReportsTest do
  use Rail.DataCase, async: true

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task

  test "reads the round's reports in the order the roles work, leaving out a role with none" do
    scratch = Path.join(System.tmp_dir!(), "read_reports_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(scratch) end)
    task = %Task{id: "tsk_read_reports", scratch_path: scratch}

    assert [] = Pipeline.read_reports(task)

    {:ok, _saved} = Pipeline.save_report(task, :review, "Nothing to report.")
    {:ok, _saved} = Pipeline.save_report(task, :engineer, "Guarded the nil.")

    assert [engineer: "Guarded the nil.", review: "Nothing to report."] = Pipeline.read_reports(task)
  end
end
