defmodule Rail.Pipeline.Schemas.QaEvidence do
  @moduledoc """
  One thing a QA finding has to show for itself.

  A QA pass that only asserts is a QA pass nobody can check, so every finding
  carries what it saw: the screenshot of the form rendering wrong, the log line
  with the stacktrace, the value queried out of the database. A screenshot lives
  as a file the agent wrote; a queried value is small enough to carry inline, so
  `path` and `text` are alternatives rather than a pair.

  `path` is relative to the task's `<scratch>/qa` and nothing else. It is the
  only string in this application that becomes a filename on a request from a
  browser, so it is checked here as well as where it is read and where it is
  served: an absolute path or one climbing out with `..` is not evidence.
  """
  use Rail.Schema

  @kinds [:screenshot, :log, :query, :note]
  @path ~r{\A[A-Za-z0-9._][A-Za-z0-9._/-]*\z}

  @primary_key false
  embedded_schema do
    field :name, :string
    field :kind, Ecto.Enum, values: @kinds
    field :path, :string
    field :text, :string
  end

  @cast_fields [:name, :kind, :path, :text]
  @required_fields [:name, :kind]

  @doc """
  Builds a changeset for one piece of evidence.
  """
  def changeset(qa_evidence, attrs) do
    qa_evidence
    |> cast(attrs, @cast_fields)
    |> validate_required(@required_fields)
    |> validate_format(:path, @path)
    |> validate_confined()
    |> validate_shown()
  end

  def kinds, do: @kinds

  # A path is confined to `<scratch>/qa` or it is not served. The format above
  # already refuses a leading slash and anything exotic; this is the segment
  # that looks ordinary and is not.
  defp validate_confined(changeset) do
    validate_change(changeset, :path, fn :path, path ->
      if ".." in Path.split(path), do: [path: "cannot climb out of the QA directory"], else: []
    end)
  end

  # Evidence that shows nothing is a caption. It is caught here rather than
  # rendered as an empty box the reader cannot explain.
  defp validate_shown(changeset) do
    if get_field(changeset, :path) || get_field(changeset, :text) do
      changeset
    else
      add_error(changeset, :path, "evidence needs a file or some text")
    end
  end
end
