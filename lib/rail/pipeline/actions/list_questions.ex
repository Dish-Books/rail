defmodule Rail.Pipeline.Actions.ListQuestions do
  @moduledoc false

  import Ecto.Query

  alias Rail.Pipeline.Schemas.Question
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Scope

  @doc """
  Lists questions for a task, project, or across projects, with optional filters.
  """
  def list_questions(%Scope{} = scope, target, opts) when is_list(opts) do
    if authorized?(scope) do
      fetch_questions(target, opts)
    else
      []
    end
  end

  def list_questions(%Scope{} = scope, opts) when is_list(opts) do
    list_questions(scope, nil, opts)
  end

  def list_questions(%Scope{} = scope, target) do
    list_questions(scope, target, [])
  end

  def list_questions(target, opts) when is_list(opts) do
    list_questions(Scope.for_system(), target, opts)
  end

  def list_questions(target) do
    list_questions(Scope.for_system(), target, [])
  end

  def list_questions do
    list_questions(Scope.for_system(), nil, [])
  end

  @doc """
  Lists pending questions for a project or across all projects.
  """
  def list_pending_questions(%Scope{} = scope, target, opts) when is_list(opts) do
    list_questions(scope, target, Keyword.put(opts, :status, :pending))
  end

  def list_pending_questions(%Scope{} = scope, opts) when is_list(opts) do
    list_pending_questions(scope, nil, opts)
  end

  def list_pending_questions(%Scope{} = scope, target) do
    list_pending_questions(scope, target, [])
  end

  def list_pending_questions(target, opts) when is_list(opts) do
    list_pending_questions(Scope.for_system(), target, opts)
  end

  def list_pending_questions(target) do
    list_pending_questions(Scope.for_system(), target, [])
  end

  def list_pending_questions do
    list_pending_questions(Scope.for_system(), nil, [])
  end

  defp authorized?(%Scope{system: true}), do: true
  defp authorized?(%Scope{user: %{}}), do: true
  defp authorized?(_scope), do: false

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
    Repo.all(from(q in query, order_by: ^order))
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
