defmodule Rail.Triage.Schemas.Message do
  @moduledoc """
  One Slack message in a triaged thread, with what the last pass that read it
  said about it: which passages raised or changed which item, or why it needed
  no response.
  """
  use Rail.Schema

  alias Rail.Triage.Schemas.Thread
  alias Rail.Users.Schemas.User

  @primary_key {:id, UXID, autogenerate: true, prefix: "tms"}
  schema "triage_messages" do
    field :external_id, :string
    field :author_external_id, :string
    field :author_name, :string
    field :from_bot, :boolean, default: false
    field :text, :string, default: ""
    field :posted_at, :utc_datetime_usec
    field :no_response_reason, :string
    field :triaged_at, :utc_datetime_usec

    embeds_many :item_links, ItemLink, on_replace: :delete, primary_key: false do
      field :item_key, :string
      field :change, Ecto.Enum, values: [:raised, :widened, :narrowed, :added]
      field :passage, :string
    end

    belongs_to :thread, Thread
    # Set when a teammate posted it through Rail, which never triages its own posts.
    belongs_to :sent_by_user, User

    timestamps()
  end

  def changeset(%Thread{id: thread_id}, attrs) do
    %__MODULE__{thread_id: thread_id}
    |> cast(attrs, [:external_id, :author_external_id, :author_name, :from_bot, :text, :posted_at])
    |> validate_required([:external_id, :posted_at])
    |> unique_constraint([:thread_id, :external_id])
  end

  @doc """
  What a triage pass said about the message.
  """
  def triage_changeset(message, attrs) do
    message
    |> cast(attrs, [:no_response_reason, :triaged_at])
    |> cast_embed(:item_links, with: &item_link_changeset/2)
  end

  def via_rail?(%__MODULE__{sent_by_user_id: user_id}), do: is_binary(user_id)

  @doc """
  Splits the text into `{text, item_position | nil}` runs, marking each passage
  a pass linked to an item. A passage not found verbatim is left unmarked.
  """
  def segments(%__MODULE__{text: text, item_links: links}, items) do
    positions = Map.new(items, &{&1.key, &1.position})

    marks =
      links
      |> Enum.flat_map(&mark(&1, text, positions))
      |> Enum.sort()
      |> Enum.reduce([], fn {start, length, position}, kept ->
        case kept do
          [{previous_start, previous_length, _position} | _rest] when start < previous_start + previous_length -> kept
          _clear -> [{start, length, position} | kept]
        end
      end)
      |> Enum.reverse()

    {runs, rest_at} =
      Enum.reduce(marks, {[], 0}, fn {start, length, position}, {runs, at} ->
        runs = if start > at, do: [{binary_part(text, at, start - at), nil} | runs], else: runs
        {[{binary_part(text, start, length), position} | runs], start + length}
      end)

    runs =
      if rest_at < byte_size(text), do: [{binary_part(text, rest_at, byte_size(text) - rest_at), nil} | runs], else: runs

    Enum.reverse(runs)
  end

  defp mark(%{item_key: key, passage: passage}, text, positions) when is_binary(passage) and passage != "" do
    with {:ok, position} <- Map.fetch(positions, key),
         {start, length} <- :binary.match(text, passage) do
      [{start, length, position}]
    else
      _unmarked -> []
    end
  end

  defp mark(_link, _text, _positions), do: []

  defp item_link_changeset(link, attrs), do: cast(link, attrs, [:item_key, :change, :passage])
end
