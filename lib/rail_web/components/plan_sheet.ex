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

  attr :sheet, :map, required: true, doc: "what `build_plan_sheet/2` made of the plan"
  attr :criteria, :list, default: [], doc: "the ticket's acceptance criteria, each `%{number:, html:}`"
  attr :part, :integer, default: nil, doc: "the split child's number, when the plan is a child's part"
  attr :target, :any, default: nil
  attr :placed, :map, default: %{}, doc: "the reader's comments on each line, by its key"
  attr :changed, :list, default: [], doc: "the reader's comments whose line no longer reads as it did"
  attr :draft, :map, default: nil, doc: "the line the comment box is open under"
  attr :offered, :boolean, default: false, doc: "the reader can comment now"

  attr :reviewed, :map,
    default: nil,
    doc: "the reader's marks, each card's path to the digest it had when marked; without them no card takes one"

  attr :default_paths, :any,
    default: nil,
    doc: "the cards' paths on the default branch, or nil when the clone could not say"

  attr :project, :any,
    default: nil,
    doc: "whose GitHub repository and default branch a path links to, with `default_paths`"

  def plan_sheet(assigns) do
    assigns =
      assigns
      |> assign(:base, if(assigns.part, do: "plan-#{assigns.part}", else: "plan"))
      |> assign(:on, %{placed: assigns.placed, draft: assigns.draft, offered: assigns.offered, doc: :plan})
      |> assign(:rows, rows(assigns.sheet.criteria, assigns.criteria))
      |> assign(:columns, @columns)

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

      <.plan_cards
        id="plan-changes"
        base={@base}
        title_line={@sheet.changes_title}
        groups={@sheet.groups}
        cards={@sheet.cards}
        reviewed={@reviewed}
        default_paths={@default_paths}
        project={@project}
        on={@on}
        target={@target}
      >
        <:heading :let={subtitle}>
          <.heading title="Changes" subtitle={subtitle} />
        </:heading>
      </.plan_cards>

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

  defp layout(%{kind: kind}) when kind in [:code, :signature], do: :code
  defp layout(%{kind: :table_row}), do: :table_row
  defp layout(_line), do: :text
end
