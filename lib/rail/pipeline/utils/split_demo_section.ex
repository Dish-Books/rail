defmodule Rail.Pipeline.Utils.SplitDemoSection do
  @moduledoc false

  @marker "\n\n## Demo\n"

  @doc """
  Splits a pull request body into what comes before its `## Demo` section, with
  trailing whitespace trimmed, and the section itself, or nil when there is none.
  """
  def split_demo_section(body) do
    case String.split(body || "", @marker, parts: 2) do
      [kept, demo] -> {String.trim_trailing(kept), "## Demo\n" <> demo}
      [kept] -> {String.trim_trailing(kept), nil}
    end
  end
end
