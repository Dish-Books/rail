defmodule Rail.Pipeline.Utils.ReturnToEngineer do
  @moduledoc """
  A merge of the default branch into a task past Engineer, which Update branch makes, goes back there
  to be committed and sent to Review again; nothing else in Review moves a task back.
  """

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo

  @doc """
  Moves `task` back to the engineer stage when it has gone past it, starting
  nothing. Returns `{:ok, task}`, moved or not.
  """
  def return_to_engineer(%Task{} = task) do
    # Callers such as the diff pane can hold a task whose stage has since moved, and
    # the changeset diffs against the struct, so it has to carry the stage as stored.
    case Repo.get!(Task, task.id) do
      %Task{stage: :review} ->
        Pipeline.enter_stage(%{task | stage: :review}, :engineer, start: false)

      %Task{stage: stage} ->
        {:ok, %{task | stage: stage}}
    end
  end
end
