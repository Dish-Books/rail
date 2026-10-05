defmodule Rail.Pipeline.Actions.ReadDesign do
  @moduledoc """
  Reads the design options the Designer saved into its task's scratch directory.

  The designer owns each option's `<key>.html` and `<key>.png`. Rail writes
  `<scratch>/design/manifest.json` from the options it saves, and owns
  `<scratch>/design/picked`, which holds the key of the option the human chose,
  and deletes the other options when it writes it. A manifest the designer wrote
  itself before that is still read the same way.
  """

  alias Rail.Pipeline.Schemas.Task

  @key ~r/\A[a-z0-9-]+\z/

  @doc """
  Returns `task`'s design, or `nil` when the designer has not written a manifest
  that can be read.

  The design is `%{options: options, picked: key | nil, picked_at: time | nil}`. Each option is a map of
  its `:key`, `:title`, `:summary`, `:good_at` and `:costs` (lists of short
  phrases), `:assumptions`, `:html` (the page, or `nil` when it is not written
  yet), `:html_version` (a URL-safe digest of the page, or `nil` with it),
  `:html_path`, `:screenshot_path` and `:screenshot_version` (when the
  screenshot was last written, or `nil` when there is none). An option without a
  usable key or title is no option, and a pick naming no option is no pick.

  A manifest written before options carried their tradeoffs has only `notes`,
  which stands in as the summary. `pages: false` leaves every `:html` and
  `:html_version` `nil` rather than reading the pages, for a caller that only counts.
  """
  def read_design(%Task{scratch_path: scratch_path}, opts \\ []) do
    dir = Path.join(scratch_path, "design")
    pages? = Keyword.get(opts, :pages, true)

    with {:ok, content} <- File.read(Path.join(dir, "manifest.json")),
         {:ok, %{"options" => options}} when is_list(options) <- Jason.decode(content) do
      options = options |> Enum.filter(&option?/1) |> Enum.map(&option(&1, dir, pages?))
      picked = picked(dir, options)
      %{options: options, picked: picked, picked_at: picked && version(Path.join(dir, "picked"), :datetime)}
    else
      _unreadable -> nil
    end
  end

  defp option?(%{"key" => key, "title" => title}) when is_binary(key) and is_binary(title) do
    Regex.match?(@key, key) and String.trim(title) != ""
  end

  defp option?(_malformed), do: false

  defp option(%{"key" => key, "title" => title} = option, dir, pages?) do
    html_path = Path.join(dir, "#{key}.html")
    screenshot_path = Path.join(dir, "#{key}.png")
    html = if pages?, do: html(html_path)

    %{
      key: key,
      title: String.trim(title),
      summary: text(option["summary"]) || text(option["notes"]) || "",
      good_at: phrases(option["good_at"]),
      costs: phrases(option["costs"]),
      assumptions: text(option["assumptions"]) || "",
      html: html,
      html_version: html_version(html),
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

  # Keyed on content, not mtime, so a same-second rewrite still reads as new and
  # an unchanged one does not reload the frame.
  defp html_version(html) when is_binary(html) do
    :sha256 |> :crypto.hash(html) |> binary_part(0, 12) |> Base.url_encode64(padding: false)
  end

  defp html_version(nil), do: nil

  defp version(path, as \\ :posix) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{mtime: mtime}} -> if as == :datetime, do: DateTime.from_unix!(mtime), else: mtime
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
