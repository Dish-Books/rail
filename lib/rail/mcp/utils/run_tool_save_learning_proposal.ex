defmodule Rail.Mcp.Utils.RunToolSaveLearningProposal do
  @moduledoc """
  Saves a rule change the curator proposes from a task, or revises one of its own still pending.
  """

  alias Rail.Learnings
  alias Rail.Learnings.Schemas.LearningProposal
  alias Rail.Pipeline.Schemas.Task

  @fields [:action, :proposal, :target, :title, :summary, :rule, :why, :kind, :path_glob]

  @doc "Saves the proposal `arguments` describe for `task`, or says why it was refused."
  def run_tool_save_learning_proposal(%Task{} = task, arguments, _opts) do
    # Only text passes, since the arguments come from an agent.
    attrs =
      @fields
      |> Map.new(fn key ->
        value = arguments[Atom.to_string(key)]
        {key, if(is_binary(value), do: value)}
      end)
      |> Map.put(:roles, if(is_list(arguments["roles"]), do: Enum.filter(arguments["roles"], &is_binary/1)))

    case Learnings.save_task_proposal(task, attrs) do
      {:ok, %LearningProposal{id: id}} ->
        {:ok, "Saved as #{id}. Save again with this id to change it."}

      {:error, :already_decided} ->
        {:refused, "Nothing saved: a person already decided that proposal, so it can no longer change."}

      {:error, :not_found} ->
        {:refused, "Nothing saved: no active or provisional rule, or proposal of this task's, has that id."}

      {:error, :bad_action} ->
        {:refused, "Nothing saved: `action` is add, rewrite or retire, or pass `proposal` to change one."}

      {:error, %Ecto.Changeset{}} = invalid ->
        invalid
    end
  end
end
