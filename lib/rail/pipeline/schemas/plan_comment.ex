defmodule Rail.Pipeline.Schemas.PlanComment do
  @moduledoc """
  One person's comment on one part of the Plan step's output, for Plan: unsent and theirs alone, then sent, after
  which it lives only as the message it went out in. The design, by an element of its picked option, is the only target.

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

  @primary_key {:id, UXID, autogenerate: true, prefix: "pcm"}
  schema "plan_comments" do
    field :target, Ecto.Enum, values: [:design]
    field :body, :string
    # Left out of the changeset, so only the action that sends moves it.
    field :status, Ecto.Enum, values: [:unsent, :sent], default: :unsent
    field :option_key, :string
    # The overlay's own grammar: a plain id, then tags and positions, so it never needs quoting.
    field :selector, :string
    field :element_text, :string, default: ""
    field :element_tag, :string

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
  Writes `comments`, one person's round oldest first, as the one message Plan is sent, numbered as their markers are.
  `design` is the task's design as `read_design/2` reads it, for the option's title.
  """
  def calculate_message(comments, design) do
    count = length(comments)
    heading = "#{count} #{if count == 1, do: "comment", else: "comments"} on the design"

    sections =
      comments
      |> Enum.with_index(1)
      |> Enum.chunk_by(fn {comment, _number} -> {comment.target, comment.option_key} end)
      |> Enum.map(&section(&1, design))

    Enum.join([heading | sections], "\n\n")
  end

  @doc """
  Reads a message `calculate_message/2` wrote back into its count and its sections of numbered comments, or `nil`
  for any other message.
  """
  def parse_message(text) when is_binary(text) do
    with [heading | rest] <- text |> String.trim() |> String.split("\n"),
         [_all, count] <- Regex.run(~r/\A(\d+) comments? on the design\z/, heading),
         {:ok, sections} <- parse_sections(rest, []),
         comments = Enum.flat_map(sections, & &1.comments),
         true <- comments != [] and length(comments) == String.to_integer(count),
         true <- Enum.map(comments, & &1.number) == Enum.to_list(1..length(comments)) do
      %{count: length(comments), sections: sections}
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

      _no_target ->
        changeset
    end
  end

  defp section([{%__MODULE__{option_key: key}, _number} | _rest] = numbered, design) do
    title = (design && Enum.find_value(design.options, &(&1.key == key && &1.title))) || key
    blocks = Enum.map(numbered, fn {comment, number} -> block(comment, number) end)

    Enum.join(["On #{title} (#{key}):" | blocks], "\n\n")
  end

  # The comment is quoted line by line, so no line of it can read as the next comment.
  defp block(%__MODULE__{} = comment, number) do
    element = if comment.element_text == "", do: "<#{comment.element_tag}>", else: ~s("#{comment.element_text}")
    quoted = comment.body |> String.split("\n") |> Enum.map_join("\n", &String.trim_trailing("> " <> &1))

    "#{number}. `#{comment.selector}` #{element}\n#{quoted}"
  end

  defp parse_sections([], sections) when sections != [], do: {:ok, Enum.reverse(sections)}

  defp parse_sections(["", section_line | rest], sections) do
    with [_all, title, key] <- Regex.run(~r/\AOn (.+) \(([a-z0-9-]+)\):\z/, section_line),
         {:ok, comments, rest} <- parse_comments(rest, []) do
      parse_sections(rest, [%{target: :design, title: title, key: key, comments: comments} | sections])
    else
      _other -> :error
    end
  end

  defp parse_sections(_other, _sections), do: :error

  defp parse_comments(["", header | rest] = lines, comments) do
    case Regex.run(~r/\A(\d+)\. `([^`]+)` (?:"(.*)"|<([A-Za-z][A-Za-z0-9-]*)>)\z/, header) do
      [_all, number, selector | element] ->
        {quoted, rest} = Enum.split_while(rest, &String.starts_with?(&1, ">"))
        body = Enum.map_join(quoted, "\n", &(&1 |> String.replace_prefix(">", "") |> String.replace_prefix(" ", "")))

        comment = %{
          number: String.to_integer(number),
          selector: selector,
          text: Enum.at(element, 0, ""),
          tag: Enum.at(element, 1),
          body: String.trim(body)
        }

        if quoted == [], do: :error, else: parse_comments(rest, [comment | comments])

      nil ->
        finish_comments(lines, comments)
    end
  end

  defp parse_comments(lines, comments), do: finish_comments(lines, comments)

  defp finish_comments(_lines, []), do: :error
  defp finish_comments(lines, comments), do: {:ok, Enum.reverse(comments), lines}
end
