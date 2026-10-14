defmodule Rail.Pipeline.Schemas.FixPlan do
  @moduledoc """
  A Review fix round's plan as it stands on disk, with no table behind it: what the round's Sends have sent and the
  HEAD they were sent on, the lead's latest plan with what it covers, and who approved it. Whether it can be approved
  is worked out when it is read.
  """
  use Rail.Schema

  alias Rail.Pipeline.Schemas.Finding
  alias Rail.Pipeline.Schemas.ImplementationPlan
  alias Rail.Pipeline.Schemas.Task

  @sections ["Changes to the plan", "What changes", "File-level changes", "Verification"]

  @counted "\\d+ (?:finding|changed ruling|comment)s?"
  @sent Regex.compile!("\\ASent (#{@counted}(?:(?:, | and )#{@counted})*)\\.\\n")

  @primary_key false
  embedded_schema do
    field :round, :integer
    # The branch's HEAD when the round was sent, so a planning turn is held only for commits of its own.
    field :head, :string
    field :plan, :string
    field :covered_keys, {:array, :string}, default: []
    # Kept at save, since a Send that drops a finding from the round leaves the saved plan still naming it.
    field :covered_titles, {:map, :string}, default: %{}
    field :covered_comments, :integer, default: 0
    # Whether the plan asks for a new demo once its round is built.
    field :record_demo, :boolean, default: false
    # Whether the plan asks for the screen states to be shot again once its round is built.
    field :retake_screens, :boolean, default: false
    # The ticket as a person asked it changed, whole, or nil where they asked for no change.
    field :title, :string
    field :description, :string
    field :version, :integer, default: 0
    field :saved_at, :utc_datetime_usec
    field :approved_by, :string
    field :approved_at, :utc_datetime_usec

    embeds_many :findings, Finding, primary_key: false, on_replace: :delete do
      field :key, :string
      field :title, :string
    end

    embeds_many :comments, Comment, primary_key: false, on_replace: :delete do
      field :number, :integer
      field :kind, Ecto.Enum, values: [:finding, :diff, :screen]
      field :place, :string
      field :text, :string
    end
  end

  @doc """
  Builds a fix plan from what Rail wrote, as `write_fix_plan/2` writes it.
  """
  def changeset(fix_plan, attrs) do
    fix_plan
    |> cast(attrs, [
      :round,
      :head,
      :plan,
      :covered_keys,
      :covered_titles,
      :covered_comments,
      :record_demo,
      :retake_screens,
      :title,
      :description,
      :version,
      :saved_at,
      :approved_by,
      :approved_at
    ])
    |> cast_embed(:findings, with: &cast(&1, &2, [:key, :title]))
    |> cast_embed(:comments, with: &cast(&1, &2, [:number, :kind, :place, :text]))
    |> validate_required([:round])
  end

  @doc """
  Takes the lead's next plan in `attrs["plan"]`, refusing one that leaves out a finding or comment the round sent,
  names one it did not, or lists a file no item names. An accepted plan covers the round as sent and is the next
  version.
  """
  def save_changeset(%__MODULE__{} = fix_plan, attrs) do
    fix_plan
    |> cast(attrs, [:plan, :record_demo, :retake_screens, :title, :description])
    |> update_change(:plan, &String.trim/1)
    |> validate_required([:plan])
    |> validate_structure(fix_plan)
    |> validate_amendments()
    |> ImplementationPlan.validate_file_changes(:plan)
    |> validate_files_named(fix_plan)
    |> then(fn changeset ->
      if changeset.valid?,
        do:
          change(changeset,
            covered_keys: Enum.map(fix_plan.findings, & &1.key),
            covered_titles: Map.new(fix_plan.findings, &{&1.key, &1.title}),
            covered_comments: length(fix_plan.comments),
            version: fix_plan.version + 1,
            saved_at: DateTime.utc_now()
          ),
        else: changeset
    end)
  end

  @doc """
  Where the plan stands against the findings ruled Fix now: `:approved`, `:writing` with none saved, `:revising`
  while it does not cover what was sent, `:outdated` while a ruling differs from what was sent, or `:waiting`.
  """
  def state(%__MODULE__{} = fix_plan, %Task{} = task, findings) do
    sent = MapSet.new(fix_plan.findings, & &1.key)

    cond do
      fix_plan.approved_at != nil -> :approved
      fix_plan.plan == nil -> :writing
      MapSet.new(fix_plan.covered_keys) != sent or fix_plan.covered_comments != length(fix_plan.comments) -> :revising
      fix_now(fix_plan, task, findings) != sent -> :outdated
      true -> :waiting
    end
  end

  @doc """
  The findings whose ruling differs from what the round sent (`unsent`) and from what the saved plan covers
  (`since_plan`), each `%{key:, title:, was:, now:}` with `:fix` or `:skip`. Nobody rules once approved or past Review.
  """
  def calculate_ruling_changes(%__MODULE__{approved_at: %DateTime{}}, %Task{}, _findings),
    do: %{unsent: [], since_plan: []}

  def calculate_ruling_changes(%__MODULE__{} = fix_plan, %Task{} = task, findings) do
    fix_now = fix_now(fix_plan, task, findings)
    sent = MapSet.new(fix_plan.findings, & &1.key)
    covered = if fix_plan.plan, do: MapSet.new(fix_plan.covered_keys), else: fix_now

    %{unsent: changes(findings, sent, fix_now), since_plan: changes(findings, covered, fix_now)}
  end

  @doc """
  Lays the plan out for the Review tab: its summary, an item per finding and comment it covers, each with the
  numbers of the files that name it, the numbered files, Verification, the counts and whether it covers the round as
  sent. `nil` before a plan is saved.
  """
  def build_sheet(%__MODULE__{plan: nil}), do: nil

  def build_sheet(%__MODULE__{plan: plan} = fix_plan) do
    {lead, sections} = sections(plan)
    bodies = sections |> List.keyfind("What changes", 0, {nil, []}) |> elem(1) |> items() |> elem(2)
    files = ImplementationPlan.build_file_changes(plan) || []

    findings =
      Enum.map(fix_plan.covered_keys, fn key ->
        %{
          id: key,
          kind: :finding,
          key: key,
          title: fix_plan.covered_titles[key],
          body: bodies |> Map.get({:finding, key}, "") |> String.trim(),
          files: for(file <- files, names?(file.description, {:finding, key}), do: file.number)
        }
      end)

    # A Send only appends comments, so the plan covers the round's first ones.
    comments =
      fix_plan.comments
      |> Enum.take(fix_plan.covered_comments)
      |> Enum.map(fn comment ->
        %{
          id: "comment-#{comment.number}",
          kind: :comment,
          number: comment.number,
          comment_kind: comment.kind,
          place: comment.place,
          text: comment.text,
          body: bodies |> Map.get({:comment, comment.number}, "") |> String.trim(),
          files: for(file <- files, names?(file.description, {:comment, comment.number}), do: file.number)
        }
      end)

    verification = sections |> List.keyfind("Verification", 0, {nil, []}) |> elem(1) |> Enum.join("\n") |> String.trim()

    %{
      summary: lead |> Enum.reject(&String.match?(&1, ~r/\A\#{1,2} /)) |> Enum.join("\n") |> String.trim(),
      items: findings ++ comments,
      files: files,
      verification: if(verification != "", do: verification),
      counts: %{findings: length(findings), comments: length(comments), files: length(files)},
      covers_round:
        MapSet.new(fix_plan.covered_keys) == MapSet.new(fix_plan.findings, & &1.key) and
          fix_plan.covered_comments == length(fix_plan.comments)
    }
  end

  @doc """
  Reads a Send's note back for the conversation: what its first line says was sent, the titles of the findings it
  sent, the rulings it changed and its numbered comments' text. `nil` for any other message.
  """
  def parse_note(text) when is_binary(text) do
    case Regex.run(@sent, String.trim_leading(text) <> "\n") do
      [_line, summary] ->
        rulings =
          for [_all, key, was, now, title] <-
                Regex.scan(~r/<ruling_change key="([^"]+)" was="([^"]+)" now="([^"]+)">\n(.*)\n/, text),
              do: %{key: key, title: title, was: was, now: now}

        changed = MapSet.new(rulings, & &1.key)

        findings =
          for [_all, key, title] <- Regex.scan(~r/<finding key="([^"]+)"[^>]*>\n(.*)\n/, text),
              not MapSet.member?(changed, key),
              do: title

        comments =
          for [number, block] <-
                Regex.scan(~r/^(\d+)\. On (?:a finding|the diff|a screen):\n(<(\w+)[^>]*>\n.*?\n<\/\3>)/ms, text,
                  capture: [1, 2]
                ),
              do: %{number: String.to_integer(number), text: comment_text(block)}

        %{summary: summary, findings: findings, rulings: rulings, comments: comments}

      nil ->
        nil
    end
  end

  def parse_note(_not_text), do: nil

  # Past Review nobody rules, so the round is what it sent.
  defp fix_now(%__MODULE__{}, %Task{stage: :review}, findings),
    do: findings |> Enum.filter(&Finding.outstanding?/1) |> MapSet.new(& &1.key)

  defp fix_now(%__MODULE__{} = fix_plan, %Task{}, _findings), do: MapSet.new(fix_plan.findings, & &1.key)

  defp changes(findings, before, now) do
    for finding <- findings,
        MapSet.member?(before, finding.key) != MapSet.member?(now, finding.key),
        do: %{
          key: finding.key,
          title: finding.title,
          was: ruling(MapSet.member?(before, finding.key)),
          now: ruling(MapSet.member?(now, finding.key))
        }
  end

  defp ruling(true), do: :fix
  defp ruling(false), do: :skip

  defp validate_structure(changeset, %__MODULE__{} = fix_plan) do
    validate_change(changeset, :plan, fn :plan, plan ->
      {_lead, sections} = sections(plan)
      titles = Enum.map(sections, &elem(&1, 0))

      section_errors =
        Enum.map(Enum.uniq(titles) -- @sections, &"has a `### #{&1}` section, but the sections are #{listed()}") ++
          Enum.map(titles -- Enum.uniq(titles), &"has `### #{&1}` more than once")

      item_errors =
        case List.keyfind(sections, "What changes", 0) do
          {_title, lines} ->
            {errors, named, _bodies} = items(lines)
            item_errors(errors, named, fix_plan)

          nil ->
            [
              "is missing its `### What changes` section, with a `#### `key`` for each finding and a `#### Comment N` for each comment"
            ]
        end

      Enum.map(section_errors ++ item_errors, &{:plan, &1})
    end)
  end

  defp item_errors(errors, named, %__MODULE__{} = fix_plan) do
    sent = Enum.map(fix_plan.findings, &{:finding, &1.key}) ++ Enum.map(fix_plan.comments, &{:comment, &1.number})
    named = Enum.reverse(named)

    errors ++
      Enum.map(named -- Enum.uniq(named), &"names #{item(&1)} under `### What changes` more than once") ++
      Enum.map(Enum.uniq(named) -- sent, &"names #{item(&1)} under `### What changes`, which this round did not send") ++
      Enum.map(sent -- named, &"leaves out #{item(&1)}; give it a `####` of its own under `### What changes`")
  end

  defp validate_files_named(%Ecto.Changeset{valid?: false} = changeset, _fix_plan), do: changeset

  defp validate_files_named(changeset, %__MODULE__{} = fix_plan) do
    validate_change(changeset, :plan, fn :plan, plan ->
      items = Enum.map(fix_plan.findings, &{:finding, &1.key}) ++ Enum.map(fix_plan.comments, &{:comment, &1.number})

      for file <- ImplementationPlan.build_file_changes(plan) || [],
          not Enum.any?(items, &names?(file.description, &1)),
          do:
            {:plan,
             "has `#{file.path}` under `### File-level changes` naming no item; end its bullet with the finding's key in backticks or `comment N`"}
    end)
  end

  defp names?(description, {:finding, key}), do: String.contains?(description, "`#{key}`")
  defp names?(description, {:comment, number}), do: Regex.match?(~r/\bcomment #{number}\b/i, description)

  defp item({:finding, key}), do: "`#{key}`"
  defp item({:comment, number}), do: "comment #{number}"

  # Each `####` under What changes is a finding by its key in backticks or a comment by its number.
  defp items(lines) do
    {errors, named, bodies, _current} =
      Enum.reduce(lines, {[], [], %{}, nil}, fn line, {errors, named, bodies, current} ->
        cond do
          match = Regex.run(~r/\A#### `([^`]+)`\s*\z/, line) ->
            {errors, [{:finding, Enum.at(match, 1)} | named], bodies, {:finding, Enum.at(match, 1)}}

          match = Regex.run(~r/\A#### Comment (\d+)\s*\z/i, line) ->
            id = {:comment, String.to_integer(Enum.at(match, 1))}
            {errors, [id | named], bodies, id}

          String.starts_with?(line, "####") ->
            {["has `#{line}` under `### What changes`; each item is `#### `key`` or `#### Comment N`" | errors], named,
             bodies, nil}

          current == nil and String.trim(line) != "" ->
            {["has text under `### What changes` before its first `####` item" | errors], named, bodies, current}

          current == nil ->
            {errors, named, bodies, current}

          true ->
            {errors, named, Map.update(bodies, current, line, &(&1 <> "\n" <> line)), current}
        end
      end)

    {errors |> Enum.reverse() |> Enum.uniq(), named, bodies}
  end

  # Splits on the `###` headings outside fenced blocks, keeping the lead and each section's body as lines.
  defp sections(plan) do
    {headed, _fenced} =
      plan
      |> String.split("\n")
      |> Enum.map_reduce(false, fn line, fenced ->
        fenced = if String.starts_with?(line, "```"), do: not fenced, else: fenced
        {{not fenced && Regex.run(~r/\A### (.+?)\s*\z/, line, capture: :all_but_first), line}, fenced}
      end)

    [{nil, lead} | sections] =
      Enum.chunk_while(
        headed,
        {nil, []},
        fn
          {[title], _line}, {current, lines} -> {:cont, {current, Enum.reverse(lines)}, {title, []}}
          {_body, line}, {current, lines} -> {:cont, {current, [line | lines]}}
        end,
        fn {current, lines} -> {:cont, {current, Enum.reverse(lines)}, nil} end
      )

    {lead, sections}
  end

  defp listed, do: Enum.map_join(@sections, ", ", &"`### #{&1}`")

  # A block's last part is the comment as written; what comes before it is where it was left.
  defp comment_text(block) do
    lines = block |> String.split("\n") |> Enum.drop(1) |> Enum.drop(-1)

    case_result =
      case hd(String.split(block, "\n")) do
        "<diff_comment>" -> lines |> Enum.drop(1) |> drop_code()
        "<screen_comment>" -> lines |> Enum.drop(1) |> Enum.reject(&String.starts_with?(&1, "Picture: "))
        _finding_comment -> lines |> Enum.drop(2) |> Enum.drop_while(&String.starts_with?(&1, "> "))
      end

    case_result
    |> Enum.join("\n")
    |> String.trim()
  end

  # The code a diff comment quotes is its lines around the comment, or the one line of an older comment.
  defp drop_code([first | rest] = lines) do
    if Regex.match?(~r/\A[> ] [+\- ]/, first),
      do: Enum.drop_while(lines, &Regex.match?(~r/\A[> ] [+\- ]/, &1)),
      else: rest
  end

  defp drop_code([]), do: []

  # A changed ticket is said where the person reads the plan, before anything is approved on it.
  defp validate_amendments(changeset) do
    amended = get_field(changeset, :title) != nil or get_field(changeset, :description) != nil
    plan = get_field(changeset, :plan) || ""

    if amended and not String.contains?(plan, "### Changes to the plan"),
      do:
        add_error(
          changeset,
          :plan,
          "changes the ticket, so it opens with a `### Changes to the plan` section saying what was asked, by whom, and what each part was and becomes"
        ),
      else: changeset
  end
end
