defmodule RailWeb.Components.TestingQueue do
  @moduledoc """
  The left pane of the testing page: every ticket in Done still waiting for testing or in it, oldest Done first.
  """
  use RailWeb, :html

  attr :issues, :list, required: true
  attr :selected_id, :string, default: nil
  attr :now, DateTime, required: true

  def testing_queue(assigns) do
    assigns =
      assigns
      |> assign(:waiting_count, Enum.count(assigns.issues, &(&1.testing_state == :waiting)))
      |> assign(:testing_count, Enum.count(assigns.issues, &(&1.testing_state == :testing)))
      |> assign(:rows, Enum.map(assigns.issues, &%{issue: &1, age: done_age(&1, assigns.now)}))

    ~H"""
    <aside
      id="testing-queue"
      data-qa="testing-queue"
      class="w-[340px] shrink-0 flex flex-col border-r border-slate-200 dark:border-slate-700 bg-slate-50 dark:bg-slate-800/30"
    >
      <div class="px-4 pt-4 pb-3 border-b border-slate-200 dark:border-slate-700 flex items-center gap-3">
        <span id="testing-queue-count" class="text-sm font-bold text-slate-900 dark:text-slate-100">
          {length(@issues)} to test
        </span>
        <span id="testing-queue-split" class="text-xs text-slate-500 dark:text-slate-400">
          {@waiting_count} waiting · {@testing_count} in testing
        </span>
        <span class="ml-auto text-[11px] text-slate-500 dark:text-slate-400">Oldest first</span>
      </div>

      <div class="flex-1 overflow-y-auto p-2 space-y-1">
        <div
          :if={@rows == []}
          id="testing-queue-empty"
          class="m-2 rounded-xl border border-dashed border-slate-300 dark:border-slate-700 px-5 py-10 text-center"
        >
          <.icon name="pi-test-tube-fill" class="size-10 text-slate-400 dark:text-slate-500" />
          <p class="mt-2 text-sm font-semibold text-slate-700 dark:text-slate-300">
            Nothing is waiting for testing.
          </p>
          <p class="mt-1 text-xs text-slate-500 dark:text-slate-400">
            A ticket joins this queue when it moves to Done.
          </p>
        </div>

        <.link
          :for={row <- @rows}
          patch={~p"/testing/#{row.issue.id}"}
          id={"testing-row-#{row.issue.id}"}
          data-qa="testing-row"
          aria-current={if row.issue.id == @selected_id, do: "true"}
          class={[
            "block rounded-xl px-3 py-2.5 focus-visible:outline-2 focus-visible:outline-blue-500",
            row.issue.id == @selected_id && "bg-white dark:bg-slate-800 ring-1 ring-blue-500",
            row.issue.id != @selected_id && "hover:bg-slate-100 dark:hover:bg-slate-800/70"
          ]}
        >
          <span class="flex items-center gap-2 text-[11px] text-slate-500 dark:text-slate-400">
            <span class="font-mono whitespace-nowrap">{row.issue.identifier}</span>
            <span class="truncate">{row.issue.project.name}</span>
            <span :if={row.age} class="ml-auto shrink-0 font-mono whitespace-nowrap">{row.age}</span>
          </span>
          <span class={[
            "mt-1 block text-[13px] leading-snug line-clamp-2 break-words",
            row.issue.id == @selected_id && "font-semibold text-slate-900 dark:text-slate-100",
            row.issue.id != @selected_id && "font-medium text-slate-800 dark:text-slate-200"
          ]}>
            {row.issue.title}
          </span>
          <span class="mt-1.5 flex items-center gap-2">
            <.testing_badge state={row.issue.testing_state} />
          </span>
        </.link>
      </div>
    </aside>
    """
  end

  # A tracker can report Done with no completed time, and then there is no age to show.
  defp done_age(%{completed_at: %DateTime{} = at}, now), do: "Done #{format_age(DateTime.diff(now, at))} ago"
  defp done_age(_issue, _now), do: nil
end
