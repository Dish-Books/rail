defmodule RailWeb.Components.PlanCards do
  @moduledoc """
  A plan's file cards in groups that fold, as a plan's Changes and a fix plan's File-level changes both show them. Each
  card says New, Changed or Deleted against the default branch, opens a file the task already changed in the Diff item
  and links one only the default branch has to GitHub, keeps its code sketch a click away and takes a reviewed mark.
  Every line takes a comment.
  """
  use RailWeb, :html

  @kinds [
    new: {"New", "ring-emerald-500/50 text-emerald-700 dark:text-emerald-300"},
    changed: {"Changed", "ring-sky-500/50 text-sky-700 dark:text-sky-300"},
    deleted: {"Deleted", "ring-red-500/50 text-red-700 dark:text-red-300"}
  ]

  attr :id, :string, required: true
  attr :base, :string, required: true, doc: "what the ids of the groups, cards and sketches start with"
  attr :title_line, :map, required: true, doc: "the section title's line, which the heading is drawn in"
  attr :groups, :list, required: true, doc: "the groups `build_plan_cards/2` made"
  attr :cards, :list, required: true, doc: "every card of the groups, in drawn order"
  attr :on, :map, required: true, doc: "`%{placed:, draft:, offered:, doc:}` for the commentable lines"
  attr :target, :any, required: true

  attr :reviewed, :map,
    default: nil,
    doc: "the reader's marks, each card's path to the digest it had when marked; without them no card takes one"

  attr :default_paths, :any,
    default: nil,
    doc: "the cards' paths on the default branch, or nil when the clone could not say"

  attr :diff_paths, :any,
    default: nil,
    doc: "the cards' paths the task's branch already changed, which open in the Diff item, or nil where none do"

  attr :project, :any,
    default: nil,
    doc: "whose GitHub repository and default branch a path links to, with `default_paths`"

  slot :heading, required: true, doc: "the section's heading, given the subtitle that says how the cards read"

  def plan_cards(assigns) do
    assigns =
      assigns
      |> assign(:reviewed_count, reviewed_count(assigns.cards, assigns.reviewed))
      |> assign(:groups, groups(assigns))
      |> assign(:subtitle, subtitle(assigns))

    ~H"""
    <section id={@id}>
      <.line line={@title_line} on={@on} target={@target} class="mb-2">
        <div class="flex items-baseline gap-2">
          {render_slot(@heading, @subtitle)}
          <span
            :if={@reviewed}
            id={"#{@base}-reviewed-count"}
            data-qa="plan_reviewed_count"
            class="ml-auto shrink-0 text-[13px] font-semibold text-slate-900 dark:text-slate-100"
          >
            {@reviewed_count} of {length(@cards)} reviewed
          </span>
        </div>
      </.line>
      <details
        :for={group <- @groups}
        id={"#{@base}-group-#{group.slug}"}
        data-qa="plan_group"
        open
        phx-mounted={JS.ignore_attributes(["open"])}
        class="group/fold mt-3 first-of-type:mt-0 rounded-xl border border-slate-300 dark:border-slate-600 bg-slate-50 dark:bg-slate-800/40"
      >
        <summary class="list-none [&::-webkit-details-marker]:hidden flex items-center gap-2.5 px-3.5 py-2.5 rounded-xl hover:bg-slate-100 dark:hover:bg-slate-800/70 cursor-pointer focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-blue-500">
          <.icon
            name="pi-caret-right-bold"
            class="size-[13px] text-slate-400 group-open/fold:rotate-90 motion-safe:transition-transform"
          />
          <.icon name="pi-folder-simple-fill" class="size-[18px] text-slate-400" />
          <span class="font-mono text-[15px] font-bold text-slate-900 dark:text-slate-100">
            {group.name}
          </span>
          <span class="min-w-0 font-mono text-[12px] text-slate-500 truncate">{group.directory}</span>
          <span
            data-qa="plan_group_count"
            class="ml-auto shrink-0 text-[12.5px] text-slate-600 dark:text-slate-300"
          >
            {group.count}
          </span>
          <span
            :if={@reviewed}
            data-qa="plan_group_reviewed"
            class="shrink-0 text-[12px] text-slate-500"
          >
            · {reviewed_count(group.cards, @reviewed)} of {length(group.cards)} reviewed
          </span>
        </summary>
        <div class="space-y-2 px-2.5 pb-2.5">
          <.card
            :for={card <- group.cards}
            card={card}
            state={state(card, @reviewed)}
            base={@base}
            on={@on}
            target={@target}
          />
        </div>
      </details>
    </section>
    """
  end

  attr :card, :map, required: true
  attr :state, :atom, required: true, values: [nil, :unreviewed, :reviewed, :revised]
  attr :base, :string, required: true
  attr :on, :map, required: true
  attr :target, :any, required: true

  # A reviewed card is its header alone, so the comments on its other lines are drawn under it, each naming its line.
  defp card(assigns) do
    ~H"""
    <div
      id={"#{@base}-card-#{@card.number}"}
      data-qa="plan_card"
      data-state={@state}
      class={[
        "rounded-xl border bg-white dark:bg-slate-900 scroll-mt-4",
        @state == :revised && "border-amber-400 dark:border-amber-700/60",
        @state != :revised && "border-slate-200 dark:border-slate-700"
      ]}
    >
      <div class="px-4 py-1.5">
        <.line line={@card.line} on={@on} target={@target}>
          <div class="flex items-center gap-2.5 py-1">
            <.kind_badge :if={@card.kind} kind={@card.kind} />
            <button
              :if={@card.link[:diff?]}
              type="button"
              phx-click="open_diff"
              phx-value-file={@card.path}
              phx-target={@target}
              data-qa="plan_card_diff"
              title={@card.link.title}
              class="min-w-0 inline-flex items-center gap-1 font-mono text-[13px] font-semibold text-slate-900 dark:text-slate-100 hover:underline decoration-slate-500 rounded-sm cursor-pointer focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-blue-500"
            >
              <span class="truncate">{@card.path}</span>
              <.icon name="pi-git-diff-bold" class="shrink-0 size-[12px] text-slate-400" />
            </button>
            <a
              :if={@card.link[:href]}
              href={@card.link.href}
              target="_blank"
              rel="noopener noreferrer"
              data-qa="plan_card_link"
              title={@card.link.title}
              class="min-w-0 inline-flex items-center gap-1 font-mono text-[13px] font-semibold text-slate-900 dark:text-slate-100 hover:underline decoration-slate-500 rounded-sm focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-blue-500"
            >
              <span class="truncate">{@card.path}</span>
              <.icon name="pi-arrow-up-right-bold" class="shrink-0 size-[12px] text-slate-400" />
            </a>
            <span
              :if={!@card.link}
              class="min-w-0 truncate font-mono text-[13px] font-semibold text-slate-900 dark:text-slate-100"
              title={@card.path}
            >
              {@card.path}
            </span>
            <span class="ml-auto" />
            <.reviewed_toggle
              :if={@state}
              reviewed={@state == :reviewed}
              phx-click="toggle_plan_file_reviewed"
              phx-value-path={@card.path}
              phx-value-digest={@card.digest}
              phx-value-reviewed={to_string(@state != :reviewed)}
              phx-target={@target}
              data-qa="plan_card_reviewed"
            />
          </div>
        </.line>
        <p
          :if={@state == :revised}
          data-qa="plan_card_revised"
          class="mb-1.5 rounded-md border border-amber-300 dark:border-amber-600/60 bg-amber-50 dark:bg-amber-950/40 px-3 py-1.5 text-[12.5px] text-amber-800 dark:text-amber-200"
        >
          <b class="font-semibold">Revised since you reviewed it.</b>
          Plan changed this file's part, so it's unmarked.
        </p>
        <.line
          :for={line <- @card.prose}
          :if={@state != :reviewed}
          line={line}
          on={@on}
          target={@target}
        />
      </div>

      <.line
        :for={line <- @card.prose ++ @card.signatures ++ @card.sketch}
        :if={@state == :reviewed}
        line={line}
        layout={:away}
        on={@on}
        target={@target}
        class="last:rounded-b-xl"
      />

      <div
        :if={@card.signatures != [] and @state != :reviewed}
        data-qa="plan_card_signatures"
        class="py-1.5 border-t border-slate-200 dark:border-slate-700 bg-slate-50 dark:bg-slate-950/50 last:rounded-b-xl"
      >
        <.line
          :for={line <- @card.signatures}
          line={line}
          layout={:code}
          framed={false}
          on={@on}
          target={@target}
        />
      </div>

      <details
        :if={@card.sketch != [] and @state != :reviewed}
        id={"#{@base}-sketch-#{@card.id}"}
        data-qa="plan_card_sketch"
        open={Enum.any?(@card.sketch, &Map.has_key?(@on.placed, &1.key))}
        phx-mounted={JS.ignore_attributes(["open"])}
        class="group/sketch border-t border-slate-200 dark:border-slate-700"
      >
        <summary class="list-none [&::-webkit-details-marker]:hidden flex items-center gap-1 px-4 py-1.5 text-[12px] font-semibold text-indigo-600 dark:text-indigo-300 hover:text-indigo-500 dark:hover:text-indigo-200 cursor-pointer focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-blue-500">
          <.icon
            name="pi-caret-right-fill"
            class="size-[10px] group-open/sketch:rotate-90 motion-safe:transition-transform"
          />
          <span class="group-open/sketch:hidden">Show code</span>
          <span class="hidden group-open/sketch:inline">Hide code</span>
        </summary>
        <div class="py-1.5 border-t border-slate-200 dark:border-slate-700 bg-slate-50 dark:bg-slate-950 rounded-b-xl">
          <.line
            :for={line <- @card.sketch}
            line={line}
            layout={:code}
            framed={false}
            on={@on}
            target={@target}
          />
        </div>
      </details>
    </div>
    """
  end

  attr :line, :map, required: true
  attr :on, :map, required: true
  attr :target, :any, required: true
  attr :layout, :atom, default: nil
  attr :framed, :boolean, default: true
  attr :class, :any, default: nil
  slot :inner_block

  # A line given nothing to show draws what its kind does.
  defp line(%{inner_block: []} = assigns) do
    ~H"""
    <.commentable_line
      line={@line}
      layout={@layout || layout(@line)}
      framed={@framed}
      doc={@on.doc}
      placed={@on.placed}
      draft={@on.draft}
      offered={@on.offered}
      target={@target}
      class={@class}
    />
    """
  end

  defp line(assigns) do
    ~H"""
    <.commentable_line
      line={@line}
      layout={@layout || layout(@line)}
      doc={@on.doc}
      placed={@on.placed}
      draft={@on.draft}
      offered={@on.offered}
      target={@target}
      class={@class}
    >
      {render_slot(@inner_block)}
    </.commentable_line>
    """
  end

  attr :kind, :atom, required: true

  defp kind_badge(assigns) do
    {label, color} = Keyword.fetch!(@kinds, assigns.kind)
    assigns = assigns |> assign(:label, label) |> assign(:color, color)

    ~H"""
    <span
      data-qa={"plan_card_#{@kind}"}
      class={[
        "shrink-0 rounded px-1.5 py-0.5 text-[10px] font-bold uppercase tracking-wider ring-1 ring-inset",
        @color
      ]}
    >
      {@label}
    </span>
    """
  end

  # Read as the card read when it was marked, so a revision to it reads revised rather than reviewed.
  defp state(_card, nil), do: nil

  defp state(card, reviewed) do
    case Map.fetch(reviewed, card.path) do
      {:ok, digest} when digest == card.digest -> :reviewed
      {:ok, _other_digest} -> :revised
      :error -> :unreviewed
    end
  end

  defp reviewed_count(_cards, nil), do: 0
  defp reviewed_count(cards, reviewed), do: Enum.count(cards, &(state(&1, reviewed) == :reviewed))

  defp subtitle(%{diff_paths: nil, default_paths: nil}), do: "Grouped by where the code goes"

  defp subtitle(%{diff_paths: nil, project: project}),
    do: "Grouped by where the code goes. Changed files link to #{project.default_branch} on GitHub."

  defp subtitle(%{default_paths: nil}), do: "Grouped by where the code goes. Files this task changed open in Diff."

  defp subtitle(%{project: project}),
    do:
      "Grouped by where the code goes. Files this task changed open in Diff, and others link to " <>
        "#{project.default_branch} on GitHub."

  # Without the default branch's paths a card cannot tell New from Changed, so a group counts its files instead.
  defp groups(%{default_paths: nil, groups: groups} = assigns) do
    Enum.map(groups, fn group ->
      cards =
        Enum.map(group.cards, &Map.merge(&1, %{kind: if(&1.deleted?, do: :deleted), link: link(&1, assigns)}))

      Map.put(%{group | cards: cards}, :count, count_label(length(cards), "file", "files"))
    end)
  end

  defp groups(%{default_paths: paths, groups: groups} = assigns) do
    Enum.map(groups, fn group ->
      cards = Enum.map(group.cards, &Map.merge(&1, %{kind: kind(&1, paths), link: link(&1, assigns)}))

      count =
        @kinds
        |> Enum.map(fn {kind, _badge} -> {kind, Enum.count(cards, &(&1.kind == kind))} end)
        |> Enum.reject(fn {_kind, number} -> number == 0 end)
        |> Enum.map_join(" · ", fn {kind, number} -> "#{number} #{kind}" end)

      Map.put(%{group | cards: cards}, :count, count)
    end)
  end

  defp kind(card, paths) do
    cond do
      card.deleted? -> :deleted
      MapSet.member?(paths, card.path) -> :changed
      true -> :new
    end
  end

  # The task's own change to a file is what a reader wants beside its card, so the Diff wins over GitHub.
  defp link(card, %{diff_paths: diff_paths, default_paths: default_paths, project: project}) do
    cond do
      diff_paths && MapSet.member?(diff_paths, card.path) ->
        %{diff?: true, title: "Open #{card.path} in Diff"}

      default_paths && MapSet.member?(default_paths, card.path) ->
        %{
          href: "https://github.com/#{project.github_repo}/blob/#{encode(project.default_branch)}/#{encode(card.path)}",
          title: "Open #{card.path} on #{project.default_branch} in GitHub (new tab)"
        }

      true ->
        nil
    end
  end

  # A path is the plan's text, so a `#` or `?` in it stays part of the path rather than ending the URL's.
  defp encode(path), do: URI.encode(path, &(&1 == ?/ or URI.char_unreserved?(&1)))

  defp count_label(1, one, _many), do: "1 #{one}"
  defp count_label(count, _one, many), do: "#{count} #{many}"

  # A sketch's and signatures' lines are drawn as code by the card itself.
  defp layout(%{kind: :table_row}), do: :table_row
  defp layout(_line), do: :text
end
