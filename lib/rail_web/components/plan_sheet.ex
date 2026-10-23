defmodule RailWeb.Components.PlanSheet do
  @moduledoc """
  An implementation plan laid out for review in one column: Approach, the data changes, the decisions, a card per file
  in groups that fold, each acceptance criterion with what answers it, and Verification. Every line takes a comment.
  """
  use RailWeb, :html

  @decision_badges %{
    decision: {"Decision", "ring-indigo-400/60 text-indigo-700 dark:text-indigo-200"},
    ruled_out: {"Ruled out", "ring-slate-400 dark:ring-slate-500 text-slate-600 dark:text-slate-300"},
    assumption: {"Assumption", "ring-violet-400/50 text-violet-700 dark:text-violet-200"}
  }

  @columns "grid-cols-[minmax(0,2fr)_minmax(0,1fr)_minmax(0,1fr)]"

  @kinds [
    new: {"New", "ring-emerald-500/50 text-emerald-700 dark:text-emerald-300"},
    changed: {"Changed", "ring-sky-500/50 text-sky-700 dark:text-sky-300"},
    deleted: {"Deleted", "ring-red-500/50 text-red-700 dark:text-red-300"}
  ]

  attr :sheet, :map, required: true, doc: "what `build_plan_sheet/2` made of the plan"
  attr :criteria, :list, default: [], doc: "the ticket's acceptance criteria, each `%{number:, html:}`"
  attr :part, :integer, default: nil, doc: "the split child's number, when the plan is a child's part"
  attr :target, :any, default: nil
  attr :placed, :map, default: %{}, doc: "the reader's comments on each line, by its key"
  attr :changed, :list, default: [], doc: "the reader's comments whose line no longer reads as it did"
  attr :draft, :map, default: nil, doc: "the line the comment box is open under"
  attr :offered, :boolean, default: false, doc: "the reader can comment now"

  attr :default_paths, :any,
    default: nil,
    doc: "the cards' paths on the default branch, or nil when the clone could not say"

  attr :project, :any, required: true, doc: "whose GitHub repository and default branch a path links to"

  def plan_sheet(assigns) do
    assigns =
      assigns
      |> assign(:base, if(assigns.part, do: "plan-#{assigns.part}", else: "plan"))
      |> assign(:on, %{placed: assigns.placed, draft: assigns.draft, offered: assigns.offered, doc: :plan})
      |> assign(:rows, rows(assigns.sheet.criteria, assigns.criteria))
      |> assign(:columns, @columns)
      |> assign(:groups, groups(assigns))

    ~H"""
    <div
      id="plan-sheet"
      data-qa="plan_sheet"
      class="max-w-[1120px] flex flex-col gap-7 wrap-anywhere"
    >
      <.changed_comments id="plan-changed-comments" comments={@changed} target={@target} />

      <section :if={@sheet.approach} id="plan-approach">
        <.line line={@sheet.approach.title_line} on={@on} target={@target}>
          <p class="text-[11px] font-bold uppercase tracking-[0.12em] text-slate-500 dark:text-slate-400">
            Approach
          </p>
        </.line>
        <.line :for={line <- @sheet.approach.lines} line={line} on={@on} target={@target} />
      </section>

      <section
        :if={@sheet.data_changes}
        id="plan-data-changes"
        class="rounded-xl border border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-900"
      >
        <div class="px-4 py-2.5 border-b border-slate-200 dark:border-slate-700">
          <.line line={@sheet.data_changes.title_line} on={@on} target={@target}>
            <.heading title="Data changes" subtitle="The hardest part to undo, so it's first" />
          </.line>
        </div>
        <div
          :for={change <- @sheet.data_changes.items}
          data-qa="plan_data_change"
          class="px-4 py-2 border-t border-slate-200 dark:border-slate-800 first:border-t-0"
        >
          <.line line={change.line} on={@on} target={@target}>
            <div class="flex items-start gap-3 py-1">
              <span class="shrink-0 mt-0.5 rounded px-1.5 py-0.5 text-[10px] font-bold uppercase tracking-wider ring-1 ring-inset ring-emerald-500/50 text-emerald-700 dark:text-emerald-300">
                {change.kind}
              </span>
              <div class="min-w-0">
                <code class="font-mono text-[13px] font-semibold break-all text-slate-900 dark:text-slate-100">
                  {change.name}
                </code>
                <.prose html={change.html} class="text-[13px] text-slate-500 dark:text-slate-400" />
              </div>
            </div>
          </.line>
        </div>
      </section>

      <section :if={@sheet.decisions} id="plan-decisions">
        <.line line={@sheet.decisions.title_line} on={@on} target={@target} class="mb-2">
          <.heading
            title="Decisions"
            subtitle="What an engineer could get wrong, and what was ruled out"
          />
        </.line>
        <ul class="rounded-xl border border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-900">
          <li
            :for={decision <- @sheet.decisions.items}
            data-qa="plan_decision"
            class="px-4 py-1.5 border-t border-slate-200 dark:border-slate-700 first:border-t-0"
          >
            <.line line={decision.line} on={@on} target={@target}>
              <div class="flex items-start gap-3 py-1">
                <span class="shrink-0 w-[6.5rem] pt-0.5">
                  <.decision_badge kind={decision.kind} />
                </span>
                <.prose
                  html={decision.html}
                  class="flex-1 text-[14px] text-slate-700 dark:text-slate-200"
                />
              </div>
            </.line>
          </li>
        </ul>
      </section>

      <section id="plan-changes">
        <.line line={@sheet.changes_title} on={@on} target={@target} class="mb-2">
          <.heading
            title="Changes"
            subtitle={
              if @default_paths,
                do:
                  "Grouped by where the code goes. Changed files link to #{@project.default_branch} on GitHub.",
                else: "Grouped by where the code goes"
            }
          />
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
          </summary>
          <div class="space-y-2 px-2.5 pb-2.5">
            <.card :for={card <- group.cards} card={card} base={@base} on={@on} target={@target} />
          </div>
        </details>
      </section>

      <section :if={@rows != []} id="plan-criteria">
        <.line line={@sheet.criteria.title_line} on={@on} target={@target} class="mb-2">
          <.heading title="Acceptance criteria" subtitle="What in the plan satisfies each one" />
        </.line>
        <div class={[
          "grid mt-2 rounded-t-lg border border-b-0 border-slate-200 dark:border-slate-800 text-[12px] font-semibold text-slate-500 dark:text-slate-400",
          @columns
        ]}>
          <div class="px-4 py-2">Criterion</div>
          <div class="px-4 py-2">Files</div>
          <div class="px-4 py-2">Test</div>
        </div>
        <.criterion
          :for={row <- @rows}
          row={row}
          columns={@columns}
          on={@on}
          target={@target}
        />
      </section>

      <section :if={@sheet.verification} id="plan-verification">
        <.line line={@sheet.verification.title_line} on={@on} target={@target} class="mb-2">
          <.heading title="Verification" subtitle="The tests that matter most" />
        </.line>
        <.line :for={line <- @sheet.verification.lines} line={line} on={@on} target={@target} />
      </section>
    </div>
    """
  end

  attr :card, :map, required: true
  attr :base, :string, required: true
  attr :on, :map, required: true
  attr :target, :any, required: true

  defp card(assigns) do
    ~H"""
    <div
      id={"#{@base}-card-#{@card.number}"}
      data-qa="plan_card"
      class="rounded-xl border border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-900"
    >
      <div class="px-4 py-1.5">
        <.line line={@card.line} on={@on} target={@target}>
          <div class="flex items-center gap-2.5 py-1">
            <.kind_badge :if={@card.kind} kind={@card.kind} />
            <a
              :if={@card.link}
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
          </div>
        </.line>
        <.line :for={line <- @card.prose} line={line} on={@on} target={@target} />
      </div>

      <div
        :if={@card.signatures != []}
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
        :if={@card.sketch != []}
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

  attr :row, :map, required: true
  attr :columns, :string, required: true
  attr :on, :map, required: true
  attr :target, :any, required: true

  # Covered by what the plan names for it, so a row with no paths reads Not covered too.
  defp criterion(assigns) do
    assigns = assign(assigns, :covered, assigns.row.files != [] or assigns.row.tests != [])

    ~H"""
    <.line
      line={%{@row.line | first?: false, last?: @row.last?}}
      layout={:table_row}
      on={@on}
      target={@target}
    >
      <div data-qa="plan_criterion" class={["col-span-full grid", @columns]}>
        <.criterion_text covered={@covered} html={@row.html} />
        <div :if={!@covered} class="px-4 py-2">
          <span class="inline-flex items-center rounded px-1.5 py-0.5 text-[11px] font-bold uppercase tracking-wider ring-1 ring-inset ring-rose-500/50 text-rose-700 dark:text-rose-300">
            Not covered
          </span>
        </div>
        <div :if={!@covered} />
        <div
          :for={cell <- tl(@row.line.cells)}
          :if={@covered}
          class="min-w-0 px-4 py-2 font-mono text-[12.5px] wrap-anywhere prose prose-slate dark:prose-invert max-w-none [&_p]:my-0 prose-code:font-normal prose-code:before:content-none prose-code:after:content-none"
        >
          {raw(cell)}
        </div>
      </div>
    </.line>
    """
  end

  attr :covered, :boolean, required: true
  attr :html, :string, required: true

  defp criterion_text(assigns) do
    ~H"""
    <div class="min-w-0 px-4 py-2 flex gap-2">
      <.icon
        name={if @covered, do: "pi-check-bold", else: "pi-x-bold"}
        class={["mt-1 size-[13px]", if(@covered, do: "text-emerald-500", else: "text-rose-500")]}
      />
      <span class="sr-only">{if @covered, do: "Covered:", else: "Not covered:"}</span>
      <.prose html={@html} class="text-[13.5px] text-slate-700 dark:text-slate-200" />
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

  attr :title, :string, required: true
  attr :subtitle, :string, required: true

  defp heading(assigns) do
    ~H"""
    <div class="flex flex-wrap items-baseline gap-x-2">
      <h3 class="text-[14.5px] font-bold text-slate-900 dark:text-slate-100">{@title}</h3>
      <span class="text-[12.5px] text-slate-500 dark:text-slate-400">{@subtitle}</span>
    </div>
    """
  end

  attr :kind, :atom, required: true

  defp decision_badge(assigns) do
    {label, color} = Map.fetch!(@decision_badges, assigns.kind)
    assigns = assigns |> assign(:label, label) |> assign(:color, color)

    ~H"""
    <span class={[
      "inline-flex rounded px-1.5 py-0.5 text-[10px] font-bold uppercase tracking-wider ring-1 ring-inset",
      @color
    ]}>
      {@label}
    </span>
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

  attr :html, :string, required: true
  attr :class, :any, default: nil

  defp prose(assigns) do
    ~H"""
    <div class={[
      "min-w-0 prose prose-slate dark:prose-invert max-w-none leading-relaxed wrap-anywhere [&>*]:my-0 text-[inherit]",
      @class
    ]}>
      {raw(@html)}
    </div>
    """
  end

  # The ticket's criteria in its order, each with the sheet's row for it; a row for a criterion the ticket lacks is not
  # drawn. Without the ticket's words, every row is drawn and reads by its number.
  defp rows(nil, _criteria), do: []

  defp rows(%{rows: rows}, []),
    do: rows(%{rows: rows}, Enum.map(rows, &%{number: &1.number, html: "Criterion #{&1.number}"}))

  defp rows(%{rows: rows}, criteria) do
    by_number = Map.new(rows, &{&1.number, &1})
    last = length(criteria) - 1

    criteria
    |> Enum.with_index()
    |> Enum.map(fn {criterion, index} ->
      Map.merge(Map.fetch!(by_number, criterion.number), %{html: criterion.html, last?: index == last})
    end)
  end

  # Without the default branch's paths a card cannot tell New from Changed, so a group counts its files instead.
  defp groups(%{default_paths: nil, sheet: sheet}) do
    Enum.map(sheet.groups, fn group ->
      cards = Enum.map(group.cards, &Map.merge(&1, %{kind: if(&1.deleted?, do: :deleted), link: nil}))
      Map.put(%{group | cards: cards}, :count, count_label(length(cards), "file", "files"))
    end)
  end

  defp groups(%{default_paths: paths, sheet: sheet, project: project}) do
    Enum.map(sheet.groups, fn group ->
      cards = Enum.map(group.cards, &mark_card(&1, paths, project))

      count =
        @kinds
        |> Enum.map(fn {kind, _badge} -> {kind, Enum.count(cards, &(&1.kind == kind))} end)
        |> Enum.reject(fn {_kind, number} -> number == 0 end)
        |> Enum.map_join(" · ", fn {kind, number} -> "#{number} #{kind}" end)

      Map.put(%{group | cards: cards}, :count, count)
    end)
  end

  defp mark_card(card, paths, project) do
    on_branch = MapSet.member?(paths, card.path)

    kind =
      cond do
        card.deleted? -> :deleted
        on_branch -> :changed
        true -> :new
      end

    link =
      if on_branch do
        %{
          href: "https://github.com/#{project.github_repo}/blob/#{encode(project.default_branch)}/#{encode(card.path)}",
          title: "Open #{card.path} on #{project.default_branch} in GitHub (new tab)"
        }
      end

    Map.merge(card, %{kind: kind, link: link})
  end

  # A path is the plan's text, so a `#` or `?` in it stays part of the path rather than ending the URL's.
  defp encode(path), do: URI.encode(path, &(&1 == ?/ or URI.char_unreserved?(&1)))

  defp count_label(1, one, _many), do: "1 #{one}"
  defp count_label(count, _one, many), do: "#{count} #{many}"

  defp layout(%{kind: kind}) when kind in [:code, :signature], do: :code
  defp layout(%{kind: :table_row}), do: :table_row
  defp layout(_line), do: :text
end
