defmodule Rail.Pipeline.Schemas.PlanCommentCapture do
  @moduledoc """
  What a design comment keeps of its element, taken at the click: the element's own HTML and the size of its box,
  in the page's 1920x1080 coordinates. Nothing else of the page is kept.
  """
  use Rail.Schema

  # The overlay cuts at the same length with the same mark, so a capture it cut is kept as it is.
  @html_max 20_000
  @cut_mark "<!-- Rail cut the element's HTML here, at 20,000 characters. -->"

  @primary_key false
  embedded_schema do
    field :html, :string
    field :width, :integer
    field :height, :integer
  end

  @doc """
  Builds a changeset for a capture, cutting HTML past 20,000 characters with Rail's mark.
  """
  def changeset(capture, attrs) do
    capture
    |> cast(attrs, [:html, :width, :height])
    |> validate_required([:html, :width, :height])
    |> update_change(:html, &cut/1)
    |> validate_number(:width, greater_than: 0)
    |> validate_number(:height, greater_than: 0)
  end

  defp cut(html) do
    kept = String.replace_suffix(html, @cut_mark, "")

    cond do
      String.length(html) <= @html_max -> html
      kept != html and String.length(kept) <= @html_max -> html
      true -> String.slice(html, 0, @html_max) <> @cut_mark
    end
  end
end
