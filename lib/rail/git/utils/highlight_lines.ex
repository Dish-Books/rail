defmodule Rail.Git.Utils.HighlightLines do
  @moduledoc """
  Lines of code as highlighted HTML, one string out for every string in.

  Tree-sitter reads a file, not a line: a heredoc, a multi-line call or an open
  string means nothing on its own, so the lines go through as one block and come
  back split again. A diff's two sides are two blocks, because interleaving what
  was deleted with what replaced it is not code any parser would recognize.

  Nothing here is required to succeed. A language with no parser, a parser that
  cannot be reached and a block that comes back the wrong length all return
  `nil`s, and the caller draws the plain text it already has.
  """

  require Logger

  @doc """
  Highlights `lines` as the language `path` names.

  Returns a list as long as `lines`, each element the line's HTML or `nil` when
  it could not be highlighted.
  """
  def highlight_lines([], _path), do: []

  def highlight_lines(lines, path) do
    case language(path) do
      language when is_binary(language) -> highlight(lines, language)
      nil -> unhighlighted(lines)
    end
  end

  # A diff carries whatever the file carries, including bytes that are not text
  # at all, and a highlighter handed those raises. Nothing about drawing a diff
  # is worth a crash, so anything that goes wrong here is plain text instead.
  defp highlight(lines, language) do
    {:ok, html} = lines |> Enum.join("\n") |> Lumis.highlight(formatter: {:html_linked, language: language})

    split(html, lines)
  rescue
    error ->
      Logger.warning("Could not highlight #{language}: #{Exception.message(error)}")

      unhighlighted(lines)
  end

  # Lumis wraps each line in its own element, which is the split point: no token
  # of its own ever spans two lines, and the text inside is already escaped.
  defp split(html, lines) do
    highlighted =
      ~r|<div class="l-line"[^>]*>(.*?)</div>|s
      |> Regex.scan(html, capture: :all_but_first)
      |> Enum.map(fn [line] -> String.replace_suffix(line, "\n", "") end)

    if length(highlighted) == length(lines), do: highlighted, else: unhighlighted(lines)
  end

  defp unhighlighted(lines), do: Enum.map(lines, fn _line -> nil end)

  defp language(path) do
    case Lumis.Languages.guess(path) do
      "plaintext" -> nil
      "elixir" -> "elixir"
      language -> if Application.get_env(:rail, :fetch_parsers, true), do: language
    end
  end
end
