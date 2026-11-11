defmodule Rail.Learnings.Actions.EmbedDocument do
  @moduledoc """
  Embeds a text for storage with the model rules are embedded with, so another context's records can be searched by meaning.
  """

  alias Rail.Learnings.Clients.Vertex

  @doc "Returns `{:ok, embedding}` for `text`, or `{:error, reason}` when it cannot be embedded."
  def embed_document(text) when is_binary(text), do: Vertex.embed(text, "RETRIEVAL_DOCUMENT")
end
