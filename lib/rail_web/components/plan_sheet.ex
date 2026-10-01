defmodule RailWeb.Components.PlanSheet do
  @moduledoc """
  An implementation plan laid out for review: the diagrams at full width, then
  File-level changes beside Program design, with a summary that checks the two agree.
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

  def plan_sheet(%{sheet: sheet} = assigns) do
    unlisted = Enum.count(sheet.modules, &(not &1.listed?))

    assigns =
      assigns
      |> assign(:unlisted, unlisted)
      |> assign(
        :unlisted_line,
        if(unlisted == 1, do: "1 module in Program design is", else: "#{unlisted} modules in Program design are")
      )
      |> assign(:both_diagrams?, [:call_flow, :change] -- Enum.map(sheet.diagrams, & &1.kind) == [])
      |> assign(:file_numbers, Map.new(sheet.files, &{&1.path, &1.number}))

    ~H"""
    <div id="plan-sheet" data-qa="plan_sheet" class="@container flex flex-col gap-7 wrap-anywhere">
      <div class="grid gap-6 items-start @min-[900px]:grid-cols-[minmax(0,1fr)_280px] @min-[1300px]:grid-cols-[minmax(0,1fr)_340px] @min-[1300px]:gap-8">
        <section id="plan-approach" class="min-w-0 max-w-[900px]">
          <.sheet_heading>Approach</.sheet_heading>
          <.markdown
            content={@sheet.approach}
            class="text-[15px] leading-relaxed [&>:first-child]:mt-0"
          />
        </section>

        <aside
          id="plan-summary"
          class="order-first @min-[900px]:order-none rounded-xl border border-slate-200 dark:border-slate-700 bg-slate-50 dark:bg-slate-800/40 p-4"
        >
          <p class="text-xs font-semibold uppercase tracking-wider text-slate-500 dark:text-slate-400">
            In this plan
          </p>
          <p class="mt-2 text-sm text-slate-700 dark:text-slate-200">
            <.tally count={length(@sheet.files)} one="file" many="files" /> ·
            <.tally count={length(@sheet.modules)} one="module" many="modules" /> ·
            <.tally count={length(@sheet.diagrams)} one="diagram" many="diagrams" />
          </p>
          <ul class="mt-3 space-y-1.5 text-sm text-slate-600 dark:text-slate-300">
            <.summary_line :if={@both_diagrams?} tone={:check}>
              Change diagram and call flow
            </.summary_line>
            <.summary_line :if={@sheet.no_diagrams} tone={:absent}>
              No diagrams, as the plan explains
            </.summary_line>
            <.summary_line :if={@sheet.modules != [] and @unlisted == 0} tone={:check}>
              Every module in Program design is in File-level changes
            </.summary_line>
            <.summary_line :if={@unlisted > 0} tone={:warning}>
              {@unlisted_line} not in File-level changes
            </.summary_line>
            <.summary_line :if={@sheet.modules == []} tone={:absent}>
              No program design: no application code changes
            </.summary_line>
          </ul>
        </aside>
      </div>

      <.plan_diagram
        :for={diagram <- @sheet.diagrams}
        diagram={diagram}
        view={Map.fetch!(@diagram_views, diagram.kind)}
        event={@event}
        target={@target}
      />

      <div
        :if={@sheet.no_diagrams}
        id="plan-no-diagrams"
        class="flex items-center gap-3 rounded-xl border border-dashed border-slate-300 dark:border-slate-700 px-4 py-3 text-sm text-slate-600 dark:text-slate-300"
      >
        <.icon name="pi-flow-arrow" class="size-5 text-slate-400 dark:text-slate-500" />
        {@sheet.no_diagrams}
      </div>

      <div
        id="plan-files"
        phx-hook="PlanLinks"
        class="grid grid-cols-1 gap-8 items-start @min-[900px]:grid-cols-2"
      >
        <section class={["min-w-0", @sheet.modules == [] && "@min-[900px]:col-span-2"]}>
          <.sheet_heading count={length(@sheet.files)} one="file" many="files">
            File-level changes
          </.sheet_heading>
          <ol class="rounded-xl border border-slate-200 dark:border-slate-700 divide-y divide-slate-200 dark:divide-slate-800 overflow-hidden">
            <li
              :for={file <- @sheet.files}
              id={"plan-file-#{file.number}"}
              data-plan-file={file.path}
              class="flex gap-3 px-4 py-3 scroll-mt-4 data-linked:bg-slate-100 dark:data-linked:bg-slate-800/50 target:bg-slate-100 dark:target:bg-slate-800/50"
            >
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
            </li>
          </ol>
        </section>

        <section :if={@sheet.modules != []} class="min-w-0">
          <.sheet_heading count={length(@sheet.modules)} one="module" many="modules">
            Program design
          </.sheet_heading>
          <div class="space-y-3">
            <div
              :for={module <- @sheet.modules}
              data-qa="plan_module"
              data-plan-file={module.path}
              class={[
                "rounded-xl border bg-white dark:bg-slate-900 overflow-hidden data-linked:ring-1 data-linked:ring-slate-400 dark:data-linked:ring-slate-500",
                module.listed? && "border-slate-200 dark:border-slate-700",
                not module.listed? && "border-amber-400 dark:border-amber-500/60"
              ]}
            >
              <div class="flex items-center gap-2 px-4 pt-3">
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

              <div
                :if={module.listed?}
                class="flex items-center gap-1.5 px-4 pt-1 last:pb-3 text-xs text-slate-500 dark:text-slate-400"
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
                class="flex flex-wrap items-center gap-1.5 px-4 pt-1 last:pb-3 text-xs text-amber-700 dark:text-amber-300"
              >
                <.icon name="pi-warning" class="size-3.5" />
                <span :if={module.path} class="min-w-0 font-mono break-all">{module.path}</span>
                <span>· not in File-level changes</span>
              </div>

              <.markdown
                :if={module.signatures != ""}
                content={module.signatures}
                class="mt-2.5 prose-p:px-4 prose-p:my-2 prose-pre:m-0 prose-pre:rounded-none prose-pre:border-t prose-pre:border-slate-200 dark:prose-pre:border-slate-800 prose-pre:text-[12.5px]"
              />
            </div>
          </div>
        </section>
      </div>

      <div
        :if={@sheet.verification || @sheet.assumptions}
        class="grid grid-cols-1 gap-8 @min-[900px]:grid-cols-2"
      >
        <section :if={@sheet.verification} id="plan-verification" class="min-w-0">
          <.sheet_heading>Verification</.sheet_heading>
          <.markdown
            content={@sheet.verification}
            class="text-[15px] leading-relaxed [&>:first-child]:mt-0"
          />
        </section>
        <section :if={@sheet.assumptions} id="plan-assumptions" class="min-w-0">
          <.sheet_heading>Assumptions</.sheet_heading>
          <.markdown
            content={@sheet.assumptions}
            class="text-[15px] leading-relaxed [&>:first-child]:mt-0"
          />
        </section>
      </div>

      <section :for={section <- @sheet.rest} data-qa="plan_section" class="min-w-0">
        <.sheet_heading :if={section.title}>{section.title}</.sheet_heading>
        <.markdown content={section.body} class="text-[15px] leading-relaxed [&>:first-child]:mt-0" />
      </section>
    </div>
    """
  end

  attr :count, :integer, default: nil
  attr :one, :string, default: nil
  attr :many, :string, default: nil
  slot :inner_block, required: true

  defp sheet_heading(assigns) do
    ~H"""
    <h3 class="flex items-center gap-2 mb-3 text-[17px] font-semibold text-slate-900 dark:text-white">
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
  slot :inner_block, required: true

  defp summary_line(assigns) do
    {icon, color} = Map.fetch!(@summary_icons, assigns.tone)
    assigns = assigns |> assign(:icon, icon) |> assign(:color, color)

    ~H"""
    <li class="flex items-start gap-2">
      <.icon name={@icon} class={["size-4 mt-0.5", @color]} />
      <span>{render_slot(@inner_block)}</span>
    </li>
    """
  end
end
