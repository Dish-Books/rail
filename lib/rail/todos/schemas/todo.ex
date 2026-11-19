defmodule Rail.Todos.Schemas.Todo do
  @moduledoc """
  One line on a person's own to-do list: typed, or a link dropped onto the panel. Checked off while
  `completed_at` is set.
  """
  use Rail.Schema

  alias Rail.Users.Schemas.User

  @primary_key {:id, UXID, autogenerate: true, prefix: "tdo"}
  schema "todos" do
    field :body, :string
    # A Rail path or an http(s) address; nil for a typed to-do.
    field :url, :string
    # Its place in the person's list; only `PlaceTodo` renumbers it.
    field :position, :integer, default: 0
    field :completed_at, :utc_datetime_usec

    belongs_to :user, User

    timestamps()
  end

  @doc """
  A typed to-do: only its text is the person's to set.
  """
  def changeset(todo, attrs) do
    todo
    |> cast(attrs, [:body])
    |> validate_body()
  end

  @doc """
  A dropped link: its text and an address that is a Rail path or an http(s) URL.
  """
  def link_changeset(todo, attrs) do
    todo
    |> cast(attrs, [:body, :url])
    |> validate_body()
    |> validate_required([:url])
    # A Rail path, never a protocol-relative one, or an http(s) address.
    |> validate_format(:url, ~r{\A(/(?!/)|https?://[^/\s]+)})
  end

  defp validate_body(changeset) do
    changeset
    |> update_change(:body, &calculate_body/1)
    |> validate_required([:body])
    |> validate_length(:body, max: 500)
  end

  # The list shows one paragraph per to-do, so a pasted line break becomes a space.
  # Blanking a saved text casts it to nil.
  defp calculate_body(body) when is_binary(body), do: body |> String.replace(~r/\s*[\r\n]+\s*/, " ") |> String.trim()
  defp calculate_body(nil), do: nil
end
