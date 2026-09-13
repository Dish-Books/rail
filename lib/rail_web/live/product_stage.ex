defmodule RailWeb.Live.ProductStage do
  @moduledoc """
  The ticket a product run wrote, and the two ways to approve it.

  The product agent's ticket lives in scratch until a human reads it, so this is
  what reads it — and the buttons only exist when there is something to show. An
  approval without the ticket in front of it would be an approval of nothing.
  """
  use RailWeb, :live_component

  import Rail.Pipeline.Utils.ParseTicket
  import RailWeb.Components.IssueIcons, only: [priority_icon: 1]
  import RailWeb.CoreComponents, only: [markdown: 1]

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task

  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign(:ticket, read_ticket(assigns.task))
      |> assign_new(:error, fn -> nil end)

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="product-stage" data-qa="product-stage" class="space-y-3">
      <div
        :if={@ticket == nil}
        id="product-ticket-pending"
        data-qa="product_ticket_pending"
        class="rounded-xl border border-slate-200 bg-slate-50 dark:border-slate-700 dark:bg-slate-800 p-4 text-xs text-slate-500 dark:text-slate-400"
      >
        The product agent has not written a ticket yet.
      </div>

      <div :if={@ticket != nil} class="space-y-3">
        <div class="flex flex-wrap items-center gap-2">
          <h3 class="mr-auto text-base font-bold text-slate-900 dark:text-slate-100">
            Proposed ticket
          </h3>

          <button
            type="button"
            id="approve-product-plan"
            data-qa="approve_product_plan"
            phx-click="approve"
            phx-target={@myself}
            class="px-4 py-2 rounded-full text-xs font-semibold inline-flex items-center gap-2 bg-blue-600 dark:bg-blue-500 text-white hover:opacity-90 cursor-pointer shadow-xs"
          >
            Approve
          </button>

          <button
            type="button"
            id="approve-product-plan-skip-design"
            data-qa="approve_product_plan_skip_design"
            phx-click="approve"
            phx-target={@myself}
            phx-value-skip_design="true"
            class="px-4 py-2 rounded-full text-xs font-semibold inline-flex items-center gap-2 border border-slate-500 dark:border-slate-400 text-slate-900 dark:text-slate-100 hover:bg-slate-50 dark:hover:bg-slate-800 cursor-pointer"
          >
            Approve and skip designs
          </button>
        </div>

        <p
          :if={@error}
          id="product-approve-error"
          data-qa="product_approve_error"
          class="text-xs text-red-600 dark:text-red-500"
        >
          {@error}
        </p>

        <div
          id="product-ticket"
          data-qa="product_ticket"
          class="rounded-xl border border-slate-200 bg-slate-50 dark:border-slate-700 dark:bg-slate-800 p-4 select-text"
        >
          <h2
            id="product-ticket-title"
            class="text-lg font-semibold text-slate-900 dark:text-slate-100"
          >
            {@ticket.title}
          </h2>

          <div
            :if={@ticket.priority || @ticket.estimate}
            class="flex items-center gap-4 mt-2 text-xs text-slate-500 dark:text-slate-400"
          >
            <span
              :if={@ticket.priority}
              id="product-ticket-priority"
              class="flex items-center gap-1.5"
            >
              <.priority_icon priority={@ticket.priority} />
              {Issue.priority_label(@ticket.priority)}
            </span>
            <span :if={@ticket.estimate} id="product-ticket-estimate">{@ticket.estimate} Points</span>
          </div>

          <.markdown content={@ticket.description} class="mt-3" />
        </div>
      </div>
    </div>
    """
  end

  @impl true
  def handle_event("approve", params, socket) do
    skip_design = Map.get(params, "skip_design") == "true"

    case Pipeline.approve_product_plan(socket.assigns.run, skip_design: skip_design) do
      {:ok, _run} ->
        send(self(), :task_changed)
        {:noreply, assign(socket, :error, nil)}

      {:error, reason} ->
        {:noreply, assign(socket, :error, message_for(reason))}
    end
  end

  defp read_ticket(%Task{scratch_path: scratch_path, issue: %{identifier: identifier}})
       when is_binary(scratch_path) and is_binary(identifier) do
    case [scratch_path, "tickets", "#{identifier}.md"] |> Path.join() |> File.read() do
      {:ok, content} -> if String.trim(content) == "", do: nil, else: parse_ticket(content)
      {:error, _unreadable} -> nil
    end
  end

  defp read_ticket(%Task{}), do: nil

  defp message_for(:already_approved), do: "This ticket has already been approved."
  defp message_for(:stage_running), do: "Something is still running on this task."
  defp message_for(:no_issue), do: "This task has no Linear issue to publish the ticket to."
  defp message_for({:invalid_stage, stage}), do: "This task is at #{Task.stage_label(stage)}, not product."
  defp message_for(reason), do: "Could not approve the ticket: #{inspect(reason)}"
end
