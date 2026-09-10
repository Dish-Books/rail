defmodule Rail.Pipeline.Actions.GetQuestion do
  @moduledoc false

  alias Rail.Pipeline.Schemas.Question
  alias Rail.Repo
  alias Rail.Scope

  @doc """
  Gets a single question by ID with scope authorization.
  """
  def get_question(%Scope{system: true}, id) when is_binary(id) do
    do_get_question(id)
  end

  def get_question(%Scope{user: %{}}, id) when is_binary(id) do
    do_get_question(id)
  end

  def get_question(_scope, _id), do: {:error, :not_authorized}

  def get_question(id) when is_binary(id) do
    get_question(Scope.for_system(), id)
  end

  @doc """
  Gets a single question by ID or raises Ecto.NoResultsError.
  """
  def get_question!(%Scope{system: true}, id) when is_binary(id) do
    Repo.get!(Question, id)
  end

  def get_question!(%Scope{user: %{}}, id) when is_binary(id) do
    Repo.get!(Question, id)
  end

  def get_question!(_scope, _id) do
    raise Ecto.NoResultsError, queryable: Question
  end

  def get_question!(id) when is_binary(id) do
    get_question!(Scope.for_system(), id)
  end

  defp do_get_question(id) do
    case Repo.get(Question, id) do
      %Question{} = question -> {:ok, question}
      nil -> {:error, :not_found}
    end
  end
end
