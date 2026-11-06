defmodule Rail.Pipeline.Utils.MatchesGlob do
  @moduledoc false

  @doc """
  Whether the repository path `path` matches `glob`: `*` and `?` stay inside one directory, `**` crosses any number,
  `**/` also matches none, and `{a,b}` is either.
  """
  def matches_glob?(path, glob) when is_binary(path) and is_binary(glob) do
    Regex.match?(~r/\A#{translate(String.trim(glob), "")}\z/, path)
  end

  defp translate("", regex), do: regex
  defp translate("**/" <> rest, regex), do: translate(rest, regex <> "(?:.*/)?")
  defp translate("**" <> rest, regex), do: translate(rest, regex <> ".*")
  defp translate("*" <> rest, regex), do: translate(rest, regex <> "[^/]*")
  defp translate("?" <> rest, regex), do: translate(rest, regex <> "[^/]")

  defp translate("{" <> rest, regex) do
    case String.split(rest, "}", parts: 2) do
      [choices, rest] ->
        either = choices |> String.split(",") |> Enum.map_join("|", &translate(&1, ""))
        translate(rest, regex <> "(?:" <> either <> ")")

      [_unclosed] ->
        translate(rest, regex <> "\\{")
    end
  end

  defp translate(<<char::utf8, rest::binary>>, regex), do: translate(rest, regex <> Regex.escape(<<char::utf8>>))
end
