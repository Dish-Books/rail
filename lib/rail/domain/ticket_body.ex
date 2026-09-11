defmodule Rail.Domain.TicketBody do
  @moduledoc """
  Represents a parsed Linear ticket specification written to `<scratch>/tickets/<identifier>.md`.

  Also provides utilities for acceptance criteria parsing and split-out ticket management.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @derive Jason.Encoder

  @fence_pattern ~r/^(```|~~~)/
  @criteria_heading_pattern ~r/^##\s+acceptance criteria\s*$/i
  @bullet_pattern ~r/^[-*]\s+(.*)$/
  @heading_pattern ~r/^##\s+/
  @split_filename_pattern ~r/^split-(\d+)\.md$/

  @priorities [:urgent, :high, :medium, :low]
  @priority_numbers %{1 => :urgent, 2 => :high, 3 => :medium, 4 => :low}

  @primary_key false
  embedded_schema do
    field :title, :string, default: ""
    field :description, :string, default: ""
    field :priority, Ecto.Enum, values: @priorities
    field :estimate, :integer
  end

  @fields [:title, :description, :priority, :estimate]

  @doc "Builds a changeset for a ticket body."
  def changeset(ticket_body, attrs) do
    ticket_body
    |> cast(attrs, @fields)
    |> validate_required([:title])
  end

  @doc """
  Parses a ticket specification markdown string into a `TicketBody` struct.

  The canonical form is a `---` delimited front matter block carrying `title`, and
  optionally `priority` and `estimate`, with everything below it as the description:

      ---
      title: Journal Entry shows its source document's attachments
      priority: high
      estimate: 3
      ---
      The problem paragraph...

  Falls back to the legacy form, where the title is the first line starting with `# `
  and the description is everything after it.
  """
  def parse(nil), do: %__MODULE__{title: "", description: ""}

  def parse(content) when is_binary(content) do
    normalized = String.replace(content, "\r\n", "\n")

    case split_front_matter(normalized) do
      {:ok, fields, body} -> from_front_matter(fields, body)
      :none -> parse_heading_form(normalized)
    end
  end

  @doc """
  Casts a front matter priority value to one of `#{inspect(@priorities)}`, or `nil`.

  Accepts the Linear names (`urgent`, `high`, `medium`, `low`, case insensitive) and the
  numbers they are labeled with in the product role's table (`1` urgent through `4` low).
  """
  def cast_priority(nil), do: nil
  def cast_priority(priority) when priority in @priorities, do: priority
  def cast_priority(number) when is_integer(number), do: Map.get(@priority_numbers, number)

  def cast_priority(value) when is_binary(value) do
    normalized = value |> String.trim() |> String.downcase()

    case Integer.parse(normalized) do
      {number, ""} -> cast_priority(number)
      _not_a_number -> Enum.find(@priorities, &(Atom.to_string(&1) == normalized))
    end
  end

  def cast_priority(_other), do: nil

  @doc """
  Casts a front matter estimate to a non-negative integer, or `nil`.
  """
  def cast_estimate(nil), do: nil
  def cast_estimate(estimate) when is_integer(estimate) and estimate >= 0, do: estimate

  def cast_estimate(value) when is_binary(value) do
    case value |> String.trim() |> Integer.parse() do
      {number, ""} when number >= 0 -> number
      _other -> nil
    end
  end

  def cast_estimate(_other), do: nil

  @doc """
  Serializes a `TicketBody` to the front matter form `parse/1` reads back.
  """
  def format(%__MODULE__{} = ticket) do
    fields =
      [
        {"title", String.trim(ticket.title || "")},
        {"priority", ticket.priority && Atom.to_string(ticket.priority)},
        {"estimate", ticket.estimate && Integer.to_string(ticket.estimate)}
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
      |> Enum.map_join("\n", fn {key, value} -> "#{key}: #{value}" end)

    description = if is_binary(ticket.description), do: String.trim(ticket.description), else: ""

    String.trim_trailing("---\n#{fields}\n---\n\n#{description}") <> "\n"
  end

  def format(title, description) when is_binary(title) do
    format(%__MODULE__{title: title, description: description})
  end

  @doc """
  Extracts the acceptance criteria list from `body`.

  Finds `## Acceptance criteria`, collects top-level `*`/`-` bullets until the next `##` heading,
  joins multi-line continuations, and strips markdown formatting. Ignores fenced code blocks.
  """
  def acceptance_criteria(""), do: []

  def acceptance_criteria(body) when is_binary(body) do
    normalized = String.replace(body, "\r\n", "\n")
    lines = String.split(normalized, "\n")

    {criteria, state} =
      Enum.reduce(lines, {[], {:outside, false, ""}}, fn line, {acc, state} ->
        process_criteria_line(line, acc, state)
      end)

    flush_final_criterion(criteria, state)
  end

  @doc """
  Scans a directory for `split-<n>.md` files, sorted numerically by `<n>`,
  and parses each into a `TicketBody` struct.
  """
  def parse_split_files(dir_path) when is_binary(dir_path) do
    case File.ls(dir_path) do
      {:ok, filenames} ->
        split_tickets =
          filenames
          |> Enum.filter(&Regex.match?(@split_filename_pattern, &1))
          |> Enum.sort_by(&extract_split_index/1)
          |> Enum.map(fn filename ->
            path = Path.join(dir_path, filename)
            content = File.read!(path)
            parse(content)
          end)

        {:ok, split_tickets}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Parses a list or map of split file contents or entries into `TicketBody` structs.
  Supports:
  - Map of `%{ "split-1.md" => content, "split-2.md" => content }`
  - List of `[{"split-1.md", content}, ...]`
  - List of raw string contents: `[content1, content2]`
  """
  def parse_splits(entries) when is_map(entries) do
    entries
    |> Map.to_list()
    |> parse_splits()
  end

  def parse_splits(entries) when is_list(entries) do
    cond do
      Enum.all?(entries, fn item -> is_tuple(item) and tuple_size(item) == 2 end) ->
        entries
        |> Enum.filter(fn {filename, _content} -> Regex.match?(@split_filename_pattern, filename) end)
        |> Enum.sort_by(fn {filename, _content} -> extract_split_index(filename) end)
        |> Enum.map(fn {_filename, content} -> parse(content) end)

      Enum.all?(entries, &is_binary/1) ->
        Enum.map(entries, &parse/1)

      true ->
        []
    end
  end

  @doc """
  Parses a manifest JSON string, decoded map, or list of ticket maps into `TicketBody` structs.
  """
  def parse_manifest(manifest) when is_binary(manifest) do
    case Jason.decode(manifest) do
      {:ok, data} -> parse_manifest(data)
      {:error, _reason} -> []
    end
  end

  def parse_manifest(%{"splits" => splits}) when is_list(splits) do
    parse_manifest(splits)
  end

  def parse_manifest(%{"tickets" => tickets}) when is_list(tickets) do
    parse_manifest(tickets)
  end

  def parse_manifest(items) when is_list(items) do
    items
    |> Enum.map(fn
      %{"title" => title, "description" => description} ->
        %__MODULE__{title: title, description: description}

      %{"title" => title} ->
        %__MODULE__{title: title, description: ""}

      %{"content" => content} when is_binary(content) ->
        parse(content)

      content when is_binary(content) ->
        parse(content)

      _other ->
        nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  def parse_manifest(_other), do: []

  defp parse_heading_form(content) do
    lines = String.split(content, "\n")

    case Enum.find_index(lines, &String.starts_with?(String.trim_leading(&1), "# ")) do
      index when is_integer(index) ->
        title_line = Enum.at(lines, index)
        title = title_line |> String.trim_leading() |> String.replace_prefix("# ", "") |> String.trim()

        description =
          lines
          |> Enum.drop(index + 1)
          |> Enum.join("\n")
          |> String.trim()

        %__MODULE__{
          title: title,
          description: description
        }

      nil ->
        %__MODULE__{
          title: "",
          description: String.trim(content)
        }
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

    cond do
      String.starts_with?(trimmed, "\"") and String.ends_with?(trimmed, "\"") and String.length(trimmed) > 1 ->
        trimmed |> String.slice(1..-2//1) |> String.trim()

      String.starts_with?(trimmed, "'") and String.ends_with?(trimmed, "'") and String.length(trimmed) > 1 ->
        trimmed |> String.slice(1..-2//1) |> String.trim()

      true ->
        trimmed
    end
  end

  defp from_front_matter(fields, body) do
    base =
      case Map.get(fields, "title") do
        title when is_binary(title) and title != "" ->
          %__MODULE__{title: title, description: String.trim(body)}

        _missing ->
          parse_heading_form(body)
      end

    %{base | priority: cast_priority(Map.get(fields, "priority")), estimate: cast_estimate(Map.get(fields, "estimate"))}
  end

  defp process_criteria_line(line, acc, {section_state, in_fence, current_item}) do
    trimmed_left = String.trim_leading(line)
    trimmed = String.trim(line)

    if Regex.match?(@fence_pattern, trimmed_left) do
      {acc, {section_state, not in_fence, current_item}}
    else
      if in_fence do
        {acc, {section_state, in_fence, current_item}}
      else
        handle_line_in_fence_free(trimmed, acc, section_state, current_item)
      end
    end
  end

  defp handle_line_in_fence_free(trimmed, acc, :outside, current_item) do
    if Regex.match?(@criteria_heading_pattern, trimmed) do
      {acc, {:inside, false, current_item}}
    else
      {acc, {:outside, false, current_item}}
    end
  end

  defp handle_line_in_fence_free(_line, acc, :done, current_item) do
    {acc, {:done, false, current_item}}
  end

  defp handle_line_in_fence_free(trimmed, acc, :inside, current_item) do
    if Regex.match?(@heading_pattern, trimmed) do
      new_acc = flush_criterion(acc, current_item)
      {new_acc, {:done, false, ""}}
    else
      case Regex.run(@bullet_pattern, trimmed) do
        [_match, bullet_content] ->
          new_acc = flush_criterion(acc, current_item)
          {new_acc, {:inside, false, bullet_content}}

        nil ->
          if current_item != "" and trimmed != "" do
            {acc, {:inside, false, "#{current_item} #{trimmed}"}}
          else
            {acc, {:inside, false, current_item}}
          end
      end
    end
  end

  defp flush_criterion(acc, "") do
    acc
  end

  defp flush_criterion(acc, item) do
    cleaned =
      item
      |> String.replace(~r/[*_`]/, "")
      |> String.replace(~r/\s+/, " ")
      |> String.trim()

    if cleaned == "" do
      acc
    else
      [cleaned | acc]
    end
  end

  defp flush_final_criterion(criteria_acc, {_section_state, _in_fence, current_item}) do
    criteria_acc
    |> flush_criterion(current_item)
    |> Enum.reverse()
  end

  defp extract_split_index(filename) do
    [_match, digits] = Regex.run(@split_filename_pattern, filename)
    String.to_integer(digits)
  end
end
