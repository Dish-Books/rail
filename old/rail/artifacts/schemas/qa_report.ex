defmodule Rail.Artifacts.Schemas.QaReport do
  @moduledoc """
  Schema for a QA check report artifact.
  """
  use Rail.Schema

  alias Rail.Domain.Embeds.QaRow

  @primary_key {:id, UXID, autogenerate: true, prefix: "qar"}
  schema "qa_reports" do
    field :task_id, UXID
    field :run_id, UXID
    field :commit, :string
    field :session, :map, default: %{}

    embeds_many :rows, QaRow, on_replace: :delete

    timestamps()
  end

  @cast_fields [:task_id, :run_id, :commit, :session]
  @required_fields [:task_id]

  @doc "Builds a changeset for a QA report."
  def changeset(qa_report, attrs) do
    qa_report
    |> cast(attrs, @cast_fields)
    |> validate_required(@required_fields)
    |> cast_embed(:rows)
  end
end
