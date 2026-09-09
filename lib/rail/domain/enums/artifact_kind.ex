defmodule Rail.Domain.Enums.ArtifactKind do
  @moduledoc """
  The kind of artifact produced during QA or run execution.
  """
  use Rail.Domain.Enums.Type,
    values: [
      :text,
      :image
    ],
    labels: %{
      text: "Text",
      image: "Image"
    }

  @doc "Returns true if the artifact is text content."
  def text?(:text), do: true
  def text?(_other), do: false

  @doc "Returns true if the artifact is an image."
  def image?(:image), do: true
  def image?(_other), do: false
end
