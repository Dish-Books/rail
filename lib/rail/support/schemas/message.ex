defmodule Rail.Support.Schemas.Message do
  @moduledoc """
  One message in an Intercom conversation: a customer's, a teammate's, a bot's, or an internal note.
  """
  use Rail.Schema

  alias Rail.Support.Schemas.Conversation

  @kinds [:customer, :teammate, :bot, :note]

  # Monotonic, so messages Intercom stamps with the same second keep their order by id.
  @primary_key {:id, UXID, autogenerate: true, prefix: "smg", monotonic: true}
  schema "support_messages" do
    field :external_id, :string
    field :kind, Ecto.Enum, values: @kinds
    field :author_name, :string
    field :text, :string, default: ""
    field :posted_at, :utc_datetime_usec

    # Attachments are built as structs, never cast, so nothing calls into the embed's own module.
    # coveralls-ignore-next-line
    embeds_many :attachments, Attachment, on_replace: :delete, primary_key: false do
      field :name, :string
      field :url, :string
      field :content_type, :string
      field :size, :integer
    end

    belongs_to :conversation, Conversation

    timestamps()
  end

  def kinds, do: @kinds

  @doc """
  The row a part of Intercom's conversation becomes, or nil for a part with nothing to show.
  """
  def build_attrs(%{"id" => id, "created_at" => created_at} = part, part_type) when is_integer(created_at) do
    {text, inline} = calculate_text(part["body"])
    kind = calculate_kind(get_in(part, ["author", "type"]), part_type)

    files =
      for %{"url" => url} = file <- List.wrap(part["attachments"]), is_binary(url) do
        %__MODULE__.Attachment{
          name: file["name"],
          url: url,
          content_type: file["content_type"],
          size: if(is_integer(file["filesize"]), do: file["filesize"])
        }
      end

    if text == "" and inline == [] and files == [] do
      nil
    else
      %{
        external_id: to_string(id),
        kind: kind,
        author_name:
          blank_to_nil(get_in(part, ["author", "name"])) || get_in(part, ["author", "email"]) || kind_name(kind),
        text: text,
        posted_at: DateTime.from_unix!(created_at * 1_000_000, :microsecond),
        attachments: inline ++ files
      }
    end
  end

  def build_attrs(_unexpected, _part_type), do: nil

  def calculate_kind(author, _part_type) when author in ["user", "lead", "contact"], do: :customer
  def calculate_kind("admin", "note"), do: :note
  def calculate_kind(author, _part_type) when author in ["admin", "team"], do: :teammate
  # Fin and any author Intercom adds later read as automated.
  def calculate_kind(_author, _part_type), do: :bot

  def image?(%__MODULE__.Attachment{content_type: "image/" <> _subtype}), do: true
  def image?(%__MODULE__.Attachment{}), do: false

  def initials(%__MODULE__{author_name: name}) when is_binary(name) and name != "",
    do: name |> String.split() |> Enum.take(2) |> Enum.map_join(&String.first/1) |> String.upcase()

  def initials(%__MODULE__{}), do: "?"

  defp kind_name(:customer), do: "Customer"
  defp kind_name(:bot), do: "Bot"
  defp kind_name(_teammate_or_note), do: "Teammate"

  defp blank_to_nil(text) when is_binary(text), do: if(String.trim(text) == "", do: nil, else: text)
  defp blank_to_nil(_none), do: nil

  defp calculate_text(html) when is_binary(html) do
    {:ok, tree} = Floki.parse_fragment(html)

    images =
      for {"img", attrs, _children} <- Floki.find(tree, "img"), {"src", src} <- attrs do
        %__MODULE__.Attachment{name: Path.basename(URI.parse(src).path || "image"), url: src, content_type: "image/*"}
      end

    # Each top-level block is a paragraph; a line break or a list item inside one is a new line.
    text =
      tree
      |> Floki.traverse_and_update(fn
        {"br", _attrs, _children} -> "\n"
        {"li", attrs, children} -> {"li", attrs, ["\n" | children]}
        node -> node
      end)
      |> Enum.map(&([&1] |> Floki.text() |> String.trim()))
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n\n")

    {text, images}
  end

  defp calculate_text(_no_body), do: {"", []}
end
