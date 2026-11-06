defmodule Rail.Pipeline.Actions.ReadStageOutputs do
  @moduledoc """
  Reads the outputs a task's custom stages saved, which every later stage is given.
  """

  import Rail.Pipeline.Utils.StageOutputPath

  alias Rail.Issues.Schemas.IssueStage
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo

  @doc """
  Returns each output saved so far as `%{name:, position:, markdown:, saved_at:}`, in the order the issue's sequence
  runs them. A file left empty or not UTF-8 reads as not saved, since an agent can write over it by hand.
  """
  def read_stage_outputs(%Task{} = task) do
    task = Repo.preload(task, :issue)

    for {%IssueStage{stage: :custom, name: name}, index} <- Enum.with_index(task.issue.stages, 1),
        path = stage_output_path(task, index, name),
        {:ok, markdown} <- [File.read(path)],
        String.valid?(markdown) and String.trim(markdown) != "",
        {:ok, %File.Stat{mtime: mtime}} <- [File.stat(path, time: :posix)] do
      %{name: name, position: index, markdown: String.trim(markdown), saved_at: DateTime.from_unix!(mtime)}
    end
  end
end
