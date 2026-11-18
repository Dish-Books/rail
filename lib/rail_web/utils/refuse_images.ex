defmodule RailWeb.Utils.RefuseImages do
  @moduledoc """
  Takes the pictures a text box's upload cannot take straight back out, so what stays in the box is what goes.
  """

  import Phoenix.Component, only: [upload_errors: 1, upload_errors: 2]
  import Phoenix.LiveView, only: [cancel_upload: 3]

  @doc """
  Cancels each entry of the upload `name` that is too large, not a picture or past its `max_entries`, and returns the
  socket with why in one sentence each, or `nil` when every entry was taken.
  """
  def refuse_images(socket, name) do
    upload = socket.assigns.uploads[name]

    refused =
      for {entry, index} <- Enum.with_index(upload.entries),
          reason = refusal(upload, entry, index),
          do: {entry, reason}

    socket = Enum.reduce(refused, socket, fn {entry, _reason}, acc -> cancel_upload(acc, name, entry.ref) end)
    {socket, if(refused != [], do: Enum.map_join(refused, " ", &elem(&1, 1)))}
  end

  defp refusal(upload, entry, index) do
    cond do
      index >= upload.max_entries and :too_many_files in upload_errors(upload) ->
        "Up to #{upload.max_entries} pictures go at a time, so #{entry.client_name} was not added."

      :too_large in upload_errors(upload, entry) ->
        "#{entry.client_name} is over #{div(upload.max_file_size, 1_000_000)} MB, so it was not added."

      :not_accepted in upload_errors(upload, entry) ->
        "#{entry.client_name} is not a PNG, JPEG, GIF or WebP picture."

      true ->
        nil
    end
  end
end
