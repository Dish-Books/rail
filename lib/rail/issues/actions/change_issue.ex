defmodule Rail.Issues.Actions.ChangeIssue do
  @moduledoc """
  A person's change to a ticket as an MCP tool takes it: names and identifiers rather than ids. Every field is resolved
  and checked before any is written, then each group is written through the action the issue page uses.
  """

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Scope
  alias Rail.Users

  @edit_fields [:title, :description, :priority, :estimate, :parent]
  @tracker_fields [:status, :assignee]

  @doc """
  Changes any of `:title`, `:description`, `:priority`, `:estimate`, `:parent` (an identifier, or `""` for none),
  `:status` (a status name), `:cycle` (`"current"`, `"next"`, a number or `"none"`), `:assignee` (a GitHub login, `"me"`,
  or `""` for none) and `:blocked_by` (identifiers), counting only the keys `attrs` holds.

  Returns the ticket as it now reads. A ticket another tracker holds takes only a status and an assignee, and anything
  else is `{:error, {:edited_in_tracker, tracker, fields}}` with nothing written. A field that does not resolve is
  `{:error, {:invalid, field, message}}` or the changeset's error, with nothing written. A write that fails after others
  is `{:error, {:partly_saved, saved_fields, failed_fields, reason}}`, and the first to fail is its own error.
  """
  def change_issue(%Scope{} = scope, %Issue{id: id, project_id: project_id}, %{} = attrs) do
    with {:ok, %Issue{project_id: ^project_id} = issue} <- Issues.get_issue(id),
         true <- Scope.can_access_project?(scope, project_id) || {:error, :not_found},
         :ok <- check_tracker(issue, attrs),
         {:ok, steps} <- resolve(scope, issue, attrs) do
      steps
      |> Enum.reduce_while({:ok, issue, []}, fn {fields, write}, {:ok, issue, saved} ->
        case write.(issue) do
          {:ok, issue} -> {:cont, {:ok, issue, saved ++ fields}}
          {:error, reason} when saved == [] -> {:halt, {:error, reason}}
          {:error, reason} -> {:halt, {:error, {:partly_saved, saved, fields, reason}}}
        end
      end)
      |> case do
        {:ok, _issue, _saved} -> Issues.get_issue(id)
        {:error, reason} -> {:error, reason}
      end
    else
      {:ok, %Issue{}} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp check_tracker(%Issue{tracker: :local}, _attrs), do: :ok

  defp check_tracker(%Issue{tracker: tracker}, attrs) do
    case attrs |> Map.keys() |> Enum.reject(&(&1 in @tracker_fields)) |> Enum.sort() do
      [] -> :ok
      fields -> {:error, {:edited_in_tracker, tracker, fields}}
    end
  end

  # Each step is the fields it writes and the write; resolving every one first is what keeps a bad field from leaving
  # the ones before it saved.
  defp resolve(scope, issue, attrs) do
    with {:ok, edit} <- resolve_edit(scope, issue, Map.take(attrs, @edit_fields)),
         {:ok, status} <- resolve_status(scope, issue, attrs),
         {:ok, cycle} <- resolve_cycle(issue, attrs),
         {:ok, owner} <- resolve_assignee(scope, issue, attrs),
         {:ok, blockers} <- resolve_blockers(scope, issue, attrs) do
      steps =
        Enum.reject(
          [
            edit && {edit_fields(attrs), &Issues.edit_issue(scope, &1, edit)},
            status && {[:status], &Issues.set_issue_status(scope, &1, status)},
            cycle && {[:cycle], &Issues.set_issue_cycle(scope, &1, elem(cycle, 1))},
            owner && {[:assignee], &Issues.assign_issue(scope, &1, elem(owner, 1))},
            blockers && {[:blocked_by], &Issues.set_blockers(scope, &1, blockers)}
          ],
          &is_nil/1
        )

      {:ok, steps}
    end
  end

  defp edit_fields(attrs), do: Enum.filter(@edit_fields, &Map.has_key?(attrs, &1))

  defp resolve_edit(_scope, _issue, edit) when map_size(edit) == 0, do: {:ok, nil}

  defp resolve_edit(scope, issue, edit) do
    text = for {field, value} <- Map.delete(edit, :parent), into: %{}, do: {Atom.to_string(field), value}

    with {:ok, text} <- check_edit(issue, text),
         {:ok, parent} <- resolve_parent(scope, issue, edit) do
      {:ok, Map.merge(text, parent)}
    end
  end

  defp check_edit(issue, text) do
    case Issue.edit_changeset(issue, text) do
      %Ecto.Changeset{valid?: true} -> {:ok, text}
      changeset -> {:error, changeset}
    end
  end

  defp resolve_parent(_scope, _issue, edit) when not is_map_key(edit, :parent), do: {:ok, %{}}

  defp resolve_parent(scope, %Issue{id: id, project_id: project_id}, %{parent: identifier}) do
    case blank?(identifier) || Issues.find_issue(scope, identifier) do
      true -> {:ok, %{"parent_id" => ""}}
      {:ok, %Issue{id: ^id}} -> {:error, {:invalid, :parent, "can't be the ticket itself"}}
      {:ok, %Issue{id: parent_id, project_id: ^project_id}} -> {:ok, %{"parent_id" => parent_id}}
      _elsewhere -> {:error, {:invalid, :parent, "#{identifier} is not a ticket in this project"}}
    end
  end

  defp resolve_status(scope, %Issue{project: project}, %{status: name}) when is_binary(name) do
    with {:ok, statuses} <- Issues.get_statuses(scope, project) do
      case Enum.find(statuses, &(String.downcase(&1.name) == name |> String.trim() |> String.downcase())) do
        %{} = status -> {:ok, status}
        nil -> {:error, {:invalid, :status, "is not one of: " <> Enum.map_join(statuses, ", ", & &1.name)}}
      end
    end
  end

  defp resolve_status(_scope, _issue, %{status: _not_a_name}), do: {:error, {:invalid, :status, "must be a status name"}}
  defp resolve_status(_scope, _issue, _attrs), do: {:ok, nil}

  defp resolve_cycle(%Issue{project: project}, %{cycle: cycle}) do
    wanted = cycle |> to_string() |> String.trim() |> String.downcase()
    {:ok, %{cycles: cycles}} = Issues.get_cycles(project)
    open = Enum.reject(cycles, &(&1.status == :ended))
    current_index = Enum.find_index(cycles, & &1.current)

    found =
      case {wanted, Integer.parse(wanted)} do
        {"none", _number} -> {:set, nil}
        {"current", _number} -> current_index && {:set, Enum.at(cycles, current_index).id}
        {"next", _number} -> next_cycle(cycles, current_index)
        {_named, {number, ""}} -> Enum.find_value(open, &(&1.number == number && {:set, &1.id}))
        _unknown -> nil
      end

    if found,
      do: {:ok, found},
      else:
        {:error,
         {:invalid, :cycle,
          "is not current, next, none or an open cycle's number: " <> Enum.map_join(open, ", ", &to_string(&1.number))}}
  end

  defp resolve_cycle(_issue, _attrs), do: {:ok, nil}

  defp next_cycle(cycles, current_index) when is_integer(current_index) do
    case Enum.at(cycles, current_index + 1) do
      %{id: id} -> {:set, id}
      nil -> nil
    end
  end

  defp next_cycle(_cycles, nil), do: nil

  defp resolve_assignee(scope, %Issue{} = issue, %{assignee: login}) when is_binary(login) do
    assignable = Users.list_assignable_users(project_id: issue.project_id, tracker: issue.tracker)
    wanted = login |> String.trim() |> String.downcase()

    found =
      cond do
        wanted == "" -> {:set, nil}
        wanted == "me" -> Enum.find_value(assignable, &(&1.id == scope.user.id && {:set, &1.id}))
        true -> Enum.find_value(assignable, &(String.downcase(&1.login || "") == wanted && {:set, &1.id}))
      end

    if found,
      do: {:ok, found},
      else: {:error, {:invalid, :assignee, "#{login} can't be assigned this ticket"}}
  end

  defp resolve_assignee(_scope, _issue, %{assignee: _not_a_login}),
    do: {:error, {:invalid, :assignee, "must be a GitHub login, me, or empty"}}

  defp resolve_assignee(_scope, _issue, _attrs), do: {:ok, nil}

  defp resolve_blockers(scope, %Issue{id: id} = issue, %{blocked_by: identifiers}) when is_list(identifiers) do
    found = Enum.map(identifiers, &{&1, find_in_project(scope, issue, &1)})

    blocks =
      issue |> List.wrap() |> Issues.get_blockers() |> Map.get(issue.external_id, %{blocks: []}) |> Map.get(:blocks)

    blocked_ids = for %{issue: %Issue{id: blocked_id}} <- blocks, do: blocked_id

    itself = for {identifier, %Issue{id: ^id}} <- found, do: identifier
    missing = for {identifier, nil} <- found, do: identifier

    reversed =
      for {_identifier, %Issue{id: blocker_id} = blocker} <- found, blocker_id in blocked_ids, do: blocker.identifier

    cond do
      itself != [] ->
        {:error, {:invalid, :blocked_by, "names this ticket itself: " <> Enum.join(itself, ", ")}}

      missing != [] ->
        {:error, {:invalid, :blocked_by, "names no ticket in this project: " <> Enum.join(missing, ", ")}}

      reversed != [] ->
        {:error, {:invalid, :blocked_by, "names tickets this one blocks: " <> Enum.join(reversed, ", ")}}

      true ->
        {:ok, Enum.map(found, &elem(&1, 1))}
    end
  end

  defp resolve_blockers(_scope, _issue, %{blocked_by: _not_a_list}),
    do: {:error, {:invalid, :blocked_by, "must be a list of identifiers"}}

  defp resolve_blockers(_scope, _issue, _attrs), do: {:ok, nil}

  defp find_in_project(scope, %Issue{project_id: project_id}, identifier) when is_binary(identifier) do
    case Issues.find_issue(scope, identifier) do
      {:ok, %Issue{project_id: ^project_id} = found} -> found
      _elsewhere -> nil
    end
  end

  defp find_in_project(_scope, _issue, _not_an_identifier), do: nil

  defp blank?(value), do: is_nil(value) or (is_binary(value) and String.trim(value) == "")
end
