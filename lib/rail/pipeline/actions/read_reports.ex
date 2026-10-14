defmodule Rail.Pipeline.Actions.ReadReports do
  @moduledoc """
  Reads the reports the engineer, QA and the code reviewer saved for the round a task is in.
  """

  alias Rail.Pipeline.Schemas.Task

  @roles [:engineer, :qa, :review]

  @doc """
  Returns `task`'s reports as a keyword list of `role: report`, in the order the roles work, leaving out a role
  that has saved none.
  """
  def read_reports(%Task{scratch_path: scratch_path}) do
    for role <- @roles,
        {:ok, report} <- [File.read(Path.join([scratch_path, "reports", "#{role}.md"]))],
        do: {role, String.trim(report)}
  end
end
