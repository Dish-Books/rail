defmodule RailWeb.Components.FixPlanSheet do
  @moduledoc """
  A fix round's plan laid out for approval: the changes to the ticket or the design a person asked for, called out
  first, its summary, What changes with an item per finding and comment the plan
  covers, In this plan beside it, then File-level changes numbered as on the Plan tab, and Verification. While it
  waits on approval, any line of its text takes a comment through the + beside it, as the plan's do.
  """
  use RailWeb, :html

  import RailWeb.Utils.BuildFixPlanLines

  attr :sheet, :map, required: true, doc: "what `FixPlan.build_sheet/1` made of the plan"
  attr :changed, :map, default: %{}, doc: "the ruling now of each covered finding whose ruling changed since the plan"
  attr :placed, :map, default: %{}, doc: "the reader's comments on each line with their tray numbers, by its key"
  attr :lifted, :list, default: [], doc: "the reader's comments whose line no longer reads as it did"
  attr :draft, :map, default: nil, doc: "the line the comment box is open under, with what is typed so far"
  attr :offered, :boolean, default: false, doc: "the reader can comment now"
  attr :target, :any, default: nil

  def fix_plan_sheet(assigns) do
    %{counts: counts} = assigns.sheet

    assigns =
      assigns
      |> assign(:sheet, build_fix_plan_lines(assigns.sheet))
      |> assign(:comment_attrs, Map.take(assigns, [:placed, :draft, :offered, :target]))
      |> assign(:covered, covered(counts, assigns.sheet.items))
      |> assign(:all_named, assigns.sheet.files != [])

    ~H"""
    <div
      id="fix-plan-sheet"
      data-qa="fix_plan_sheet"
      class="@container flex flex-col gap-7 wrap-anywhere"
    >
      <.changed_comments id="fix-plan-changed-comments" comments={@lifted} target={@target} />

      <div class="grid gap-6 items-start @min-[900px]:grid-cols-[minmax(0,1fr)_280px] @min-[1300px]:grid-cols-[minmax(0,1fr)_320px] @min-[1300px]:gap-8">
        <section class="min-w-0 max-w-[900px]">
          <aside
            :if={@sheet.changes}
            id="fix-plan-changes"
            data-qa="fix_plan_changes"
            class="mb-5 rounded-xl border border-amber-200 dark:border-amber-900 bg-amber-50 dark:bg-amber-950 px-4 py-3"
          >
            <h3 class="flex items-center gap-1.5 text-sm font-semibold text-amber-900 dark:text-amber-200">
              <.icon name="pi-pencil-simple-line" class="size-4" /> Changes to the plan
            </h3>
            <.lines lines={@sheet.changes_lines} {@comment_attrs} class="mt-2" />
          </aside>
          <.lines lines={@sheet.summary_lines} {@comment_attrs} />
          <div class="mt-5 mb-1">
            <.sheet_heading count={length(@sheet.items)} one="item" many="items">
              What changes
            </.sheet_heading>
          </div>
          <ol class="divide-y divide-slate-200 dark:divide-slate-800">
            <li
              :for={item <- @sheet.items}
              id={"fix-plan-item-#{item.id}"}
              data-qa="fix_plan_item"
              class="flex gap-3 py-3"
            >
              <span
                :if={item.kind == :finding}
                aria-hidden="true"
                class="mt-0.5 size-[18px] shrink-0 grid place-items-center rounded-full ring-1 ring-inset ring-slate-400 dark:ring-slate-500 text-slate-600 dark:text-slate-300"
              >
                <.icon name="pi-wrench-bold" class="size-[11px]" />
              </span>
              <span
                :if={item.kind == :comment}
                aria-hidden="true"
                class="mt-0.5 size-[18px] shrink-0 grid place-items-center rounded-full text-[10px] font-bold bg-amber-400 text-slate-900"
              >
                {item.number}
              </span>
              <div class="min-w-0 flex-1">
                <div class="flex items-center gap-1.5 min-w-0 text-[11px] text-slate-500 dark:text-slate-400">
                  <span class="shrink-0 font-semibold text-slate-600 dark:text-slate-300">
                    {label(item)}
                  </span>
                  <span :if={item.kind == :finding} class="truncate font-mono">{item.key}</span>
                  <span :if={item.kind == :comment and item.place} class="truncate font-mono">
                    {item.place}
                  </span>
                  <span
                    :if={item.kind == :finding and @changed[item.key] == :skip}
                    data-qa="fix_plan_item_changed"
                    class="ml-auto shrink-0 inline-flex items-center gap-1 font-semibold text-amber-700 dark:text-amber-300"
                  >
                    <.icon name="pi-swap" class="size-3" />Now Don't fix
                  </span>
                </div>
                <p
                  :if={item.kind == :finding}
                  class="mt-0.5 text-[14px] font-semibold text-slate-900 dark:text-slate-100 wrap-anywhere"
                >
                  {item.title}
                </p>
                <p
                  :if={item.kind == :comment}
                  class="mt-1 pl-3 border-l-2 border-slate-300 dark:border-slate-600 text-[13.5px] text-slate-600 dark:text-slate-300 whitespace-pre-wrap wrap-anywhere"
                >
                  {item.text}
                </p>
                <.lines lines={item.body_lines} {@comment_attrs} class="mt-1.5" />
                <p
                  :if={item.files != []}
                  class="mt-1 text-[11.5px] text-slate-500 dark:text-slate-400"
                >
                  {if length(item.files) == 1, do: "File", else: "Files"}
                  <span :for={{number, index} <- Enum.with_index(item.files)}>{if index > 0,
                    do: ", "}<a
                    href={"#plan-file-#{number}"}
                    class="font-mono hover:underline text-blue-600 dark:text-blue-400"
                  >{number}</a></span>
                </p>
              </div>
            </li>
          </ol>
        </section>

        <aside
          id="plan-summary"
          class="order-first @min-[900px]:order-none rounded-xl border border-slate-200 dark:border-slate-700 bg-slate-50 dark:bg-slate-800/40 p-4"
        >
          <p class="text-xs font-semibold uppercase tracking-wider text-slate-500 dark:text-slate-400">
            In this plan
          </p>
          <p data-qa="fix_plan_counts" class="mt-2 text-sm text-slate-700 dark:text-slate-200">
            <.tally count={@sheet.counts.findings} one="finding" many="findings" /> ·
            <.tally count={@sheet.counts.comments} one="comment" many="comments" /> ·
            <.tally count={@sheet.counts.files} one="file" many="files" />
          </p>
          <div class="mt-2 space-y-1 text-sm text-slate-600 dark:text-slate-300">
            <p :if={@sheet.covers_round} class="flex gap-2">
              <.icon
                name="pi-check-circle"
                class="size-4 mt-0.5 text-emerald-500 dark:text-emerald-400"
              />
              <span>{@covered} covered</span>
            </p>
            <p :if={not @sheet.covers_round} class="flex gap-2">
              <.icon name="pi-warning" class="size-4 mt-0.5 text-amber-500 dark:text-amber-300" />
              <span>{@covered} covered, before the last Send</span>
            </p>
            <p :if={@all_named} class="flex gap-2">
              <.icon
                name="pi-check-circle"
                class="size-4 mt-0.5 text-emerald-500 dark:text-emerald-400"
              />
              <span>Every file is named by an item</span>
            </p>
          </div>
        </aside>
      </div>

      <section :if={@sheet.files != []} class="min-w-0">
        <div class="mb-2">
          <.sheet_heading count={length(@sheet.files)} one="file" many="files">
            File-level changes
          </.sheet_heading>
        </div>
        <ol class="rounded-xl border border-slate-200 dark:border-slate-700 divide-y divide-slate-200 dark:divide-slate-800">
          <li
            :for={file <- @sheet.files}
            id={"plan-file-#{file.number}"}
            class="px-2 py-1 scroll-mt-4 target:bg-slate-100 dark:target:bg-slate-800/50"
          >
            <div class="flex gap-3 py-1.5">
              <span class="w-4 shrink-0 pt-0.5 font-mono text-xs tabular-nums text-slate-400 dark:text-slate-500">
                {file.number}
              </span>
              <div class="min-w-0">
                <.commentable_line line={file.path_line} doc={:fix_plan} {@comment_attrs}>
                  <code class="font-mono text-[13px] font-semibold break-all text-slate-900 dark:text-slate-100">
                    {file.path}
                  </code>
                </.commentable_line>
                <.lines lines={file.description_lines} {@comment_attrs} class="mt-0.5" />
              </div>
            </div>
          </li>
        </ol>
      </section>

      <section :if={@sheet.verification} class="min-w-0">
        <div class="mb-2">
          <.sheet_heading>Verification</.sheet_heading>
        </div>
        <.lines lines={@sheet.verification_lines} {@comment_attrs} />
      </section>
    </div>
    """
  end

  attr :lines, :list, required: true
  attr :placed, :map, required: true
  attr :draft, :map, default: nil
  attr :offered, :boolean, required: true
  attr :target, :any, required: true
  attr :class, :any, default: nil

  defp lines(assigns) do
    ~H"""
    <div :if={@lines != []} class={@class}>
      <.commentable_line
        :for={line <- @lines}
        line={line}
        layout={layout(line)}
        doc={:fix_plan}
        placed={@placed}
        draft={@draft}
        offered={@offered}
        target={@target}
      />
    </div>
    """
  end

  defp layout(%{kind: :code}), do: :code
  defp layout(%{kind: :table_row}), do: :table_row
  defp layout(_line), do: :text

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

  defp label(%{kind: :finding}), do: "Fix finding"
  defp label(%{kind: :comment, number: number, comment_kind: kind}), do: "Comment #{number} · #{kind_label(kind)}"

  defp kind_label(:diff), do: "Diff"
  defp kind_label(:screen), do: "Screen"
  defp kind_label(:finding), do: "Finding"

  # The save refuses a plan that leaves anything out, so a saved one covers all it was sent when it was saved.
  defp covered(%{findings: findings}, items) do
    numbers = for %{kind: :comment, number: number} <- items, do: number

    {first, rest} =
      [findings(findings), comments(numbers)]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" and ")
      |> String.split_at(1)

    String.upcase(first) <> rest
  end

  defp findings(0), do: nil
  defp findings(1), do: "the Fix finding"
  defp findings(2), do: "both Fix findings"
  defp findings(count), do: "all #{count} Fix findings"

  defp comments([]), do: nil
  defp comments([one]), do: "comment #{one}"
  defp comments(numbers), do: "comments #{Enum.join(Enum.drop(numbers, -1), ", ")} and #{List.last(numbers)}"
end
