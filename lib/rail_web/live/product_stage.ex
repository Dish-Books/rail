defmodule RailWeb.Live.ProductStage do
  @moduledoc """
  The ticket a product run wrote, and the two ways to approve it.

  The product agent's ticket lives in scratch until a human reads it, so this is
  what reads it — and the buttons only exist when there is something to show. An
  approval without the ticket in front of it would be an approval of nothing.
  """
  use RailWeb, :live_component

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task

  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign(:ticket, Pipeline.read_ticket(assigns.task))
      |> assign_new(:error, fn -> nil end)

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="product-stage" data-qa="product-stage" class="contents">
      <.task_layout task={@task} run={@run} title={ticket_title(@ticket, @task)}>
        <:tabs>{render_slot(@tabs)}</:tabs>

        <:meta :if={@ticket != nil and (@ticket.priority || @ticket.estimate)}>
          <span class="inline-flex items-center gap-1.5">
            <span
              :if={@ticket.priority}
              id="product-ticket-priority"
              class="inline-flex items-center gap-1.5"
            >
              <.priority_icon priority={@ticket.priority} />
              {Issue.priority_label(@ticket.priority)}
            </span>
            <span :if={@ticket.priority && @ticket.estimate}>·</span>
            <span :if={@ticket.estimate} id="product-ticket-estimate">{@ticket.estimate} Points</span>
          </span>
        </:meta>

        <:actions>
          {render_slot(@actions)}

          <button
            :if={@approvable and @ticket != nil}
            type="button"
            id="approve-product-plan-skip-design"
            data-qa="approve_product_plan_skip_design"
            phx-click="approve"
            phx-target={@myself}
            phx-value-skip_design="true"
            class="px-4 py-2 rounded-lg text-sm font-semibold border border-slate-300 dark:border-slate-600 text-slate-900 dark:text-slate-100 hover:bg-slate-50 dark:hover:bg-slate-800 cursor-pointer"
          >
            Approve and skip designs
          </button>

          <button
            :if={@approvable and @ticket != nil}
            type="button"
            id="approve-product-plan"
            data-qa="approve_product_plan"
            phx-click="approve"
            phx-target={@myself}
            class="px-4 py-2 rounded-lg text-sm font-semibold bg-blue-600 dark:bg-blue-500 text-white hover:opacity-90 cursor-pointer shadow-xs"
          >
            Approve
          </button>
        </:actions>

        <:alerts :if={@error}>
          <p
            id="product-approve-error"
            data-qa="product_approve_error"
            class="text-xs text-red-600 dark:text-red-500"
          >
            {@error}
          </p>
        </:alerts>

        <div
          :if={@ticket == nil}
          id="product-ticket-pending"
          data-qa="product_ticket_pending"
          class="max-w-3xl mx-auto text-sm text-slate-500 dark:text-slate-400"
        >
          The product agent has not written a ticket yet.
        </div>

        <div
          :if={@ticket != nil}
          id="product-ticket"
          data-qa="product_ticket"
          class="max-w-3xl mx-auto select-text"
        >
          <h2 id="product-ticket-title" class="sr-only">{@ticket.title}</h2>
          <.markdown content={@ticket.description} class="text-[15px] leading-relaxed" />
        </div>

        <:sidebar>{render_slot(@sidebar)}</:sidebar>
      </.task_layout>
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

  # The title under review is the one the agent proposed; until it writes one,
  # the issue's own title stands.
  defp ticket_title(%{title: title}, _task) when is_binary(title) and title != "", do: title
  defp ticket_title(_no_ticket, %Task{issue: %{title: title}}), do: title

  defp message_for(:stage_running), do: "Something is still running on this task."
  defp message_for({:invalid_stage, stage}), do: "This task is at #{Task.stage_label(stage)}, not product."
  defp message_for(reason), do: "Could not approve the ticket: #{inspect(reason)}"
end
