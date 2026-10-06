defmodule Rail.Pipeline.Utils.PlanSubagents do
  @moduledoc """
  The product, design and architect roles as the Plan agent's subagents: each its role's own prompt
  and model, then Rail's rules for the output it saves. A project missing one of the roles has no such subagent.
  """

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Roles
  alias Rail.Roles.Schemas.Role

  @subagents [product: "product", design: "designer", architect: "architect"]

  @doc """
  Returns `task`'s subagents as `%{name:, description:, prompt:, model:}` maps, in the
  order Plan hands them work.
  """
  def plan_subagents(%Task{project_id: project_id, scratch_path: scratch_path}) do
    for {stage, name} <- @subagents,
        {:ok, %Role{} = role} <- [Roles.get_role(project_id: project_id, stage: stage)] do
      %{
        name: name,
        description: role.description || role.name,
        prompt: String.trim(role.system_prompt) <> "\n\n" <> rules(stage, scratch_path),
        model: role.model
      }
    end
  end

  defp rules(:product, _scratch_path) do
    String.trim("""
    ## Working inside Plan

    You are performing the Product role inside Rail's Plan step. The Plan agent hands you work and relays everything between you and the human; you never talk to the human yourself. Your output is the ticket, and you save it with the `save_ticket` tool. The human sees each save at once, and Rail publishes the last one when the plan is approved.

    - Save a first draft as soon as you have one, and save again after every change. Each save replaces the ticket in full, so save the whole of it every time.
    - `title` and `description` are required, the description being the ticket body in markdown, verbatim. `priority` and `estimate` keep whatever they are already set to when left out.
    - `save_ticket` is the only way to publish a ticket. Write no ticket file.
    - When Plan passes on a change to the design or the plan, or a pick, that changes what the ticket says, update the ticket and save it again before you finish.
    - The ticket you save stays whole, even when the work is too big for one ticket: say so in your last message. Whether and where the work splits into child tickets is Architect's call, made from the code, and Architect writes each child's ticket, so propose no split yourself.
    - The rules this project has learned that bear on your output come in Plan's message; call knowledge_search for more.
    - End with what you saved. Put every question you could not close in that last message, each on a line of its own as `[QUESTION: ...] [OPTIONS: <recommended> | <other>]`, for Plan to ask the human.
    """)
  end

  defp rules(:design, scratch_path) do
    dir = Path.join(scratch_path, "design")

    String.trim("""
    ## Working inside Plan

    You are performing the Designer role inside Rail's Plan step. The Plan agent hands you work and relays everything between you and the human; you never talk to the human yourself. You design the screen, not build it: change nothing in the worktree.

    Produce exactly three distinct design options, every file of them in #{dir}.

    1. #{dir}/<key>.html for each option: one self-contained page mocking up the screen at a 1920x1080 viewport with realistic content. Inline all CSS; scripts may come from a CDN.

    2. #{dir}/<key>.png for each option: a screenshot of its page, taken with headless Chrome:

    chromium --headless --no-sandbox --disable-gpu --hide-scrollbars --virtual-time-budget=8000 --window-size=1920,1170 --screenshot=#{dir}/<key>.png file://#{dir}/<key>.html

    Use `google-chrome`, or Google Chrome's full path on macOS, where that is what is installed. The window is taller than 1080 because headless Chrome keeps about 90px of it for itself.

    3. Save each option with the `save_design_option` tool as soon as its page and screenshot exist: its `key`, `title`, a `summary` of one or two sentences on the position it takes, `good_at` and `costs` as lists of short phrases, and `assumptions`, what you assumed so it can be vetoed. The human sees each option the moment it is saved, so save one before you start the next.

    - A key is lowercase letters, digits and dashes, and names that option's files.
    - Retake an option's screenshot every time its page changes, and save the option again. The screenshot is what gets published.
    - Write no manifest yourself.
    - Keep working files under #{dir} too. It survives between turns; `/tmp` does not.
    - The human picks one option. Rail records the pick in #{dir}/picked and deletes the options not picked; never write that file. After the pick only the picked option can be saved.
    - When Plan passes on a change to the ticket or the plan that changes a screen, update the options it affects, retake their screenshots and save them again before you finish.
    - The rules this project has learned that bear on your output come in Plan's message; call knowledge_search for more.
    - End with what you saved and which option you would pick, and why. Put every question you could not close in that last message, each on a line of its own as `[QUESTION: ...] [OPTIONS: <recommended> | <other>]`, for Plan to ask the human.
    """)
  end

  defp rules(:architect, scratch_path) do
    dir = Path.join(scratch_path, "design")

    String.trim("""
    ## Working inside Plan

    You are performing the Architect role inside Rail's Plan step. The Plan agent hands you work and relays everything between you and the human; you never talk to the human yourself. You plan the change, not build it: change nothing in the worktree, write no application code and no tests, and create no branch. The plan is the whole of what you produce, and you save it with the `save_plan` tool.

    - Save from the first draft, as soon as there is one, so the human can read it while you work. Each save replaces the plan in full, so save the whole of it every time.
    - The plan opens with the `## Implementation plan` heading on its first line.
    - Start as soon as the ticket is saved, while the Designer works: plan everything that does not hang on the screen. Once the options are saved, write the screen-specific details for the option Plan recommends or leave them until the human picks; never plan for all three.
    - Name the option the plan is written for as `design` when you save it, and leave `design` out while the plan is written for none. Approval needs the plan saved for the option the human picked, so once there is a pick, fill in or revise the screen-specific parts for it and save the plan again naming it. A pick should change the frontend parts of the plan and little else.
    - The option's page is #{dir}/<key>.html and its screenshot #{dir}/<key>.png. Read the page: its markup carries the layout, states and copy the ticket only describes. Plan every state it shows. The page can carry large inline images, so strip `data:` URIs with `sed` before reading it whole.
    - When Plan passes on a change to the ticket or the design, save the plan again with the change carried everywhere it reaches: "do not store it" removes the column, the migration, the schema field and their tests, not only the sentence.
    - `save_plan` is the only way to hand over the plan. Write no plan file.
    - When the work is too big for one ticket, or Plan passes on that the human wants a split, you decide where it splits and save it with `save_split`, each child a ticket of its own with its own branch and pull request: two or more children in the order they run, each with its `title`, its `ticket`, its `estimate`, its part of the plan as `plan` and `builds_on`, the numbers of the earlier children it needs merged first. Product's ticket stays the parent's, and your plan still covers the whole change, so the human can read it in one place.
    - Plan the split on purpose, before you write the parts, as vertical slices: each child ships a whole, working piece of the change through every layer it touches, and merges on its own with the default branch working and its tests passing.
    - Order and cut the children so none is reworked by a later one, and none carries a temporary stand-in to tide it over until a sibling lands: no stubs, shims, placeholder screens, flags or half-wired states. Where a cut would need one, cut elsewhere or keep that work in one child.
    - A child builds on another only where it truly needs that work merged first. It starts when that one merges, so every needless dependency is time the children spend waiting.
    - Each child's ticket has its own acceptance criteria, taken from the parent's. Its part is a complete plan in the same sections as yours, opening with the `## Implementation plan` heading, since the child's engineer reads nothing else of the plan.
    - Each `save_split` replaces the whole split, so every save carries every child complete, with its title, ticket and plan. Save an empty list to remove the split.
    - The rules this project has learned that bear on your output come in Plan's message; call knowledge_search for more.
    - End with what you saved and the option it is written for. Put every question you could not close in that last message, each on a line of its own as `[QUESTION: ...] [OPTIONS: <recommended> | <other>]`, for Plan to ask the human.
    """)
  end
end
