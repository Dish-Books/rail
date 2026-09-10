defmodule Rail.Domain.TicketBody do
  @moduledoc """
  Represents a parsed Linear ticket specification written to `$RAIL_SCRATCH/tickets/<identifier>.md`.

  Also provides utilities for legacy plan extraction, acceptance criteria parsing,
  and split-out ticket management.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @derive Jason.Encoder

  @plan_heading_pattern ~r/^##\s+implementation plan\s*$/i
  @fence_pattern ~r/^(```|~~~)/
  @criteria_heading_pattern ~r/^##\s+acceptance criteria\s*$/i
  @bullet_pattern ~r/^[-*]\s+(.*)$/
  @heading_pattern ~r/^##\s+/
  @split_filename_pattern ~r/^split-(\d+)\.md$/

  @primary_key false
  embedded_schema do
    field :title, :string, default: ""
    field :description, :string, default: ""
  end

  @fields [:title, :description]

  @doc "Builds a changeset for a ticket body."
  def changeset(ticket_body, attrs) do
    ticket_body
    |> cast(attrs, @fields)
    |> validate_required([:title])
  end

  @doc """
  Parses a ticket specification markdown string into a `TicketBody` struct.

  Extracts the title from the first line starting with `# ` (trimmed).
  The description is everything after the title line, with leading/trailing whitespace trimmed.
  """
  def parse(nil), do: %__MODULE__{title: "", description: ""}

  def parse(content) when is_binary(content) do
    normalized = String.replace(content, "\r\n", "\n")
    lines = String.split(normalized, "\n")

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

  @doc """
  Serializes a `TicketBody` or `(title, description)` tuple to markdown:
  `# <Title>\n\n<Description>`.
  """
  def format(%__MODULE__{title: title, description: description}) do
    format(title, description)
  end

  def format(title, description) when is_binary(title) do
    trimmed_title = String.trim(title)
    trimmed_desc = if is_binary(description), do: String.trim(description), else: ""

    if trimmed_desc == "" do
      "# #{trimmed_title}"
    else
      "# #{trimmed_title}\n\n#{trimmed_desc}"
    end
  end

  @doc """
  Splits a body into the original ticket specification and an optional implementation plan.

  Headings inside fenced code blocks are ignored.
  Returns `%{ticket: String.t(), plan: String.t() | nil}`.
  """
  def split(""), do: %{ticket: "", plan: nil}

  def split(body) when is_binary(body) do
    normalized = String.replace(body, "\r\n", "\n")
    lines = String.split(normalized, "\n")

    split_index = find_plan_heading_index(lines, 0, false)

    if is_nil(split_index) do
      %{ticket: body, plan: nil}
    else
      {ticket_lines, plan_lines} = Enum.split(lines, split_index)
      ticket = ticket_lines |> Enum.join("\n") |> String.trim_trailing()

      after_heading =
        plan_lines
        |> Enum.drop(1)
        |> Enum.join("\n")
        |> String.trim()

      if after_heading == "" do
        %{ticket: ticket, plan: nil}
      else
        plan = plan_lines |> Enum.join("\n") |> String.trim()
        %{ticket: ticket, plan: plan}
      end
    end
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

  defp find_plan_heading_index([], _idx, _in_fence), do: nil

  defp find_plan_heading_index([line | rest], idx, in_fence) do
    trimmed_left = String.trim_leading(line)
    trimmed = String.trim(line)

    if Regex.match?(@fence_pattern, trimmed_left) do
      find_plan_heading_index(rest, idx + 1, not in_fence)
    else
      if not in_fence and Regex.match?(@plan_heading_pattern, trimmed) do
        idx
      else
        find_plan_heading_index(rest, idx + 1, in_fence)
      end
    end
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
