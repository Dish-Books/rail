defmodule RailWeb.Components.FindingDetail do
  @moduledoc """
  One finding, read whole: what is wrong, where, the fix that points the way and why, the evidence, the
  rule with every place it applies, the commits it was raised and fixed in, and its dated history, a note
  per pass, ruling and fix, each in its round. Fix and Don't fix sit in its header.
  """
  use RailWeb, :html

  alias Rail.Pipeline.Schemas.Finding
  alias Rail.Pipeline.Schemas.FindingNote
  alias Rail.Pipeline.Schemas.FindingPlace

  attr :finding, Finding, required: true
  attr :position, :integer, required: true
  attr :count, :integer, required: true
  attr :decidable, :boolean, required: true
  attr :running, :boolean, required: true
  attr :hunk, :any, default: nil, doc: "the code range the finding points at, as `Rail.Git.load_diff_hunk/4` reads it"
  attr :diff_link, :string, default: nil
  attr :filed, :list, default: [], doc: "`%{index:, evidence:, kind:, url:}` for each attached piece"
  attr :filed_index, :integer, default: 0
  attr :labels, :map, default: %{}, doc: "each commit on the branch to what made it, as Engineer or Fix round N"
  attr :names, :map, default: %{}, doc: "who ruled, by user id"
  attr :viewer_id, :string, default: nil
  attr :suppressor, :any, default: nil
  attr :neighbours, :map, required: true
  attr :target, :any, required: true

  def finding_detail(assigns) do
    # A piece keeps its place in the whole evidence list, code ranges included, which the tabs leave out.
    picked = Enum.find(assigns.filed, &(&1.index == assigns.filed_index)) || List.first(assigns.filed)
    assigns = assign(assigns, :picked, picked)

    ~H"""
    <div
      id="review-finding-detail"
      data-qa="review_finding_detail"
      class="@container flex-1 min-w-0 min-h-0 flex flex-col"
    >
      <div class="shrink-0 flex flex-wrap items-start gap-x-4 gap-y-3 px-6 py-4 border-b border-slate-200 dark:border-slate-700">
        <div class="min-w-0 flex-1 basis-[22rem]">
          <div class="flex flex-wrap items-center gap-2.5">
            <span class={[
              "rounded px-2 py-0.5 text-[10px] font-extrabold uppercase tracking-wider",
              severity_chip(@finding.severity)
            ]}>
              {@finding.severity}
            </span>
            <span class="inline-flex items-center gap-1 rounded px-2 py-0.5 text-[10px] font-bold uppercase tracking-wider bg-slate-100 text-slate-600 dark:bg-slate-800 dark:text-slate-300">
              <.icon
                name={if @finding.kind == :screen, do: "pi-browser", else: "pi-code"}
                class="size-[11px]"
              />
              {if @finding.kind == :screen, do: "Screen", else: "Code"}
            </span>
            <span
              data-qa="finding_round"
              class="shrink-0 rounded px-1.5 py-px text-[10px] font-semibold bg-slate-100 dark:bg-slate-800 text-slate-600 dark:text-slate-300 ring-1 ring-inset ring-slate-200 dark:ring-slate-700"
            >
              {round_chip(@finding)}
            </span>
            <span data-qa="finding_position" class="text-xs text-slate-500 dark:text-slate-400">
              {@position} of {@count}
            </span>
            <span
              data-qa="finding_state"
              class={["inline-flex items-center gap-1 text-xs font-semibold", state_class(@finding)]}
            >
              {state_text(@finding, @running)}
            </span>
          </div>
          <h2 class="mt-2 text-lg font-bold text-slate-900 dark:text-slate-100 wrap-anywhere">
            {@finding.title}
          </h2>
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
            <.field :if={@finding.problem} label="Problem" qa="finding_problem">
              <p class="text-[13.5px] leading-relaxed text-slate-800 dark:text-slate-100 wrap-anywhere">
                {@finding.problem}
              </p>
            </.field>
            <.field :if={Finding.where(@finding)} label="Where" qa="finding_where">
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
            <.field :if={@finding.fix} label="Fix" qa="finding_fix">
              <p class="text-[13.5px] leading-relaxed text-slate-800 dark:text-slate-100 wrap-anywhere">
                {@finding.fix}
              </p>
            </.field>
            <.field
              :if={@finding.why}
              label={if @finding.recommendation == :skip, do: "Why skip", else: "Why fix"}
              qa="finding_why"
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
            <span class={["size-1.5 rounded-full", dot(@finding.severity)]} />
            {raised_by(@finding)} recommends {if @finding.recommendation == :skip,
              do: "Don't fix",
              else: "Fix"}
          </p>

          <div
            :if={@hunk}
            data-qa="finding_diff"
            class="rounded-xl border border-slate-200 dark:border-slate-700 overflow-hidden"
          >
            <div class="flex items-center gap-2.5 px-3.5 py-2.5 bg-slate-100 dark:bg-slate-800 border-b border-slate-200 dark:border-slate-700">
              <span class="min-w-0 truncate font-mono text-[11.5px] text-slate-700 dark:text-slate-300">
                {@hunk.display_path}
              </span>
              <.diff_stat additions={@hunk.additions} deletions={@hunk.deletions} font_size={11} />
              <.link
                :if={@diff_link}
                patch={@diff_link}
                id="finding-open-in-diff"
                data-qa="finding_open_in_diff"
                class="ml-auto shrink-0 inline-flex items-center gap-1 text-[11.5px] font-semibold text-blue-600 dark:text-blue-400 hover:underline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-blue-500"
              >
                Open in diff <.icon name="pi-arrow-up-right" class="size-3" />
              </.link>
            </div>
            <.diff_hunk rows={@hunk.rows} />
            <p
              :if={elided(@hunk)}
              data-qa="finding_other_hunks"
              class="px-3.5 py-2 border-t border-slate-200 dark:border-slate-700 bg-slate-50 dark:bg-slate-800/40 text-[11.5px] text-slate-500 dark:text-slate-400"
            >
              {elided(@hunk)}
            </p>
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
            :if={@finding.rule != nil or @finding.places != []}
            id="finding-rule"
            data-qa="finding_rule"
            class="rounded-lg border border-slate-200 dark:border-slate-700 px-4 py-3"
          >
            <p class="text-[11px] font-extrabold uppercase tracking-wider text-slate-500 dark:text-slate-400">
              Rule
            </p>
            <p
              :if={@finding.rule}
              class="mt-1 text-[13.5px] font-medium text-slate-900 dark:text-slate-100 wrap-anywhere"
            >
              {@finding.rule}
            </p>
            <p
              :if={@finding.places != []}
              class="mt-3 text-[11px] font-extrabold uppercase tracking-wider text-slate-500 dark:text-slate-400"
            >
              Applies in {places(@finding.places)}
            </p>
            <ul class="mt-1.5 space-y-1">
              <li
                :for={place <- @finding.places}
                data-qa="finding_place"
                class="flex items-baseline gap-2 min-w-0"
              >
                <.icon name="pi-map-pin" class="size-3 text-slate-400 translate-y-0.5" />
                <span class="min-w-0">
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
                  <span
                    :if={place.left_reason}
                    class="block text-[11.5px] text-amber-700 dark:text-amber-300 wrap-anywhere"
                  >
                    Left as it is: {place.left_reason}
                  </span>
                </span>
              </li>
            </ul>
          </div>

          <div data-qa="finding_commits" class="flex flex-wrap items-center gap-x-2 gap-y-1">
            <span class="text-[11.5px] font-semibold text-slate-600 dark:text-slate-300">Raised in</span>
            <.commit commit={@finding.raised_in} labels={@labels} qa="finding_raised_in" />
            <span class="mx-1 text-slate-300 dark:text-slate-600">·</span>
            <span class="text-[11.5px] font-semibold text-slate-600 dark:text-slate-300">Fixed in</span>
            <.commit commit={@finding.fixed_in} labels={@labels} qa="finding_fixed_in" />
          </div>

          <div :if={@finding.notes != []}>
            <p class="text-[11px] font-extrabold uppercase tracking-wider text-slate-500 dark:text-slate-400">
              History
            </p>
            <ol data-qa="finding_history" class="mt-2 space-y-1.5">
              <li
                :for={{note, n} <- Enum.with_index(@finding.notes)}
                data-qa="finding_note"
                class="flex flex-wrap items-baseline gap-x-2 gap-y-0.5"
              >
                <span class="shrink-0 rounded px-1.5 py-px text-[10px] font-semibold bg-slate-100 dark:bg-slate-800 text-slate-600 dark:text-slate-300 ring-1 ring-inset ring-slate-200 dark:ring-slate-700">
                  {if note.kind == :fix, do: "Fix round #{note.round}", else: "Round #{note.round}"}
                </span>
                <.local_time
                  id={"finding-note-#{@finding.key}-#{n}"}
                  at={note.at}
                  class="font-mono text-[11px] text-slate-500 dark:text-slate-400"
                />
                <.note note={note} finding={@finding} names={@names} viewer_id={@viewer_id} />
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

  attr :label, :string, required: true
  attr :qa, :string, required: true
  slot :inner_block, required: true

  defp field(assigns) do
    ~H"""
    <div data-qa={@qa} class="flex flex-col @xl:flex-row gap-1 @xl:gap-4">
      <dt class="w-[84px] shrink-0 pt-0.5 text-[11px] font-extrabold uppercase tracking-wider text-slate-500 dark:text-slate-400">
        {@label}
      </dt>
      <dd class="min-w-0 flex-1">{render_slot(@inner_block)}</dd>
    </div>
    """
  end

  attr :commit, :string, default: nil
  attr :labels, :map, required: true
  attr :qa, :string, required: true

  defp commit(%{commit: nil} = assigns) do
    ~H"""
    <span data-qa={@qa} class="text-[11.5px] text-slate-500 dark:text-slate-400">not yet</span>
    """
  end

  defp commit(assigns) do
    ~H"""
    <span data-qa={@qa} class="inline-flex items-center gap-1.5">
      <span class="inline-flex items-center gap-1 font-mono text-[11.5px] text-blue-600 dark:text-blue-400">
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
      Fixed in {short(@note.commit)}{covered(@note)}; test that failed first: {@note.test}
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

  defp ruler(%FindingNote{by_id: id}, _names, id) when is_binary(id), do: "You"
  defp ruler(%FindingNote{by_id: id}, names, _viewer_id), do: Map.get(names, id) || "Someone"

  defp on(nil), do: ""
  defp on(commit), do: " on #{short(commit)}"

  defp words(nil), do: ""
  defp words(text), do: ": #{text}"

  defp covered(%FindingNote{covered: covered, left: left}) do
    [covered != [] && "; covers #{Enum.join(covered, ", ")}", left != [] && "; leaves #{Enum.join(left, "; ")}"]
    |> Enum.filter(&is_binary/1)
    |> Enum.join()
  end

  defp short(commit), do: String.slice(commit, 0, 7)

  defp places([_one]), do: "1 place"
  defp places(places), do: "#{length(places)} places"

  defp round_chip(%Finding{carried_round: carried, round: round}) when is_integer(carried),
    do: "Round #{round}, carried into round #{carried}"

  defp round_chip(%Finding{round: round}), do: "Round #{round}"

  defp state_text(%Finding{} = finding, running) do
    case Finding.state(finding) do
      :undecided -> if running, do: "Rule on it once the round finishes", else: "Needs your call"
      :to_fix -> "Fix"
      :not_fixed -> "Still failing"
      :fixed -> "Fixed"
      :dismissed -> "Don't fix"
      :suppressed -> "Suppressed"
    end
  end

  defp state_class(%Finding{} = finding) do
    case Finding.state(finding) do
      :undecided -> "text-blue-600 dark:text-blue-400"
      :not_fixed -> "text-red-600 dark:text-red-400"
      :fixed -> "text-emerald-600 dark:text-emerald-500"
      _ruled -> "text-slate-500 dark:text-slate-400"
    end
  end

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

  # Only a window around the lines the finding names is shown, so the pane says what it left out.
  defp elided(%{hidden_lines: hidden, other_hunks: others}) do
    [{hidden, "line", "lines"}, {others, "other change", "other changes"}]
    |> Enum.reject(fn {count, _one, _many} -> count == 0 end)
    |> Enum.map(fn
      {1, one, _many} -> "1 more #{one}"
      {count, _one, many} -> "#{count} more #{many}"
    end)
    |> case do
      [] -> nil
      parts -> "#{Enum.join(parts, " and ")} in this file."
    end
  end

  defp severity_chip(:blocker), do: "bg-red-100 text-red-700 dark:bg-red-950 dark:text-red-300"
  defp severity_chip(:major), do: "bg-amber-100 text-amber-800 dark:bg-amber-950 dark:text-amber-300"
  defp severity_chip(:minor), do: "bg-amber-50 text-amber-700 dark:bg-amber-950/60 dark:text-amber-400"
  defp severity_chip(:nit), do: "bg-slate-100 text-slate-600 dark:bg-slate-800 dark:text-slate-300"

  defp dot(:blocker), do: "bg-red-500"
  defp dot(:major), do: "bg-amber-500"
  defp dot(:minor), do: "bg-amber-400"
  defp dot(:nit), do: "bg-slate-400"
end
