defmodule Rail.Pipeline.Schemas.Question do
  @moduledoc """
  Schema for an agent question that pauses a task pending human answer or dismissal.

  Rail answers one itself when a person already answered one like it, with
  `answered_by_rail` set, and suggests a likely past answer where it is less sure.
  """
  use Rail.Schema

  alias Rail.Learnings.Schemas.Learning
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Users.Schemas.User

  # Stands in for each citation while a sent round is read back; no answer holds a control character.
  @cited "\u0001cited\u0001"

  # An asked question was filed mid-turn and joins the round, as pending, when the turn ends.
  @statuses [:asked, :pending, :unanswered, :answered, :dismissed]

  @primary_key {:id, UXID, autogenerate: true, prefix: "qst"}
  schema "questions" do
    belongs_to :task, Task
    belongs_to :run, Run

    field :prompt, :string
    field :options, {:array, :string}, default: []
    field :answer, :string
    field :status, Ecto.Enum, values: @statuses, default: :pending
    field :answered_at, :utc_datetime_usec
    field :delivered_at, :utc_datetime_usec
    field :answered_by_rail, :boolean, default: false

    belongs_to :answered_by, User
    belongs_to :suggested_learning, Learning

    timestamps()
  end

  @cast_fields [
    :task_id,
    :run_id,
    :prompt,
    :options,
    :answer,
    :status,
    :answered_at,
    :delivered_at,
    :answered_by_id,
    :answered_by_rail,
    :suggested_learning_id
  ]

  @required_fields [
    :task_id,
    :run_id,
    :prompt,
    :status
  ]

  @doc """
  Builds a changeset for an agent question.
  """
  def changeset(question, attrs, task_id \\ nil) do
    question
    |> cast(attrs, @cast_fields)
    |> maybe_put_task_id(task_id)
    |> clear_answer_on_dismiss()
    |> clear_rail_on_person()
    |> validate_required(@required_fields)
    |> foreign_key_constraint(:task_id)
    |> foreign_key_constraint(:run_id)
  end

  def statuses, do: @statuses

  def pending?(:pending), do: true
  def pending?(_other), do: false

  def resolved?(status) when is_atom(status), do: status in [:answered, :dismissed]
  def resolved?(_other), do: false

  @doc """
  The message that hands `round` back to the run that asked it. `citations` maps the learning each of Rail's
  answers came from to whose answer it was, as in "Dana's answer on RAIL-31, Oct 2".
  """
  def calculate_answers_message([%__MODULE__{} = question], citations) do
    "You asked: #{question.prompt}\n#{outcome(question, citations)}"
  end

  def calculate_answers_message(round, citations) do
    body =
      round
      |> Enum.with_index(1)
      |> Enum.map_join("\n\n", fn {question, index} ->
        "#{index}. You asked: #{question.prompt}\n   #{outcome(question, citations)}"
      end)

    "You asked #{length(round)} questions. Answers, in order:\n\n#{body}"
  end

  @doc """
  Reads `text` back as the delivered round of `questions` it was sent as, in the order asked, each with the
  `by`, `identifier` and `date` its Rail answer was cited with, or `nil` when it is no round's message.
  """
  def parse_answers_message("You asked" <> _rest = text, questions) do
    text = normalized_lines(text)

    questions
    |> Enum.filter(&match?(%__MODULE__{delivered_at: %DateTime{}}, &1))
    |> Enum.group_by(& &1.delivered_at)
    |> Map.values()
    |> Enum.find_value(&parse_round(text, Enum.sort(&1, fn a, b -> asked_before?(a, b) end)))
  end

  def parse_answers_message(_text, _questions), do: nil

  # A dismissed question never carries a stale answer back to the agent or into Answer instead.
  defp clear_answer_on_dismiss(changeset) do
    case get_change(changeset, :status) do
      :dismissed -> change(changeset, answer: nil, answered_at: nil)
      _other -> changeset
    end
  end

  # Once a person answers, the answer is theirs and no longer Rail's.
  defp clear_rail_on_person(changeset) do
    case get_change(changeset, :answered_by_id) do
      user_id when is_binary(user_id) -> put_change(changeset, :answered_by_rail, false)
      nil -> changeset
    end
  end

  defp outcome(%__MODULE__{status: :answered, answered_by_rail: true, answer: answer} = question, citations) do
    case Map.fetch(citations, question.suggested_learning_id) do
      {:ok, cited} -> "Answered by Rail from #{cited}: #{answer}"
      :error -> "Answered by Rail from a past answer: #{answer}"
    end
  end

  defp outcome(%__MODULE__{status: :answered, answer: answer}, _citations), do: "The answer is: #{answer}"
  defp outcome(%__MODULE__{status: :dismissed}, _citations), do: "Dismissed without an answer; carry on without it."

  # The round's own message with every citation left open, so what each one said is read off the text that went out.
  defp parse_round(text, round) do
    citations = Map.new(round, &{&1.suggested_learning_id, @cited})

    pattern =
      round
      |> calculate_answers_message(citations)
      |> normalized_lines()
      |> Regex.escape()
      |> String.replace(@cited, "(.*?)")

    case Regex.run(Regex.compile!("\\A" <> pattern <> "\\z"), text, capture: :all_but_first) do
      cited when is_list(cited) ->
        by_rail = for %__MODULE__{status: :answered, answered_by_rail: true} = question <- round, do: question.id
        cited = by_rail |> Enum.zip(cited) |> Map.new(fn {id, said} -> {id, citation(said)} end)
        Enum.map(round, &%{question: &1, citation: cited[&1.id]})

      nil ->
        nil
    end
  end

  defp citation(said) do
    case Regex.run(~r/^(.+?)'s answer(?: on (\S+))?, ([A-Z][a-z]{2} \d{1,2})$/, said) do
      [_said, by, "", date] -> %{by: by, identifier: nil, date: date}
      [_said, by, identifier, date] -> %{by: by, identifier: identifier, date: date}
      nil -> nil
    end
  end

  # The log keeps each line of a message without the indent it was sent with.
  defp normalized_lines(text), do: text |> String.split("\n") |> Enum.map_join("\n", &String.trim/1) |> String.trim()

  defp asked_before?(%__MODULE__{} = a, %__MODULE__{} = b) do
    case DateTime.compare(a.inserted_at, b.inserted_at) do
      :eq -> a.id <= b.id
      order -> order == :lt
    end
  end

  defp maybe_put_task_id(changeset, nil), do: changeset
  defp maybe_put_task_id(changeset, task_id), do: put_change(changeset, :task_id, task_id)
end
