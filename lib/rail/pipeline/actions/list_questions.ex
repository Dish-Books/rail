defmodule Rail.Pipeline.Actions.ListQuestions do
  @moduledoc false

  import Ecto.Query

  alias Rail.Pipeline.Schemas.Question
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo

  @doc """
  Lists the questions every run of `task` asked.

  Filters by `:status`, one or a list of them, and orders by `:order_by` (newest
  first by default).
  """
  def list_questions(%Task{id: task_id}, opts \\ []) do
    order = Keyword.get(opts, :order_by, desc: :inserted_at)

    query = from(q in Question, where: q.task_id == ^task_id, order_by: ^order)

    query =
      case Keyword.fetch(opts, :status) do
        {:ok, statuses} when is_list(statuses) -> from(q in query, where: q.status in ^statuses)
        {:ok, status} -> from(q in query, where: q.status == ^status)
        :error -> query
      end

    Repo.all(query)
  end
end
