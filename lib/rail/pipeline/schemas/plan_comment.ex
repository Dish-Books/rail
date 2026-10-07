defmodule Rail.Pipeline.Schemas.PlanComment do
  @moduledoc """
  One person's comment on one part of the Plan step's output, for Plan: unsent and theirs alone, then sent, after
  which it lives only as the message it went out in. Its target is the design, by an element of its picked option,
  or the ticket or the plan, by one line, which it finds again by the line's text and its occurrence among the same.

  The message a round is sent as is written and read back here, so the conversation's card cannot drift from it.
  """
  use Rail.Schema

  alias Rail.Pipeline.Schemas.PlanCommentCapture
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Users.Schemas.User

  # The overlay caps what it reports to the same lengths.
  @selector_max 1_000
  @text_max 200
  @tag_max 64

  @targets [:design, :ticket, :plan]
  @element_kinds [
    :title,
    :priority,
    :estimate,
    :heading,
    :paragraph,
    :list_item,
    :table_row,
    :blockquote,
    :code,
    :section_title,
    :summary,
    :file,
    :module,
    :signature,
    :source,
    :node
  ]
  @groups %{design: "the design", ticket: "the ticket", plan: "the plan"}

  @primary_key {:id, UXID, autogenerate: true, prefix: "pcm"}
  schema "plan_comments" do
    field :target, Ecto.Enum, values: @targets
    field :body, :string
    # Left out of the changeset, so only sending moves it. Queued is in a message still waiting on a working Plan.
    field :status, Ecto.Enum, values: [:unsent, :queued, :sent], default: :unsent
    field :option_key, :string
    # The overlay's own grammar: a plain id, then tags and positions, so it never needs quoting.
    field :selector, :string
    field :element_text, :string, default: ""
    field :element_tag, :string
    # A ticket or plan comment's line: what kind it is, its label as the page writes it, and which of the lines that
    # read the same it is, its text being `element_text` uncut.
    field :element_kind, Ecto.Enum, values: @element_kinds
    field :element_label, :string
    field :element_occurrence, :integer

    embeds_one :capture, PlanCommentCapture, on_replace: :update

    belongs_to :task, Task
    belongs_to :user, User

    timestamps()
  end

  @doc """
  Builds a changeset for a comment. The task, its author and its status are set by the caller.
  """
  def changeset(plan_comment, attrs) do
    plan_comment
    |> cast(attrs, [:target, :body])
    |> update_change(:body, &String.trim/1)
    |> validate_required([:target, :body])
    |> cast_target(attrs)
    |> foreign_key_constraint(:task_id)
    |> foreign_key_constraint(:user_id)
  end

  @doc """
  Puts one person's comments in the order a round is numbered in: the design's, then the ticket's, then the plan's,
  each oldest first.
  """
  def calculate_round(comments) do
    Enum.sort_by(comments, &{Enum.find_index(@targets, fn target -> target == &1.target end), sort_time(&1), &1.id})
  end

  @doc """
  Writes `comments`, one person's round in `calculate_round/1` order, as the one message Plan is sent, numbered as
  the tray numbers them. `design` is the task's design as `read_design/2` reads it, for the option's title.
  """
  def calculate_message(comments, design) do
    count = length(comments)
    groups = comments |> Enum.map(& &1.target) |> Enum.uniq()
    heading = "#{count} #{if count == 1, do: "comment", else: "comments"} on #{groups(groups)}"

    sections =
      comments
      |> Enum.with_index(1)
      |> Enum.chunk_by(fn {comment, _number} -> {comment.target, comment.option_key} end)
      |> Enum.map(&section(&1, design))

    Enum.join([heading | sections], "\n\n")
  end

  @doc """
  Reads a message `calculate_message/2` wrote back into its count, the groups it names and its sections of numbered
  comments, or `nil` for any other message.
  """
  def parse_message(text) when is_binary(text) do
    with [heading | rest] <- text |> String.trim() |> String.split("\n"),
         [_all, count, groups] <- Regex.run(~r/\A(\d+) comments? on (.+)\z/, heading),
         {:ok, sections} <- parse_sections(rest, []),
         true <- groups == sections |> Enum.map(& &1.target) |> Enum.uniq() |> groups(),
         comments = Enum.flat_map(sections, & &1.comments),
         true <- comments != [] and length(comments) == String.to_integer(count),
         true <- Enum.map(comments, & &1.number) == Enum.to_list(1..length(comments)) do
      %{count: length(comments), groups: groups, sections: sections}
    else
      _other -> nil
    end
  end

  def parse_message(_not_text), do: nil

  defp cast_target(%Ecto.Changeset{} = changeset, attrs) do
    case get_field(changeset, :target) do
      :design ->
        changeset
        |> cast(attrs, [:option_key, :selector, :element_tag])
        # An element with no text is still an element, so its empty text is kept rather than nulled.
        |> cast(attrs, [:element_text], empty_values: [nil])
        |> update_change(:element_text, &(&1 |> String.split() |> Enum.join(" ") |> String.slice(0, @text_max)))
        |> validate_required([:option_key, :selector, :element_tag])
        |> validate_format(:option_key, ~r/\A[a-z0-9-]+\z/)
        |> validate_length(:selector, max: @selector_max)
        |> validate_format(:selector, ~r/\A[A-Za-z0-9_#:()> -]+\z/)
        |> validate_length(:element_tag, max: @tag_max)
        |> validate_format(:element_tag, ~r/\A[A-Za-z][A-Za-z0-9-]*\z/)
        |> cast_embed(:capture, required: true, with: &PlanCommentCapture.changeset/2)

      target when target in [:ticket, :plan] ->
        changeset
        |> cast(attrs, [:element_kind, :element_label, :element_occurrence, :element_text])
        |> validate_required([:element_kind, :element_label, :element_occurrence, :element_text])
        |> validate_number(:element_occurrence, greater_than: 0)

      _no_target ->
        changeset
    end
  end

  defp groups([one]), do: @groups[one]
  defp groups([first, second]), do: "#{@groups[first]} and #{@groups[second]}"
  defp groups([first, second, third]), do: "#{@groups[first]}, #{@groups[second]} and #{@groups[third]}"

  defp sort_time(%__MODULE__{inserted_at: %DateTime{} = at}), do: DateTime.to_unix(at, :microsecond)

  defp section([{%__MODULE__{target: :design, option_key: key}, _number} | _rest] = numbered, design) do
    title = (design && Enum.find_value(design.options, &(&1.key == key && &1.title))) || key
    blocks = Enum.map(numbered, fn {comment, number} -> block(comment, number) end)

    Enum.join(["On #{title} (#{key}):" | blocks], "\n\n")
  end

  defp section([{%__MODULE__{target: target}, _number} | _rest] = numbered, _design) do
    blocks = Enum.map(numbered, fn {comment, number} -> block(comment, number) end)

    Enum.join(["On #{@groups[target]}:" | blocks], "\n\n")
  end

  # The comment is quoted line by line, so no line of it can read as the next comment.
  defp block(%__MODULE__{target: :design} = comment, number) do
    element = if comment.element_text == "", do: "<#{comment.element_tag}>", else: ~s("#{comment.element_text}")

    "#{number}. `#{comment.selector}` #{element}\n#{quoted(comment.body, ">")}"
  end

  # The line goes as it read when the comment was written, so Plan knows which one even once it has changed.
  defp block(%__MODULE__{} = comment, number) do
    "#{number}. #{comment.element_label}\n#{quoted(comment.element_text, "|")}\n#{quoted(comment.body, ">")}"
  end

  defp quoted(text, mark), do: text |> String.split("\n") |> Enum.map_join("\n", &String.trim_trailing("#{mark} " <> &1))

  defp parse_sections([], sections) when sections != [], do: {:ok, Enum.reverse(sections)}

  defp parse_sections(["", "On the " <> group | rest], sections) when group in ["ticket:", "plan:"] do
    target = if group == "ticket:", do: :ticket, else: :plan
    title = if target == :ticket, do: "Ticket", else: "Plan"

    with {:ok, comments, rest} <- parse_comments(rest, target, []) do
      parse_sections(rest, [%{target: target, title: title, key: nil, comments: comments} | sections])
    end
  end

  defp parse_sections(["", section_line | rest], sections) do
    with [_all, title, key] <- Regex.run(~r/\AOn (.+) \(([a-z0-9-]+)\):\z/, section_line),
         {:ok, comments, rest} <- parse_comments(rest, :design, []) do
      parse_sections(rest, [%{target: :design, title: title, key: key, comments: comments} | sections])
    else
      _other -> :error
    end
  end

  defp parse_sections(_other, _sections), do: :error

  defp parse_comments(["", header | rest] = lines, :design, comments) do
    case Regex.run(~r/\A(\d+)\. `([^`]+)` (?:"(.*)"|<([A-Za-z][A-Za-z0-9-]*)>)\z/, header) do
      [_all, number, selector | element] ->
        {body, rest} = unquote_lines(rest, ">")

        comment = %{
          number: String.to_integer(number),
          selector: selector,
          text: Enum.at(element, 0, ""),
          tag: Enum.at(element, 1),
          body: body
        }

        if body == nil, do: :error, else: parse_comments(rest, :design, [comment | comments])

      nil ->
        finish_comments(lines, comments)
    end
  end

  defp parse_comments(["", header | rest] = lines, target, comments) do
    with [_all, number, label] <- Regex.run(~r/\A(\d+)\. (.+)\z/, header),
         {text, rest} when is_binary(text) <- unquote_lines(rest, "|"),
         {body, rest} when is_binary(body) <- unquote_lines(rest, ">") do
      comment = %{number: String.to_integer(number), label: label, text: text, body: body}
      parse_comments(rest, target, [comment | comments])
    else
      nil -> finish_comments(lines, comments)
      {nil, _rest} -> :error
    end
  end

  defp parse_comments(lines, _target, comments), do: finish_comments(lines, comments)

  defp unquote_lines(lines, mark) do
    {quoted, rest} = Enum.split_while(lines, &String.starts_with?(&1, mark))
    text = Enum.map_join(quoted, "\n", &(&1 |> String.replace_prefix(mark, "") |> String.replace_prefix(" ", "")))

    {if(quoted != [], do: String.trim(text)), rest}
  end

  defp finish_comments(_lines, []), do: :error
  defp finish_comments(lines, comments), do: {:ok, Enum.reverse(comments), lines}
end
