defmodule Rail.Learnings.Actions.EmbedQuery do
  @moduledoc """
  Embeds a search the way `list_learnings/1` would, so a caller searching again with the same words can reuse it.
  """

  alias Rail.Learnings.Clients.Vertex

  @doc "Returns `{:ok, embedding}` for `query`, or `{:error, reason}` when it cannot be embedded."
  def embed_query(query) when is_binary(query), do: Vertex.embed(String.trim(query), "RETRIEVAL_QUERY")
end
