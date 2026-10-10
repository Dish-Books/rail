defmodule RailWeb.Components.SplitBoard do
  @moduledoc """
  The Children tab of a split parent: a row per child in order, across Engineer to Merged, each saying
  where it stands and linking to the child and to the tab its next action opens.
  """
  use RailWeb, :html

  import RailWeb.Utils.ChildStatus

  alias Rail.Pipeline.Schemas.Task

  # Each entry is `RailWeb.Utils.ChildStatus.child_status/2` for one child, in order.
  attr :statuses, :list, required: true
  attr :parent_id, :string, required: true

  def split_board(assigns) do
    identifiers = Enum.map(assigns.statuses, & &1.identifier)
    # Longest first, so SPL-10 is not read as SPL-1 followed by a 0.
    alternatives = identifiers |> Enum.sort_by(&(-byte_size(&1))) |> Enum.map_join("|", &Regex.escape/1)

    assigns =
      assigns
      |> assign(:identifiers, identifiers)
      |> assign(:identifier_pattern, Regex.compile!("(#{alternatives})"))

    ~H"""
    <div id="split-board" data-qa="split-board">
      <%!-- Relative so the screen-reader text in each cell scrolls with the frame instead of widening the page. --%>
      <div class="relative rounded-xl border border-slate-200 dark:border-slate-700 overflow-x-auto">
        <table class="w-full min-w-[60rem] table-fixed text-left">
          <colgroup>
            <col class="w-[48px]" />
            <col />
            <col :for={_stage <- child_stages()} class="w-[112px]" />
            <col class="w-[112px]" />
            <col class="w-[16rem]" />
          </colgroup>
          <thead class="bg-slate-50 dark:bg-slate-800/40 text-[11px] uppercase tracking-wider text-slate-500 dark:text-slate-400">
            <tr>
              <th scope="col" class="pl-4 py-2 font-medium">#</th>
              <th scope="col" class="px-3 py-2 font-medium">Child</th>
              <th
                :for={stage <- child_stages()}
                scope="col"
                class="px-2 py-2 text-center font-medium"
              >
                {Task.stage_label(stage)}
              </th>
              <th scope="col" class="px-2 py-2 text-center font-medium">Merged</th>
              <th scope="col" class="px-3 py-2 font-medium">Where it stands</th>
            </tr>
          </thead>
          <tbody>
            <tr
              :for={status <- @statuses}
              id={"split-row-#{status.identifier}"}
              data-qa="split-row"
              data-state={status.state}
              class={[
                "border-t border-slate-200 dark:border-slate-800 hover:bg-slate-50 dark:hover:bg-slate-800/50",
                (status.needs_attention and status.state != :failed) &&
                  "bg-amber-50/60 dark:bg-amber-950/15"
              ]}
            >
              <td class={[
                "pl-0 pr-2 py-3 border-l-2 align-top",
                status.state == :failed && "border-l-red-500",
                (status.state != :failed and status.needs_attention) && "border-l-amber-500",
                (status.state != :failed and not status.needs_attention) && "border-l-transparent"
              ]}>
                <span class="pl-4 font-mono text-xs text-slate-400 dark:text-slate-500">
                  {status.task.split_position}
                </span>
              </td>
              <td class="px-3 py-3 min-w-0 align-top">
                <.link
                  patch={~p"/tasks/#{@parent_id}?child=#{status.identifier}"}
                  id={"split-open-#{status.identifier}"}
                  class="block min-w-0 rounded focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-blue-500"
                >
                  <span class="flex items-center gap-2 min-w-0">
                    <span class="font-mono text-xs text-slate-500 dark:text-slate-400 shrink-0">
                      {status.identifier}
                    </span>
                    <.child_badge badge={status.badge} />
                    <span class="text-[11.5px] text-slate-500 dark:text-slate-400 truncate">
                      · {if status.after == [],
                        do: "starts at once",
                        else: "after #{Enum.join(status.after, ", ")}"}
                    </span>
                  </span>
                  <span
                    data-qa="split-row-title"
                    class="mt-0.5 line-clamp-2 text-sm font-semibold leading-snug text-slate-900 dark:text-slate-100 wrap-break-word"
                    title={status.task.issue.title}
                  >
                    {status.task.issue.title}
                  </span>
                </.link>
              </td>
              <td :for={cell <- status.cells} class="px-2 py-3 text-center align-top">
                <.stage_cell mark={cell.mark} chip={cell.chip} />
              </td>
              <td class="px-2 py-3 text-center align-top">
                <.stage_cell mark={status.merged.mark} chip={status.merged.chip} />
              </td>
              <td class="px-3 py-3 align-top">
                <span class="flex items-start gap-3 min-w-0">
                  <span class="mt-0.5">
                    <.icon name={status.icon} class={["size-[15px]", status.text_class]} />
                  </span>
                  <span class="min-w-0 flex-1">
                    <span
                      data-qa="split-row-line"
                      class={[
                        "text-[13px] leading-snug line-clamp-2 wrap-break-word",
                        status.line_class
                      ]}
                      title={status.line}
                    ><span
                      :for={
                        piece <-
                          Regex.split(@identifier_pattern, status.line,
                            include_captures: true,
                            trim: true
                          )
                      }
                      class={piece in @identifiers && "whitespace-nowrap"}
                    >{piece}</span></span>
                    <span :if={status.action} class="mt-1 block">
                      <.link
                        patch={
                          ~p"/tasks/#{@parent_id}?child=#{status.identifier}&tab=#{status.action.tab}"
                        }
                        id={"split-action-#{status.identifier}"}
                        class="whitespace-nowrap text-sm font-semibold text-blue-600 dark:text-blue-400 hover:underline rounded focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-blue-500"
                      >
                        {status.action.label}
                      </.link>
                    </span>
                  </span>
                </span>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
      <p class="mt-3 text-[13px] text-slate-500 dark:text-slate-400">
        Open a child to work on it. Children run in this order; one that builds on another starts when that one merges.
      </p>
    </div>
    """
  end

  attr :mark, :atom, required: true
  attr :chip, :map, default: nil

  defp stage_cell(%{mark: :current} = assigns) do
    ~H"""
    <span class="inline-flex justify-center w-full min-w-0">
      <span
        title={@chip.label}
        class={[
          "inline-flex items-center gap-1 h-6 px-2 max-w-full rounded-full text-[11px] font-semibold",
          @chip.class
        ]}
      >
        <.icon name={@chip.icon} class="size-3" /><span class="truncate">{@chip.label}</span>
      </span>
    </span>
    """
  end

  defp stage_cell(%{mark: :done} = assigns) do
    ~H"""
    <span class="inline-flex justify-center w-full" title="Done">
      <.icon name="pi-check-bold" class="size-[13px] text-emerald-500 dark:text-emerald-400" />
      <span class="sr-only">Done</span>
    </span>
    """
  end

  defp stage_cell(assigns) do
    ~H"""
    <span class="inline-flex justify-center w-full">
      <span class="block size-1.5 rounded-full bg-slate-300 dark:bg-slate-700" aria-hidden="true" />
    </span>
    """
  end

  attr :badge, :any, required: true

  defp child_badge(assigns) do
    ~H"""
    <span
      :if={is_integer(@badge)}
      data-qa="split-row-badge"
      aria-label={"#{@badge} waiting on you"}
      class="inline-flex items-center justify-center min-w-[1.25rem] h-5 px-1.5 rounded-full text-[11px] font-semibold bg-amber-100 dark:bg-amber-950 text-amber-900 dark:text-amber-200"
    >
      {@badge}
    </span>
    <span
      :if={@badge == :dot}
      data-qa="split-row-badge"
      aria-label="Waiting on you"
      class="size-2 shrink-0 rounded-full bg-amber-500"
    />
    """
  end
end
