defmodule Rail.Pipeline.Schemas.FindingComment do
  @moduledoc """
  One person's comment on one piece of a Review finding, for the Review lead: unsent and theirs alone, then sent,
  after which it reads only in the message it went out in. It quotes the piece as it read when it was written.
  """
  use Rail.Schema

  alias Rail.Pipeline.Schemas.Finding
  alias Rail.Pipeline.Schemas.FindingNote
  alias Rail.Pipeline.Schemas.FindingPlace
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Users.Schemas.User

  @pieces [:title, :problem, :where, :fix, :why, :rule, :place, :note]

  @primary_key {:id, UXID, autogenerate: true, prefix: "fcm"}
  schema "finding_comments" do
    field :piece, Ecto.Enum, values: @pieces
    # Which place or note, by its position on the finding; nil for every other piece.
    field :index, :integer
    # The piece's label and its text when the comment was written, set from the finding, never the client.
    field :label, :string
    field :quote, :string
    field :body, :string
    # Left out of the changeset, so only sending moves it.
    field :status, Ecto.Enum, values: [:unsent, :sent], default: :unsent

    belongs_to :task, Task
    belongs_to :user, User
    belongs_to :finding, Finding

    timestamps()
  end

  @doc """
  Builds a changeset for a comment on the piece `piece` (and `index`) of the finding `finding_id`. The task, its
  author, the label and the quote are set by the caller.
  """
  def changeset(finding_comment, attrs) do
    finding_comment
    |> cast(attrs, [:finding_id, :piece, :index, :body])
    |> update_change(:body, &String.trim/1)
    |> validate_required([:finding_id, :piece, :body])
    |> validate_number(:index, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:task_id)
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:finding_id)
  end

  @doc """
  The piece `piece` of `finding` as `%{label:, quote:}`, what a reader knows it by and what it says, or nil when the
  finding has no such piece.
  """
  def calculate_piece(%Finding{} = finding, :title, nil), do: piece("Title", finding.title)
  def calculate_piece(%Finding{} = finding, :problem, nil), do: piece("Problem", finding.problem)
  def calculate_piece(%Finding{} = finding, :where, nil), do: piece("Where", where(finding))
  def calculate_piece(%Finding{} = finding, :fix, nil), do: piece("Fix", finding.fix)

  def calculate_piece(%Finding{recommendation: recommendation} = finding, :why, nil),
    do: piece(if(recommendation == :skip, do: "Why skip", else: "Why fix"), finding.why)

  def calculate_piece(%Finding{} = finding, :rule, nil), do: piece("Rule", finding.rule)

  def calculate_piece(%Finding{places: places}, :place, index) when is_integer(index) and index >= 0 do
    case Enum.at(places, index) do
      %FindingPlace{} = place -> piece(place_label(place, index), place_text(place))
      nil -> nil
    end
  end

  def calculate_piece(%Finding{notes: notes}, :note, index) when is_integer(index) and index >= 0 do
    case Enum.at(notes, index) do
      %FindingNote{} = note -> piece(note_label(note), note_text(note))
      nil -> nil
    end
  end

  def calculate_piece(%Finding{}, _piece, _index), do: nil

  @doc """
  `comments` in the order the tray numbers them and Send sends them: as written, the id breaking a tie.
  """
  def calculate_order(comments) when is_list(comments),
    do: Enum.sort_by(comments, &{DateTime.to_unix(&1.inserted_at, :microsecond), &1.id})

  @doc """
  Writes `comment`, its finding preloaded, as the block the Review lead is sent.
  """
  def calculate_block(%__MODULE__{finding: %Finding{} = finding} = comment) do
    quoted = comment.quote |> String.split("\n") |> Enum.map_join("\n", &"> #{&1}")

    """
    <finding_comment key="#{finding.key}" ruling="#{ruling(finding)}">
    #{finding.title}
    #{comment.label}, as it read:
    #{quoted}
    #{comment.body}
    </finding_comment>\
    """
  end

  defp piece(label, text) when is_binary(text) and text != "", do: %{label: label, quote: text}
  defp piece(_label, _text), do: nil

  defp where(%Finding{steps: []} = finding), do: Finding.where(finding)

  defp where(%Finding{steps: steps} = finding) do
    numbered = steps |> Enum.with_index(1) |> Enum.map_join("\n", fn {step, n} -> "#{n}. #{step}" end)
    "#{Finding.where(finding)}\n#{numbered}"
  end

  defp place_label(%FindingPlace{label: label}, index) when is_binary(label), do: "Place #{index + 1}, #{label}"
  defp place_label(%FindingPlace{}, index), do: "Place #{index + 1}"

  defp place_text(%FindingPlace{left_reason: reason} = place) when is_binary(reason),
    do: "#{FindingPlace.describe(place)}\nLeft as it is: #{reason}"

  defp place_text(%FindingPlace{} = place), do: FindingPlace.describe(place)

  # What the note is, so two notes of one round read apart in the card, the tray and the lead's note.
  defp note_label(%FindingNote{kind: :raised, round: round}), do: "Round #{round}, raised"
  defp note_label(%FindingNote{kind: :ruling, decision: :skip, round: round}), do: "Round #{round}, ruled Don't fix"
  defp note_label(%FindingNote{kind: :ruling, round: round}), do: "Round #{round}, ruled Fix"
  defp note_label(%FindingNote{kind: :fix, round: round}), do: "Fix round #{round}, fix report"
  defp note_label(%FindingNote{kind: :carried, round: round}), do: "Round #{round}, carried"
  defp note_label(%FindingNote{status: :not_fixed, round: round}), do: "Round #{round} pass, still failing"
  defp note_label(%FindingNote{status: :fixed, round: round}), do: "Round #{round} pass, checked fixed"
  defp note_label(%FindingNote{round: round}), do: "Round #{round} pass, still open"

  # As the finding's history reads it, short of who ruled, which the lead does not need.
  defp note_text(%FindingNote{kind: :raised} = note), do: "Raised#{on(note.commit)}#{words(note.text)}"
  defp note_text(%FindingNote{kind: :ruling, decision: :skip}), do: "Ruled Don't fix"
  defp note_text(%FindingNote{kind: :ruling}), do: "Ruled Fix"

  defp note_text(%FindingNote{kind: :fix} = note),
    do: "Fixed#{if note.commit, do: " in #{short(note.commit)}"}; test that failed first: #{note.test}"

  defp note_text(%FindingNote{kind: :carried, round: round}), do: "Carried into round #{round} with its Fix ruling"

  defp note_text(%FindingNote{status: :not_fixed} = note), do: "Still failing#{on(note.commit)}#{words(note.text)}"

  defp note_text(%FindingNote{status: :fixed} = note), do: "Checked fixed#{on(note.commit)}#{words(note.text)}"
  defp note_text(%FindingNote{} = note), do: "Still open#{on(note.commit)}#{words(note.text)}"

  defp on(nil), do: ""
  defp on(commit), do: " on #{short(commit)}"

  defp words(nil), do: ""
  defp words(text), do: ": #{text}"

  defp short(commit), do: String.slice(commit, 0, 7)

  defp ruling(%Finding{decision: :fix}), do: "Fix"
  defp ruling(%Finding{decision: :skip}), do: "Don't fix"
  defp ruling(%Finding{decision: nil}), do: "Not ruled"
end
