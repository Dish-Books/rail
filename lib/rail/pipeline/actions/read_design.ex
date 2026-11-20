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
  @max_rows 20

  @doc """
  Returns `task`'s design, or `nil` when the designer has not written a manifest
  that can be read.

  The design is `%{options: options, picked: key | nil, picked_at: time | nil}`. Each option is a map of
  its `:key`, `:title`, `:summary`, `:good_at` and `:costs` (lists of short
  phrases), `:assumptions`, `:html` (the page, or `nil` when it is not written
  yet), `:html_version` (a URL-safe digest of the page, or `nil` with it),
  `:html_path`, `:screenshot_path` and `:screenshot_version` (when the
  screenshot was last written, or `nil` when there is none), `:web`, whether the
  page marks a web screen, and `:rows`, its phone screens one per state in page
  order: `%{state: name | nil, ios: "ios-n" | nil, android: "android-n" | nil}`.
  An option without a usable key or title is no option, and a pick naming no
  option is no pick.

  A manifest written before options carried their tradeoffs has only `notes`,
  which stands in as the summary. `pages: false` leaves every `:html` and
  `:html_version` `nil`, `:web` false and `:rows` empty rather than reading the
  pages, for a caller that only counts.
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
    marks = marks(html)

    %{
      key: key,
      title: String.trim(title),
      summary: text(option["summary"]) || text(option["notes"]) || "",
      good_at: phrases(option["good_at"]),
      costs: phrases(option["costs"]),
      assumptions: text(option["assumptions"]) || "",
      html: html,
      html_version: html_version(html),
      web: Enum.any?(marks, &(&1.screen == "web")),
      rows: rows(marks),
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

  # Counted as the browser counts them: a template's content is no element, and a value is matched exactly.
  # Floki's parser takes any bytes, so a page that is no HTML has no marks rather than an error.
  defp marks(html) when is_binary(html) do
    for element <- html |> Floki.parse_document!() |> Floki.filter_out("template") |> Floki.find("[data-screen]"),
        [screen] = Floki.attribute(element, "data-screen"),
        screen in ["ios", "android", "web"] do
      %{screen: screen, state: state(Floki.attribute(element, "data-state"))}
    end
  end

  defp marks(nil), do: []

  # The page is the agent's, and a name in another encoding would break the page that shows it.
  defp state([name | _rest]) do
    case name |> String.replace_invalid() |> String.trim() |> String.slice(0, 120) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp state([]), do: nil

  # The nth iOS screen and the nth Android screen are one state, named by either, iOS first.
  defp rows(marks) do
    ios = Enum.filter(marks, &(&1.screen == "ios"))
    android = Enum.filter(marks, &(&1.screen == "android"))
    count = min(max(length(ios), length(android)), @max_rows)

    for n <- 1..count//1 do
      i = Enum.at(ios, n - 1)
      a = Enum.at(android, n - 1)
      %{state: (i && i.state) || (a && a.state), ios: i && "ios-#{n}", android: a && "android-#{n}"}
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
