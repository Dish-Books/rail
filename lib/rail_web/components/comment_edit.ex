defmodule RailWeb.Components.CommentEdit do
  @moduledoc """
  An unsent comment's Edit button and the text it opens for editing, `RailWeb.Live.CommentBody`, drawn apart so a card
  can put the button beside its Remove. `place` tells apart the cards and trays that draw one comment at once, and the
  button hides while its comment is being edited, as long as a `group/comment` holds both.
  """
  use RailWeb, :html

  alias RailWeb.Live.CommentBody

  attr :place, :string, required: true, doc: "which card or tray draws the comment"
  attr :comment, :map, required: true
  attr :class, :any, default: nil

  def comment_edit_button(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="edit"
      phx-target={"##{id(@place, @comment)}"}
      data-qa="comment_edit"
      class={[
        "group-has-[[data-editing]]/comment:hidden inline-flex items-center gap-1 px-2 py-0.5 rounded text-[11px] font-semibold text-slate-500 dark:text-slate-400 hover:text-slate-900 dark:hover:text-slate-100 hover:bg-slate-100 dark:hover:bg-slate-800 cursor-pointer shrink-0 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-blue-500",
        @class
      ]}
    >
      <.icon name="pi-pencil-simple" class="size-3.5" />Edit
    </button>
    """
  end

  attr :place, :string, required: true, doc: "which card or tray draws the comment"
  attr :comment, :map, required: true
  attr :label, :string, required: true, doc: "what the comment is on, for the box's label"
  attr :class, :any, required: true, doc: "the text's, as its card draws it"
  attr :narrow, :boolean, default: false, doc: "puts the box's hint on a line of its own"

  def comment_body(assigns) do
    ~H"""
    <.live_component
      module={CommentBody}
      id={id(@place, @comment)}
      comment={@comment}
      label={@label}
      class={@class}
      narrow={@narrow}
    />
    """
  end

  defp id(place, %{id: id}), do: "comment-body-#{place}-#{id}"
end
