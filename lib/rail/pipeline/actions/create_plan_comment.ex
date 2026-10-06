defmodule Rail.Pipeline.Actions.CreatePlanComment do
  @moduledoc """
  Saves a comment on the Plan step's output, unsent, for the person writing it. A design comment is only for the
  picked option, and any comment only while the Plan run can take a message, as typing in its chat can.
  """

  import Rail.Pipeline.Utils.BroadcastPlanComments

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.PlanComment
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Scope

  @doc """
  Saves `attrs` as the scope user's comment on the task of the Plan `run`.

  Returns `{:ok, comment}`, `{:error, changeset}`, or `{:error, reason}` when the run cannot be messaged or the
  design has no pick, or the comment is not on it.
  """
  def create_plan_comment(%Scope{user: %{id: user_id}}, %Run{} = run, attrs) do
    changeset = PlanComment.changeset(%PlanComment{user_id: user_id}, attrs)

    # Read again, so a page drawn before the chat closed cannot write after it.
    with %Run{} = run <- Repo.get(Run, run.id),
         true <- Run.can_chat?(run) || {:error, :chat_unavailable},
         :ok <- validate_target(Repo.get!(Task, run.task_id), changeset),
         {:ok, comment} <- changeset |> Ecto.Changeset.put_change(:task_id, run.task_id) |> Repo.insert() do
      broadcast_plan_comments(run.task_id, user_id)
      {:ok, comment}
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_target(%Task{} = task, %Ecto.Changeset{valid?: true} = changeset) do
    key = Ecto.Changeset.get_field(changeset, :option_key)

    case Pipeline.read_design(task, pages: false) do
      %{picked: ^key} -> :ok
      %{picked: picked} when is_binary(picked) -> {:error, :not_the_pick}
      _no_pick -> {:error, :design_not_picked}
    end
  end

  defp validate_target(_task, changeset), do: {:error, changeset}
end
