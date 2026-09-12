defmodule Rail.Pipeline.Actions.ListQuestions do
  @moduledoc false

  import Ecto.Query

  alias Rail.Pipeline.Schemas.Question
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo

  @doc """
  Lists questions for a task, project, or across projects, with optional filters.

  `target` is a `%Task{}`, a `%Project{}`, or `nil` for every project.
  """
  def list_questions(target \\ nil, opts \\ []) do
    # TODO: don't do wrapper functions, just do it inline
    fetch_questions(target, opts)
  end

  defp fetch_questions(target, opts) do
    query = base_query(target)

    query =
      case Keyword.get(opts, :status) do
        status when is_atom(status) and status != nil ->
          from(q in query, where: q.status == ^status)

        statuses when is_list(statuses) ->
          from(q in query, where: q.status in ^statuses)

        _other ->
          query
      end

    order = Keyword.get(opts, :order_by, desc: :inserted_at)
    query = from(q in query, order_by: ^order)

    query =
      case Keyword.get(opts, :preload) do
        preloads when is_list(preloads) and preloads != [] -> from(q in query, preload: ^preloads)
        _other -> query
      end

    Repo.all(query)
  end

  defp base_query(%Project{id: project_id}) do
    from(q in Question,
      join: t in Task,
      on: q.task_id == t.id,
      where: t.project_id == ^project_id
    )
  end

  defp base_query(%Task{id: task_id}) do
    from(q in Question, where: q.task_id == ^task_id)
  end

  defp base_query(id) when is_binary(id) do
    if String.starts_with?(id, "tsk_") do
      from(q in Question, where: q.task_id == ^id)
    else
      from(q in Question,
        join: t in Task,
        on: q.task_id == t.id,
        where: t.project_id == ^id
      )
    end
  end

  defp base_query(_other) do
    from(q in Question)
  end
end
