defmodule RailWeb.Components.TriageQueue do
  @moduledoc """
  The left pane of the triage page: the threads in one status, newest first,
  and the channels triage reads.
  """
  use RailWeb, :html

  alias Rail.Triage.Schemas.Item
  alias Rail.Triage.Schemas.Thread
  alias RailWeb.Components.TriageVerdict

  attr :threads, :list, required: true
  attr :counts, :map, required: true
  attr :filter, :atom, required: true
  attr :selected_id, :string, default: nil
  attr :channel_names, :list, required: true
  attr :now, DateTime, required: true

  def triage_queue(assigns) do
    assigns =
      assigns
      |> assign(:rows, Enum.map(assigns.threads, &row(&1, assigns.now)))
      |> assign(:channels_line, Enum.map_join(assigns.channel_names, " · ", &"##{&1}"))
      |> assign(:empty_message, empty_message(assigns.filter))

    ~H"""
    <aside
      id="triage-queue"
      data-qa="triage-queue"
      class="w-[330px] shrink-0 flex flex-col border-r border-slate-200 dark:border-slate-700 bg-slate-50 dark:bg-slate-800/30"
    >
      <div class="px-4 pt-4 pb-3 space-y-3 border-b border-slate-200 dark:border-slate-700">
        <.segmented_control
          id="triage-filter"
          options={[
            waiting: "Waiting · #{@counts.waiting}",
            triaging: "Triaging · #{@counts.triaging}",
            done: "Done · #{@counts.done}"
          ]}
          selected={@filter}
          event="filter"
          value_name="filter"
          class="whitespace-nowrap"
        />
        <p
          :if={@channel_names != []}
          id="triage-channels"
          class="text-[11px] text-slate-500 dark:text-slate-400 font-mono"
        >
          {@channels_line}
        </p>
      </div>

      <div class="flex-1 overflow-y-auto p-2 space-y-1">
        <div
          :if={@rows == []}
          id="triage-queue-empty"
          class="m-2 rounded-xl border border-dashed border-slate-300 dark:border-slate-700 px-5 py-10 text-center"
        >
          <.icon name="pi-chat-circle-text-fill" class="size-10 text-slate-400 dark:text-slate-500" />
          <p class="mt-2 text-sm font-semibold text-slate-700 dark:text-slate-300">
            {@empty_message}
          </p>
          <p :if={@channel_names != []} class="mt-1 text-xs text-slate-500 dark:text-slate-400">
            {@channels_line} {if length(@channel_names) == 1, do: "is", else: "are"} connected.
          </p>
          <p :if={@channel_names == []} class="mt-1 text-xs text-slate-500 dark:text-slate-400">
            No Slack channels are connected. An admin picks them in Settings, Projects.
          </p>
          <p
            :if={@filter == :waiting}
            class="mt-4 flex justify-center gap-2 text-[11.5px] text-slate-500 dark:text-slate-400"
          >
            <.icon name="pi-minus-circle" class="size-3.5 mt-px" />Messages that needed no response go straight to Done.
          </p>
        </div>

        <.link
          :for={row <- @rows}
          patch={~p"/triage/#{row.thread.id}?#{[filter: @filter]}"}
          id={"triage-row-#{row.thread.id}"}
          data-qa="triage-row"
          aria-current={if row.thread.id == @selected_id, do: "true"}
          class={[
            "block rounded-xl px-3 py-2.5",
            row.thread.id == @selected_id && "bg-white dark:bg-slate-800 ring-1 ring-blue-500",
            row.thread.id != @selected_id && "hover:bg-slate-100 dark:hover:bg-slate-800/70"
          ]}
        >
          <span class="flex items-center gap-2 text-[11px] text-slate-500 dark:text-slate-400">
            <span class="font-mono whitespace-nowrap shrink-0">#{row.thread.slack_channel.name}</span>
            <span class="truncate">{row.author}</span>
            <span class="ml-auto shrink-0 whitespace-nowrap font-mono">{row.age}</span>
          </span>
          <span class={[
            "mt-1 block text-[13px] leading-snug line-clamp-2",
            row.thread.id == @selected_id && "font-semibold text-slate-900 dark:text-slate-100",
            row.thread.id != @selected_id && "font-medium text-slate-800 dark:text-slate-200"
          ]}>
            {Thread.title_or_preview(row.thread)}
          </span>
          <span class="mt-1.5 flex items-center gap-1.5 text-[11px]">
            <span
              :if={row.no_response}
              class="inline-flex items-center gap-1 px-1.5 py-0.5 rounded border border-slate-300 dark:border-slate-600 text-slate-600 dark:text-slate-300"
            >
              <.icon name="pi-minus-circle" class="size-3" />Needed no response
            </span>
            <span
              :for={{kind, label} <- row.kind_chips}
              class={[
                "whitespace-nowrap inline-flex items-center gap-1 px-1.5 py-0.5 rounded font-semibold",
                TriageVerdict.kind_style(kind).class
              ]}
            >
              <.icon name={TriageVerdict.kind_style(kind).icon} class="size-3" />{label}
            </span>
            <span :if={row.verdict} class="whitespace-nowrap text-slate-500 dark:text-slate-400">{row.verdict}</span>
            <span :if={row.created} class="font-mono text-blue-600 dark:text-blue-400">{row.created}</span>
            <span :if={row.error} class="whitespace-nowrap text-red-600 dark:text-red-400">Triage failed</span>
            <span
              :if={row.to_accept > 0 and @filter != :done}
              class="ml-auto whitespace-nowrap font-semibold text-amber-600 dark:text-amber-400"
            >
              {row.to_accept} to accept
            </span>
            <span
              :if={@filter == :done}
              class="ml-auto whitespace-nowrap text-slate-500 dark:text-slate-400"
            >
              {row.outcome}
            </span>
          </span>
        </.link>
      </div>
    </aside>
    """
  end

  defp row(%Thread{} = thread, now) do
    counts = Thread.kind_counts(thread)

    %{
      thread: thread,
      author: thread.messages |> List.first() |> then(&(&1 && &1.author_name)),
      age: format_age(DateTime.diff(now, thread.last_message_at || thread.inserted_at)),
      no_response: thread.items == [] and is_binary(thread.no_response_reason),
      kind_chips:
        Enum.reject(
          [
            {:bug, plural(counts.bug, "bug", "bugs")},
            {:feature_request, plural(counts.feature_request, "request", "requests")}
          ],
          fn {kind, _label} -> Map.fetch!(counts, kind) == 0 end
        ),
      verdict: single_verdict(thread.items),
      created: Enum.find_value(thread.items, &(&1.created_issue && &1.created_issue.identifier)),
      error: is_binary(thread.error),
      to_accept: Thread.to_accept_count(thread),
      outcome: outcome(thread)
    }
  end

  defp single_verdict([%Item{verdict: verdict}]), do: Item.verdict_label(verdict)
  defp single_verdict(_items), do: nil

  # A thread that needed nothing says why, where a finished one says who finished it.
  defp outcome(%Thread{items: [], dismissed_by: nil, no_response_reason: reason}) when is_binary(reason), do: reason
  defp outcome(%Thread{} = thread), do: Thread.outcome_label(thread)

  defp plural(1, one, _many), do: "1 #{one}"
  defp plural(count, _one, many), do: "#{count} #{many}"

  defp empty_message(:waiting), do: "Nothing is waiting on you."
  defp empty_message(:triaging), do: "Nothing is being triaged."
  defp empty_message(:done), do: "Nothing has finished yet."
end
