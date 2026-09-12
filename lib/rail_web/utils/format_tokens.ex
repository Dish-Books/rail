defmodule RailWeb.Utils.FormatTokens do
  @moduledoc false

  @doc """
  Formats a token count compactly: `"1.23M"`, `"1.5K"`, `"500"`.

  `suffix: true` appends the word, singular where it should be.
  """
  def format_tokens(count, opts \\ [])

  def format_tokens(nil, opts), do: with_suffix("0", 0, opts)
  def format_tokens(count, opts) when is_float(count), do: format_tokens(round(count), opts)

  def format_tokens(count, opts) when is_integer(count) do
    count |> compact() |> with_suffix(count, opts)
  end

  defp compact(count) when count >= 1_000_000, do: "#{trim(count / 1_000_000, 2)}M"
  defp compact(count) when count >= 1_000, do: "#{trim(count / 1_000, 1)}K"
  defp compact(count), do: Integer.to_string(count)

  # A round number reads better without the zero after the point.
  defp trim(value, places) do
    rounded = Float.round(value, places)
    if rounded == Float.round(rounded), do: rounded |> trunc() |> Integer.to_string(), else: Float.to_string(rounded)
  end

  defp with_suffix(formatted, count, opts) do
    if Keyword.get(opts, :suffix, false) do
      "#{formatted} #{if count == 1, do: "token", else: "tokens"}"
    else
      formatted
    end
  end
end
