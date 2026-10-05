defmodule Rail.Mcp.Utils.RunToolSaveVerdictTest do
  use Rail.DataCase, async: true

  import Rail.Mcp.Utils.RunToolSaveVerdict

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.QaReport
  alias Rail.Pipeline.Schemas.Task

  setup do
    scratch = Path.join(System.tmp_dir!(), "rt_save_verdict_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(scratch) end)

    %{task: %Task{id: "tsk_rt_verdict", scratch_path: scratch, issue: %Issue{identifier: "RTV-1"}}}
  end

  test "a good save is receipted by its label", %{task: task} do
    assert {:ok, "Verdict saved: Passed. The pass is finished."} =
             run_tool_save_verdict(task, %{"verdict" => "pass", "summary" => "Works.", "findings" => []}, [])

    assert %QaReport{verdict: :pass} = Pipeline.read_qa_report(task)
  end

  test "a refusal is passed back as the changeset", %{task: task} do
    assert {:error, %Ecto.Changeset{valid?: false}} = run_tool_save_verdict(task, %{"verdict" => "great"}, [])
  end
end
