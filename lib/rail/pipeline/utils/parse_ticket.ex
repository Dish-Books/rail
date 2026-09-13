defmodule Rail.Pipeline.Utils.ParseTicket do
  @moduledoc false
  alias Rail.Issues.Schemas.Issue

  @doc """
  Reads the ticket the product role wrote to `<scratch>/tickets/<identifier>.md`.

  The canonical form is a `---` front matter block carrying `title`, and
  optionally `priority` and `estimate`, with everything below it the description:

      ---
      title: Journal Entry shows its source document's attachments
      priority: high
      estimate: 3
      ---
      The problem paragraph...

  Tickets written before the front matter existed lead with a `# ` heading
  instead, and are still read that way.
  """
  def parse_ticket(nil), do: %{title: "", description: "", priority: nil, estimate: nil}

  def parse_ticket(content) when is_binary(content) do
    normalized = String.replace(content, "\r\n", "\n")

    case split_front_matter(normalized) do
      {:ok, fields, body} -> from_front_matter(fields, body)
      :none -> parse_heading_form(normalized)
    end
  end

  defp parse_heading_form(content) do
    lines = String.split(content, "\n")

    case Enum.find_index(lines, &String.starts_with?(String.trim_leading(&1), "# ")) do
      index when is_integer(index) ->
        title =
          lines
          |> Enum.at(index)
          |> String.trim_leading()
          |> String.replace_prefix("# ", "")
          |> String.trim()

        description = lines |> Enum.drop(index + 1) |> Enum.join("\n") |> String.trim()

        ticket(title, description)

      nil ->
        ticket("", String.trim(content))
    end
  end

  defp split_front_matter(content) do
    case String.split(content, "\n") do
      ["---" | rest] ->
        case Enum.find_index(rest, &(String.trim_trailing(&1) == "---")) do
          index when is_integer(index) ->
            {field_lines, body_lines} = Enum.split(rest, index)
            body = body_lines |> Enum.drop(1) |> Enum.join("\n")
            {:ok, parse_front_matter_fields(field_lines), body}

          nil ->
            :none
        end

      _no_delimiter ->
        :none
    end
  end

  defp parse_front_matter_fields(lines) do
    Map.new(lines, fn line ->
      case String.split(line, ":", parts: 2) do
        [key, value] -> {key |> String.trim() |> String.downcase(), unquote_value(value)}
        [key] -> {key |> String.trim() |> String.downcase(), ""}
      end
    end)
  end

  defp unquote_value(value) do
    trimmed = String.trim(value)

    if quoted?(trimmed) do
      trimmed |> String.slice(1..-2//1) |> String.trim()
    else
      trimmed
    end
  end

  defp quoted?(value) do
    String.length(value) > 1 and
      ((String.starts_with?(value, "\"") and String.ends_with?(value, "\"")) or
         (String.starts_with?(value, "'") and String.ends_with?(value, "'")))
  end

  # Front matter with no usable title is a ticket the agent wrote in the older
  # form with a stray delimiter, so the body is read as a heading-form ticket.
  defp from_front_matter(fields, body) do
    base =
      case Map.get(fields, "title") do
        title when is_binary(title) and title != "" -> ticket(title, String.trim(body))
        _missing -> parse_heading_form(body)
      end

    %{
      base
      | priority: cast_priority(Map.get(fields, "priority")),
        estimate: cast_estimate(Map.get(fields, "estimate"))
    }
  end

  # The product role writes the priority by name; anything else it wrote is not
  # a priority we have, and the ticket goes without one.
  defp cast_priority(value) when is_binary(value) do
    normalized = value |> String.trim() |> String.downcase()

    Enum.find(Issue.priorities(), &(Atom.to_string(&1) == normalized))
  end

  defp cast_priority(_other), do: nil

  defp cast_estimate(value) when is_binary(value) do
    case value |> String.trim() |> Integer.parse() do
      {number, ""} when number >= 0 -> number
      _other -> nil
    end
  end

  defp cast_estimate(_other), do: nil

  defp ticket(title, description) do
    %{title: title, description: description, priority: nil, estimate: nil}
  end
end
