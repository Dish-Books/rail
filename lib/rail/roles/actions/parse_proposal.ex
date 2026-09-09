defmodule Rail.Roles.Actions.ParseProposal do
  @moduledoc false

  alias Rail.Domain.Diff.TextLineDiff
  alias Rail.Roles.RoleInstructionProposal

  @start_marker "<<<INSTRUCTIONS>>>"
  @end_marker "<<<END INSTRUCTIONS>>>"

  def parse_proposal(output, role_id, chosen_model, current_prompt, sources, usage \\ %{})

  def parse_proposal(output, role_id, chosen_model, current_prompt, sources, usage)
      when is_binary(output) and is_binary(role_id) and is_binary(chosen_model) and is_binary(current_prompt) and
             is_list(sources) do
    case :binary.match(output, @start_marker) do
      :nomatch ->
        {:error, :no_marker_block}

      {start_idx, start_len} ->
        content_start = start_idx + start_len
        rest_len = byte_size(output) - content_start

        case :binary.match(binary_part(output, content_start, rest_len), @end_marker) do
          :nomatch ->
            {:error, :no_marker_block}

          {match_offset, end_len} ->
            raw_proposed = binary_part(output, content_start, match_offset)
            proposed = String.trim(raw_proposed)

            if proposed == "" do
              {:error, :no_marker_block}
            else
              before_text = String.trim(binary_part(output, 0, start_idx))
              after_start = content_start + match_offset + end_len
              after_len = byte_size(output) - after_start
              after_text = String.trim(binary_part(output, after_start, after_len))

              rationale =
                [before_text, after_text]
                |> Enum.reject(&(&1 == ""))
                |> Enum.join("\n\n")

              diff = TextLineDiff.diff(current_prompt, proposed, "instructions.md")

              proposal = %RoleInstructionProposal{
                role_id: role_id,
                model_id: chosen_model,
                current: current_prompt,
                proposed: proposed,
                rationale: rationale,
                diff: diff,
                sources: sources,
                usage: usage || %{}
              }

              {:ok, proposal}
            end
        end
    end
  end

  def parse_proposal(_output, _role_id, _chosen_model, _current_prompt, _sources, _usage) do
    {:error, :no_marker_block}
  end
end
