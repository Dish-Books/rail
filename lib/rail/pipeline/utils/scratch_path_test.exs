defmodule Rail.Pipeline.Utils.ScratchPathTest do
  use Rail.DataCase, async: true

  import Rail.Pipeline.Utils.ScratchPath

  test "scratch_path nests the task scratch dir under the workspace root" do
    assert scratch_path("prj_13501", "tsk_13501") ==
             Path.join([System.tmp_dir!(), "rail", "prj_13501", "scratch", "tsk_13501"])
  end
end
