defmodule RailWeb.Components.TicketSheet do
  @moduledoc """
  A saved ticket laid out for reading: its title, its priority and estimate, then its description. Each line takes
  a comment only when offered, and the reader's comments sit under the lines they are on.
  """
  use RailWeb, :html

  attr :id, :string, required: true
  attr :ticket, :map, required: true
  attr :lines, :map, required: true, doc: "what `build_ticket_lines/1` made of the ticket"
  attr :target, :any, default: nil
  attr :placed, :map, default: %{}, doc: "the reader's comments on each line, by its key"
  attr :changed, :list, default: [], doc: "the reader's comments whose line no longer reads as it did"
  attr :draft, :map, default: nil, doc: "the line the comment box is open under"
  attr :offered, :boolean, default: false, doc: "the reader can comment now"

  def ticket_sheet(assigns) do
    ~H"""
    <div id={@id} data-qa={String.replace(@id, "-", "_")} class="max-w-3xl select-text">
      <.changed_comments id="ticket-changed-comments" comments={@changed} target={@target} />

      <.commentable_line
        line={@lines.title}
        doc={:ticket}
        placed={@placed}
        draft={@draft}
        offered={@offered}
        target={@target}
      >
        <h2
          id={"#{@id}-title"}
          class="text-xl font-bold text-slate-900 dark:text-slate-100 wrap-break-word"
        >
          {@ticket.title}
        </h2>
      </.commentable_line>

      <.commentable_line
        layout={:values}
        doc={:ticket}
        placed={@placed}
        draft={@draft}
        offered={@offered}
        target={@target}
        class="mt-1 mb-3"
      >
        <:value line={@lines.priority}>
          <.priority_icon :if={@ticket.priority} priority={@ticket.priority} />
          <span id={"#{@id}-priority"}>{@lines.priority.text}</span>
        </:value>
        <:value line={@lines.estimate}>
          <.icon name="pi-triangle" class="size-3.5 text-slate-500 dark:text-slate-400" />
          <span id={"#{@id}-estimate"}>{@lines.estimate.text}</span>
        </:value>
      </.commentable_line>

      <div id={"#{@id}-description"}>
        <.commentable_line
          :for={line <- @lines.description}
          line={line}
          layout={layout(line)}
          doc={:ticket}
          placed={@placed}
          draft={@draft}
          offered={@offered}
          target={@target}
        />
      </div>
    </div>
    """
  end

  defp layout(%{kind: :code}), do: :code
  defp layout(%{kind: :table_row}), do: :table_row
  defp layout(_line), do: :text
end
