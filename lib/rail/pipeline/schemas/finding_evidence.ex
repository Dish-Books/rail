defmodule Rail.Pipeline.Schemas.FindingEvidence do
  @moduledoc """
  What a finding has to show for itself: a highlighted code range in the worktree, or a screenshot, log,
  query or note a pass wrote under `<scratch>/qa` and saving the finding attached, with the commit and
  browser it was taken on.

  `file` is relative to the worktree and `path` to the QA folder, and neither may leave its root: `path` is
  the one string here that becomes a filename on a request from a browser.
  """
  use Rail.Schema

  alias Rail.Pipeline.Schemas.Finding

  @kinds [:code, :screenshot, :log, :query, :note]
  @pictures [".jpg", ".jpeg", ".png", ".gif", ".webp"]
  @path ~r{\A[A-Za-z0-9._][A-Za-z0-9._/~-]*\z}

  @primary_key false
  embedded_schema do
    field :name, :string
    field :kind, Ecto.Enum, values: @kinds
    field :file, :string
    field :line, :integer
    field :end_line, :integer
    field :path, :string
    field :text, :string
    # Rail's own record of when and where, never taken from the agent; `browser` is the lead's word.
    field :commit, :string
    field :browser, :string
    field :taken_at, :utc_datetime_usec
  end

  @doc """
  Builds a changeset for one piece of evidence; `commit` and `taken_at` are Rail's, set when it is attached.
  """
  def changeset(evidence, attrs) do
    evidence
    |> cast(attrs, [:name, :kind, :file, :line, :end_line, :path, :text, :commit, :browser, :taken_at])
    |> validate_required([:name, :kind])
    |> validate_length(:name, max: 120)
    |> validate_number(:line, greater_than: 0, message: "must be a positive whole number")
    |> validate_number(:end_line, greater_than: 0, message: "must be a positive whole number")
    |> validate_format(:path, @path)
    |> validate_change(:path, fn :path, path ->
      if confined?(path), do: [], else: [path: "cannot climb out of the QA directory"]
    end)
    |> validate_change(:file, fn :file, file ->
      if Path.type(file) == :relative and ".." not in Path.split(file),
        do: [],
        else: [file: "is a path relative to the worktree, never climbing out with `..`"]
    end)
    |> validate_shown()
    |> validate_change(:name, &plain/2)
    |> validate_change(:text, &plain/2)
  end

  @doc """
  True when `path` is relative to the task's `<scratch>/qa` and never climbs out
  of it, which is the one test for a path a finding cites.
  """
  def confined?(path) when is_binary(path), do: path =~ @path and ".." not in Path.split(path)

  @doc """
  True when `path` names a picture, which the panel shows and serves as one.
  """
  def picture?(path) when is_binary(path), do: String.downcase(Path.extname(path)) in @pictures

  defp plain(field, value), do: if(Finding.markup?(value), do: [{field, "holds tool-call markup"}], else: [])

  # A code range is read off the worktree; anything else is a filed file or a value small enough to carry.
  defp validate_shown(changeset) do
    case get_field(changeset, :kind) do
      :code ->
        if get_field(changeset, :file) && get_field(changeset, :line),
          do: changeset,
          else: add_error(changeset, :file, "code evidence needs the `file` and `line` it highlights")

      _filed ->
        if get_field(changeset, :path) || get_field(changeset, :text),
          do: changeset,
          else: add_error(changeset, :path, "evidence needs a file or some text")
    end
  end
end
