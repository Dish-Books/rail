defmodule RailWeb.Components.PlanSheet do
  @moduledoc """
  An implementation plan laid out for review: the diagrams at full width, then
  File-level changes beside Program design, with a summary that checks the two agree.
  Every line takes a comment, and the reader's comments sit under the lines they are on.
  """
  use RailWeb, :html

  @summary_icons %{
    check: {"pi-check-circle", "text-emerald-500 dark:text-emerald-400"},
    absent: {"pi-minus-circle", "text-slate-400 dark:text-slate-500"},
    warning: {"pi-warning", "text-amber-500 dark:text-amber-300"}
  }

  attr :sheet, :map, required: true, doc: "what `build_plan_sheet/1` made of the plan"
  attr :diagram_views, :map, required: true, doc: "`:diagram` or `:source` for each diagram kind"
  attr :event, :string, required: true
  attr :target, :any, default: nil
  attr :placed, :map, default: %{}, doc: "the reader's comments on each line, by its key"
  attr :changed, :list, default: [], doc: "the reader's comments whose line no longer reads as it did"
  attr :draft, :map, default: nil, doc: "the line the comment box is open under"
  attr :offered, :boolean, default: false, doc: "the reader can comment now"

  def plan_sheet(%{sheet: sheet} = assigns) do
    assigns =
      assigns
      |> assign(:file_numbers, Map.new(sheet.files, &{&1.path, &1.number}))
      |> assign(:on, %{placed: assigns.placed, draft: assigns.draft, offered: assigns.offered})

    ~H"""
    <div id="plan-sheet" data-qa="plan_sheet" class="@container flex flex-col gap-7 wrap-anywhere">
      <.changed_comments id="plan-changed-comments" comments={@changed} target={@target} />

      <div class="grid gap-6 items-start @min-[900px]:grid-cols-[minmax(0,1fr)_280px] @min-[1300px]:grid-cols-[minmax(0,1fr)_340px] @min-[1300px]:gap-8">
        <section id="plan-approach" class="min-w-0 max-w-[900px]">
          <.section_lines lines={@sheet.approach_lines} on={@on} target={@target} />
          <.commentable_line
            :if={@sheet.no_diagrams_line}
            line={@sheet.no_diagrams_line}
            doc={:plan}
            placed={@on.placed}
            draft={@on.draft}
            offered={@on.offered}
            target={@target}
            class="mt-4"
          >
            <div
              id="plan-no-diagrams"
              class="flex items-center gap-3 rounded-xl border border-dashed border-slate-300 dark:border-slate-700 px-4 py-3 text-sm text-slate-600 dark:text-slate-300"
            >
              <.icon name="pi-flow-arrow" class="size-5 text-slate-400 dark:text-slate-500" />
              {@sheet.no_diagrams}
            </div>
          </.commentable_line>
        </section>

        <aside
          id="plan-summary"
          class="order-first @min-[900px]:order-none rounded-xl border border-slate-200 dark:border-slate-700 bg-slate-50 dark:bg-slate-800/40 p-4"
        >
          <p class="text-xs font-semibold uppercase tracking-wider text-slate-500 dark:text-slate-400">
            In this plan
          </p>
          <.commentable_line
            line={@sheet.summary.tally}
            layout={:summary}
            doc={:plan}
            placed={@on.placed}
            draft={@on.draft}
            offered={@on.offered}
            target={@target}
            class="mt-2"
          >
            <p class="text-sm text-slate-700 dark:text-slate-200">
              <.tally count={length(@sheet.files)} one="file" many="files" /> ·
              <.tally count={length(@sheet.modules)} one="module" many="modules" /> ·
              <.tally count={length(@sheet.diagrams)} one="diagram" many="diagrams" />
            </p>
          </.commentable_line>
          <div class="mt-2 space-y-1 text-sm text-slate-600 dark:text-slate-300">
            <.commentable_line
              :for={summary <- @sheet.summary.lines}
              line={summary.line}
              layout={:summary}
              doc={:plan}
              placed={@on.placed}
              draft={@on.draft}
              offered={@on.offered}
              target={@target}
            >
              <.summary_icon tone={summary.tone} />
              <span>{summary.line.text}</span>
            </.commentable_line>
          </div>
        </aside>
      </div>

      <.plan_diagram
        :for={diagram <- @sheet.diagrams}
        diagram={diagram}
        view={Map.fetch!(@diagram_views, diagram.kind)}
        event={@event}
        target={@target}
        placed={@on.placed}
        draft={@on.draft}
        offered={@on.offered}
      />

      <div
        id="plan-files"
        phx-hook="PlanLinks"
        class="grid grid-cols-1 gap-8 items-start @min-[900px]:grid-cols-2"
      >
        <section class={["min-w-0", @sheet.modules == [] && "@min-[900px]:col-span-2"]}>
          <.commentable_line
            line={@sheet.files_title}
            doc={:plan}
            placed={@on.placed}
            draft={@on.draft}
            offered={@on.offered}
            target={@target}
            class="mb-2"
          >
            <.sheet_heading count={length(@sheet.files)} one="file" many="files">
              File-level changes
            </.sheet_heading>
          </.commentable_line>
          <ol class="rounded-xl border border-slate-200 dark:border-slate-700 divide-y divide-slate-200 dark:divide-slate-800">
            <li
              :for={file <- @sheet.files}
              id={"plan-file-#{file.number}"}
              data-plan-file={file.path}
              class="px-2 py-1 scroll-mt-4 data-linked:bg-slate-100 dark:data-linked:bg-slate-800/50 target:bg-slate-100 dark:target:bg-slate-800/50"
            >
              <.commentable_line
                line={file.line}
                doc={:plan}
                placed={@on.placed}
                draft={@on.draft}
                offered={@on.offered}
                target={@target}
              >
                <div class="flex gap-3 py-1.5">
                  <span class="w-4 shrink-0 pt-0.5 font-mono text-xs tabular-nums text-slate-400 dark:text-slate-500">
                    {file.number}
                  </span>
                  <div class="min-w-0">
                    <code class="font-mono text-[13px] font-semibold break-all text-slate-900 dark:text-slate-100">
                      {file.path}
                    </code>
                    <.markdown
                      :if={file.description != ""}
                      content={file.description}
                      class="mt-0.5 prose-p:my-0 prose-ul:my-1 text-slate-500 dark:text-slate-400"
                    />
                  </div>
                </div>
              </.commentable_line>
            </li>
          </ol>
        </section>

        <section :if={@sheet.modules != []} class="min-w-0">
          <.commentable_line
            line={@sheet.program_title}
            doc={:plan}
            placed={@on.placed}
            draft={@on.draft}
            offered={@on.offered}
            target={@target}
            class="mb-2"
          >
            <.sheet_heading count={length(@sheet.modules)} one="module" many="modules">
              Program design
            </.sheet_heading>
          </.commentable_line>
          <div class="space-y-3">
            <div
              :for={module <- @sheet.modules}
              data-qa="plan_module"
              data-plan-file={module.path}
              class={[
                "rounded-xl border bg-white dark:bg-slate-900 data-linked:ring-1 data-linked:ring-slate-400 dark:data-linked:ring-slate-500",
                module.listed? && "border-slate-200 dark:border-slate-700",
                not module.listed? && "border-amber-400 dark:border-amber-500/60"
              ]}
            >
              <div class="px-4 pt-2 last:pb-2">
                <.commentable_line
                  line={module.name_line}
                  doc={:plan}
                  placed={@on.placed}
                  draft={@on.draft}
                  offered={@on.offered}
                  target={@target}
                >
                  <div class="flex items-center gap-2 py-0.5">
                    <span class="min-w-0 font-mono text-[13px] font-semibold break-all text-slate-900 dark:text-slate-100">
                      {module.name}
                    </span>
                    <span
                      :if={module.new?}
                      data-qa="plan_module_new"
                      class="shrink-0 px-1.5 py-0.5 rounded text-[10px] font-semibold border border-emerald-500/60 text-emerald-700 dark:text-emerald-300"
                    >
                      new
                    </span>
                  </div>
                </.commentable_line>

                <.commentable_line
                  :if={module.path_line}
                  line={module.path_line}
                  doc={:plan}
                  placed={@on.placed}
                  draft={@on.draft}
                  offered={@on.offered}
                  target={@target}
                >
                  <div
                    :if={module.listed?}
                    class="flex items-center gap-1.5 pb-0.5 text-xs text-slate-500 dark:text-slate-400"
                  >
                    <.icon name="pi-arrow-bend-down-left" class="size-3.5" />
                    <a
                      href={"#plan-file-#{@file_numbers[module.path]}"}
                      class="min-w-0 font-mono break-all hover:underline hover:text-slate-900 dark:hover:text-slate-200"
                    >
                      {module.path}
                    </a>
                  </div>
                  <div
                    :if={not module.listed?}
                    class="flex flex-wrap items-center gap-1.5 pb-0.5 text-xs text-amber-700 dark:text-amber-300"
                  >
                    <.icon name="pi-warning" class="size-3.5" />
                    <span class="min-w-0 font-mono break-all">{module.path}</span>
                    <span>· not in File-level changes</span>
                  </div>
                </.commentable_line>

                <div
                  :if={not module.listed? and module.path == nil}
                  class="flex items-center gap-1.5 pb-0.5 text-xs text-amber-700 dark:text-amber-300"
                >
                  <.icon name="pi-warning" class="size-3.5" />
                  <span>· not in File-level changes</span>
                </div>
              </div>

              <div
                :if={module.signature_lines != []}
                data-qa="plan_module_signatures"
                class="mt-1.5 py-1.5 border-t border-slate-200 dark:border-slate-800 bg-slate-50 dark:bg-slate-950 rounded-b-xl"
              >
                <.commentable_line
                  :for={line <- module.signature_lines}
                  line={line}
                  layout={layout(line)}
                  framed={false}
                  doc={:plan}
                  placed={@on.placed}
                  draft={@on.draft}
                  offered={@on.offered}
                  target={@target}
                  class={line.kind != :signature && "px-4"}
                />
              </div>
            </div>
          </div>
        </section>
      </div>

      <div
        :if={@sheet.verification_lines || @sheet.assumptions_lines}
        class="grid grid-cols-1 gap-8 @min-[900px]:grid-cols-2"
      >
        <section :if={@sheet.verification_lines} id="plan-verification" class="min-w-0">
          <.section_lines lines={@sheet.verification_lines} on={@on} target={@target} />
        </section>
        <section :if={@sheet.assumptions_lines} id="plan-assumptions" class="min-w-0">
          <.section_lines lines={@sheet.assumptions_lines} on={@on} target={@target} />
        </section>
      </div>

      <section :for={section <- @sheet.rest} data-qa="plan_section" class="min-w-0">
        <.section_lines lines={section} on={@on} target={@target} />
      </section>
    </div>
    """
  end

  attr :lines, :map, required: true, doc: "a section's `title_line`, or `nil`, and the `lines` of its text"
  attr :on, :map, required: true
  attr :target, :any, required: true

  defp section_lines(assigns) do
    ~H"""
    <.commentable_line
      :if={@lines.title_line}
      line={@lines.title_line}
      doc={:plan}
      placed={@on.placed}
      draft={@on.draft}
      offered={@on.offered}
      target={@target}
      class="mb-2"
    >
      <.sheet_heading>{@lines.title_line.text}</.sheet_heading>
    </.commentable_line>
    <.commentable_line
      :for={line <- @lines.lines}
      line={line}
      layout={layout(line)}
      doc={:plan}
      placed={@on.placed}
      draft={@on.draft}
      offered={@on.offered}
      target={@target}
    />
    """
  end

  attr :count, :integer, default: nil
  attr :one, :string, default: nil
  attr :many, :string, default: nil
  slot :inner_block, required: true

  defp sheet_heading(assigns) do
    ~H"""
    <h3 class="flex items-center gap-2 text-[17px] font-semibold text-slate-900 dark:text-white">
      {render_slot(@inner_block)}
      <span :if={@count} class="text-sm font-normal text-slate-500 dark:text-slate-400">
        {@count} {if @count == 1, do: @one, else: @many}
      </span>
    </h3>
    """
  end

  attr :count, :integer, required: true
  attr :one, :string, required: true
  attr :many, :string, required: true

  defp tally(assigns) do
    ~H"""
    <span class="font-semibold tabular-nums text-slate-900 dark:text-white">{@count}</span>
    {if @count == 1, do: @one, else: @many}
    """
  end

  attr :tone, :atom, required: true, values: [:check, :absent, :warning]

  defp summary_icon(assigns) do
    {icon, color} = Map.fetch!(@summary_icons, assigns.tone)
    assigns = assigns |> assign(:icon, icon) |> assign(:color, color)

    ~H"""
    <.icon name={@icon} class={["size-4 mt-0.5", @color]} />
    """
  end

  defp layout(%{kind: kind}) when kind in [:code, :signature], do: :code
  defp layout(%{kind: :table_row}), do: :table_row
  defp layout(_line), do: :text
end
