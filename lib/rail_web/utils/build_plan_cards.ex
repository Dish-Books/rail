defmodule RailWeb.Utils.BuildPlanCards do
  @moduledoc """
  A plan's file cards grouped by where the code goes, as a plan's `### Changes` and a fix plan's
  `### File-level changes` both lay them out, with every part a reader can comment on as a line.
  """

  import RailWeb.Utils.BuildDocumentBlocks

  @line %{
    key: nil,
    kind: nil,
    text: "",
    occurrence: 1,
    label: nil,
    html: nil,
    depth: 0,
    marker: nil,
    cells: [],
    header?: false,
    columns: 0,
    number: nil,
    first?: false,
    last?: false
  }

  @doc """
  Returns `{%{groups:, cards:}, counts}` for `cards` as `ImplementationPlan` reads them: the groups in the order each
  first appears, and the cards numbered in the order the groups draw them. Lines are numbered on from `counts`, so a
  sheet numbers the lines around the cards the same way.
  """
  def build_plan_cards(cards, counts) do
    groups = cards |> Enum.group_by(&group/1) |> then(&order_groups(cards, &1))
    {cards, counts} = groups |> Enum.flat_map(& &1.cards) |> Enum.with_index(1) |> Enum.map_reduce(counts, &card/2)

    by_path = Map.new(cards, &{&1.path, &1})
    groups = Enum.map(groups, fn group -> %{group | cards: Enum.map(group.cards, &Map.fetch!(by_path, &1.path))} end)

    {%{groups: groups, cards: cards}, counts}
  end

  # Each context of `lib/rail` is a group, as are the web, migrations, prompts and assets; anything else goes by the
  # first directory in its path.
  defp group(%{path: path}) do
    case Path.split(path) do
      ["lib", "rail", context | _rest] -> {Path.rootname(context), "lib/rail/#{Path.rootname(context)}"}
      ["lib", "rail_web" | _rest] -> {"web", "lib/rail_web"}
      ["priv", "repo", "migrations" | _rest] -> {"migrations", "priv/repo/migrations"}
      [".rail", "prompts" | _rest] -> {"prompts", ".rail/prompts"}
      ["assets" | _rest] -> {"assets", "assets"}
      [_file] -> {"root", "."}
      [directory | _rest] -> {directory, directory}
    end
  end

  # In the order each group first appears in the plan, and each group's cards in the plan's order.
  defp order_groups(cards, grouped) do
    cards
    |> Enum.map(&group/1)
    |> Enum.uniq()
    |> Enum.map(fn {name, directory} = key ->
      %{
        name: name,
        slug: name |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-") |> String.trim("-"),
        directory: directory,
        cards: Map.fetch!(grouped, key)
      }
    end)
  end

  defp card({card, number}, counts) do
    file = "File #{number}"
    {file_line, counts} = number(Map.merge(@line, %{kind: :file, text: card.path, label: file}), counts)

    {prose, counts} =
      card.prose |> build_document_blocks() |> Enum.map_reduce(counts, &number(%{&1 | label: within(file, &1.label)}, &2))

    {signatures, counts} = code_lines(card.signatures, card.path, :signature, "#{file}, signature line", counts)
    {sketch, counts} = code_lines(card.sketch, card.path, :code, "#{file}, sketch line", counts)

    # Keyed on the path, as a slug could fold two paths into one, so a sketch left open stays with its file.
    id = :erlang.phash2(card.path)

    # Of the card's own text alone, so a reviewed mark lapses only when a revision changes this card.
    digest =
      :sha256
      |> :crypto.hash(:erlang.term_to_binary({card.path, card.deleted?, card.prose, card.signatures, card.sketch}))
      |> Base.encode16(case: :lower)

    card =
      Map.merge(card, %{
        id: id,
        digest: digest,
        number: number,
        line: file_line,
        prose: prose,
        signatures: signatures,
        sketch: sketch
      })

    {card, counts}
  end

  defp code_lines(nil, _path, _kind, _label, counts), do: {[], counts}

  # Highlighted as the file's own language when the fence names none.
  defp code_lines(fenced, path, kind, label, counts) do
    fenced
    |> build_document_blocks(path)
    |> Enum.map_reduce(counts, &number(%{&1 | kind: kind, label: "#{label} #{&1.number}"}, &2))
  end

  defp within(title, label), do: "#{title}, #{String.downcase(String.first(label))}#{String.slice(label, 1..-1//1)}"

  # Numbered across the whole sheet, as the sheet around the cards numbers its own lines.
  defp number(%{kind: kind, text: text} = line, counts) do
    occurrence = Map.get(counts, {kind, text}, 0) + 1
    key = "#{kind}-#{:erlang.phash2({text, occurrence})}"
    {%{line | occurrence: occurrence, key: key}, Map.put(counts, {kind, text}, occurrence)}
  end
end
