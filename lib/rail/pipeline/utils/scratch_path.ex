defmodule Rail.Pipeline.Utils.ScratchPath do
  @moduledoc """
  The scratch directory a task's agents read and write, named when the task is created.

  It lives in the repository rather than in the system's temp directory, and is
  ignored by git. What is in it - the ticket, the design options, the plan, the
  commit message, the review and the QA report with its screenshots - is the
  record of how a task was built, read back by the panels long after the agent
  that wrote it exited. macOS empties its temp directory of anything untouched
  for a few days, which took those files while the database kept every row that
  pointed at them.

  Each task stores the path it was given, so moving the root only affects tasks
  created afterwards.
  """

  @doc """
  Returns the scratch directory for a task under the workspace root.
  """
  def scratch_path(project_id, task_id) when is_binary(project_id) and is_binary(task_id) do
    Path.join([root(), project_id, "scratch", task_id])
  end

  defp root, do: Application.get_env(:rail, :scratch_root) || Path.join(File.cwd!(), "output")
end
