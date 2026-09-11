defmodule Rail.Pipeline.Utils.ScratchPath do
  @moduledoc """
  The `$RAIL_SCRATCH` directory a task's agents read and write.
  """

  @doc """
  Returns the scratch directory for a task under the workspace root.
  """
  def scratch_path(project_id, task_id) when is_binary(project_id) and is_binary(task_id) do
    Path.join([System.tmp_dir!(), "rail", project_id, "scratch", task_id])
  end
end
