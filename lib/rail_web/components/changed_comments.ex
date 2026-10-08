defmodule RailWeb.Components.ChangedComments do
  @moduledoc """
  The reader's comments on a document whose lines no longer read as they did, at its top, each still quoting its line.
  """
  use RailWeb, :html

  attr :id, :string, required: true
  attr :comments, :list, required: true, doc: "the lifted comments with their tray numbers, in round order"
  attr :target, :any, required: true

  def changed_comments(assigns) do
    ~H"""
    <div :if={@comments != []} id={@id} data-qa="changed_comments" class="mb-6 space-y-2">
      <.document_comment
        :for={{comment, number} <- @comments}
        comment={comment}
        number={number}
        lifted
        target={@target}
      />
    </div>
    """
  end
end
