defmodule Rail.Pipeline.Actions.GetQuestion do
  @moduledoc false

  alias Rail.Pipeline.Schemas.Question
  alias Rail.Repo

  @doc """
  Gets a single question by ID.
  """
  def get_question(id) when is_binary(id) do
    case Repo.get(Question, id) do
      %Question{} = question -> {:ok, question}
      nil -> {:error, :not_found}
    end
  end
end
