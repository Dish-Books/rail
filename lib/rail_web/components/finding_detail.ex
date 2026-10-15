defmodule RailWeb.Components.FindingDetail do
  @moduledoc """
  One finding, read whole: what is wrong, where, the fix that points the way and why, the evidence, the
  rule with every place it applies, each with its code and what the latest fix did there, the commits it
  was raised and fixed in, and its dated history, a note per pass, ruling and fix, each in its round. Fix
  and Don't fix sit in its header. Each commit on the branch opens in the Diff item at the finding's file.
  Each piece of it takes the reader's comments, under it, as a line of the plan does.
  """
  use RailWeb, :html

  alias Rail.Pipeline.Schemas.Finding
  alias Rail.Pipeline.Schemas.FindingComment
  alias Rail.Pipeline.Schemas.FindingNote
  alias Rail.Pipeline.Schemas.FindingPlace

  attr :finding, Finding, required: true
  attr :position, :integer, required: true
  attr :count, :integer, required: true
  attr :decidable, :boolean, required: true
  attr :ruling_was, :atom, default: nil, doc: "the ruling the fix plan was saved for, when it changed since"
  attr :running, :boolean, required: true
  attr :where_code, :any, default: nil, doc: "the Where's lines, as `Rail.Git.load_diff_hunks/3` reads them"
  attr :place_codes, :map, default: %{}, doc: "each code place's lines by its index, its Where place's left out"
  attr :where_place, :integer, default: nil, doc: "the index of the place whose lines are the Where's"
  attr :head, :string, default: nil, doc: "the commit the branch is on, which unchanged lines read as"
  attr :filed, :list, default: [], doc: "`%{index:, evidence:, kind:, url:}` for each attached piece"
  attr :filed_index, :integer, default: 0

  attr :labels, :map,
    default: %{},
    doc: "each commit on the branch to what made it, as Engineer or Fix round N; only these open in the Diff item"

  attr :names, :map, default: %{}, doc: "who ruled, by user id"
  attr :viewer_id, :string, default: nil
  attr :suppressor, :any, default: nil
  attr :neighbours, :map, required: true

  attr :comments, :map,
    default: %{},
    doc: "the reader's unsent comments on this finding with their tray numbers, by `{piece, index}`"

  attr :draft, :map, default: nil, doc: "`%{piece:, index:, body:}`, the piece the comment box is open under"
  attr :offered, :boolean, default: false, doc: "the reader can comment now"
  attr :target, :any, required: true

  def finding_detail(assigns) do
    # A piece keeps its place in the whole evidence list, code ranges included, which the tabs leave out.
    picked = Enum.find(assigns.filed, &(&1.index == assigns.filed_index)) || List.first(assigns.filed)

    commenting = Map.take(assigns, [:finding, :comments, :draft, :offered, :target])
    cards? = length(assigns.finding.places) > 1
    # A card tagged Where shows the Where's code, so the box above draws it only when no card does.
    where_box? = assigns.where_code != nil and (not cards? or assigns.where_place == nil)

    assigns =
      assigns
      |> assign(:picked, picked)
      |> assign(:commenting, commenting)
      |> assign(:cards?, cards?)
      |> assign(:where_box?, where_box?)
      |> assign(:outcome, calculate_outcome(assigns.finding, assigns.running))
      # A fix saved before Rail noted its commit has none to name, and is not waiting on one.
      |> assign(:show_fixed_in, assigns.finding.status != :fixed or is_binary(assigns.finding.fixed_in))

    ~H"""
    <div
      id="review-finding-detail"
      data-qa="review_finding_detail"
      class="@container flex-1 min-w-0 min-h-0 flex flex-col"
    >
      <div class="shrink-0 flex flex-wrap items-start gap-x-4 gap-y-3 px-6 py-4 border-b border-slate-200 dark:border-slate-700">
        <div class="min-w-0 flex-1 basis-[22rem]">
          <p
            id="finding-outcome"
            data-qa="finding_state"
            class={["flex items-center gap-2 text-[15px] font-semibold", @outcome.class]}
          >
            <.icon name={@outcome.icon} class="size-5" />
            <span class="min-w-0 wrap-anywhere">
              {@outcome.text}<span
                :if={@outcome.detail}
                class="font-normal text-slate-500 dark:text-slate-400"
              > · {@outcome.detail}</span>
            </span>
          </p>
          <p
            id="finding-meta"
            class="mt-1 flex flex-wrap items-center gap-x-1.5 text-xs text-slate-500 dark:text-slate-400"
          >
            <span class="inline-flex items-center gap-1">
              Raised as
              <span
                id="finding-severity"
                data-qa="finding_severity"
                class={["rounded px-1.5 py-px font-semibold", severity_tint(@finding)]}
              >
                {@finding.severity}
              </span>
            </span>
            <span aria-hidden="true">·</span>
            <span class="inline-flex items-center gap-1">
              <.icon
                name={if @finding.kind == :screen, do: "pi-browser", else: "pi-code"}
                class="size-3"
              />
              {if @finding.kind == :screen, do: "Screen", else: "Code"}
            </span>
            <span aria-hidden="true">·</span>
            <span data-qa="finding_round">{round_line(@finding)}</span>
            <span aria-hidden="true">·</span>
            <span data-qa="finding_position">{@position} of {@count}</span>
            <span :if={@ruling_was} aria-hidden="true">·</span>
            <span
              :if={@ruling_was}
              id="finding-ruling-changed"
              class="inline-flex items-center gap-1 font-semibold text-amber-700 dark:text-amber-300"
            >
              <.icon name="pi-swap" class="size-[13px]" />Ruling changed since the fix plan · was {ruling(
                @ruling_was
              )}
            </span>
          </p>
          <div data-qa="finding_title" class="group/line relative mt-2">
            <.add commenting={@commenting} piece={:title} class="-left-6 top-1" />
            <h2 class="text-lg font-bold text-slate-900 dark:text-slate-100 wrap-anywhere">
              {@finding.title}
            </h2>
          </div>
        </div>

        <div :if={@decidable and @finding.status != :fixed} class="shrink-0 flex gap-2">
          <button
            :for={{decision, label} <- decisions(@finding)}
            type="button"
            id={"decide-#{decision}-#{@finding.key}"}
            data-qa={"decide_#{decision}"}
            phx-click="decide"
            phx-target={@target}
            phx-value-key={@finding.key}
            phx-value-decision={decision}
            aria-pressed={to_string(@finding.decision == decision)}
            class={[
              "px-3.5 py-1.5 rounded-lg text-xs font-semibold cursor-pointer focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-blue-500",
              @finding.decision == decision && "bg-blue-600 dark:bg-blue-500 text-white",
              @finding.decision != decision &&
                "border border-slate-300 dark:border-slate-600 text-slate-600 dark:text-slate-400 hover:bg-slate-50 dark:hover:bg-slate-800"
            ]}
          >
            {label}
          </button>
        </div>
      </div>

      <div class="flex-1 min-h-0 overflow-y-auto px-6 py-5">
        <div class="max-w-4xl space-y-5">
          <%!-- The header does not scroll, so the title's comments open here, where any number of them fit. --%>
          <.under commenting={@commenting} piece={:title} caption="Title" qa="finding_title_comments" />
          <div
            :if={Finding.suppressed?(@finding) and @suppressor != nil}
            id="finding-suppressor"
            data-qa="finding_suppressor"
            class="rounded-lg border border-slate-200 dark:border-slate-700 bg-slate-50 dark:bg-slate-800/40 px-4 py-3"
          >
            <p class="flex items-center gap-1.5 text-[11px] font-semibold text-slate-500 dark:text-slate-400">
              <.icon name="pi-funnel-simple" class="size-3.5" />Suppressed by a calibration rule
            </p>
            <p class="mt-1.5 text-[13.5px] font-medium text-slate-900 dark:text-slate-100 wrap-anywhere">
              {@suppressor.rule}
            </p>
            <.link
              navigate={~p"/learnings/#{@suppressor.id}"}
              id="finding-open-rule"
              class="mt-2 inline-flex items-center gap-1 text-xs font-semibold text-blue-600 dark:text-blue-400 hover:underline"
            >
              Open rule<.icon name="pi-arrow-up-right" class="size-3" />
            </.link>
          </div>

          <dl class="space-y-3">
            <.field
              :if={@finding.problem}
              label="Problem"
              qa="finding_problem"
              commenting={@commenting}
              piece={:problem}
            >
              <p class="text-[13.5px] leading-relaxed text-slate-800 dark:text-slate-100 wrap-anywhere">
                {@finding.problem}
              </p>
            </.field>
            <.field
              :if={Finding.where(@finding)}
              label="Where"
              qa="finding_where"
              commenting={@commenting}
              piece={:where}
            >
              <span class={[
                "text-slate-700 dark:text-slate-200",
                @finding.kind == :code && "font-mono text-[12px] break-all",
                @finding.kind == :screen && "text-[13px] wrap-anywhere"
              ]}>
                {Finding.where(@finding)}
              </span>
              <ol
                :if={@finding.steps != []}
                class="mt-1 list-decimal pl-5 text-[13px] text-slate-700 dark:text-slate-200 space-y-0.5"
              >
                <li :for={step <- @finding.steps} class="wrap-anywhere">{step}</li>
              </ol>
            </.field>
            <.field
              :if={@finding.fix}
              label="Fix"
              qa="finding_fix"
              commenting={@commenting}
              piece={:fix}
            >
              <p class="text-[13.5px] leading-relaxed text-slate-800 dark:text-slate-100 wrap-anywhere">
                {@finding.fix}
              </p>
            </.field>
            <.field
              :if={@finding.why}
              label={if @finding.recommendation == :skip, do: "Why skip", else: "Why fix"}
              qa="finding_why"
              commenting={@commenting}
              piece={:why}
            >
              <p class="text-[13.5px] leading-relaxed text-slate-800 dark:text-slate-100 wrap-anywhere">
                {@finding.why}
              </p>
            </.field>
          </dl>

          <p
            data-qa="finding_recommendation"
            class="flex items-center gap-1.5 text-xs text-slate-500 dark:text-slate-400"
          >
            <span class={["size-1.5 rounded-full", dot(@finding)]} />
            {raised_by(@finding)} recommends {if @finding.recommendation == :skip,
              do: "Don't fix",
              else: "Fix"}
          </p>

          <div
            :if={@where_box?}
            data-qa="finding_diff"
            class="rounded-xl border border-slate-200 dark:border-slate-700 overflow-hidden"
          >
            <div class="flex flex-wrap items-center gap-x-2.5 gap-y-1 px-3.5 py-2.5 bg-slate-100 dark:bg-slate-800 border-b border-slate-200 dark:border-slate-700">
              <span class="min-w-0 break-all font-mono text-[11.5px] text-slate-700 dark:text-slate-300">
                {@where_code.display_path}
              </span>
              <.code_state excerpt={@where_code} />
              <.open_in_diff
                :if={@where_code.in_diff?}
                id="finding-open-in-diff"
                qa="finding_open_in_diff"
                commit={on_branch(@finding.raised_in, @labels)}
                file={@where_code.path}
                target={@target}
              />
            </div>
            <.finding_code excerpt={@where_code} head={@head} />
          </div>

          <div
            :if={@picked}
            id="finding-evidence"
            data-qa="finding_evidence"
            class="rounded-xl border border-slate-200 dark:border-slate-700 overflow-hidden"
          >
            <div
              role="tablist"
              class="flex items-center gap-2 px-3.5 pt-2.5 overflow-x-auto overflow-y-hidden border-b border-slate-200 dark:border-slate-700 bg-slate-50 dark:bg-slate-800/40"
            >
              <button
                :for={piece <- @filed}
                type="button"
                role="tab"
                id={"finding-evidence-#{piece.index}"}
                aria-selected={to_string(piece.index == @picked.index)}
                phx-click="select_evidence"
                phx-value-index={piece.index}
                phx-target={@target}
                class={[
                  "shrink-0 flex items-center gap-2 px-3 py-1.5 -mb-px rounded-t-lg text-[12.5px] cursor-pointer focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-blue-500",
                  piece.index == @picked.index &&
                    "border border-slate-200 dark:border-slate-700 border-b-white dark:border-b-slate-900 bg-white dark:bg-slate-900 font-semibold",
                  piece.index != @picked.index && "text-slate-500"
                ]}
              >
                <.icon name={evidence_icon(piece.kind)} class="size-3.5" />
                <span class="text-[10px] font-bold uppercase tracking-wider text-slate-500">{piece.evidence.kind}</span>
                <span class="max-w-[16rem] truncate">{piece.evidence.name}</span>
              </button>
            </div>
            <div class="p-3 bg-white dark:bg-slate-900">
              <div
                data-qa="finding_evidence_taken"
                class="mb-2 flex flex-wrap items-center gap-x-2 gap-y-1 text-[11.5px] text-slate-500 dark:text-slate-400"
              >
                <span :if={@picked.evidence.commit}>Taken on</span>
                <span :if={@picked.evidence.commit} class="font-mono text-blue-600 dark:text-blue-400">
                  {short(@picked.evidence.commit)}
                </span>
                <.local_time
                  :if={@picked.evidence.taken_at}
                  id={"finding-evidence-at-#{@picked.index}"}
                  at={@picked.evidence.taken_at}
                />
                <span :if={@picked.evidence.browser}>· {browser_label(@picked.evidence.browser)}</span>
                <a
                  :if={@picked.url}
                  href={@picked.url}
                  target="_blank"
                  rel="noopener"
                  class="ml-auto font-semibold text-blue-600 dark:text-blue-400 hover:underline"
                >
                  {if @picked.kind == :screenshot, do: "Full size", else: "Open"}
                </a>
              </div>
              <img
                :if={@picked.kind == :screenshot}
                src={@picked.url}
                alt={@picked.evidence.name}
                class="w-full rounded-lg border border-slate-200 dark:border-slate-700"
              />
              <pre
                :if={@picked.kind == :inline}
                data-qa="finding_evidence_text"
                class="max-h-96 overflow-auto rounded-lg bg-slate-50 dark:bg-slate-800/40 p-3 font-mono text-[11.5px] whitespace-pre-wrap wrap-anywhere text-slate-700 dark:text-slate-300"
              >{@picked.evidence.text}</pre>
            </div>
          </div>

          <div
            :if={@finding.rule != nil or (@finding.places != [] and not @cards?)}
            id="finding-rule"
            data-qa="finding_rule"
            class="rounded-lg border border-slate-200 dark:border-slate-700 px-4 py-3"
          >
            <p class="text-[11px] font-extrabold uppercase tracking-wider text-slate-500 dark:text-slate-400">
              Rule
            </p>
            <div :if={@finding.rule} data-qa="finding_rule_text" class="group/line relative mt-1">
              <.add commenting={@commenting} piece={:rule} class="-left-[41px] top-0" />
              <p class="text-[13.5px] font-medium text-slate-900 dark:text-slate-100 wrap-anywhere">
                {@finding.rule}
              </p>
              <.under commenting={@commenting} piece={:rule} class="mt-1.5" />
            </div>
            <p
              :if={@finding.places != [] and not @cards?}
              class="mt-3 text-[11px] font-extrabold uppercase tracking-wider text-slate-500 dark:text-slate-400"
            >
              Applies in 1 place
            </p>
            <ul :if={not @cards?} class="mt-1.5 space-y-1">
              <li
                :for={{place, n} <- Enum.with_index(@finding.places)}
                id={"finding-place-#{n + 1}"}
                data-qa="finding_place"
                class="group/line relative flex flex-wrap items-baseline gap-x-2 min-w-0"
              >
                <.add commenting={@commenting} piece={:place} index={n} class="-left-[41px] -top-0.5" />
                <.icon name="pi-map-pin" class="size-3 text-slate-400 translate-y-0.5" />
                <span class="min-w-0 flex-1">
                  <span class={[
                    "text-[11.5px] text-slate-700 dark:text-slate-200 wrap-anywhere",
                    place.file && "font-mono"
                  ]}>
                    {FindingPlace.describe(place)}
                  </span>
                  <span
                    :if={place.label}
                    class="text-[11.5px] text-slate-500 dark:text-slate-400 wrap-anywhere"
                  >
                    {place.label}
                  </span>
                  <.place_fix
                    fix={Finding.calculate_place_fix(@finding, place)}
                    reason={place.left_reason}
                  />
                </span>
                <.under
                  commenting={@commenting}
                  piece={:place}
                  index={n}
                  class="basis-full mt-1 mb-1.5"
                />
              </li>
            </ul>
          </div>

          <div :if={@cards?} id="finding-places" data-qa="finding_places" class="space-y-3">
            <p class="text-[11px] font-extrabold uppercase tracking-wider text-slate-500 dark:text-slate-400">
              Applies in {length(@finding.places)} places
            </p>
            <.place_card
              :for={{place, n} <- Enum.with_index(@finding.places)}
              place={place}
              index={n}
              excerpt={if n == @where_place, do: @where_code, else: @place_codes[n]}
              where?={n == @where_place}
              fix={Finding.calculate_place_fix(@finding, place)}
              raised_in={on_branch(@finding.raised_in, @labels)}
              head={@head}
              commenting={@commenting}
            />
          </div>

          <div data-qa="finding_commits" class="flex flex-wrap items-center gap-x-2 gap-y-1">
            <span class="text-[11.5px] font-semibold text-slate-600 dark:text-slate-300">Raised in</span>
            <.commit
              commit={@finding.raised_in}
              labels={@labels}
              file={@finding.file}
              target={@target}
              qa="finding_raised_in"
            />
            <span :if={@show_fixed_in} class="mx-1 text-slate-300 dark:text-slate-600">·</span>
            <span
              :if={@show_fixed_in}
              class="text-[11.5px] font-semibold text-slate-600 dark:text-slate-300"
            >
              Fixed in
            </span>
            <.commit
              :if={@show_fixed_in}
              commit={@finding.fixed_in}
              labels={@labels}
              file={@finding.file}
              target={@target}
              qa="finding_fixed_in"
            />
          </div>

          <div :if={@finding.notes != []}>
            <p class="text-[11px] font-extrabold uppercase tracking-wider text-slate-500 dark:text-slate-400">
              History
            </p>
            <ol data-qa="finding_history" class="mt-2 space-y-1.5">
              <li
                :for={{note, n} <- Enum.with_index(@finding.notes)}
                data-qa="finding_note"
                class="group/line relative flex flex-wrap items-baseline gap-x-2 gap-y-0.5"
              >
                <.add commenting={@commenting} piece={:note} index={n} class="-left-6 -top-0.5" />
                <span class="shrink-0 rounded px-1.5 py-px text-[10px] font-semibold bg-slate-100 dark:bg-slate-800 text-slate-600 dark:text-slate-300 ring-1 ring-inset ring-slate-200 dark:ring-slate-700">
                  {if note.kind == :fix, do: "Fix round #{note.round}", else: "Round #{note.round}"}
                </span>
                <.local_time
                  id={"finding-note-#{@finding.key}-#{n}"}
                  at={note.at}
                  class="font-mono text-[11px] text-slate-500 dark:text-slate-400"
                />
                <.note note={note} finding={@finding} names={@names} viewer_id={@viewer_id} />
                <.under
                  commenting={@commenting}
                  piece={:note}
                  index={n}
                  class="basis-full mt-1 mb-1.5"
                />
              </li>
            </ol>
          </div>
        </div>
      </div>

      <div class="shrink-0 flex items-center gap-2 px-6 py-3 border-t border-slate-200 dark:border-slate-700 text-xs">
        <button
          :for={{side, label} <- [previous: "← Previous", next: "Next finding →"]}
          type="button"
          id={"finding-#{side}"}
          data-qa={"finding_#{side}"}
          disabled={@neighbours[side] == nil}
          phx-click="select_finding"
          phx-target={@target}
          phx-value-key={@neighbours[side]}
          class="px-3 py-1.5 rounded-lg border border-slate-300 dark:border-slate-600 text-slate-600 dark:text-slate-400 hover:bg-slate-50 dark:hover:bg-slate-800 cursor-pointer disabled:opacity-40 disabled:cursor-not-allowed focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-blue-500"
        >
          {label}
        </button>
      </div>
    </div>
    """
  end

  attr :place, FindingPlace, required: true
  attr :index, :integer, required: true
  attr :excerpt, :map, default: nil
  attr :where?, :boolean, required: true
  attr :fix, :any, required: true
  attr :raised_in, :string, default: nil, doc: "the commit the Where card opens, when the branch still has it"
  attr :head, :string, default: nil
  attr :commenting, :map, required: true

  # A code place shows its lines, always open; a screen place its steps. Comments sit under the card.
  defp place_card(assigns) do
    ~H"""
    <div
      id={"finding-place-#{@index + 1}"}
      data-qa="finding_place"
      data-where={@where?}
      class="group/line relative"
    >
      <.add commenting={@commenting} piece={:place} index={@index} class="-left-[26px] top-2" />
      <div class="rounded-xl border border-slate-200 dark:border-slate-700 overflow-hidden">
        <div class="flex flex-wrap items-center gap-x-2.5 gap-y-1 px-3.5 py-2 bg-slate-100 dark:bg-slate-800 border-b border-slate-200 dark:border-slate-700">
          <span
            aria-label={"Place #{@index + 1}"}
            class="size-[18px] shrink-0 grid place-items-center rounded-md bg-slate-200 dark:bg-slate-700 text-[10px] font-bold text-slate-700 dark:text-slate-200"
          >
            {@index + 1}
          </span>
          <.icon
            :if={!@place.file}
            name="pi-browser"
            class="size-[13px] text-slate-500 dark:text-slate-400"
          />
          <span
            :if={@place.file}
            class="min-w-0 break-all font-mono text-[11.5px] text-slate-700 dark:text-slate-300"
          >
            {FindingPlace.describe(@place)}
          </span>
          <span
            :if={!@place.file}
            class="min-w-0 text-[12.5px] font-semibold text-slate-700 dark:text-slate-200 wrap-anywhere"
          >
            {@place.screen}
          </span>
          <span
            :if={@where?}
            data-qa="finding_place_where"
            class="shrink-0 rounded px-1.5 py-px text-[10px] font-semibold bg-white dark:bg-slate-900 text-slate-600 dark:text-slate-300 ring-1 ring-inset ring-slate-300 dark:ring-slate-600"
          >
            Where
          </span>
          <.code_state :if={@excerpt} excerpt={@excerpt} />
          <span
            :if={@place.label}
            class="min-w-0 text-[11.5px] text-slate-500 dark:text-slate-400 wrap-anywhere"
          >
            {@place.label}
          </span>
          <.open_in_diff
            :if={@excerpt && @excerpt.in_diff?}
            id={"finding-place-#{@index + 1}-open-in-diff"}
            qa="finding_place_open_in_diff"
            commit={if @where?, do: @raised_in}
            file={@excerpt.path}
            target={@commenting.target}
          />
        </div>
        <div
          :if={@fix}
          class="px-3.5 py-1.5 border-b border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-900"
        >
          <.place_fix fix={@fix} reason={@place.left_reason} />
        </div>
        <.finding_code :if={@excerpt} excerpt={@excerpt} head={@head} />
        <ol
          :if={!@place.file and @place.steps != []}
          class="py-2.5 pr-3.5 list-decimal pl-9 text-[13px] text-slate-700 dark:text-slate-200 space-y-0.5 bg-white dark:bg-slate-900"
        >
          <li :for={step <- @place.steps} class="wrap-anywhere">{step}</li>
        </ol>
      </div>
      <.under commenting={@commenting} piece={:place} index={@index} class="mt-1.5" />
    </div>
    """
  end

  attr :fix, :any, required: true, doc: "`Rail.Pipeline.Schemas.Finding.calculate_place_fix/2`"
  attr :reason, :string, default: nil

  # Covered and left read in the same gray: a place left on purpose is not a warning.
  defp place_fix(%{fix: nil} = assigns), do: ~H""

  defp place_fix(%{fix: {:covered, _round}} = assigns) do
    ~H"""
    <p
      data-qa="finding_place_fix"
      class="flex items-center gap-1 text-[11.5px] font-semibold text-slate-600 dark:text-slate-300"
    >
      <.icon name="pi-check-circle" class="size-[13px]" />Covered by fix round {elem(@fix, 1)}
    </p>
    """
  end

  defp place_fix(%{fix: {:left, _round}} = assigns) do
    ~H"""
    <p
      data-qa="finding_place_fix"
      class="flex items-start gap-1 text-[11.5px] text-slate-600 dark:text-slate-300 wrap-anywhere"
    >
      <.icon
        name="pi-arrow-bend-down-right"
        class="size-[13px] mt-px text-slate-500 dark:text-slate-400"
      />
      <span><span class="font-semibold">Left by fix round {elem(@fix, 1)}:</span> {@reason}</span>
    </p>
    """
  end

  attr :excerpt, :map, required: true

  # Lines the branch does not have are not unchanged, so their file's stat stands in the chip's place.
  defp code_state(%{excerpt: %{changed?: false, missing: nil}} = assigns) do
    ~H"""
    <span
      data-qa="finding_code_unchanged_chip"
      class="inline-flex items-center gap-1 shrink-0 rounded px-1.5 py-0.5 text-[10px] font-bold uppercase tracking-wider bg-slate-200 dark:bg-slate-700 text-slate-700 dark:text-slate-200"
    >
      <.icon name="pi-equals" class="size-[11px]" />Unchanged
    </span>
    """
  end

  defp code_state(assigns) do
    ~H"""
    <.diff_stat additions={@excerpt.additions} deletions={@excerpt.deletions} font_size={11} />
    """
  end

  attr :id, :string, required: true
  attr :qa, :string, required: true
  attr :commit, :string, default: nil
  attr :file, :string, required: true
  attr :target, :any, required: true

  # Only a file in the branch's diff has a section to put in front.
  defp open_in_diff(assigns) do
    ~H"""
    <button
      type="button"
      id={@id}
      data-qa={@qa}
      phx-click="open_diff"
      phx-value-commit={@commit}
      phx-value-file={@file}
      phx-target={@target}
      class="ml-auto shrink-0 inline-flex items-center gap-1 text-[11.5px] font-semibold text-blue-600 dark:text-blue-400 hover:underline cursor-pointer whitespace-nowrap focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-blue-500"
    >
      Open{if @commit, do: " #{short(@commit)}"} in Diff
      <.icon name="pi-arrow-up-right" class="size-3" />
    </button>
    """
  end

  attr :label, :string, required: true
  attr :qa, :string, required: true
  attr :commenting, :map, required: true
  attr :piece, :atom, required: true
  slot :inner_block, required: true

  defp field(assigns) do
    ~H"""
    <div data-qa={@qa} class="group/line relative flex flex-col @xl:flex-row gap-1 @xl:gap-4">
      <.add commenting={@commenting} piece={@piece} class="-left-6 top-0" />
      <dt class="w-[84px] shrink-0 pt-0.5 text-[11px] font-extrabold uppercase tracking-wider text-slate-500 dark:text-slate-400">
        {@label}
      </dt>
      <dd class="min-w-0 flex-1">
        {render_slot(@inner_block)}
        <.under commenting={@commenting} piece={@piece} class="mt-1.5" />
      </dd>
    </div>
    """
  end

  attr :commenting, :map, required: true
  attr :piece, :atom, required: true
  attr :index, :integer, default: nil
  attr :class, :string, required: true

  # A direct child of its piece's `group/line`, which app.css shows it on, by hover or by focus within.
  defp add(assigns) do
    assigns = assign(assigns, :label, piece_label(assigns))

    ~H"""
    <button
      :if={@commenting.offered and @label != nil}
      type="button"
      data-qa="finding_comment_add"
      aria-label={"Comment on #{@label}"}
      phx-click="open_finding_comment"
      phx-value-piece={@piece}
      phx-value-index={@index}
      phx-target={@commenting.target}
      class={["line-comment-add", @class]}
    >
      +
    </button>
    """
  end

  attr :commenting, :map, required: true
  attr :piece, :atom, required: true
  attr :index, :integer, default: nil
  attr :caption, :string, default: nil, doc: "names the piece, for comments drawn away from it"
  attr :qa, :string, default: "finding_piece_comments"
  attr :class, :string, default: nil

  defp under(assigns) do
    %{commenting: %{comments: comments, draft: draft}, piece: piece, index: index} = assigns

    assigns =
      assigns
      |> assign(:placed, Map.get(comments, {piece, index}, []))
      |> assign(:open, match?(%{piece: ^piece, index: ^index}, draft))
      |> assign(:label, piece_label(assigns))

    ~H"""
    <div :if={@placed != [] or @open} data-qa={@qa} class={["space-y-1.5", @class]}>
      <p
        :if={@caption}
        class="text-[11px] font-extrabold uppercase tracking-wider text-slate-500 dark:text-slate-400"
      >
        {@caption}
      </p>
      <.document_comment
        :for={{comment, number} <- @placed}
        comment={comment}
        number={number}
        remove="remove_finding_comment"
        target={@commenting.target}
      />
      <.comment_box
        :if={@open}
        id="finding-comment-form"
        body_id="finding-comment-body"
        qa="finding_comment"
        label={@label}
        body={@commenting.draft.body}
        submit="save_finding_comment"
        change="change_finding_comment"
        cancel="cancel_finding_comment"
        target={@commenting.target}
      />
    </div>
    """
  end

  attr :commit, :string, default: nil
  attr :labels, :map, required: true
  attr :file, :string, default: nil
  attr :target, :any, required: true
  attr :qa, :string, required: true

  defp commit(%{commit: nil} = assigns) do
    ~H"""
    <span data-qa={@qa} class="text-[11.5px] text-slate-500 dark:text-slate-400">not yet</span>
    """
  end

  # A commit the branch no longer has, after a rebase say, has no view to open.
  defp commit(assigns) do
    ~H"""
    <span data-qa={@qa} class="inline-flex items-center gap-1.5">
      <button
        :if={@labels[@commit]}
        type="button"
        title={"Open #{short(@commit)} in Diff"}
        data-qa="finding_commit_link"
        phx-click="open_diff"
        phx-value-commit={@commit}
        phx-value-file={@file}
        phx-target={@target}
        class="inline-flex items-center gap-1 font-mono text-[11.5px] text-blue-600 dark:text-blue-400 hover:underline cursor-pointer focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-blue-500"
      >
        <.icon name="pi-git-commit" class="size-[13px]" />{short(@commit)}
      </button>
      <span
        :if={!@labels[@commit]}
        class="inline-flex items-center gap-1 font-mono text-[11.5px] text-slate-600 dark:text-slate-300"
      >
        <.icon name="pi-git-commit" class="size-[13px]" />{short(@commit)}
      </span>
      <span :if={@labels[@commit]} class="text-[11.5px] text-slate-500 dark:text-slate-400">{@labels[
        @commit
      ]}</span>
    </span>
    """
  end

  attr :note, FindingNote, required: true
  attr :finding, Finding, required: true
  attr :names, :map, required: true
  attr :viewer_id, :string, default: nil

  defp note(%{note: %FindingNote{kind: :raised}} = assigns) do
    ~H"""
    <span class="text-[12.5px] text-slate-700 dark:text-slate-200 wrap-anywhere">
      Raised{on(@note.commit)}, from {String.downcase(raised_by(@finding))}{words(@note.text)}
    </span>
    """
  end

  defp note(%{note: %FindingNote{kind: :ruling}} = assigns) do
    ~H"""
    <span class="text-[12.5px] text-slate-700 dark:text-slate-200">
      {ruler(@note, @names, @viewer_id)} ruled {if @note.decision == :skip,
        do: "Don't fix",
        else: "Fix"}
    </span>
    """
  end

  defp note(%{note: %FindingNote{kind: :fix}} = assigns) do
    ~H"""
    <span class="text-[12.5px] text-emerald-600 dark:text-emerald-500 wrap-anywhere">
      Fixed{fixed_in(@note.commit)}{covered(@note)}; test that failed first: {@note.test}
    </span>
    """
  end

  defp note(%{note: %FindingNote{kind: :carried}} = assigns) do
    ~H"""
    <span class="text-[12.5px] text-slate-700 dark:text-slate-200">
      Carried into round {@note.round} with its Fix ruling
    </span>
    """
  end

  defp note(%{note: %FindingNote{status: :not_fixed}} = assigns) do
    ~H"""
    <span class="text-[12.5px] text-red-600 dark:text-red-400 wrap-anywhere">
      Still failing{on(@note.commit)}{words(@note.text)}
    </span>
    """
  end

  defp note(%{note: %FindingNote{status: :fixed}} = assigns) do
    ~H"""
    <span class="text-[12.5px] text-emerald-600 dark:text-emerald-500 wrap-anywhere">
      Checked fixed{on(@note.commit)}{words(@note.text)}
    </span>
    """
  end

  defp note(assigns) do
    ~H"""
    <span class="text-[12.5px] text-slate-700 dark:text-slate-200 wrap-anywhere">
      Still open{on(@note.commit)}{words(@note.text)}
    </span>
    """
  end

  defp piece_label(%{commenting: %{finding: finding}, piece: piece, index: index}) do
    case FindingComment.calculate_piece(finding, piece, index) do
      %{label: label} -> label
      nil -> nil
    end
  end

  defp ruler(%FindingNote{by_id: id}, _names, id) when is_binary(id), do: "You"
  defp ruler(%FindingNote{by_id: id}, names, _viewer_id), do: Map.get(names, id) || "Someone"

  defp on(nil), do: ""
  defp on(commit), do: " on #{short(commit)}"

  # A fix saved before Rail noted the commit it was saved on has none to name.
  defp fixed_in(nil), do: ""
  defp fixed_in(commit), do: " in #{short(commit)}"

  defp words(nil), do: ""
  defp words(text), do: ": #{text}"

  defp covered(%FindingNote{covered: covered, left: left, files: files}) do
    [
      covered != [] && "; covers #{Enum.join(covered, ", ")}",
      left != [] && "; leaves #{Enum.join(left, "; ")}",
      files != [] && "; changes #{Enum.join(files, ", ")}"
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.join()
  end

  defp short(commit), do: String.slice(commit, 0, 7)

  defp on_branch(commit, labels), do: if(is_binary(commit) and Map.has_key?(labels, commit), do: commit)

  defp round_line(%Finding{carried_round: carried, round: round}) when is_integer(carried),
    do: "Round #{round}, carried into round #{carried}"

  defp round_line(%Finding{round: round}), do: "Round #{round}"

  # The status line leads the header, so it carries the commit and round a reader would otherwise hunt for.
  defp calculate_outcome(%Finding{} = finding, running) do
    case Finding.state(finding) do
      :undecided when running ->
        outcome("Rule on it once the round finishes", nil, "pi-hourglass-bold", "text-blue-600 dark:text-blue-400")

      :undecided ->
        outcome("Needs your call", nil, "pi-hand-pointing-bold", "text-blue-600 dark:text-blue-400")

      :to_fix ->
        outcome("Fix", nil, "pi-wrench-bold", "text-slate-700 dark:text-slate-300")

      :not_fixed ->
        outcome(
          "Still failing",
          on_commit(still_failing_on(finding)),
          "pi-x-circle-fill",
          "text-red-600 dark:text-red-400"
        )

      :fixed ->
        text = if finding.fixed_in, do: "Fixed in #{short(finding.fixed_in)}", else: "Fixed"
        outcome(text, fix_round(finding), "pi-check-circle-fill", "text-emerald-700 dark:text-emerald-400")

      :dismissed ->
        outcome("Don't fix", nil, "pi-prohibit-bold", "text-slate-700 dark:text-slate-300")

      :suppressed ->
        outcome("Suppressed", nil, "pi-funnel-simple-bold", "text-slate-700 dark:text-slate-300")
    end
  end

  defp outcome(text, detail, icon, class), do: %{text: text, detail: detail, icon: icon, class: class}

  defp on_commit(nil), do: nil
  defp on_commit(commit), do: "on #{short(commit)}"

  # The commit the last pass saw it still failing on.
  defp still_failing_on(%Finding{notes: notes}) do
    notes |> Enum.reverse() |> Enum.find_value(fn %FindingNote{} = note -> note.status == :not_fixed && note.commit end)
  end

  defp fix_round(%Finding{notes: notes}) do
    case notes |> Enum.filter(&(&1.kind == :fix)) |> List.last() do
      %FindingNote{round: round} -> "Fix round #{round}"
      nil -> nil
    end
  end

  defp settled?(%Finding{} = finding), do: Finding.state(finding) in [:fixed, :dismissed, :suppressed]

  defp raised_by(%Finding{raised_by: :code_reviewer}), do: "Code reviewer"
  defp raised_by(%Finding{raised_by: :review_lead}), do: "Review lead"

  defp raised_by(%Finding{raised_by: :explorer, evidence: evidence}) do
    case Enum.find_value(evidence, & &1.browser) do
      browser when is_binary(browser) -> browser_label(browser)
      nil -> "QA explorer"
    end
  end

  # Leaving a suppressed finding alone is what the rule already did, so the only call left is Fix.
  defp decisions(%Finding{} = finding) do
    if Finding.suppressed?(finding), do: [fix: "Fix"], else: [fix: "Fix", skip: "Don't fix"]
  end

  defp evidence_icon(:screenshot), do: "pi-image"
  defp evidence_icon(:pdf), do: "pi-file-pdf"
  defp evidence_icon(:file), do: "pi-file"
  defp evidence_icon(_text), do: "pi-file-text"

  # A settled finding keeps what it was raised as for the record, without asking for attention.
  defp severity_tint(%Finding{} = finding) do
    case {settled?(finding), finding.severity} do
      {true, _severity} ->
        "bg-slate-100 text-slate-500 dark:bg-slate-800 dark:text-slate-400 ring-1 ring-inset ring-slate-200 dark:ring-slate-700"

      {false, :blocker} ->
        "bg-red-100 text-red-700 dark:bg-red-950 dark:text-red-300"

      {false, :major} ->
        "bg-amber-100 text-amber-800 dark:bg-amber-950 dark:text-amber-300"

      {false, :minor} ->
        "bg-amber-50 text-amber-700 dark:bg-amber-950/60 dark:text-amber-400"

      {false, :nit} ->
        "bg-slate-100 text-slate-600 dark:bg-slate-800 dark:text-slate-300"
    end
  end

  defp dot(%Finding{} = finding) do
    case {settled?(finding), finding.severity} do
      {true, _severity} -> "bg-slate-400 dark:bg-slate-500"
      {false, :blocker} -> "bg-red-500"
      {false, :major} -> "bg-amber-500"
      {false, :minor} -> "bg-amber-400"
      {false, :nit} -> "bg-slate-400"
    end
  end

  defp ruling(:fix), do: "Fix"
  defp ruling(:skip), do: "Don't fix"
end
