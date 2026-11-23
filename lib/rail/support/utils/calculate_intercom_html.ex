defmodule Rail.Support.Utils.CalculateIntercomHtml do
  @moduledoc false

  @doc """
  The HTML Intercom takes a reply's body as: a paragraph per blank-line break, a line break per newline.
  """
  def calculate_intercom_html(text) when is_binary(text) do
    text
    |> String.split(~r/\n{2,}/, trim: true)
    |> Enum.map_join(fn paragraph ->
      escaped = paragraph |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
      "<p>" <> String.replace(escaped, "\n", "<br>") <> "</p>"
    end)
  end
end
