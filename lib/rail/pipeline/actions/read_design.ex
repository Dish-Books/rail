defmodule Rail.Pipeline.Actions.ReadDesign do
  @moduledoc """
  Reads the design options a design run wrote into its task's scratch directory.

  The designer owns `<scratch>/design/manifest.json` and each option's
  `<key>.html` and `<key>.png`; Rail owns `<scratch>/design/picked`, which holds
  the key of the option the human chose.
  """

  alias Rail.Pipeline.Schemas.Task

  @key ~r/\A[a-z0-9-]+\z/

  @doc """
  Returns `task`'s design, or `nil` when the designer has not written a manifest
  that can be read.

  The design is `%{options: options, picked: key | nil}`. Each option is a map of
  its `:key`, `:title`, `:summary`, `:good_at` and `:costs` (lists of short
  phrases), `:assumptions`, `:html` (the page, or `nil` when it is not written
  yet), `:html_path`, `:screenshot_path` and `:screenshot_version` (when the
  screenshot was last written, or `nil` when there is none). An option without a
  usable key or title is no option, and a pick naming no option is no pick.

  A manifest written before options carried their tradeoffs has only `notes`,
  which stands in as the summary.
  """
  def read_design(%Task{scratch_path: scratch_path}) do
    dir = Path.join(scratch_path, "design")

    with {:ok, content} <- File.read(Path.join(dir, "manifest.json")),
         {:ok, %{"options" => options}} when is_list(options) <- Jason.decode(content) do
      options = options |> Enum.filter(&option?/1) |> Enum.map(&option(&1, dir))
      %{options: options, picked: picked(dir, options)}
    else
      _unreadable -> nil
    end
  end

  defp option?(%{"key" => key, "title" => title}) when is_binary(key) and is_binary(title) do
    Regex.match?(@key, key) and String.trim(title) != ""
  end

  defp option?(_malformed), do: false

  defp option(%{"key" => key, "title" => title} = option, dir) do
    html_path = Path.join(dir, "#{key}.html")
    screenshot_path = Path.join(dir, "#{key}.png")

    %{
      key: key,
      title: String.trim(title),
      summary: text(option["summary"]) || text(option["notes"]) || "",
      good_at: phrases(option["good_at"]),
      costs: phrases(option["costs"]),
      assumptions: text(option["assumptions"]) || "",
      html: html(html_path),
      html_path: html_path,
      screenshot_path: screenshot_path,
      screenshot_version: version(screenshot_path)
    }
  end

  defp text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp text(_missing), do: nil

  defp phrases(values) when is_list(values), do: values |> Enum.map(&text/1) |> Enum.reject(&is_nil/1)
  defp phrases(_missing), do: []

  defp html(path) do
    case File.read(path) do
      {:ok, html} -> html
      {:error, _unwritten} -> nil
    end
  end

  defp version(path) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{mtime: mtime}} -> mtime
      {:error, _unwritten} -> nil
    end
  end

  defp picked(dir, options) do
    with {:ok, content} <- File.read(Path.join(dir, "picked")),
         key = String.trim(content),
         true <- Enum.any?(options, &(&1.key == key)) do
      key
    else
      _no_pick -> nil
    end
  end
end
