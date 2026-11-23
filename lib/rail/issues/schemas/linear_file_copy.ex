defmodule Rail.Issues.Schemas.LinearFileCopy do
  @moduledoc """
  One Linear upload a ticket shows, on its way to R2 while its project moves into Rail. Each is copied by its own job,
  so a move that stops keeps every file already copied and picks up from the rest.

  `issue_id` is the Rail id the file is stored under, which the ticket keeps when the move writes it.
  """
  use Rail.Schema

  alias Rail.Projects.Schemas.Project

  @primary_key {:id, UXID, autogenerate: true, prefix: "lfc"}
  schema "linear_file_copies" do
    field :issue_external_id, :string
    field :issue_id, :string
    field :identifier, :string
    field :url, :string
    field :state, Ecto.Enum, values: [:pending, :copied, :gone, :failed], default: :pending
    field :copied_url, :string
    field :error, :string

    belongs_to :project, Project

    timestamps()
  end
end
